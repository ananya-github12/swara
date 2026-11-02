-- Round 4D: server-only durable billing, lifecycle, and retention queues.
--
-- This migration creates only the five Round 4 queues. It does not drop,
-- purge, rename, or otherwise modify the existing Round 2 queues.

begin;

-- Use the pgmq version supplied by the target Supabase Postgres image/project.
-- Logged queues are durable; create_unlogged is intentionally not used.
create extension if not exists pgmq;

select pgmq.create('billing-outbox');
select pgmq.create('usage-reconciliation');
select pgmq.create('account-export');
select pgmq.create('account-deletion');
select pgmq.create('artifact-retention');

-- Keep the pgmq extension and all queue/archive tables server-only. These
-- revokes also cover the existing Round 2 queues without changing their data
-- or queue definitions.
revoke all privileges on schema pgmq from public, anon, authenticated;
revoke all privileges on all tables in schema pgmq from public, anon, authenticated;
revoke all privileges on all sequences in schema pgmq from public, anon, authenticated;
revoke execute on all functions in schema pgmq from public, anon, authenticated;

-- The trusted application server may publish and consume messages directly
-- through pgmq. No CREATE privilege is granted on the internal schema.
grant usage on schema pgmq to service_role;
grant select, insert, update, delete
  on all tables in schema pgmq to service_role;
grant usage, select, update
  on all sequences in schema pgmq to service_role;
grant execute on all functions in schema pgmq to service_role;

-- Keep future pgmq objects closed to client roles and available to the
-- trusted server role if additional server-side queues are added later.
alter default privileges in schema pgmq
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges in schema pgmq
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges in schema pgmq
  revoke execute on functions from public, anon, authenticated;
alter default privileges in schema pgmq
  grant select, insert, update, delete on tables to service_role;
alter default privileges in schema pgmq
  grant usage, select, update on sequences to service_role;
alter default privileges in schema pgmq
  grant execute on functions to service_role;

-- pgmq_public is created only when queue exposure is enabled. If it exists,
-- revoke every client/API privilege from its current wrappers and objects;
-- do not create, drop, or expose the schema here.
do $function$
begin
  if exists (
    select 1
    from pg_catalog.pg_namespace
    where nspname = 'pgmq_public'
  ) then
    execute 'revoke all privileges on schema pgmq_public from public, anon, authenticated';
    execute 'revoke all privileges on all tables in schema pgmq_public from public, anon, authenticated';
    execute 'revoke all privileges on all sequences in schema pgmq_public from public, anon, authenticated';
    execute 'revoke execute on all functions in schema pgmq_public from public, anon, authenticated';
  end if;
end;
$function$;

commit;
