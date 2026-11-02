-- Round 5A / M018: least-privilege direct-database runtime groups.
--
-- The Supabase Data API remains restricted to public, graphql_public.  These
-- NOLOGIN roles are only permission groups for separately provisioned direct
-- Postgres logins.  They neither expose a schema nor carry a password.

begin;

-- Idempotently create the two application permission groups.  Supabase's
-- migration runner can create roles but intentionally cannot alter arbitrary
-- roles, so an unexpected pre-existing privileged role fails closed instead
-- of silently changing its authority.
do $role$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'swara_api_runtime'
  ) then
    create role swara_api_runtime
      nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls noinherit;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'swara_worker_runtime'
  ) then
    create role swara_worker_runtime
      nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls noinherit;
  end if;

  if exists (
    select 1
    from pg_catalog.pg_roles
    where rolname in ('swara_api_runtime', 'swara_worker_runtime')
      and (
        rolcanlogin
        or rolsuper
        or rolcreatedb
        or rolcreaterole
        or rolreplication
        or rolbypassrls
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'Swara runtime permission groups must remain NOLOGIN and non-privileged';
  end if;
end;
$role$;

-- The database administrator can assume the NOLOGIN groups for pgTAP and
-- operational inspection. This neither creates a runtime login nor broadens
-- either group; separately provisioned application logins are still managed
-- out of band.
grant swara_api_runtime, swara_worker_runtime to postgres;

-- Neither permission group may create durable objects.  A separately
-- provisioned runtime login should inherit only the grants below; it must
-- never become the owner of a Swara table or function.
revoke create on schema public, private, audit, pgmq
  from swara_api_runtime, swara_worker_runtime;

-- Remove the legacy broad server credential from every internal namespace.
-- service_role remains available for Supabase Auth and Storage administration,
-- but can no longer reach Swara private state, audit records, or PGMQ.
revoke all privileges on schema private from public, anon, authenticated, service_role;
revoke all privileges on all tables in schema private from public, anon, authenticated, service_role;
revoke all privileges on all sequences in schema private from public, anon, authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated, service_role;

revoke all privileges on schema audit from public, anon, authenticated, service_role;
revoke all privileges on all tables in schema audit from public, anon, authenticated, service_role;
revoke all privileges on all sequences in schema audit from public, anon, authenticated, service_role;
revoke execute on all functions in schema audit from public, anon, authenticated, service_role;

revoke all privileges on schema pgmq from public, anon, authenticated, service_role;
revoke all privileges on all tables in schema pgmq from public, anon, authenticated, service_role;
revoke all privileges on all sequences in schema pgmq from public, anon, authenticated, service_role;
revoke execute on all functions in schema pgmq from public, anon, authenticated, service_role;

-- Reset both runtime groups before granting their intentionally narrow
-- contracts.  In particular, workers must not operate PGMQ directly; M020
-- will introduce reviewed queue wrappers before that capability is restored.
revoke all privileges on schema private, audit, pgmq
  from swara_api_runtime, swara_worker_runtime;
revoke all privileges on all tables in schema private from swara_api_runtime, swara_worker_runtime;
revoke all privileges on all sequences in schema private from swara_api_runtime, swara_worker_runtime;
revoke execute on all functions in schema private from swara_api_runtime, swara_worker_runtime;

revoke all privileges on all tables in schema audit from swara_api_runtime, swara_worker_runtime;
revoke all privileges on all sequences in schema audit from swara_api_runtime, swara_worker_runtime;
revoke execute on all functions in schema audit from swara_api_runtime, swara_worker_runtime;

revoke all privileges on all tables in schema pgmq from swara_api_runtime, swara_worker_runtime;
revoke all privileges on all sequences in schema pgmq from swara_api_runtime, swara_worker_runtime;
revoke execute on all functions in schema pgmq from swara_api_runtime, swara_worker_runtime;

-- Replace service_role-only RLS policies with the two direct-runtime policies.
-- RLS remains enabled on all private/audit tables; neither runtime group has
-- BYPASSRLS, so table grants alone are insufficient.
drop policy if exists browser_sessions_service_role on private.browser_sessions;
drop policy if exists agent_tasks_service_role on private.agent_tasks;
drop policy if exists task_steps_service_role on private.task_steps;
drop policy if exists task_events_service_role_select on private.task_events;
drop policy if exists task_events_service_role_insert on private.task_events;
drop policy if exists task_artifacts_service_role on private.task_artifacts;
drop policy if exists provider_calls_service_role on private.provider_calls;

drop policy if exists billing_links_service_role_all on private.billing_links;
drop policy if exists entitlement_snapshots_service_role_all on private.entitlement_snapshots;
drop policy if exists quota_buckets_service_role_all on private.quota_buckets;
drop policy if exists usage_reservations_service_role_all on private.usage_reservations;
drop policy if exists usage_events_service_role_select on private.usage_events;
drop policy if exists usage_events_service_role_insert on private.usage_events;
drop policy if exists usage_events_service_role_update_settlement on private.usage_events;
drop policy if exists billing_outbox_service_role_all on private.billing_outbox;

drop policy if exists account_states_service on private.account_states;
drop policy if exists account_exports_service on private.account_export_requests;
drop policy if exists account_deletions_service on private.account_deletion_requests;
drop policy if exists audit_events_service_select on audit.events;
drop policy if exists audit_events_service_insert on audit.events;

-- API runtime: the exact private execution tables and verbs used by the
-- current request-scoped ExecutionRepository.  It can read registered devices
-- solely to validate the request's device/user pairing; it receives no public
-- write privilege and no access to any Vault, billing, lifecycle, audit, or
-- queue table.
grant usage on schema private to swara_api_runtime;
grant select on table public.devices to swara_api_runtime;
grant select, insert, update on table private.browser_sessions to swara_api_runtime;
grant select, insert, update on table private.agent_tasks to swara_api_runtime;
grant select, insert on table private.task_steps to swara_api_runtime;
grant select, insert on table private.task_events to swara_api_runtime;
grant select, insert on table private.provider_calls to swara_api_runtime;

create policy devices_api_runtime_select
  on public.devices
  for select
  to swara_api_runtime
  using (true);

create policy browser_sessions_api_runtime
  on private.browser_sessions
  for all
  to swara_api_runtime
  using (true)
  with check (true);

create policy agent_tasks_api_runtime
  on private.agent_tasks
  for all
  to swara_api_runtime
  using (true)
  with check (true);

create policy task_steps_api_runtime
  on private.task_steps
  for select
  to swara_api_runtime
  using (true);
create policy task_steps_api_runtime_insert
  on private.task_steps
  for insert
  to swara_api_runtime
  with check (true);

create policy task_events_api_runtime_select
  on private.task_events
  for select
  to swara_api_runtime
  using (true);
create policy task_events_api_runtime_insert
  on private.task_events
  for insert
  to swara_api_runtime
  with check (true);

create policy provider_calls_api_runtime_select
  on private.provider_calls
  for select
  to swara_api_runtime
  using (true);
create policy provider_calls_api_runtime_insert
  on private.provider_calls
  for insert
  to swara_api_runtime
  with check (true);

-- The API does not get direct billing or lifecycle table access.  The
-- reviewed transaction functions are SECURITY DEFINER with a fixed search
-- path, and accept identities only from the authenticated API layer.
alter function private.reserve_usage_atomic(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.timestamptz,
  pg_catalog.timestamptz, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.timestamptz
) security definer;
alter function private.commit_usage_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.uuid, pg_catalog.uuid
) security definer;
alter function private.release_usage_reservation_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.text
) security definer;

grant execute on function private.reserve_usage_atomic(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.timestamptz,
  pg_catalog.timestamptz, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.timestamptz
) to swara_api_runtime;
grant execute on function private.commit_usage_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.uuid, pg_catalog.uuid
) to swara_api_runtime;
grant execute on function private.release_usage_reservation_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.text
) to swara_api_runtime;
grant execute on function private.request_account_export(uuid, text)
  to swara_api_runtime;
grant execute on function private.request_account_deletion(uuid, text, uuid)
  to swara_api_runtime;

-- Worker runtime: documents, billing/lifecycle state transitions, bounded
-- retention handoff, and the bounded Cron dispatcher.  It deliberately has
-- neither execution-table access nor any direct PGMQ schema/table/function
-- privilege.  Later queue gateways will replace the remaining direct worker
-- table grants with tighter transaction functions.
grant usage on schema private, audit to swara_worker_runtime;
grant select, insert, update, delete on table private.document_chunks to swara_worker_runtime;

grant select, insert, update on table private.billing_links to swara_worker_runtime;
grant select, insert on table private.entitlement_snapshots to swara_worker_runtime;
grant select, insert, update on table private.quota_buckets to swara_worker_runtime;
grant select, update on table private.usage_reservations to swara_worker_runtime;
grant select, update (
  alterity_receipt_id,
  billed_amount_micros,
  billed_currency_code,
  settled_at
) on table private.usage_events to swara_worker_runtime;
grant select, update on table private.billing_outbox to swara_worker_runtime;

grant select, update on table private.account_states to swara_worker_runtime;
grant select, update on table private.account_export_requests to swara_worker_runtime;
grant select, update on table private.account_deletion_requests to swara_worker_runtime;
grant insert on table audit.events to swara_worker_runtime;

create policy document_chunks_worker_runtime
  on private.document_chunks
  for all
  to swara_worker_runtime
  using (true)
  with check (true);

create policy billing_links_worker_runtime
  on private.billing_links
  for all
  to swara_worker_runtime
  using (true)
  with check (true);
create policy entitlement_snapshots_worker_runtime_select
  on private.entitlement_snapshots
  for select
  to swara_worker_runtime
  using (true);
create policy entitlement_snapshots_worker_runtime_insert
  on private.entitlement_snapshots
  for insert
  to swara_worker_runtime
  with check (true);
create policy quota_buckets_worker_runtime
  on private.quota_buckets
  for all
  to swara_worker_runtime
  using (true)
  with check (true);
create policy usage_reservations_worker_runtime_select
  on private.usage_reservations
  for select
  to swara_worker_runtime
  using (true);
create policy usage_reservations_worker_runtime_update
  on private.usage_reservations
  for update
  to swara_worker_runtime
  using (true)
  with check (true);
create policy usage_events_worker_runtime_select
  on private.usage_events
  for select
  to swara_worker_runtime
  using (true);
create policy usage_events_worker_runtime_update
  on private.usage_events
  for update
  to swara_worker_runtime
  using (true)
  with check (true);
create policy billing_outbox_worker_runtime_select
  on private.billing_outbox
  for select
  to swara_worker_runtime
  using (true);
create policy billing_outbox_worker_runtime_update
  on private.billing_outbox
  for update
  to swara_worker_runtime
  using (true)
  with check (true);

create policy account_states_worker_runtime_select
  on private.account_states
  for select
  to swara_worker_runtime
  using (true);
create policy account_states_worker_runtime_update
  on private.account_states
  for update
  to swara_worker_runtime
  using (true)
  with check (true);
create policy account_export_requests_worker_runtime_select
  on private.account_export_requests
  for select
  to swara_worker_runtime
  using (true);
create policy account_export_requests_worker_runtime_update
  on private.account_export_requests
  for update
  to swara_worker_runtime
  using (true)
  with check (true);
create policy account_deletion_requests_worker_runtime_select
  on private.account_deletion_requests
  for select
  to swara_worker_runtime
  using (true);
create policy account_deletion_requests_worker_runtime_update
  on private.account_deletion_requests
  for update
  to swara_worker_runtime
  using (true)
  with check (true);
create policy audit_events_worker_runtime_insert
  on audit.events
  for insert
  to swara_worker_runtime
  with check (true);

-- Existing retention and maintenance functions are already bounded and have
-- fixed search paths.  Make the dispatcher SECURITY DEFINER so workers do
-- not need direct pgmq.send access; its allowlist remains the only path.
alter function private.enqueue_maintenance_dispatch(text, text, integer, integer)
  security definer;

grant execute on function private.release_usage_reservation_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.text
) to swara_worker_runtime;
grant execute on function private.select_expired_task_artifacts(integer, timestamptz)
  to swara_worker_runtime;
grant execute on function private.request_expired_task_artifact_purge(integer, timestamptz)
  to swara_worker_runtime;
grant execute on function private.enqueue_maintenance_dispatch(text, text, integer, integer)
  to swara_worker_runtime;

-- Default ACLs must never silently recreate the old service-role path.  The
-- global function rule handles PostgreSQL's implicit PUBLIC EXECUTE default;
-- schema-specific rules make the Swara boundary explicit for future objects.
alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema private
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke execute on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema audit
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema audit
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema audit
  revoke execute on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema pgmq
  revoke all privileges on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pgmq
  revoke all privileges on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema pgmq
  revoke execute on functions from public, anon, authenticated, service_role;

-- Fail closed on a restored database if either permission group somehow owns
-- durable Swara objects.  Do not transfer ownership implicitly in a security
-- migration: an operator must review that unexpected state explicitly.
do $ownership$
begin
  if exists (
    select 1
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_roles as owner on owner.oid = relation.relowner
    where relation.relkind in ('r', 'p')
      and owner.rolname in ('swara_api_runtime', 'swara_worker_runtime')
  ) then
    raise exception using
      errcode = '55000',
      message = 'Swara runtime permission groups must not own tables';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_roles as owner on owner.oid = routine.proowner
    where owner.rolname in ('swara_api_runtime', 'swara_worker_runtime')
  ) then
    raise exception using
      errcode = '55000',
      message = 'Swara runtime permission groups must not own functions';
  end if;
end;
$ownership$;

comment on role swara_api_runtime is
  'NOLOGIN direct-Postgres permission group for authenticated Swara API execution and atomic user operations.';
comment on role swara_worker_runtime is
  'NOLOGIN direct-Postgres permission group for bounded Swara workers; PGMQ remains unavailable until queue gateways exist.';

commit;
