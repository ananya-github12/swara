-- Round 5 M019: a non-Data-API, atomic workflow import boundary.
--
-- The authenticated Edge Function is responsible for deriving p_user_id from
-- verified claims.  This function is deliberately available only to the
-- dedicated API runtime role, never to browser/Data API roles.

begin;

-- pgcrypto is used solely for deterministic, server-side SHA-256 hashes.  Do
-- not pin extension versions: Supabase manages the supported default.
create extension if not exists pgcrypto with schema extensions;

-- Store only an idempotency digest and the durable result.  The definition is
-- intentionally not copied here, so retries cannot turn this ledger into a
-- second workflow-content store.
create table private.workflow_import_requests (
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null,
  input_hash text not null,
  workflow_id uuid not null,
  version_id uuid not null,
  content_hash text not null,
  step_count integer not null,
  correlation_id uuid not null,
  created_at timestamptz not null default pg_catalog.now(),

  constraint workflow_import_requests_pkey
    primary key (user_id, idempotency_key),
  constraint workflow_import_requests_idempotency_key_check
    check (
      idempotency_key = pg_catalog.btrim(idempotency_key)
      and pg_catalog.char_length(idempotency_key) between 8 and 200
      and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
    ),
  constraint workflow_import_requests_input_hash_check
    check (
      input_hash = pg_catalog.lower(input_hash)
      and input_hash ~ '^[0-9a-f]{64}$'
    ),
  constraint workflow_import_requests_content_hash_check
    check (
      content_hash = pg_catalog.lower(content_hash)
      and content_hash ~ '^[0-9a-f]{64}$'
    ),
  constraint workflow_import_requests_step_count_check
    check (step_count between 0 and 50),
  constraint workflow_import_requests_workflow_owner_fkey
    foreign key (workflow_id, user_id)
    references public.workflows (id, user_id)
    on delete cascade,
  constraint workflow_import_requests_version_owner_fkey
    foreign key (version_id, workflow_id, user_id)
    references public.workflow_versions (id, workflow_id, user_id)
    on delete cascade
);

alter table private.workflow_import_requests enable row level security;

revoke all privileges on table private.workflow_import_requests
  from public, anon, authenticated, service_role, swara_api_runtime;

create or replace function private.import_workflow_atomic(
  p_user_id uuid,
  p_workflow_id uuid,
  p_name text,
  p_schema_version integer,
  p_definition jsonb,
  p_expected_current_version_id uuid,
  p_idempotency_key text,
  p_correlation_id uuid
)
returns table (
  workflow_id uuid,
  version_id uuid,
  content_hash text,
  step_count integer,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_canonical_definition text;
  v_content_hash text;
  v_input_hash text;
  v_step_count integer;
  v_workflow_id uuid;
  v_current_version_id uuid;
  v_existing_owner_id uuid;
  v_version_id uuid;
  v_reused_version boolean := false;
  v_prior_input_hash text;
  v_prior_workflow_id uuid;
  v_prior_version_id uuid;
  v_prior_content_hash text;
  v_prior_step_count integer;
begin
  if p_user_id is null or p_correlation_id is null then
    raise exception using
      errcode = '22023',
      message = 'Workflow import requires owner and correlation identifiers';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Workflow import idempotency key is invalid';
  end if;

  -- JSONB emits its canonical textual representation.  The operation digest
  -- includes every semantic import input except correlation_id, which is an
  -- observability value and may legitimately change on a safe retry.
  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'workflow_id', p_workflow_id,
          'name', p_name,
          'schema_version', p_schema_version,
          'definition', p_definition,
          'expected_current_version_id', p_expected_current_version_id
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  -- Serialize same-key calls before consulting the durable ledger.  This is
  -- separate from the owner/workflow lock below because create requests do
  -- not have a workflow ID until after their first successful execution.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-workflow-import-key:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select
    request.input_hash,
    request.workflow_id,
    request.version_id,
    request.content_hash,
    request.step_count
  into
    v_prior_input_hash,
    v_prior_workflow_id,
    v_prior_version_id,
    v_prior_content_hash,
    v_prior_step_count
  from private.workflow_import_requests as request
  where request.user_id = p_user_id
    and request.idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Idempotency key is already bound to a different workflow import';
    end if;

    return query
    select
      v_prior_workflow_id,
      v_prior_version_id,
      v_prior_content_hash,
      v_prior_step_count,
      true;
    return;
  end if;

  if p_name is null
     or p_name <> pg_catalog.btrim(p_name)
     or pg_catalog.char_length(p_name) not between 1 and 120
     or p_name ~ '[[:cntrl:]]' then
    raise exception using
      errcode = '22023',
      message = 'Workflow name is invalid';
  end if;

  if p_schema_version is null or p_schema_version not between 1 and 1000000 then
    raise exception using
      errcode = '22023',
      message = 'Workflow schema version is invalid';
  end if;

  if pg_catalog.jsonb_typeof(p_definition) is distinct from 'object'
     or p_definition = '{}'::jsonb then
    raise exception using
      errcode = '22023',
      message = 'Workflow definition must be a non-empty JSON object';
  end if;

  if not (p_definition ? 'steps')
     or pg_catalog.jsonb_typeof(p_definition -> 'steps') is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message = 'Workflow definition must contain a steps array';
  end if;

  v_canonical_definition := p_definition::text;

  if pg_catalog.octet_length(v_canonical_definition) > 262144 then
    raise exception using
      errcode = '22023',
      message = 'Workflow definition exceeds the permitted size';
  end if;

  v_step_count := pg_catalog.jsonb_array_length(p_definition -> 'steps');
  if v_step_count > 50 then
    raise exception using
      errcode = '22023',
      message = 'Workflow definition exceeds the permitted step count';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_definition -> 'steps') as step(value)
    where pg_catalog.jsonb_typeof(step.value) is distinct from 'object'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Workflow steps must be JSON objects';
  end if;

  -- The insert below deliberately fires private.validate_workflow_version(),
  -- which rejects persisted secrets and sensitive defaults without echoing the
  -- definition.  This function does not duplicate or bypass that validator.
  v_content_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(v_canonical_definition, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  if not exists (
    select 1
    from auth.users as account
    where account.id = p_user_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Workflow owner is not available';
  end if;

  if p_workflow_id is null then
    if p_expected_current_version_id is not null then
      raise exception using
        errcode = '22023',
        message = 'Expected current version is only valid for an existing workflow';
    end if;
    v_workflow_id := pg_catalog.gen_random_uuid();
  else
    v_workflow_id := p_workflow_id;
  end if;

  -- Hold a transaction-scoped owner/workflow lock before inspecting or
  -- updating the current-version pointer.  Hash collisions only serialize
  -- unrelated imports; they cannot grant access or alter correctness.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-workflow-owner:' || p_user_id::text || ':' || v_workflow_id::text,
      8072026::bigint
    )
  );

  if p_workflow_id is null then
    insert into public.workflows (id, user_id, name)
    values (v_workflow_id, p_user_id, p_name);
    v_current_version_id := null;
  else
    select workflow.user_id, workflow.current_version_id
      into v_existing_owner_id, v_current_version_id
      from public.workflows as workflow
     where workflow.id = v_workflow_id
     for update;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'Workflow is not available';
    end if;

    if v_existing_owner_id is distinct from p_user_id then
      raise exception using
        errcode = '42501',
        message = 'Workflow is not available';
    end if;

    if p_expected_current_version_id is not null
       and v_current_version_id is distinct from p_expected_current_version_id then
      raise exception using
        errcode = '40001',
        message = 'Workflow version conflict';
    end if;
  end if;

  v_version_id := null;
  insert into public.workflow_versions (
    workflow_id,
    user_id,
    schema_version,
    definition,
    content_hash
  )
  values (
    v_workflow_id,
    p_user_id,
    p_schema_version,
    p_definition,
    v_content_hash
  )
  on conflict on constraint workflow_versions_user_id_workflow_id_content_hash_key do nothing
  returning id into v_version_id;

  if v_version_id is null then
    select version.id
      into v_version_id
      from public.workflow_versions as version
     where version.user_id = p_user_id
       and version.workflow_id = v_workflow_id
       and version.content_hash = v_content_hash;
    v_reused_version := true;
  end if;

  update public.workflows as workflow
     set name = p_name,
         current_version_id = v_version_id,
         step_count = v_step_count
   where workflow.id = v_workflow_id
     and workflow.user_id = p_user_id;

  insert into private.workflow_import_requests (
    user_id,
    idempotency_key,
    input_hash,
    workflow_id,
    version_id,
    content_hash,
    step_count,
    correlation_id
  )
  values (
    p_user_id,
    p_idempotency_key,
    v_input_hash,
    v_workflow_id,
    v_version_id,
    v_content_hash,
    v_step_count,
    p_correlation_id
  );

  return query
  select
    v_workflow_id,
    v_version_id,
    v_content_hash,
    v_step_count,
    v_reused_version;
end;
$function$;

-- Function ownership defaults to the migration owner.  Keep the invoker
-- surface narrow even if role defaults change in a future Supabase release.
revoke all privileges on function private.import_workflow_atomic(
  uuid, uuid, text, integer, jsonb, uuid, text, uuid
) from public, anon, authenticated, service_role;

grant usage on schema private to swara_api_runtime;
grant execute on function private.import_workflow_atomic(
  uuid, uuid, text, integer, jsonb, uuid, text, uuid
) to swara_api_runtime;

comment on table private.workflow_import_requests is
  'Private idempotency ledger for atomic workflow imports; it stores only hashes and durable result identifiers.';

comment on function private.import_workflow_atomic(
  uuid, uuid, text, integer, jsonb, uuid, text, uuid
) is
  'Private, atomic workflow import. Caller must derive p_user_id from verified Swara authentication; only swara_api_runtime may execute it.';

commit;
