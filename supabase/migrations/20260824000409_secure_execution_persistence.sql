-- Round 3D: server-only security for browser and voice execution state.
--
-- These tables are deliberately not an application/API surface.  The only
-- role granted DML access is service_role, which must remain server-side.
-- RLS is still enabled (and forced) as defense in depth in case a trusted
-- connection is ever used without the service_role bypass.
--
-- This migration creates trigger-only private functions for invariants.  It
-- does not create a callable checkpoint/event/provider API, so there is no
-- client-facing write function whose arguments could be confused with an
-- authenticated user's identity.  The execution schema is expected to store
-- redacted operational metadata only; filled values, raw instructions,
-- provider payloads, and secrets are intentionally not introduced here.

begin;

-- Keep the private namespace unavailable to all client roles.  Revoke the
-- schema and object classes separately because schema usage, relation access,
-- sequence access, and function execution are independent PostgreSQL checks.
revoke all privileges on schema private
  from public, anon, authenticated;

revoke all privileges on all tables in schema private
  from public, anon, authenticated;

revoke all privileges on all sequences in schema private
  from public, anon, authenticated;

revoke execute on all functions in schema private
  from public, anon, authenticated;

-- Reset direct grants on the Round 3 tables before granting the narrow
-- service-role contract.  In particular, task_events is insert/read only;
-- append-only behavior is also enforced by triggers below.
revoke all privileges on table
  private.browser_sessions,
  private.agent_tasks,
  private.task_steps,
  private.task_events,
  private.task_artifacts,
  private.provider_calls
  from public, anon, authenticated, service_role;

grant usage on schema private to service_role;

grant select, insert, update, delete
  on table
    private.browser_sessions,
    private.agent_tasks,
    private.task_steps,
    private.task_artifacts,
    private.provider_calls
  to service_role;

grant select, insert
  on table private.task_events
  to service_role;

-- UUID-backed tables normally need no sequences, but keep any sequence used
-- by this private schema inaccessible to clients and usable by the trusted
-- server role.  Do not grant sequence ownership or ALTER privileges.
revoke all privileges on all sequences in schema private
  from service_role;
grant usage, select, update on all sequences in schema private
  to service_role;

-- RLS remains enabled even though clients have no table grants.  FORCE makes
-- the policy boundary apply to table owners as well; service_role is given
-- explicit allow policies below and normally bypasses RLS in Supabase.
alter table private.browser_sessions enable row level security;
alter table private.browser_sessions force row level security;

alter table private.agent_tasks enable row level security;
alter table private.agent_tasks force row level security;

alter table private.task_steps enable row level security;
alter table private.task_steps force row level security;

alter table private.task_events enable row level security;
alter table private.task_events force row level security;

alter table private.task_artifacts enable row level security;
alter table private.task_artifacts force row level security;

alter table private.provider_calls enable row level security;
alter table private.provider_calls force row level security;

-- If a trusted connection does not use the service_role RLS bypass, it still
-- has an explicit policy.  No policy is created for PUBLIC, anon, or
-- authenticated; their revoked grants stop access before policy evaluation.
create policy browser_sessions_service_role
  on private.browser_sessions
  for all
  to service_role
  using (true)
  with check (true);

create policy agent_tasks_service_role
  on private.agent_tasks
  for all
  to service_role
  using (true)
  with check (true);

create policy task_steps_service_role
  on private.task_steps
  for all
  to service_role
  using (true)
  with check (true);

create policy task_events_service_role_select
  on private.task_events
  for select
  to service_role
  using (true);

create policy task_events_service_role_insert
  on private.task_events
  for insert
  to service_role
  with check (true);

create policy task_artifacts_service_role
  on private.task_artifacts
  for all
  to service_role
  using (true)
  with check (true);

create policy provider_calls_service_role
  on private.provider_calls
  for all
  to service_role
  using (true)
  with check (true);

-- One task sequence can have only one durable checkpoint.  This gives retry
-- and duplicate-delivery paths a database-level idempotency boundary and is
-- also the index used by the predecessor check in the trigger below.
create unique index if not exists task_steps_task_sequence_uidx
  on private.task_steps (task_id, "sequence");

-- The execution timeline is append-only.  Removing UPDATE/DELETE/TRUNCATE
-- grants is the first control; the trigger protects the invariant from a
-- later trusted-role grant or an accidental maintenance statement.
create or replace function private.reject_task_event_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  raise exception using
    errcode = '23514',
    message = 'private.task_events is append-only';

  return null;
end;
$function$;

create trigger task_events_append_only_row
  before update or delete on private.task_events
  for each row
  execute function private.reject_task_event_mutation();

create trigger task_events_append_only_truncate
  before truncate on private.task_events
  for each statement
  execute function private.reject_task_event_mutation();

-- Every event must belong to the same individual and a real browser session
-- through its task.  This is a trigger invariant rather than a client-callable
-- helper, so there is no user-controlled identity argument to trust.
create or replace function private.validate_task_event_ownership()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  task_user_id uuid;
begin
  if new.user_id is null or new.task_id is null then
    raise exception using
      errcode = '23514',
      message = 'Execution events require an owner and task';
  end if;

  select t.user_id
    into task_user_id
    from private.agent_tasks as t
    join private.browser_sessions as s
      on s.id = t.session_id
     and s.user_id = t.user_id
   where t.id = new.task_id;

  if not found or task_user_id is distinct from new.user_id then
    raise exception using
      errcode = '23514',
      message = 'Execution event ownership does not match its task session';
  end if;

  return new;
end;
$function$;

create trigger task_events_validate_ownership
  before insert on private.task_events
  for each row
  execute function private.validate_task_event_ownership();

-- A checkpoint is tied to an owned task/session, uses a positive ordered
-- sequence, and cannot be moved to another task or owner after insertion.
-- Requiring the predecessor prevents a retry or concurrent writer from
-- silently creating a hole in the durable execution timeline.
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
     or new."sequence" is null
     or new."sequence" < 1 then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoints require an owner, task, and positive sequence';
  end if;

  select t.user_id, t.max_steps
    into task_user_id, task_max_steps
    from private.agent_tasks as t
    join private.browser_sessions as s
      on s.id = t.session_id
     and s.user_id = t.user_id
   where t.id = new.task_id;

  if not found or task_user_id is distinct from new.user_id then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint ownership does not match its task session';
  end if;

  if task_max_steps is not null and new."sequence" > task_max_steps then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint exceeds the task step limit';
  end if;

  if new."sequence" > 1 and not exists (
    select 1
      from private.task_steps as prior
     where prior.task_id = new.task_id
       and prior.user_id = new.user_id
       and prior."sequence" = new."sequence" - 1
  ) then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoints must be written in order';
  end if;

  if tg_op = 'UPDATE' and (
       new.user_id is distinct from old.user_id
    or new.task_id is distinct from old.task_id
    or new."sequence" is distinct from old."sequence"
  ) then
    raise exception using
      errcode = '23514',
      message = 'Task checkpoint ownership and sequence are immutable';
  end if;

  return new;
end;
$function$;

create trigger task_steps_validate_checkpoint
  before insert or update on private.task_steps
  for each row
  execute function private.validate_task_step_checkpoint();

-- Trigger functions are internal implementation details, never RPC/API
-- endpoints.  Revoke their default PUBLIC execution explicitly after
-- creation and allow only the trusted role needed to execute the triggers.
revoke execute on function private.reject_task_event_mutation()
  from public, anon, authenticated;
revoke execute on function private.validate_task_event_ownership()
  from public, anon, authenticated;
revoke execute on function private.validate_task_step_checkpoint()
  from public, anon, authenticated;

grant execute on function private.reject_task_event_mutation()
  to service_role;
grant execute on function private.validate_task_event_ownership()
  to service_role;
grant execute on function private.validate_task_step_checkpoint()
  to service_role;

commit;
