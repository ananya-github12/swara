-- Round 5 / M023: security review fixes for runtime boundaries, workflows,
-- lifecycle work, Vault uploads, and Alterity webhook replay handling.
--
-- This migration deliberately does not create, move, read, write, or delete
-- legacy `documents` Storage objects.  It only removes obsolete RLS policies
-- that exposed that legacy bucket to browser roles.

begin;

-- M020 uses the conditional PGMQ read overload introduced in PGMQ 1.5.1.
-- Fail before changing any state on an older project rather than accepting a
-- queue gateway that will fail at runtime or weakening it to direct PGMQ.
do $preflight$
begin
  if pg_catalog.to_regprocedure('pgmq.read(text,integer,integer,jsonb)') is null then
    raise exception using
      errcode = '55000',
      message = 'M023 requires PGMQ 1.5.1 conditional read(text,integer,integer,jsonb)';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_roles
     where rolname = 'swara_api_runtime'
  ) or not exists (
    select 1
      from pg_catalog.pg_roles
     where rolname = 'swara_worker_runtime'
  ) then
    raise exception using
      errcode = '55000',
      message = 'M023 requires the M018 Swara runtime permission groups';
  end if;

  if exists (
    select 1
      from pg_catalog.pg_roles as runtime_role
     where runtime_role.rolname in ('swara_api_runtime', 'swara_worker_runtime')
       and (
         runtime_role.rolcanlogin
         or runtime_role.rolsuper
         or runtime_role.rolcreatedb
         or runtime_role.rolcreaterole
         or runtime_role.rolreplication
         or runtime_role.rolbypassrls
         or runtime_role.rolinherit
       )
  ) then
    raise exception using
      errcode = '55000',
      message = 'Swara runtime permission groups must remain NOLOGIN NOINHERIT and non-privileged';
  end if;

  -- A runtime group may be granted *to* a separately provisioned login, but
  -- it must never itself be a member of an upstream role with extra rights.
  if exists (
    select 1
      from pg_catalog.pg_auth_members as membership
      join pg_catalog.pg_roles as member_role
        on member_role.oid = membership.member
     where member_role.rolname in ('swara_api_runtime', 'swara_worker_runtime')
  ) then
    raise exception using
      errcode = '55000',
      message = 'Swara runtime permission groups must not inherit membership from another role';
  end if;
end;
$preflight$;

-- M022 closed the Data API workflow write path.  Repeat that final boundary
-- here because the import gateway below is the only permissible mutation
-- path and must remain true when this migration is replayed from scratch.
revoke all privileges on table public.workflows, public.workflow_versions
  from public, anon, authenticated, service_role,
       swara_api_runtime, swara_worker_runtime;
grant select on table public.workflows, public.workflow_versions to authenticated;
drop policy if exists workflows_insert_own on public.workflows;
drop policy if exists workflows_update_own on public.workflows;
drop policy if exists workflows_delete_own on public.workflows;
drop policy if exists workflow_versions_insert_own on public.workflow_versions;

-- Check every sibling label independently.  In particular, a harmless
-- fieldId must not mask a dangerous name/label/type field in the same JSON
-- object.  Error messages retain only a JSON path and reason, never a value.
create or replace function private.validate_workflow_version()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  violation_path text;
  violation_reason text;
begin
  if tg_op = 'UPDATE' then
    raise exception using
      errcode = '55000',
      message = 'Workflow versions are immutable';
  end if;

  if pg_catalog.jsonb_typeof(new.definition) is distinct from 'object'
     or new.definition = '{}'::jsonb then
    raise exception using
      errcode = '22023',
      message = 'Workflow definitions must be non-empty JSON objects';
  end if;

  with recursive workflow_nodes(path, key_name, value) as (
    select array[]::text[], null::text, new.definition

    union all

    select
      workflow_nodes.path || child.path_segment,
      child.key_name,
      child.value
    from workflow_nodes
    cross join lateral (
      select object_entry.key, object_entry.key, object_entry.value
      from pg_catalog.jsonb_each(
        case
          when pg_catalog.jsonb_typeof(workflow_nodes.value) = 'object'
            then workflow_nodes.value
          else '{}'::jsonb
        end
      ) as object_entry(key, value)

      union all

      select array_entry.ordinality::text, null::text, array_entry.value
      from pg_catalog.jsonb_array_elements(
        case
          when pg_catalog.jsonb_typeof(workflow_nodes.value) = 'array'
            then workflow_nodes.value
          else '[]'::jsonb
        end
      ) with ordinality as array_entry(value, ordinality)
    ) as child(path_segment, key_name, value)
  ),
  violations as (
    select
      coalesce(nullif(pg_catalog.array_to_string(path, '.'), ''), '$') as path,
      case
        when key_name is not null
          and pg_catalog.lower(key_name) ~
            '(password|passwd|passcode|one.?time.?passcode|(^|[^a-z0-9])otp([^a-z0-9]|$)|api.?key|access.?token|refresh.?token|id.?token|auth.?token|authorization|bearer.?token|secret|private.?key|session.?cookie|cookie|card.?number|credit.?card|debit.?card|cvv|cvc|social.?security|ssn)'
          and not (
            pg_catalog.jsonb_typeof(value) = 'string'
            and (value #>> '{}') ~ '^\\{\\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\\}\\}$'
          )
          then 'secret-bearing key'

        when pg_catalog.jsonb_typeof(value) = 'object'
          and value @> '{"sensitive": true}'::jsonb
          and (value ? 'defaultValue' or value ? 'default_value' or value ? 'default')
          then 'sensitive variable default'

        -- Do not use COALESCE here.  Every available sibling label is a
        -- security signal; any sensitive label makes a literal value unsafe.
        when pg_catalog.jsonb_typeof(value) = 'object'
          and exists (
            select 1
              from pg_catalog.unnest(
                array['fieldId', 'field_id', 'key', 'name', 'label', 'type']::text[]
              ) as label_key(name)
             where pg_catalog.lower(
                     coalesce(value ->> label_key.name, '')
                   ) ~
                   '(password|passwd|passcode|one.?time.?passcode|(^|[^a-z0-9])otp([^a-z0-9]|$)|api.?key|access.?token|refresh.?token|id.?token|auth.?token|authorization|bearer.?token|secret|private.?key|session.?cookie|cookie|card.?number|credit.?card|debit.?card|cvv|cvc|social.?security|ssn)'
          )
          and (
            (
              value ? 'value'
              and coalesce(value ->> 'value', '') !~ '^\\{\\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\\}\\}$'
            )
            or (
              (value ? 'defaultValue' or value ? 'default_value' or value ? 'default')
              and coalesce(
                value ->> 'defaultValue',
                value ->> 'default_value',
                value ->> 'default',
                ''
              ) !~ '^\\{\\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\\}\\}$'
            )
          )
          then 'sensitive field default or value'

        when pg_catalog.jsonb_typeof(value) = 'string'
          and (value #>> '{}') !~ '^\\{\\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\\}\\}$'
          and (
            (value #>> '{}') ~* '-----BEGIN( [A-Z]+)? PRIVATE KEY-----'
            or (value #>> '{}') ~* '(^|[^A-Za-z0-9])(sk|pk|api)[_-][A-Za-z0-9_-]{12,}($|[^A-Za-z0-9_-])'
            or (value #>> '{}') ~* '(^|[^A-Za-z0-9])bearer[[:space:]]+[A-Za-z0-9._~-]{8,}'
            or (value #>> '{}') ~* '(password|passwd|passcode|one.?time.?passcode|otp|api.?key|access.?token|refresh.?token|auth.?token|secret|authorization|cookie|session.?cookie|card.?number|credit.?card|debit.?card|cvv|cvc)[[:space:]]*[:=][[:space:]]*[^[:space:]]+'
            or (value #>> '{}') ~* '(session|sid|auth|token)[A-Za-z0-9_.-]*[[:space:]]*=[[:space:]]*[^;[:space:]]+'
            or (value #>> '{}') ~ '(^|[^0-9])([0-9][[:space:]-]?){11,17}[0-9]($|[^0-9])'
            or (value #>> '{}') ~ '^[0-9]{6,8}$'
            or (value #>> '{}') ~ '^eyJ[A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]{8,}$'
          )
          then 'secret-like literal'
      end as reason
    from workflow_nodes
  )
  select path, reason
    into violation_path, violation_reason
    from violations
   where reason is not null
   limit 1;

  if found then
    raise exception using
      errcode = '22023',
      message = 'Workflow definitions cannot contain persisted secrets or sensitive defaults',
      detail = 'Blocked content at JSON path ' || violation_path || ' (' || violation_reason || ')';
  end if;

  return new;
end;
$function$;

-- Retain the public signature for deterministic test callers, but use only
-- the database clock for eligibility and lease construction.  A caller may
-- not advance p_as_of more than a tiny clock-skew allowance to claim work
-- that is not yet expired.
create or replace function private.claim_expired_task_artifacts(
  p_limit integer default 100,
  p_lease_seconds integer default 300,
  p_as_of timestamptz default pg_catalog.now()
)
returns table (
  artifact_id uuid,
  user_id uuid,
  task_id uuid,
  artifact_type text,
  storage_bucket text,
  storage_path text,
  content_hash text,
  lease_token uuid,
  lease_expires_at timestamptz,
  attempt_count integer
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge claim limit must be between 1 and 100';
  end if;

  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 3600 then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge lease must be between 30 and 3600 seconds';
  end if;

  if p_as_of is null
     or p_as_of > v_now + interval '1 second' then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge claim time is outside the permitted clock skew';
  end if;

  return query
  with candidates as (
    select artifact.id
      from private.task_artifacts as artifact
     where artifact.expires_at <= v_now
       and (
         artifact.status = 'pending'
         or (
           artifact.status = 'leased'
           and artifact.lease_expires_at <= v_now
         )
       )
     order by artifact.expires_at asc, artifact.id asc
     limit p_limit
     for update skip locked
  ), claimed as (
    update private.task_artifacts as artifact
       set status = 'leased',
           lease_token = pg_catalog.gen_random_uuid(),
           lease_expires_at = v_now + (p_lease_seconds * interval '1 second'),
           attempt_count = artifact.attempt_count + 1,
           last_error_code = null
      from candidates
     where artifact.id = candidates.id
    returning
      artifact.id,
      artifact.user_id,
      artifact.task_id,
      artifact.artifact_type,
      artifact.storage_bucket,
      artifact.storage_path,
      artifact.content_hash,
      artifact.lease_token,
      artifact.lease_expires_at,
      artifact.attempt_count,
      artifact.expires_at
  )
  select
    claimed.id,
    claimed.user_id,
    claimed.task_id,
    claimed.artifact_type,
    claimed.storage_bucket,
    claimed.storage_path,
    claimed.content_hash,
    claimed.lease_token,
    claimed.lease_expires_at,
    claimed.attempt_count
  from claimed
  order by claimed.expires_at asc, claimed.id asc;
end;
$function$;

create or replace function private.complete_task_artifact_purge(
  p_artifact_id uuid,
  p_lease_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_completed boolean := false;
begin
  if p_artifact_id is null or p_lease_token is null then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge completion requires artifact and lease identifiers';
  end if;

  update private.task_artifacts as artifact
     set status = 'completed',
         lease_token = null,
         lease_expires_at = null,
         completed_at = pg_catalog.clock_timestamp(),
         last_error_code = null
   where artifact.id = p_artifact_id
     and artifact.status = 'leased'
     and artifact.lease_token = p_lease_token
     and artifact.lease_expires_at > pg_catalog.clock_timestamp()
  returning true into v_completed;

  return coalesce(v_completed, false);
end;
$function$;

create or replace function private.fail_task_artifact_purge(
  p_artifact_id uuid,
  p_lease_token uuid,
  p_error_code text,
  p_terminal boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_failed boolean := false;
begin
  if p_artifact_id is null or p_lease_token is null then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge failure requires artifact and lease identifiers';
  end if;

  if p_terminal is null then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge terminal flag is required';
  end if;

  if p_error_code is null
     or p_error_code <> pg_catalog.lower(pg_catalog.btrim(p_error_code))
     or pg_catalog.char_length(p_error_code) not between 1 and 128
     or p_error_code !~ '^[a-z0-9][a-z0-9_.:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Artifact purge error code is invalid';
  end if;

  update private.task_artifacts as artifact
     set status = case when p_terminal then 'failed' else 'pending' end,
         lease_token = null,
         lease_expires_at = null,
         completed_at = case when p_terminal then pg_catalog.clock_timestamp() else null end,
         last_error_code = p_error_code
   where artifact.id = p_artifact_id
     and artifact.status = 'leased'
     and artifact.lease_token = p_lease_token
     and artifact.lease_expires_at > pg_catalog.clock_timestamp()
  returning true into v_failed;

  return coalesce(v_failed, false);
end;
$function$;

-- M016's historical constraints were intentionally broad.  Add a narrower
-- final constraint instead of rewriting legacy rows; a reset or deployment
-- fails closed if pre-existing data does not satisfy the queue contract.
alter table private.account_export_requests
  add constraint account_export_requests_swara_idempotency_key_check
  check (
    idempotency_key = pg_catalog.btrim(idempotency_key)
    and pg_catalog.char_length(idempotency_key) between 8 and 160
    and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
  );

alter table private.account_deletion_requests
  add constraint account_deletion_requests_swara_idempotency_key_check
  check (
    idempotency_key = pg_catalog.btrim(idempotency_key)
    and pg_catalog.char_length(idempotency_key) between 8 and 160
    and idempotency_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
  );

-- Only one non-terminal deletion job may exist for an account.  A terminal
-- request can be retried with a new key, while a same-key retry always
-- recovers its original durable result first.
create unique index account_deletion_requests_one_active_user_uidx
  on private.account_deletion_requests (user_id)
  where status in ('requested', 'export_pending', 'revoking', 'deleting');

create or replace function private.request_account_export(
  p_user_id uuid,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_request_id uuid;
  v_correlation_id uuid;
  v_queue_message_id bigint;
begin
  if p_user_id is null
     or p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 160
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Account export request input is invalid';
  end if;

  if pg_catalog.to_regprocedure('private.enqueue_job(text,jsonb,integer)') is null then
    raise exception using
      errcode = '55000',
      message = 'Account export queue gateway is not available';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-account-export:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  -- Recover before checking the current account state.  A user who has since
  -- been deleted must still receive the same durable idempotent result.
  select request.id, request.correlation_id, request.queue_message_id
    into v_request_id, v_correlation_id, v_queue_message_id
    from private.account_export_requests as request
   where request.user_id = p_user_id
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_queue_message_id is not null then
      return v_request_id;
    end if;
  else
    perform private.ensure_account_active(p_user_id);

    insert into private.account_export_requests (user_id, idempotency_key)
    values (p_user_id, p_idempotency_key);

    select request.id, request.correlation_id, request.queue_message_id
      into v_request_id, v_correlation_id, v_queue_message_id
      from private.account_export_requests as request
     where request.user_id = p_user_id
       and request.idempotency_key = p_idempotency_key
     for update;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Account export request could not be recovered';
    end if;
  end if;

  -- A prior M021 request can be durably present without an acknowledgement
  -- only after an interrupted/manual recovery.  Preserve the same-key result
  -- while atomically restoring its missing queue handoff in this transaction.

  select private.enqueue_job(
    'account-export',
    pg_catalog.jsonb_build_object(
      'schema_version', 1,
      'job_type', 'account_export',
      'job_id', v_request_id,
      'idempotency_key', p_idempotency_key,
      'correlation_id', v_correlation_id
    ),
    0
  ) into v_queue_message_id;

  if v_queue_message_id is null or v_queue_message_id <= 0 then
    raise exception using
      errcode = '55000',
      message = 'Account export queue did not accept the request';
  end if;

  update private.account_export_requests
     set queue_message_id = v_queue_message_id,
         queue_enqueued_at = pg_catalog.clock_timestamp()
   where id = v_request_id
     and user_id = p_user_id
     and queue_message_id is null;

  insert into audit.events (user_id, event_type, actor_type, subject_hash, correlation_id, metadata)
  values (
    p_user_id,
    'account_export_queued',
    'service',
    null,
    v_correlation_id,
    pg_catalog.jsonb_build_object(
      'request_id', v_request_id,
      'queue_message_id', v_queue_message_id
    )
  );

  return v_request_id;
end;
$function$;

create or replace function private.request_account_deletion(
  p_user_id uuid,
  p_idempotency_key text,
  p_export_request_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_account_status text;
  v_request_id uuid;
  v_existing_export_request_id uuid;
  v_correlation_id uuid;
  v_queue_message_id bigint;
  v_active_request_id uuid;
begin
  if p_user_id is null
     or p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 160
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Account deletion request input is invalid';
  end if;

  if pg_catalog.to_regprocedure('private.enqueue_job(text,jsonb,integer)') is null then
    raise exception using
      errcode = '55000',
      message = 'Account deletion queue gateway is not available';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-account-deletion:' || p_user_id::text,
      8072026::bigint
    )
  );

  -- Same-key recovery precedes account-state validation so an already deleted
  -- account cannot turn a prior accepted request into an indeterminate retry.
  select
    request.id,
    request.export_request_id,
    request.correlation_id,
    request.queue_message_id
  into
    v_request_id,
    v_existing_export_request_id,
    v_correlation_id,
    v_queue_message_id
  from private.account_deletion_requests as request
  where request.user_id = p_user_id
    and request.idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_existing_export_request_id is distinct from p_export_request_id then
      raise exception using
        errcode = '22023',
        message = 'Account deletion idempotency key is bound to a different export request';
    end if;

    if v_queue_message_id is not null then
      return v_request_id;
    end if;
  else
    select request.id
      into v_active_request_id
      from private.account_deletion_requests as request
     where request.user_id = p_user_id
       and request.status in ('requested', 'export_pending', 'revoking', 'deleting')
     order by request.requested_at asc, request.id asc
     limit 1
     for update;

    if found then
      raise exception using
        errcode = '55000',
        message = 'Account deletion already has an active request';
    end if;

    insert into private.account_states (user_id, status, deletion_requested_at)
    values (p_user_id, 'deleting', pg_catalog.clock_timestamp())
    on conflict (user_id) do update
       set status = 'deleting',
           deletion_requested_at = coalesce(
             private.account_states.deletion_requested_at,
             pg_catalog.clock_timestamp()
           )
     where private.account_states.status <> 'deleted'
    returning status into v_account_status;

    if v_account_status is null then
      select account_state.status
        into v_account_status
        from private.account_states as account_state
       where account_state.user_id = p_user_id
       for update;
    end if;

    if v_account_status is distinct from 'deleting' then
      raise exception using
        errcode = '55000',
        message = 'Account deletion is not available for this account state';
    end if;

    insert into private.account_deletion_requests (
      user_id,
      export_request_id,
      status,
      idempotency_key
    )
    values (
      p_user_id,
      p_export_request_id,
      case when p_export_request_id is null then 'requested' else 'export_pending' end,
      p_idempotency_key
    );

    select
      request.id,
      request.correlation_id,
      request.queue_message_id
    into
      v_request_id,
      v_correlation_id,
      v_queue_message_id
    from private.account_deletion_requests as request
    where request.user_id = p_user_id
      and request.idempotency_key = p_idempotency_key
    for update;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Account deletion request could not be recovered';
    end if;
  end if;

  -- See request_account_export: a same-key recovery may repair only a
  -- missing queue acknowledgement, never a user/idempotency/correlation field.

  select private.enqueue_job(
    'account-deletion',
    pg_catalog.jsonb_build_object(
      'schema_version', 1,
      'job_type', 'account_deletion',
      'job_id', v_request_id,
      'idempotency_key', p_idempotency_key,
      'correlation_id', v_correlation_id
    ),
    0
  ) into v_queue_message_id;

  if v_queue_message_id is null or v_queue_message_id <= 0 then
    raise exception using
      errcode = '55000',
      message = 'Account deletion queue did not accept the request';
  end if;

  update private.account_deletion_requests
     set queue_message_id = v_queue_message_id,
         queue_enqueued_at = pg_catalog.clock_timestamp()
   where id = v_request_id
     and user_id = p_user_id
     and queue_message_id is null;

  insert into audit.events (user_id, event_type, actor_type, subject_hash, correlation_id, metadata)
  values (
    p_user_id,
    'account_deletion_queued',
    'service',
    null,
    v_correlation_id,
    pg_catalog.jsonb_build_object(
      'request_id', v_request_id,
      'queue_message_id', v_queue_message_id,
      'export_request_id', p_export_request_id
    )
  );

  return v_request_id;
end;
$function$;

-- Worker account transitions are column-scoped.  Queue correlation and
-- ownership/idempotency data remain write-once at the API transaction edge.
revoke update on table
  private.account_states,
  private.account_export_requests,
  private.account_deletion_requests
  from swara_worker_runtime;

grant update (status, deleted_at)
  on table private.account_states to swara_worker_runtime;
grant update (
  status,
  storage_path,
  started_at,
  completed_at,
  expires_at,
  error_code,
  error_message
) on table private.account_export_requests to swara_worker_runtime;
grant update (
  status,
  started_at,
  completed_at,
  error_code,
  error_message
) on table private.account_deletion_requests to swara_worker_runtime;

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

  -- Idempotency comes first so a completed request is still a safe retry
  -- even if a later import has moved the workflow's current-version pointer.
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

  v_content_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(v_canonical_definition, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  if not exists (
    select 1 from auth.users as account where account.id = p_user_id
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

    -- Existing workflows must always use optimistic concurrency.  A NULL
    -- expected version is accepted only for a create request above.
    if p_expected_current_version_id is null
       or v_current_version_id is distinct from p_expected_current_version_id then
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
  select v_workflow_id, v_version_id, v_content_hash, v_step_count, v_reused_version;
end;
$function$;

-- Serialize same task/batch-sequence checkpoints before testing either the
-- sequence-to-batch or batch-to-sequence invariant.  The required sequence
-- key closes same-sequence races; the second, ordered batch key closes the
-- complementary same-batch/different-sequence empty-table race.  Both keys
-- are stable and carry no browser content.
create or replace function private.validate_task_step_checkpoint()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  task_user_id uuid;
  task_max_steps integer;
begin
  if new.user_id is null
     or new.task_id is null
     or new.sequence is null
     or new.sequence < 1
     or new.action_index is null
     or new.action_index < 0 then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoints require an owner, task, positive batch sequence, and non-negative action index';
  end if;

  if new.batch_id is null and new.action_index <> 0 then
    raise exception using
      errcode = '23514',
      message = 'A non-zero action index requires a browser batch identifier';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-task-step-sequence:' || new.user_id::text || ':'
        || new.task_id::text || ':' || new.sequence::text,
      8072026::bigint
    )
  );

  if new.batch_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'swara-task-step-batch:' || new.user_id::text || ':'
          || new.task_id::text || ':' || new.batch_id::text,
        8072026::bigint
      )
    );
  end if;

  select task.user_id, task.max_steps
    into task_user_id, task_max_steps
    from private.agent_tasks as task
    join private.browser_sessions as session
      on session.id = task.session_id
     and session.user_id = task.user_id
   where task.id = new.task_id;

  if not found or task_user_id is distinct from new.user_id then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint ownership does not match its task session';
  end if;

  if task_max_steps is not null and new.sequence > task_max_steps then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint exceeds the task step limit';
  end if;

  if new.batch_id is not null and exists (
    select 1
      from private.task_steps as existing
     where existing.user_id = new.user_id
       and existing.task_id = new.task_id
       and existing.batch_id = new.batch_id
       and existing.sequence <> new.sequence
  ) then
    raise exception using
      errcode = '23514',
      message = 'A browser batch cannot span multiple task sequences';
  end if;

  if exists (
    select 1
      from private.task_steps as existing
     where existing.user_id = new.user_id
       and existing.task_id = new.task_id
       and existing.sequence = new.sequence
       and existing.batch_id is distinct from new.batch_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'A task sequence cannot combine different browser batches';
  end if;

  if new.sequence > 1 and not exists (
    select 1
      from private.task_steps as prior
     where prior.task_id = new.task_id
       and prior.user_id = new.user_id
       and prior.sequence = new.sequence - 1
       and prior.batch_id is not null
  ) then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint batches must be written in sequence order';
  end if;

  if tg_op = 'UPDATE' and (
       new.user_id is distinct from old.user_id
    or new.task_id is distinct from old.task_id
    or new.sequence is distinct from old.sequence
    or new.batch_id is distinct from old.batch_id
    or new.action_index is distinct from old.action_index
  ) then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint identity, batch, sequence, and action index are immutable';
  end if;

  return new;
end;
$function$;

-- Browser context remains append-only.  Corrections must create a currently
-- active replacement; they cannot insert a deleted/superseded replacement.
drop policy if exists context_items_insert_own on public.swara_context_items;
create policy context_items_insert_own
  on public.swara_context_items
  for insert
  to authenticated
  with check (
    (select auth.uid()) = user_id
    and status = 'active'
    and version >= 1
    and (
      (version = 1 and supersedes_id is null)
      or (version > 1 and supersedes_id is not null)
    )
  );

create or replace function private.validate_context_item_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  prior_user_id uuid;
  prior_version bigint;
  prior_key text;
  prior_scope text;
  prior_status text;
  prior_browser_session_id uuid;
  prior_task_id uuid;
begin
  if new.version is null or new.version < 1 then
    raise exception using
      errcode = '23514',
      message = 'Context item versions must be positive';
  end if;

  if new.version = 1 then
    if new.supersedes_id is not null then
      raise exception using
        errcode = '23514',
        message = 'The first context item version cannot supersede a row';
    end if;
    return new;
  end if;

  if new.status is distinct from 'active' then
    raise exception using
      errcode = '23514',
      message = 'Context correction inserts must begin active';
  end if;

  if new.supersedes_id is null then
    raise exception using
      errcode = '23514',
      message = 'A corrected context item must supersede a prior version';
  end if;

  select
    context.user_id,
    context.version,
    context.key,
    context.scope,
    context.status,
    context.browser_session_id,
    context.task_id
  into
    prior_user_id,
    prior_version,
    prior_key,
    prior_scope,
    prior_status,
    prior_browser_session_id,
    prior_task_id
  from public.swara_context_items as context
  where context.id = new.supersedes_id;

  if not found
     or prior_user_id is distinct from new.user_id
     or prior_version is distinct from new.version - 1
     or prior_key is distinct from new.key
     or prior_scope is distinct from new.scope
     or prior_status is distinct from 'active'
     or prior_browser_session_id is distinct from new.browser_session_id
     or prior_task_id is distinct from new.task_id then
    raise exception using
      errcode = '23514',
      message = 'Context corrections must retain the prior row owner and temporary scope';
  end if;

  update public.swara_context_items
     set status = 'superseded'
   where id = new.supersedes_id;

  return new;
end;
$function$;

-- The envelope deliberately remains the closed five-field M020 contract.
-- Rather than placing p_max_items in a message, Cron must provide the exact
-- reviewed operation maximum so workers can infer the bound from job_type.
create or replace function private.enqueue_maintenance_dispatch(
  p_queue_name text,
  p_operation text,
  p_max_items integer,
  p_interval_seconds integer
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_expected_queue_name text;
  v_expected_interval_seconds integer;
  v_max_allowed_items integer;
  v_window_start timestamptz;
  v_idempotency_key text;
  v_job_digest text;
  v_correlation_digest text;
  v_job_id uuid;
  v_correlation_id uuid;
begin
  case p_operation
    when 'retry_due_billing_outbox' then
      v_expected_queue_name := 'billing-outbox';
      v_expected_interval_seconds := 60;
      v_max_allowed_items := 50;
    when 'release_expired_usage_reservations' then
      v_expected_queue_name := 'usage-reconciliation';
      v_expected_interval_seconds := 300;
      v_max_allowed_items := 100;
    when 'detect_stuck_vault_ingestion' then
      v_expected_queue_name := 'vault-ingest';
      v_expected_interval_seconds := 600;
      v_max_allowed_items := 50;
    when 'refresh_near_expiry_entitlements' then
      v_expected_queue_name := 'billing-outbox';
      v_expected_interval_seconds := 900;
      v_max_allowed_items := 50;
    when 'purge_expired_task_artifacts' then
      v_expected_queue_name := 'artifact-retention';
      v_expected_interval_seconds := 3600;
      v_max_allowed_items := 100;
    when 'reconcile_usage' then
      v_expected_queue_name := 'usage-reconciliation';
      v_expected_interval_seconds := 86400;
      v_max_allowed_items := 100;
    when 'cleanup_expired_account_exports' then
      v_expected_queue_name := 'account-export';
      v_expected_interval_seconds := 86400;
      v_max_allowed_items := 100;
    else
      raise exception using
        errcode = '22023',
        message = 'Unknown Swara maintenance dispatch operation';
  end case;

  if p_queue_name is distinct from v_expected_queue_name
     or p_interval_seconds is distinct from v_expected_interval_seconds
     or p_max_items is distinct from v_max_allowed_items then
    raise exception using
      errcode = '22023',
      message = 'Invalid Swara maintenance dispatch contract';
  end if;

  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-maintenance-dispatch:%s', p_operation),
      0::bigint
    )
  ) then
    return null;
  end if;

  v_window_start := pg_catalog.to_timestamp(
    (
      pg_catalog.floor(
        extract(epoch from pg_catalog.clock_timestamp()) / p_interval_seconds
      ) * p_interval_seconds
    )::double precision
  );

  v_idempotency_key := pg_catalog.format(
    'swara-maintenance:%s:%s',
    p_operation,
    pg_catalog.to_char(
      v_window_start at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS"Z"'
    )
  );

  v_job_digest := pg_catalog.md5('job:' || v_idempotency_key);
  v_correlation_digest := pg_catalog.md5('correlation:' || v_idempotency_key);
  v_job_id := (
    pg_catalog.substr(v_job_digest, 1, 8) || '-'
    || pg_catalog.substr(v_job_digest, 9, 4) || '-'
    || pg_catalog.substr(v_job_digest, 13, 4) || '-'
    || pg_catalog.substr(v_job_digest, 17, 4) || '-'
    || pg_catalog.substr(v_job_digest, 21, 12)
  )::uuid;
  v_correlation_id := (
    pg_catalog.substr(v_correlation_digest, 1, 8) || '-'
    || pg_catalog.substr(v_correlation_digest, 9, 4) || '-'
    || pg_catalog.substr(v_correlation_digest, 13, 4) || '-'
    || pg_catalog.substr(v_correlation_digest, 17, 4) || '-'
    || pg_catalog.substr(v_correlation_digest, 21, 12)
  )::uuid;

  return private.enqueue_job(
    p_queue_name,
    pg_catalog.jsonb_build_object(
      'schema_version', 1,
      'job_type', 'maintenance.' || p_operation,
      'job_id', v_job_id::text,
      'idempotency_key', v_idempotency_key,
      'correlation_id', v_correlation_id::text
    ),
    0
  );
end;
$function$;

-- Preserve the immutable return snapshot for device operations.  Existing
-- pre-M023 rows deliberately remain marked unsnapshotted and fail closed on
-- replay rather than reading a later device state as if it were historical.
alter table private.device_mutation_requests
  add column result_revoked_at timestamptz,
  add column result_recorded_at timestamptz not null default pg_catalog.clock_timestamp(),
  add column result_snapshot_recorded boolean not null default false;

comment on column private.device_mutation_requests.result_revoked_at is
  'Immutable revoked_at value returned by the original device mutation. A retry never reads current device state.';
comment on column private.device_mutation_requests.result_recorded_at is
  'Server timestamp at which the original device mutation result was durably recorded.';
comment on column private.device_mutation_requests.result_snapshot_recorded is
  'False only for pre-M023 ledger rows, which fail closed on replay because their historical outcome is unavailable.';

create or replace function private.register_device(
  p_user_id uuid,
  p_installation_hash text,
  p_browser text,
  p_extension_version text,
  p_device_public_key text,
  p_idempotency_key text
)
returns table (
  device_id uuid,
  revoked_at timestamptz,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_device_id uuid;
  v_prior_revoked_at timestamptz;
  v_prior_snapshot_recorded boolean;
  v_device_id uuid;
  v_revoked_at timestamptz;
begin
  if p_user_id is null
     or p_installation_hash is null
     or p_installation_hash <> pg_catalog.lower(pg_catalog.btrim(p_installation_hash))
     or p_installation_hash !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023',
      message = 'Device registration requires a canonical installation SHA-256 hash';
  end if;

  if p_browser is null
     or p_browser <> pg_catalog.btrim(p_browser)
     or pg_catalog.char_length(p_browser) not between 1 and 128
     or p_browser ~ '[[:cntrl:]]'
     or p_extension_version is null
     or p_extension_version <> pg_catalog.btrim(p_extension_version)
     or pg_catalog.char_length(p_extension_version) not between 1 and 128
     or p_extension_version ~ '[[:cntrl:]]' then
    raise exception using
      errcode = '22023',
      message = 'Device registration metadata is invalid';
  end if;

  if p_device_public_key is not null and (
       p_device_public_key <> pg_catalog.btrim(p_device_public_key)
       or pg_catalog.char_length(p_device_public_key) not between 1 and 16384
       or p_device_public_key ~ '[[:cntrl:]]'
     ) then
    raise exception using
      errcode = '22023',
      message = 'Device public key is invalid';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Device registration idempotency key is invalid';
  end if;

  if not exists (
    select 1 from auth.users as account where account.id = p_user_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Device owner is not available';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'installation_hash', p_installation_hash,
          'browser', p_browser,
          'extension_version', p_extension_version,
          'device_public_key', p_device_public_key
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-device-register:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select
    request.input_hash,
    request.device_id,
    request.result_revoked_at,
    request.result_snapshot_recorded
  into
    v_prior_input_hash,
    v_prior_device_id,
    v_prior_revoked_at,
    v_prior_snapshot_recorded
  from private.device_mutation_requests as request
  where request.user_id = p_user_id
    and request.operation = 'register'
    and request.idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Device registration idempotency key is bound to different input';
    end if;

    if v_prior_snapshot_recorded is not true then
      raise exception using
        errcode = '55000',
        message = 'Device registration historical result requires explicit remediation';
    end if;

    return query select v_prior_device_id, v_prior_revoked_at, true;
    return;
  end if;

  insert into public.devices (
    user_id,
    installation_hash,
    browser,
    extension_version,
    device_public_key,
    revoked_at,
    last_seen_at
  )
  values (
    p_user_id,
    p_installation_hash,
    p_browser,
    p_extension_version,
    p_device_public_key,
    null,
    pg_catalog.clock_timestamp()
  )
  on conflict (user_id, installation_hash) do update
    set browser = excluded.browser,
        extension_version = excluded.extension_version,
        device_public_key = excluded.device_public_key,
        revoked_at = null,
        last_seen_at = pg_catalog.clock_timestamp()
  returning id, public.devices.revoked_at into v_device_id, v_revoked_at;

  insert into private.device_mutation_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    device_id,
    result_revoked_at,
    result_snapshot_recorded
  )
  values (
    p_user_id,
    'register',
    p_idempotency_key,
    v_input_hash,
    v_device_id,
    v_revoked_at,
    true
  );

  return query select v_device_id, v_revoked_at, false;
end;
$function$;

create or replace function private.revoke_device(
  p_user_id uuid,
  p_device_id uuid,
  p_idempotency_key text
)
returns table (
  device_id uuid,
  revoked_at timestamptz,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_device_id uuid;
  v_prior_revoked_at timestamptz;
  v_prior_snapshot_recorded boolean;
  v_revoked_at timestamptz;
begin
  if p_user_id is null or p_device_id is null then
    raise exception using
      errcode = '22023',
      message = 'Device revocation requires owner and device identifiers';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Device revocation idempotency key is invalid';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'device_id', p_device_id
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-device-revoke:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select
    request.input_hash,
    request.device_id,
    request.result_revoked_at,
    request.result_snapshot_recorded
  into
    v_prior_input_hash,
    v_prior_device_id,
    v_prior_revoked_at,
    v_prior_snapshot_recorded
  from private.device_mutation_requests as request
  where request.user_id = p_user_id
    and request.operation = 'revoke'
    and request.idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Device revocation idempotency key is bound to different input';
    end if;

    if v_prior_snapshot_recorded is not true then
      raise exception using
        errcode = '55000',
        message = 'Device revocation historical result requires explicit remediation';
    end if;

    return query select v_prior_device_id, v_prior_revoked_at, true;
    return;
  end if;

  select device.revoked_at
    into v_revoked_at
    from public.devices as device
   where device.id = p_device_id
     and device.user_id = p_user_id
   for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'Device is not available';
  end if;

  if v_revoked_at is null then
    update public.devices as device
       set revoked_at = pg_catalog.clock_timestamp()
     where device.id = p_device_id
       and device.user_id = p_user_id
    returning device.revoked_at into v_revoked_at;
  end if;

  insert into private.device_mutation_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    device_id,
    result_revoked_at,
    result_snapshot_recorded
  )
  values (
    p_user_id,
    'revoke',
    p_idempotency_key,
    v_input_hash,
    p_device_id,
    v_revoked_at,
    true
  );

  return query select p_device_id, v_revoked_at, false;
end;
$function$;

-- Existing content-hash recovery is intentionally strict.  A non-deleted
-- document may only deduplicate when every persisted upload contract field
-- agrees.  A deleted row may be explicitly revived with the same immutable
-- identity (owner, filename, hash, bucket, and exact path); it may refresh
-- MIME, size, and extraction metadata because it is starting a new pending
-- upload.  A failed row may retry only with the exact prior contract.
create or replace function private.create_vault_upload_intent(
  p_user_id uuid,
  p_filename text,
  p_mime_type text,
  p_size_bytes bigint,
  p_sha256 text,
  p_extraction_method text,
  p_idempotency_key text
)
returns table (
  document_id uuid,
  storage_bucket text,
  storage_path text,
  status text,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_document_id uuid;
  v_existing_filename text;
  v_existing_mime_type text;
  v_existing_size_bytes bigint;
  v_existing_sha256 text;
  v_storage_bucket text;
  v_storage_path text;
  v_existing_extraction_method text;
  v_status text;
  v_deleted_at timestamptz;
  v_expected_path text;
  v_duplicate boolean := false;
begin
  if p_user_id is null
     or p_filename is null
     or p_filename <> pg_catalog.btrim(p_filename)
     or pg_catalog.char_length(p_filename) not between 1 and 255
     or p_filename in ('.', '..')
     or pg_catalog.strpos(p_filename, '/') > 0
     or pg_catalog.strpos(p_filename, E'\\') > 0
     or p_filename ~ '[[:cntrl:]]'
     or p_mime_type is null
     or p_mime_type <> pg_catalog.btrim(p_mime_type)
     or p_mime_type not in (
       'application/pdf',
       'application/msword',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       'application/vnd.ms-excel',
       'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
       'application/vnd.ms-powerpoint',
       'application/vnd.openxmlformats-officedocument.presentationml.presentation',
       'application/vnd.oasis.opendocument.text',
       'application/vnd.oasis.opendocument.spreadsheet',
       'application/vnd.oasis.opendocument.presentation',
       'application/rtf',
       'application/epub+zip',
       'text/plain',
       'text/markdown',
       'text/csv',
       'text/rtf',
       'image/jpeg',
       'image/png',
       'image/webp',
       'image/tiff'
     )
     or p_size_bytes is null
     or p_size_bytes not between 1 and 52428800
     or p_sha256 is null
     or p_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_sha256))
     or p_sha256 !~ '^[0-9a-f]{64}$'
     or p_extraction_method is null
     or p_extraction_method not in ('local', 'ocr', 'manual') then
    raise exception using
      errcode = '22023',
      message = 'Vault upload intent input is invalid';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Vault upload intent idempotency key is invalid';
  end if;

  if not exists (
    select 1 from auth.users as account where account.id = p_user_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Vault owner is not available';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'filename', p_filename,
          'mime_type', p_mime_type,
          'size_bytes', p_size_bytes,
          'sha256', p_sha256,
          'extraction_method', p_extraction_method
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-vault-upload-intent:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.document_id
    into v_prior_input_hash, v_document_id
    from private.vault_document_requests as request
   where request.user_id = p_user_id
     and request.operation = 'create_upload_intent'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Vault upload intent idempotency key is bound to different input';
    end if;

    select document.storage_bucket, document.storage_path, document.status
      into v_storage_bucket, v_storage_path, v_status
      from public.vault_documents as document
     where document.id = v_document_id
       and document.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault upload intent result is no longer available';
    end if;

    return query select v_document_id, v_storage_bucket, v_storage_path, v_status, true;
    return;
  end if;

  v_document_id := pg_catalog.gen_random_uuid();
  v_expected_path := p_user_id::text || '/' || v_document_id::text || '/' || p_filename;

  insert into public.vault_documents as document (
    id,
    user_id,
    filename,
    mime_type,
    size_bytes,
    sha256,
    storage_bucket,
    storage_path,
    extraction_method,
    status,
    error_code,
    error_message,
    deleted_at
  )
  values (
    v_document_id,
    p_user_id,
    p_filename,
    p_mime_type,
    p_size_bytes,
    p_sha256,
    'vault-originals',
    v_expected_path,
    p_extraction_method,
    'pending',
    null,
    null,
    null
  )
  on conflict (user_id, sha256) do nothing
  returning document.id, document.filename, document.storage_bucket, document.storage_path, document.status
    into v_document_id, v_existing_filename, v_storage_bucket, v_storage_path, v_status;

  if not found then
    select
      document.id,
      document.filename,
      document.mime_type,
      document.size_bytes,
      document.sha256,
      document.storage_bucket,
      document.storage_path,
      document.extraction_method,
      document.status,
      document.deleted_at
    into
      v_document_id,
      v_existing_filename,
      v_existing_mime_type,
      v_existing_size_bytes,
      v_existing_sha256,
      v_storage_bucket,
      v_storage_path,
      v_existing_extraction_method,
      v_status,
      v_deleted_at
    from public.vault_documents as document
    where document.user_id = p_user_id
      and document.sha256 = p_sha256
    for update;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault document could not be recovered';
    end if;

    v_expected_path := p_user_id::text || '/' || v_document_id::text || '/' || p_filename;
    if v_existing_filename is distinct from p_filename
       or v_existing_sha256 is distinct from p_sha256
       or v_storage_bucket is distinct from 'vault-originals'
       or v_storage_path is distinct from v_expected_path then
      raise exception using
        errcode = '22023',
        message = 'Vault content hash is already bound to different immutable document metadata';
    end if;

    if v_status = 'deleted' then
      if v_deleted_at is null then
        raise exception using
          errcode = '55000',
          message = 'Vault deleted document state is inconsistent';
      end if;

      update public.vault_documents as document
         set mime_type = p_mime_type,
             size_bytes = p_size_bytes,
             extraction_method = p_extraction_method,
             status = 'pending',
             error_code = null,
             error_message = null,
             deleted_at = null
       where document.id = v_document_id
         and document.user_id = p_user_id
      returning document.storage_bucket, document.storage_path, document.status
        into v_storage_bucket, v_storage_path, v_status;
      v_duplicate := false;
    else
      if v_existing_mime_type is distinct from p_mime_type
         or v_existing_size_bytes is distinct from p_size_bytes
         or v_existing_extraction_method is distinct from p_extraction_method then
        raise exception using
          errcode = '22023',
          message = 'Vault content hash is already bound to different document metadata';
      end if;

      if v_status = 'failed' then
        update public.vault_documents as document
           set status = 'pending',
               error_code = null,
               error_message = null
         where document.id = v_document_id
           and document.user_id = p_user_id
        returning document.storage_bucket, document.storage_path, document.status
          into v_storage_bucket, v_storage_path, v_status;
        v_duplicate := false;
      else
        -- pending/processing/ready are an existing same-hash document, not a
        -- newly created upload intent.  Tell callers to reuse it deterministically.
        v_duplicate := true;
      end if;
    end if;
  end if;

  insert into private.vault_document_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    document_id
  )
  values (
    p_user_id,
    'create_upload_intent',
    p_idempotency_key,
    v_input_hash,
    v_document_id
  );

  return query select v_document_id, v_storage_bucket, v_storage_path, v_status, v_duplicate;
end;
$function$;

-- Storage object existence is a necessary condition before pending metadata
-- can advance.  Object metadata may corroborate size/MIME when supplied by
-- Storage, but it is never treated as proof of SHA-256 content; Edge/worker
-- content hashing remains the authoritative verification step.
create or replace function private.finalize_vault_upload(
  p_user_id uuid,
  p_document_id uuid,
  p_sha256 text,
  p_idempotency_key text
)
returns table (
  document_id uuid,
  storage_bucket text,
  storage_path text,
  status text,
  duplicate boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_input_hash text;
  v_prior_input_hash text;
  v_prior_document_id uuid;
  v_filename text;
  v_actual_sha256 text;
  v_mime_type text;
  v_size_bytes bigint;
  v_storage_bucket text;
  v_storage_path text;
  v_status text;
  v_expected_path text;
  v_storage_metadata jsonb;
  v_duplicate boolean := false;
begin
  if p_user_id is null
     or p_document_id is null
     or p_sha256 is null
     or p_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_sha256))
     or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023',
      message = 'Vault upload finalization input is invalid';
  end if;

  if p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 200
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Vault upload finalization idempotency key is invalid';
  end if;

  v_input_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'user_id', p_user_id,
          'document_id', p_document_id,
          'sha256', p_sha256
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'swara-vault-finalize:' || p_user_id::text || ':' || p_idempotency_key,
      8072026::bigint
    )
  );

  select request.input_hash, request.document_id
    into v_prior_input_hash, v_prior_document_id
    from private.vault_document_requests as request
   where request.user_id = p_user_id
     and request.operation = 'finalize_upload'
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_prior_input_hash is distinct from v_input_hash then
      raise exception using
        errcode = '22023',
        message = 'Vault upload finalization idempotency key is bound to different input';
    end if;

    select document.storage_bucket, document.storage_path, document.status
      into v_storage_bucket, v_storage_path, v_status
      from public.vault_documents as document
     where document.id = v_prior_document_id
       and document.user_id = p_user_id;

    if not found then
      raise exception using
        errcode = '55000',
        message = 'Vault upload finalization result is no longer available';
    end if;

    return query select v_prior_document_id, v_storage_bucket, v_storage_path, v_status, true;
    return;
  end if;

  select
    document.filename,
    document.sha256,
    document.mime_type,
    document.size_bytes,
    document.storage_bucket,
    document.storage_path,
    document.status
  into
    v_filename,
    v_actual_sha256,
    v_mime_type,
    v_size_bytes,
    v_storage_bucket,
    v_storage_path,
    v_status
  from public.vault_documents as document
  where document.id = p_document_id
    and document.user_id = p_user_id
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'Vault document is not available';
  end if;

  v_expected_path := p_user_id::text || '/' || p_document_id::text || '/' || v_filename;
  if v_actual_sha256 is distinct from p_sha256
     or v_storage_bucket is distinct from 'vault-originals'
     or v_storage_path is distinct from v_expected_path then
    raise exception using
      errcode = '22023',
      message = 'Vault upload finalization does not match the pending document';
  end if;

  if v_status = 'pending' then
    select object.metadata
      into v_storage_metadata
      from storage.objects as object
     where object.bucket_id = 'vault-originals'
       and object.name = v_storage_path
       and object.owner_id = p_user_id::text;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'Vault upload finalization requires the exact owned Storage object';
    end if;

    if v_storage_metadata ? 'size' and (
         pg_catalog.jsonb_typeof(v_storage_metadata -> 'size') not in ('number', 'string')
         or (v_storage_metadata ->> 'size') !~ '^[0-9]{1,18}$'
         or (v_storage_metadata ->> 'size')::bigint is distinct from v_size_bytes
       ) then
      raise exception using
        errcode = '22023',
        message = 'Vault upload finalization Storage size does not match metadata';
    end if;

    if v_storage_metadata ? 'mimetype' and (
         pg_catalog.jsonb_typeof(v_storage_metadata -> 'mimetype') is distinct from 'string'
         or v_storage_metadata ->> 'mimetype' is distinct from v_mime_type
       ) then
      raise exception using
        errcode = '22023',
        message = 'Vault upload finalization Storage MIME type does not match metadata';
    end if;

    update public.vault_documents as document
       set status = 'processing',
           error_code = null,
           error_message = null
     where document.id = p_document_id
       and document.user_id = p_user_id
    returning document.status into v_status;
  elsif v_status in ('processing', 'ready') then
    v_duplicate := true;
  else
    raise exception using
      errcode = '22023',
      message = 'Vault document cannot be finalized from its current state';
  end if;

  insert into private.vault_document_requests (
    user_id,
    operation,
    idempotency_key,
    input_hash,
    document_id
  )
  values (
    p_user_id,
    'finalize_upload',
    p_idempotency_key,
    v_input_hash,
    p_document_id
  );

  return query select p_document_id, v_storage_bucket, v_storage_path, v_status, v_duplicate;
end;
$function$;

-- Claim outcome contract for the verified webhook handler:
--   * first_delivery is the sole processable outcome;
--   * in_progress, terminal_replay, and hash_conflict must return without
--     vendor-side effects; and
--   * finalization is allowed only while the matching receipt is claimed.
-- This is intentionally state-based (rather than a token) to preserve the
-- existing public function signature; advisory locking serializes transitions.
create or replace function private.claim_alterity_webhook(
  p_event_id text,
  p_body_sha256 text,
  p_signed_at timestamptz,
  p_event_type text
)
returns table (
  claim_outcome text,
  status text,
  attempt_count integer,
  first_received_at timestamptz,
  processed_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_existing_body_sha256 text;
  v_existing_event_type text;
  v_status text;
  v_attempt_count integer;
  v_first_received_at timestamptz;
  v_processed_at timestamptz;
begin
  if p_event_id is null
     or p_event_id <> pg_catalog.btrim(p_event_id)
     or pg_catalog.char_length(p_event_id) not between 1 and 200
     or p_event_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
     or p_body_sha256 is null
     or p_body_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_body_sha256))
     or p_body_sha256 !~ '^[0-9a-f]{64}$'
     or p_event_type is null
     or p_event_type <> pg_catalog.lower(pg_catalog.btrim(p_event_type))
     or pg_catalog.char_length(p_event_type) not between 1 and 80
     or p_event_type !~ '^[a-z][a-z0-9._-]*$'
     or p_signed_at is null
     or p_signed_at < v_now - interval '15 minutes'
     or p_signed_at > v_now + interval '5 minutes' then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook claim input is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('swara-alterity-webhook:' || p_event_id, 8072026::bigint)
  );

  select
    receipt.body_sha256,
    receipt.event_type,
    receipt.status,
    receipt.attempt_count,
    receipt.first_received_at,
    receipt.processed_at
  into
    v_existing_body_sha256,
    v_existing_event_type,
    v_status,
    v_attempt_count,
    v_first_received_at,
    v_processed_at
  from private.alterity_webhook_receipts as receipt
  where receipt.event_id = p_event_id
  for update;

  if found then
    if v_existing_body_sha256 is distinct from p_body_sha256
       or v_existing_event_type is distinct from p_event_type then
      return query
      select 'hash_conflict', v_status, v_attempt_count, v_first_received_at, v_processed_at;
      return;
    end if;

    if v_status in ('processed', 'failed') then
      update private.alterity_webhook_receipts as receipt
         set last_received_at = v_now
       where receipt.event_id = p_event_id;

      return query
      select 'terminal_replay', v_status, v_attempt_count, v_first_received_at, v_processed_at;
      return;
    end if;

    if v_status is distinct from 'claimed' then
      raise exception using
        errcode = '55000',
        message = 'Alterity webhook receipt has an unsupported active state';
    end if;

    if v_attempt_count >= 1000 then
      raise exception using
        errcode = '22023',
        message = 'Alterity webhook replay limit has been reached';
    end if;

    update private.alterity_webhook_receipts as receipt
       set attempt_count = receipt.attempt_count + 1,
           last_received_at = v_now
     where receipt.event_id = p_event_id
    returning receipt.status, receipt.attempt_count, receipt.first_received_at, receipt.processed_at
      into v_status, v_attempt_count, v_first_received_at, v_processed_at;

    return query
    select 'in_progress', v_status, v_attempt_count, v_first_received_at, v_processed_at;
    return;
  end if;

  insert into private.alterity_webhook_receipts as receipt (
    event_id,
    body_sha256,
    signed_at,
    event_type,
    status,
    attempt_count,
    first_received_at,
    last_received_at,
    claimed_at
  )
  values (
    p_event_id,
    p_body_sha256,
    p_signed_at,
    p_event_type,
    'claimed',
    1,
    v_now,
    v_now,
    v_now
  )
  returning receipt.status, receipt.attempt_count, receipt.first_received_at, receipt.processed_at
    into v_status, v_attempt_count, v_first_received_at, v_processed_at;

  return query
  select 'first_delivery', v_status, v_attempt_count, v_first_received_at, v_processed_at;
end;
$function$;

create or replace function private.finalize_alterity_webhook(
  p_event_id text,
  p_body_sha256 text,
  p_status text,
  p_safe_error_code text default null
)
returns table (
  status text,
  finalized boolean,
  processed_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_existing_body_sha256 text;
  v_current_status text;
  v_current_error_code text;
  v_processed_at timestamptz;
begin
  if p_event_id is null
     or p_event_id <> pg_catalog.btrim(p_event_id)
     or pg_catalog.char_length(p_event_id) not between 1 and 200
     or p_event_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
     or p_body_sha256 is null
     or p_body_sha256 <> pg_catalog.lower(pg_catalog.btrim(p_body_sha256))
     or p_body_sha256 !~ '^[0-9a-f]{64}$'
     or p_status not in ('processed', 'failed') then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook finalization input is invalid';
  end if;

  if (p_status = 'processed' and p_safe_error_code is not null)
     or (p_status = 'failed' and (
       p_safe_error_code is null
       or p_safe_error_code <> pg_catalog.lower(pg_catalog.btrim(p_safe_error_code))
       or pg_catalog.char_length(p_safe_error_code) not between 1 and 64
       or p_safe_error_code !~ '^[a-z0-9][a-z0-9._-]*$'
     )) then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook finalization error code is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('swara-alterity-webhook:' || p_event_id, 8072026::bigint)
  );

  select
    receipt.body_sha256,
    receipt.status,
    receipt.safe_error_code,
    receipt.processed_at
  into
    v_existing_body_sha256,
    v_current_status,
    v_current_error_code,
    v_processed_at
  from private.alterity_webhook_receipts as receipt
  where receipt.event_id = p_event_id
  for update;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook claim is not available';
  end if;

  if v_existing_body_sha256 is distinct from p_body_sha256 then
    raise exception using
      errcode = '22023',
      message = 'Alterity webhook finalization does not match the claimed body';
  end if;

  -- The only processable state is the active matching claim.  No conflict or
  -- terminal replay may re-open a receipt through the finalization gateway;
  -- callers must observe terminal_replay from claim and stop.
  if v_current_status is distinct from 'claimed' then
    raise exception using
      errcode = '55000',
      message = 'Alterity webhook is not actively claimed';
  end if;

  update private.alterity_webhook_receipts as receipt
     set status = p_status,
         processed_at = pg_catalog.clock_timestamp(),
         safe_error_code = p_safe_error_code
   where receipt.event_id = p_event_id
     and receipt.status = 'claimed'
  returning receipt.status, receipt.processed_at
    into v_current_status, v_processed_at;

  if not found then
    raise exception using
      errcode = '55000',
      message = 'Alterity webhook active claim was lost';
  end if;

  return query select v_current_status, true, v_processed_at;
end;
$function$;

-- Remove exactly the four hosted legacy-bucket policies.  This touches policy
-- metadata only; it does not create, delete, move, or inspect any bucket or
-- object in the legacy `documents` namespace.
drop policy if exists demo_documents_select on storage.objects;
drop policy if exists demo_documents_insert on storage.objects;
drop policy if exists demo_documents_update on storage.objects;
drop policy if exists demo_documents_delete on storage.objects;

-- Browser writes to vault-originals must be backed by an exact, owned,
-- pending upload-intent row.  The UUID test is retained as defense in depth;
-- the metadata row/path equality is what blocks untracked arbitrary uploads.
drop policy if exists swara_vault_originals_insert_own on storage.objects;
drop policy if exists swara_vault_originals_update_own on storage.objects;

create policy swara_vault_originals_insert_own
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
    and exists (
      select 1
        from public.vault_documents as document
       where document.user_id = (select auth.uid())
         and document.id::text = (storage.foldername(name))[2]
         and document.storage_bucket = 'vault-originals'
         and document.storage_path = name
         and document.status = 'pending'
         and document.deleted_at is null
    )
  );

create policy swara_vault_originals_update_own
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
    and exists (
      select 1
        from public.vault_documents as document
       where document.user_id = (select auth.uid())
         and document.id::text = (storage.foldername(name))[2]
         and document.storage_bucket = 'vault-originals'
         and document.storage_path = name
         and document.status = 'pending'
         and document.deleted_at is null
    )
  )
  with check (
    bucket_id = 'vault-originals'
    and owner_id = (select auth.uid()::text)
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and storage.filename(name) <> ''
    and exists (
      select 1
        from public.vault_documents as document
       where document.user_id = (select auth.uid())
         and document.id::text = (storage.foldername(name))[2]
         and document.storage_bucket = 'vault-originals'
         and document.storage_path = name
         and document.status = 'pending'
         and document.deleted_at is null
    )
  );

-- Pin all M019-M022 security-definer gateways after every replacement above.
-- CREATE OR REPLACE retains an existing ACL, so each function is explicitly
-- re-owned, locked to an empty search_path, revoked from untrusted roles, and
-- granted only to the one intended direct runtime group below.
alter function private.import_workflow_atomic(uuid, uuid, text, integer, jsonb, uuid, text, uuid) owner to postgres;
alter function private.import_workflow_atomic(uuid, uuid, text, integer, jsonb, uuid, text, uuid) security definer;
alter function private.import_workflow_atomic(uuid, uuid, text, integer, jsonb, uuid, text, uuid) set search_path to '';

alter function private.enqueue_job(text, jsonb, integer) owner to postgres;
alter function private.enqueue_job(text, jsonb, integer) security definer;
alter function private.enqueue_job(text, jsonb, integer) set search_path to '';
alter function private.read_jobs(text, integer, integer) owner to postgres;
alter function private.read_jobs(text, integer, integer) security definer;
alter function private.read_jobs(text, integer, integer) set search_path to '';
alter function private.claim_job(text, bigint, text, integer) owner to postgres;
alter function private.claim_job(text, bigint, text, integer) security definer;
alter function private.claim_job(text, bigint, text, integer) set search_path to '';
alter function private.extend_job_visibility(text, bigint, text, integer) owner to postgres;
alter function private.extend_job_visibility(text, bigint, text, integer) security definer;
alter function private.extend_job_visibility(text, bigint, text, integer) set search_path to '';
alter function private.archive_job(text, bigint, text) owner to postgres;
alter function private.archive_job(text, bigint, text) security definer;
alter function private.archive_job(text, bigint, text) set search_path to '';
alter function private.dead_letter_job(text, bigint, text, text) owner to postgres;
alter function private.dead_letter_job(text, bigint, text, text) security definer;
alter function private.dead_letter_job(text, bigint, text, text) set search_path to '';
alter function private.enqueue_maintenance_dispatch(text, text, integer, integer) owner to postgres;
alter function private.enqueue_maintenance_dispatch(text, text, integer, integer) security definer;
alter function private.enqueue_maintenance_dispatch(text, text, integer, integer) set search_path to '';

alter function private.claim_expired_task_artifacts(integer, integer, timestamptz) owner to postgres;
alter function private.claim_expired_task_artifacts(integer, integer, timestamptz) security definer;
alter function private.claim_expired_task_artifacts(integer, integer, timestamptz) set search_path to '';
alter function private.complete_task_artifact_purge(uuid, uuid) owner to postgres;
alter function private.complete_task_artifact_purge(uuid, uuid) security definer;
alter function private.complete_task_artifact_purge(uuid, uuid) set search_path to '';
alter function private.fail_task_artifact_purge(uuid, uuid, text, boolean) owner to postgres;
alter function private.fail_task_artifact_purge(uuid, uuid, text, boolean) security definer;
alter function private.fail_task_artifact_purge(uuid, uuid, text, boolean) set search_path to '';
alter function private.request_account_export(uuid, text) owner to postgres;
alter function private.request_account_export(uuid, text) security definer;
alter function private.request_account_export(uuid, text) set search_path to '';
alter function private.request_account_deletion(uuid, text, uuid) owner to postgres;
alter function private.request_account_deletion(uuid, text, uuid) security definer;
alter function private.request_account_deletion(uuid, text, uuid) set search_path to '';
alter function private.validate_context_item_version() owner to postgres;
alter function private.validate_context_item_version() security definer;
alter function private.validate_context_item_version() set search_path to '';

alter function private.register_device(uuid, text, text, text, text, text) owner to postgres;
alter function private.register_device(uuid, text, text, text, text, text) security definer;
alter function private.register_device(uuid, text, text, text, text, text) set search_path to '';
alter function private.revoke_device(uuid, uuid, text) owner to postgres;
alter function private.revoke_device(uuid, uuid, text) security definer;
alter function private.revoke_device(uuid, uuid, text) set search_path to '';
alter function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text) owner to postgres;
alter function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text) security definer;
alter function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text) set search_path to '';
alter function private.finalize_vault_upload(uuid, uuid, text, text) owner to postgres;
alter function private.finalize_vault_upload(uuid, uuid, text, text) security definer;
alter function private.finalize_vault_upload(uuid, uuid, text, text) set search_path to '';
alter function private.soft_delete_vault_document(uuid, uuid, text) owner to postgres;
alter function private.soft_delete_vault_document(uuid, uuid, text) security definer;
alter function private.soft_delete_vault_document(uuid, uuid, text) set search_path to '';
alter function private.complete_vault_document_processing(uuid, text, text, text) owner to postgres;
alter function private.complete_vault_document_processing(uuid, text, text, text) security definer;
alter function private.complete_vault_document_processing(uuid, text, text, text) set search_path to '';
alter function private.claim_alterity_webhook(text, text, timestamptz, text) owner to postgres;
alter function private.claim_alterity_webhook(text, text, timestamptz, text) security definer;
alter function private.claim_alterity_webhook(text, text, timestamptz, text) set search_path to '';
alter function private.finalize_alterity_webhook(text, text, text, text) owner to postgres;
alter function private.finalize_alterity_webhook(text, text, text, text) security definer;
alter function private.finalize_alterity_webhook(text, text, text, text) set search_path to '';

revoke all privileges on function private.import_workflow_atomic(uuid, uuid, text, integer, jsonb, uuid, text, uuid)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.enqueue_job(text, jsonb, integer)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.read_jobs(text, integer, integer)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.claim_job(text, bigint, text, integer)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.extend_job_visibility(text, bigint, text, integer)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.archive_job(text, bigint, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.dead_letter_job(text, bigint, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.enqueue_maintenance_dispatch(text, text, integer, integer)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.claim_expired_task_artifacts(integer, integer, timestamptz)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.complete_task_artifact_purge(uuid, uuid)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.fail_task_artifact_purge(uuid, uuid, text, boolean)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.request_account_export(uuid, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.request_account_deletion(uuid, text, uuid)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.validate_context_item_version()
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.register_device(uuid, text, text, text, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.revoke_device(uuid, uuid, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.finalize_vault_upload(uuid, uuid, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.soft_delete_vault_document(uuid, uuid, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.complete_vault_document_processing(uuid, text, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.claim_alterity_webhook(text, text, timestamptz, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.finalize_alterity_webhook(text, text, text, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;

grant usage on schema private to swara_api_runtime, swara_worker_runtime;

grant execute on function private.import_workflow_atomic(uuid, uuid, text, integer, jsonb, uuid, text, uuid)
  to swara_api_runtime;
grant execute on function private.request_account_export(uuid, text)
  to swara_api_runtime;
grant execute on function private.request_account_deletion(uuid, text, uuid)
  to swara_api_runtime;
grant execute on function private.register_device(uuid, text, text, text, text, text)
  to swara_api_runtime;
grant execute on function private.revoke_device(uuid, uuid, text)
  to swara_api_runtime;
grant execute on function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text)
  to swara_api_runtime;
grant execute on function private.finalize_vault_upload(uuid, uuid, text, text)
  to swara_api_runtime;
grant execute on function private.soft_delete_vault_document(uuid, uuid, text)
  to swara_api_runtime;
grant execute on function private.claim_alterity_webhook(text, text, timestamptz, text)
  to swara_api_runtime;
grant execute on function private.finalize_alterity_webhook(text, text, text, text)
  to swara_api_runtime;

grant execute on function private.enqueue_job(text, jsonb, integer)
  to swara_worker_runtime;
grant execute on function private.read_jobs(text, integer, integer)
  to swara_worker_runtime;
grant execute on function private.claim_job(text, bigint, text, integer)
  to swara_worker_runtime;
grant execute on function private.extend_job_visibility(text, bigint, text, integer)
  to swara_worker_runtime;
grant execute on function private.archive_job(text, bigint, text)
  to swara_worker_runtime;
grant execute on function private.dead_letter_job(text, bigint, text, text)
  to swara_worker_runtime;
grant execute on function private.enqueue_maintenance_dispatch(text, text, integer, integer)
  to swara_worker_runtime;
grant execute on function private.claim_expired_task_artifacts(integer, integer, timestamptz)
  to swara_worker_runtime;
grant execute on function private.complete_task_artifact_purge(uuid, uuid)
  to swara_worker_runtime;
grant execute on function private.fail_task_artifact_purge(uuid, uuid, text, boolean)
  to swara_worker_runtime;
grant execute on function private.complete_vault_document_processing(uuid, text, text, text)
  to swara_worker_runtime;

-- Preserve the final M022 service-role closure after all function replacements.
revoke all privileges on schema private, audit, pgmq from service_role;
revoke all privileges on all tables in schema private from service_role;
revoke all privileges on all sequences in schema private from service_role;
revoke execute on all functions in schema private from service_role;
revoke all privileges on all tables in schema audit from service_role;
revoke all privileges on all sequences in schema audit from service_role;
revoke execute on all functions in schema audit from service_role;
revoke all privileges on all tables in schema pgmq from service_role;
revoke all privileges on all sequences in schema pgmq from service_role;
revoke execute on all functions in schema pgmq from service_role;

comment on function private.claim_alterity_webhook(text, text, timestamptz, text) is
  'API-runtime-only webhook replay claim. Only claim_outcome=first_delivery authorizes processing; in_progress, terminal_replay, and hash_conflict are non-processable.';
comment on function private.finalize_alterity_webhook(text, text, text, text) is
  'API-runtime-only webhook finalization. It accepts only the active matching claimed receipt; terminal_replay is non-processable and must not call finalize again.';
comment on function private.finalize_vault_upload(uuid, uuid, text, text) is
  'API-runtime-only Vault finalization. Pending metadata advances only after an exact owned Storage object exists; Edge/worker SHA-256 content verification remains authoritative.';
comment on function private.create_vault_upload_intent(uuid, text, text, bigint, text, text, text) is
  'API-runtime-only Vault intent. Exact same-hash documents return duplicate=true; failed rows retry only with identical metadata and deleted rows revive under the documented immutable-identity rules.';

commit;
