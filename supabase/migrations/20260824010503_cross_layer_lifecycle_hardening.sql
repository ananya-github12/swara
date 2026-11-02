-- Round 5 M021: cross-layer identifiers, temporary-context ownership, and
-- reclaimable lifecycle work.
--
-- This migration depends on M018's NOLOGIN runtime groups and M020's private
-- queue gateway.  It does not create, map, read, write, or delete anything in
-- the legacy `documents` Storage bucket.

begin;

-- Fail before changing state if the reviewed queue boundary is not present.
-- Falling back to direct PGMQ or service_role would weaken the runtime split.
do $dependencies$
begin
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
      message = 'M021 requires the M018 Swara runtime roles';
  end if;

  if pg_catalog.to_regprocedure('private.enqueue_job(text,jsonb,integer)') is null then
    raise exception using
      errcode = '55000',
      message = 'M021 requires the M020 private.enqueue_job queue gateway';
  end if;

end;
$dependencies$;

-- A sequence is a browser batch, not a single browser action.  Preserve the
-- old default for existing one-action checkpoints while giving every action
-- in a batch a stable, non-negative position.
alter table private.task_steps
  add column action_index integer not null default 0;

alter table private.task_steps
  drop constraint if exists task_steps_user_id_task_id_sequence_key;

drop index if exists private.task_steps_task_sequence_uidx;

alter table private.task_steps
  add constraint task_steps_user_id_task_id_sequence_action_index_key
    unique (user_id, task_id, sequence, action_index),
  add constraint task_steps_action_index_check
    check (action_index >= 0),
  add constraint task_steps_batch_action_index_check
    check (batch_id is not null or action_index = 0);

-- A batch cannot reuse an action position.  The checkpoint trigger below
-- additionally ensures that a batch is never split across sequences and that
-- a sequence is never split across batches.
create unique index task_steps_user_id_task_id_batch_id_action_index_uidx
  on private.task_steps (user_id, task_id, batch_id, action_index)
  where batch_id is not null;

create index task_steps_user_id_task_id_sequence_action_index_idx
  on private.task_steps (user_id, task_id, sequence, action_index);

comment on column private.task_steps.action_index is
  'Zero-based action position inside one browser action batch. A sequence identifies the batch, not an individual action.';

-- Replace the one-checkpoint-per-sequence invariant.  The predecessor test
-- applies only to a later sequence/batch; actions inside the current batch
-- may arrive together in any action-index order.
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

  -- A later batch needs evidence that the immediately preceding batch began.
  -- It deliberately does not require an earlier action in the same batch.
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

comment on function private.validate_task_step_checkpoint() is
  'Internal trigger invariant for owner-safe, ordered browser batches with multiple action checkpoints.';

-- Temporary context must be bound to a concrete owned execution resource.
-- Do not infer a browser session or task for legacy rows: an unexpected
-- non-persistent row aborts this migration before any ownership change.
lock table public.swara_context_items in access exclusive mode;

do $temporary_context_preflight$
begin
  if exists (
    select 1
      from public.swara_context_items
     where scope <> 'persistent'
  ) then
    raise exception using
      errcode = '55000',
      message = 'Unsafe legacy session or task context rows require explicit owner remediation';
  end if;
end;
$temporary_context_preflight$;

alter table public.swara_context_items
  add column browser_session_id uuid,
  add column task_id uuid;

alter table public.swara_context_items
  add constraint context_items_browser_session_owner_fkey
    foreign key (browser_session_id, user_id)
    references private.browser_sessions (id, user_id)
    on delete cascade,
  add constraint context_items_task_owner_fkey
    foreign key (task_id, user_id)
    references private.agent_tasks (id, user_id)
    on delete cascade,
  add constraint context_items_scope_owner_binding_check
    check (
      (scope = 'persistent' and browser_session_id is null and task_id is null)
      or (scope = 'session' and browser_session_id is not null and task_id is null)
      or (scope = 'task' and browser_session_id is null and task_id is not null)
    );

drop index if exists public.swara_context_items_user_id_key_scope_version_key;
drop index if exists public.swara_context_items_user_id_active_key_scope_key;

create unique index context_items_persistent_user_key_version_uidx
  on public.swara_context_items (user_id, key, version)
  where scope = 'persistent';

create unique index context_items_session_user_session_key_version_uidx
  on public.swara_context_items (user_id, browser_session_id, key, version)
  where scope = 'session';

create unique index context_items_task_user_task_key_version_uidx
  on public.swara_context_items (user_id, task_id, key, version)
  where scope = 'task';

create unique index context_items_persistent_user_active_key_uidx
  on public.swara_context_items (user_id, key)
  where scope = 'persistent' and status = 'active';

create unique index context_items_session_user_session_active_key_uidx
  on public.swara_context_items (user_id, browser_session_id, key)
  where scope = 'session' and status = 'active';

create unique index context_items_task_user_task_active_key_uidx
  on public.swara_context_items (user_id, task_id, key)
  where scope = 'task' and status = 'active';

comment on column public.swara_context_items.browser_session_id is
  'Required only for session-scoped context; owner-safe through the composite browser-session foreign key.';
comment on column public.swara_context_items.task_id is
  'Required only for task-scoped context; its owned browser session is derived through private.agent_tasks.';

-- Corrections must remain in the same temporary ownership scope as the row
-- they supersede.  The original trigger already checks user/key/scope/version
-- and atomically retires the previous version; add the session/task identity.
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

-- Replace the old one-way artifact purge marker.  The legacy column remains
-- only as an always-null compatibility column so an old code path cannot
-- silently claim work; all old markers become reclaimable pending work.
drop function if exists private.select_expired_task_artifacts(integer, timestamptz);
drop function if exists private.request_expired_task_artifact_purge(integer, timestamptz);

alter table private.task_artifacts
  add column status text not null default 'pending',
  add column lease_token uuid,
  add column lease_expires_at timestamptz,
  add column attempt_count integer not null default 0,
  add column completed_at timestamptz,
  add column last_error_code text;

update private.task_artifacts
   set purge_requested_at = null
 where purge_requested_at is not null;

alter table private.task_artifacts
  drop constraint if exists task_artifacts_purge_requested_at_check,
  add constraint task_artifacts_legacy_purge_requested_at_empty_check
    check (purge_requested_at is null),
  add constraint task_artifacts_purge_status_check
    check (status in ('pending', 'leased', 'completed', 'failed')),
  add constraint task_artifacts_purge_attempt_count_check
    check (attempt_count between 0 and 1000000),
  add constraint task_artifacts_purge_last_error_code_check
    check (
      last_error_code is null
      or (
        last_error_code = pg_catalog.lower(pg_catalog.btrim(last_error_code))
        and pg_catalog.char_length(last_error_code) between 1 and 128
        and last_error_code ~ '^[a-z0-9][a-z0-9_.:-]*$'
      )
    ),
  add constraint task_artifacts_purge_completed_at_check
    check (completed_at is null or completed_at >= created_at),
  add constraint task_artifacts_purge_lease_state_check
    check (
      (status = 'pending' and lease_token is null and lease_expires_at is null and completed_at is null)
      or (status = 'leased' and lease_token is not null and lease_expires_at is not null and completed_at is null)
      or (status = 'completed' and lease_token is null and lease_expires_at is null and completed_at is not null)
      or (status = 'failed' and lease_token is null and lease_expires_at is null and completed_at is not null and last_error_code is not null)
    );

drop index if exists private.task_artifacts_expired_unrequested_idx;

create index task_artifacts_reclaimable_purge_idx
  on private.task_artifacts (expires_at asc, lease_expires_at asc, id asc)
  where status in ('pending', 'leased');

comment on column private.task_artifacts.purge_requested_at is
  'Deprecated compatibility column. It is constrained to NULL; lease state is authoritative.';
comment on column private.task_artifacts.lease_token is
  'Opaque claim token. Only the worker holding this token may complete or fail a leased artifact purge.';
comment on column private.task_artifacts.lease_expires_at is
  'Lease deadline for a claimed artifact purge. An expired lease is reclaimable by another worker.';
comment on column private.task_artifacts.attempt_count is
  'Number of durable purge claims; queue retry/dead-letter policy decides terminal failure.';

-- No runtime role may directly change artifact metadata.  The narrow
-- SECURITY DEFINER functions below are the worker's only retention surface.
revoke all privileges on table private.task_artifacts
  from service_role, swara_api_runtime, swara_worker_runtime;
drop policy if exists task_artifacts_service_role on private.task_artifacts;

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

  if p_as_of is null then
    raise exception using
      errcode = '22004',
      message = 'Artifact purge claim time is required';
  end if;

  return query
  with candidates as (
    select artifact.id
      from private.task_artifacts as artifact
     where artifact.expires_at <= p_as_of
       and (
         artifact.status = 'pending'
         or (
           artifact.status = 'leased'
           and artifact.lease_expires_at <= p_as_of
         )
       )
     order by artifact.expires_at asc, artifact.id asc
     limit p_limit
     for update skip locked
  ), claimed as (
    update private.task_artifacts as artifact
       set status = 'leased',
           lease_token = pg_catalog.gen_random_uuid(),
           lease_expires_at = p_as_of + (p_lease_seconds * interval '1 second'),
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
         completed_at = pg_catalog.now(),
         last_error_code = null
   where artifact.id = p_artifact_id
     and artifact.status = 'leased'
     and artifact.lease_token = p_lease_token
  returning true into v_completed;

  return v_completed;
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
         completed_at = case when p_terminal then pg_catalog.now() else null end,
         last_error_code = p_error_code
   where artifact.id = p_artifact_id
     and artifact.status = 'leased'
     and artifact.lease_token = p_lease_token
  returning true into v_failed;

  return v_failed;
end;
$function$;

revoke execute on function private.claim_expired_task_artifacts(integer, integer, timestamptz)
  from public, anon, authenticated, service_role, swara_api_runtime;
revoke execute on function private.complete_task_artifact_purge(uuid, uuid)
  from public, anon, authenticated, service_role, swara_api_runtime;
revoke execute on function private.fail_task_artifact_purge(uuid, uuid, text, boolean)
  from public, anon, authenticated, service_role, swara_api_runtime;

grant usage on schema private to swara_worker_runtime;
grant execute on function private.claim_expired_task_artifacts(integer, integer, timestamptz)
  to swara_worker_runtime;
grant execute on function private.complete_task_artifact_purge(uuid, uuid)
  to swara_worker_runtime;
grant execute on function private.fail_task_artifact_purge(uuid, uuid, text, boolean)
  to swara_worker_runtime;

comment on function private.claim_expired_task_artifacts(integer, integer, timestamptz) is
  'Worker-only bounded claim for expired task-artifact metadata. Leases are reclaimable and contain no artifact bytes.';
comment on function private.complete_task_artifact_purge(uuid, uuid) is
  'Worker-only completion acknowledgement for a matching task-artifact purge lease.';
comment on function private.fail_task_artifact_purge(uuid, uuid, text, boolean) is
  'Worker-only retry or terminal-failure acknowledgement for a matching task-artifact purge lease.';

-- audit.events is append-only. ON DELETE SET NULL attempted an UPDATE when
-- an Auth user was deleted and therefore conflicted with the append-only
-- trigger. Retain the nullable historical UUID and subject digest without a
-- live Auth foreign key so user deletion cannot mutate the audit ledger.
do $audit_auth_fk$
declare
  v_constraint_name name;
begin
  select constraint_row.conname
    into v_constraint_name
    from pg_catalog.pg_constraint as constraint_row
   where constraint_row.conrelid = 'audit.events'::pg_catalog.regclass
     and constraint_row.contype = 'f'
     and constraint_row.confrelid = 'auth.users'::pg_catalog.regclass
   limit 1;

  if v_constraint_name is not null then
    execute pg_catalog.format(
      'alter table audit.events drop constraint %I',
      v_constraint_name
    );
  end if;
end;
$audit_auth_fk$;

comment on column audit.events.user_id is
  'Nullable historical Swara Auth UUID. Deliberately not an Auth foreign key so append-only audit history never blocks Auth user deletion.';
comment on column audit.events.subject_hash is
  'Optional SHA-256 subject digest retained for durable audit correlation after an Auth account is deleted.';

-- Account lifecycle requests must be durably enqueued in the same transaction
-- that creates or recovers the idempotent request. No payload includes a
-- Storage path or the legacy documents bucket.
alter table private.account_export_requests
  add column correlation_id uuid not null default pg_catalog.gen_random_uuid(),
  add column queue_message_id bigint,
  add column queue_enqueued_at timestamptz,
  add constraint account_export_requests_queue_message_check
    check (queue_message_id is null or queue_message_id > 0),
  add constraint account_export_requests_queue_enqueued_check
    check ((queue_message_id is null) = (queue_enqueued_at is null));

alter table private.account_deletion_requests
  add column correlation_id uuid not null default pg_catalog.gen_random_uuid(),
  add column queue_message_id bigint,
  add column queue_enqueued_at timestamptz,
  add constraint account_deletion_requests_queue_message_check
    check (queue_message_id is null or queue_message_id > 0),
  add constraint account_deletion_requests_queue_enqueued_check
    check ((queue_message_id is null) = (queue_enqueued_at is null));

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
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 255 then
    raise exception using
      errcode = '22023',
      message = 'Account export request input is invalid';
  end if;

  -- M020 may be timestamped after this migration in an in-progress local
  -- branch. Check at invocation time, before any request state is written.
  if pg_catalog.to_regprocedure('private.enqueue_job(text,jsonb,integer)') is null then
    raise exception using
      errcode = '55000',
      message = 'Account export queue gateway is not available';
  end if;

  perform private.ensure_account_active(p_user_id);

  insert into private.account_export_requests (user_id, idempotency_key)
  values (p_user_id, p_idempotency_key)
  on conflict (user_id, idempotency_key) do nothing;

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

  if v_queue_message_id is null then
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
           queue_enqueued_at = pg_catalog.now()
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
  end if;

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
begin
  if p_user_id is null
     or p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 8 and 255 then
    raise exception using
      errcode = '22023',
      message = 'Account deletion request input is invalid';
  end if;

  -- See request_account_export: fail before creating a lifecycle row rather
  -- than weakening the queue boundary while M020 is unavailable.
  if pg_catalog.to_regprocedure('private.enqueue_job(text,jsonb,integer)') is null then
    raise exception using
      errcode = '55000',
      message = 'Account deletion queue gateway is not available';
  end if;

  insert into private.account_states (user_id, status, deletion_requested_at)
  values (p_user_id, 'deleting', pg_catalog.now())
  on conflict (user_id) do update
     set status = 'deleting',
         deletion_requested_at = coalesce(
           private.account_states.deletion_requested_at,
           pg_catalog.now()
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
  )
  on conflict (user_id, idempotency_key) do nothing;

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

  if not found then
    raise exception using
      errcode = '55000',
      message = 'Account deletion request could not be recovered';
  end if;

  if v_existing_export_request_id is distinct from p_export_request_id then
    raise exception using
      errcode = '22023',
      message = 'Account deletion idempotency key is bound to a different export request';
  end if;

  if v_queue_message_id is null then
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
           queue_enqueued_at = pg_catalog.now()
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
  end if;

  return v_request_id;
end;
$function$;

revoke execute on function private.request_account_export(uuid, text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke execute on function private.request_account_deletion(uuid, text, uuid)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;

grant usage on schema private to swara_api_runtime;
grant execute on function private.request_account_export(uuid, text)
  to swara_api_runtime;
grant execute on function private.request_account_deletion(uuid, text, uuid)
  to swara_api_runtime;

comment on function private.request_account_export(uuid, text) is
  'API-runtime-only atomic account-export request and account-export queue enqueue. Payload contains identifiers only, never Storage paths.';
comment on function private.request_account_deletion(uuid, text, uuid) is
  'API-runtime-only atomic account-deletion request and account-deletion queue enqueue. Payload contains identifiers only, never legacy documents paths.';

commit;
