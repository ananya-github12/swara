-- Round 3A: optional cloud workflow metadata and immutable definitions.
--
-- Cloud workflow sync is intentionally separate from local workflows.  This
-- migration creates only the data contract; RLS and role grants are owned by
-- M009.  The validator is deliberately conservative so definitions never
-- become a durable store for runtime credentials or payment data.

begin;

create table public.workflows (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  status text not null default 'active',
  current_version_id uuid,
  step_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- This owner-qualified key is the parent for every version and prevents a
  -- workflow version from ever being attached to another Swara user.
  constraint workflows_id_user_id_key unique (id, user_id),
  constraint workflows_name_check
    check (name = btrim(name) and char_length(name) between 1 and 120),
  constraint workflows_status_check
    check (status in ('active', 'archived')),
  constraint workflows_step_count_check
    check (step_count between 0 and 50),
  constraint workflows_updated_at_check
    check (updated_at >= created_at)
);

create index workflows_user_id_status_updated_at_idx
  on public.workflows (user_id, status, updated_at desc);

create index workflows_user_id_current_version_id_idx
  on public.workflows (user_id, current_version_id)
  where current_version_id is not null;

create table public.workflow_versions (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  schema_version integer not null,
  definition jsonb not null,
  content_hash text not null,
  created_at timestamptz not null default now(),

  -- The first key is required for the owner-safe current-version foreign key
  -- below.  The second deduplicates identical immutable versions per workflow.
  constraint workflow_versions_id_workflow_id_user_id_key
    unique (id, workflow_id, user_id),
  constraint workflow_versions_user_id_workflow_id_content_hash_key
    unique (user_id, workflow_id, content_hash),
  constraint workflow_versions_workflow_owner_fkey
    foreign key (workflow_id, user_id)
    references public.workflows (id, user_id)
    on delete cascade,
  constraint workflow_versions_schema_version_check
    check (schema_version between 1 and 1000000),
  constraint workflow_versions_definition_object_check
    check (pg_catalog.jsonb_typeof(definition) = 'object'),
  constraint workflow_versions_definition_nonempty_check
    check (definition <> '{}'::jsonb),
  constraint workflow_versions_content_hash_check
    check (
      content_hash = pg_catalog.lower(content_hash)
      and content_hash ~ '^[0-9a-f]{64}$'
    )
);

create index workflow_versions_user_id_workflow_id_created_at_idx
  on public.workflow_versions (user_id, workflow_id, created_at desc);

-- A current version must belong to this exact workflow and its owner.  Keeping
-- this FK deferred permits one atomic transaction to create a workflow, its
-- first immutable version, and then set the pointer.  It also lets account
-- deletion cascade through both tables without a circular-FK ordering issue.
alter table public.workflows
  add constraint workflows_current_version_same_owner_fkey
  foreign key (current_version_id, id, user_id)
  references public.workflow_versions (id, workflow_id, user_id)
  on delete no action
  deferrable initially deferred;

-- This trigger is an internal-only, defense-in-depth validation layer.  The
-- extension already validates its local export format, but imports and future
-- clients must not be able to persist secrets by bypassing that client code.
-- A strict whole-value placeholder remains valid (for example {{email}} or
-- {{sensitive_value_1}}); its runtime value is never stored in the workflow.
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

  -- Walk every object key, array item, and scalar without interpolating any
  -- user-provided JSON into dynamic SQL.  The function reports a path only;
  -- it never echoes a candidate secret back to the caller or database logs.
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
        -- Permit a strict placeholder in a sensitive position, but reject a
        -- literal value under a secret-bearing key such as apiKey or cookie.
        when key_name is not null
          and pg_catalog.lower(key_name) ~
            '(password|passwd|passcode|one.?time.?passcode|(^|[^a-z0-9])otp([^a-z0-9]|$)|api.?key|access.?token|refresh.?token|id.?token|auth.?token|authorization|bearer.?token|secret|private.?key|session.?cookie|cookie|card.?number|credit.?card|debit.?card|cvv|cvc|social.?security|ssn)'
          and not (
            pg_catalog.jsonb_typeof(value) = 'string'
            and (value #>> '{}') ~ '^\{\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\}\}$'
          )
          then 'secret-bearing key'

        -- Match the extension contract: a variable explicitly marked
        -- sensitive can never have a saved default, including a placeholder.
        when pg_catalog.jsonb_typeof(value) = 'object'
          and value @> '{"sensitive": true}'::jsonb
          and (value ? 'defaultValue' or value ? 'default_value' or value ? 'default')
          then 'sensitive variable default'

        -- Catch raw literals where the secret-bearing label and its value are
        -- siblings (for example {"fieldId":"password","value":"..."}).
        when pg_catalog.jsonb_typeof(value) = 'object'
          and pg_catalog.lower(coalesce(
            value ->> 'fieldId',
            value ->> 'field_id',
            value ->> 'key',
            value ->> 'name',
            value ->> 'label',
            value ->> 'type',
            ''
          )) ~
            '(password|passwd|passcode|one.?time.?passcode|(^|[^a-z0-9])otp([^a-z0-9]|$)|api.?key|access.?token|refresh.?token|id.?token|auth.?token|authorization|bearer.?token|secret|private.?key|session.?cookie|cookie|card.?number|credit.?card|debit.?card|cvv|cvc|social.?security|ssn)'
          and (
            (
              value ? 'value'
              and coalesce(value ->> 'value', '') !~ '^\{\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\}\}$'
            )
            or (
              (value ? 'defaultValue' or value ? 'default_value' or value ? 'default')
              and coalesce(
                value ->> 'defaultValue',
                value ->> 'default_value',
                value ->> 'default',
                ''
              ) !~ '^\{\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\}\}$'
            )
          )
          then 'sensitive field default or value'

        -- Detect common secret formats even when an untrusted client hides
        -- them beneath an innocuous key.  Bare 6-8 digit literals are treated
        -- as one-time passcodes; callers can use a runtime placeholder for a
        -- non-sensitive dynamic numeric value.
        when pg_catalog.jsonb_typeof(value) = 'string'
          and (value #>> '{}') !~ '^\{\{[[:space:]]*[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*\}\}$'
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

revoke execute on function private.validate_workflow_version()
  from public, anon, authenticated, service_role;

create trigger workflow_versions_validate_definition
  before insert or update on public.workflow_versions
  for each row
  execute function private.validate_workflow_version();

create trigger workflows_set_updated_at
  before update on public.workflows
  for each row
  execute function private.set_updated_at();

comment on table public.workflows is
  'User-owned cloud workflow metadata. Local workflows remain usable without a cloud account.';

comment on table public.workflow_versions is
  'Immutable, user-owned cloud workflow definitions. Runtime values and credentials are never stored here.';

comment on function private.validate_workflow_version() is
  'Internal workflow-definition validation and immutability trigger; never a client-callable API.';

commit;
