-- Round 2D: server-only durable Vault queues.
--
-- This migration deliberately does not create pgmq_public wrappers or expose
-- pgmq through the Data API. Queue consumers use trusted server-side database
-- access to the pgmq schema directly.

begin;

-- No VERSION clause: use the pgmq version supplied by the target Supabase
-- Postgres image/project.
create extension if not exists pgmq;

-- pgmq.create creates logged queue and archive tables. Logged queues are the
-- durable/basic queue type; create_unlogged is intentionally not used.
select pgmq.create('vault-ingest');
select pgmq.create('ocr-fallback');
select pgmq.create('generate-embeddings');

-- Remove client-role access from the extension schema, its queue/archive
-- tables, sequences, and all extension functions. This is separate from the
-- Data API schema allow-list and remains enforced at the database boundary.
revoke all privileges on schema pgmq from public, anon, authenticated;
revoke all privileges on all tables in schema pgmq from public, anon, authenticated;
revoke all privileges on all sequences in schema pgmq from public, anon, authenticated;
revoke execute on all functions in schema pgmq from public, anon, authenticated;

-- The application server may consume and publish messages through its trusted
-- service role. It is not a Data API client role and receives no pgmq_public
-- access. No CREATE privilege is granted on the internal schema.
grant usage on schema pgmq to service_role;
grant select, insert, update, delete
  on all tables in schema pgmq to service_role;
grant usage, select, update
  on all sequences in schema pgmq to service_role;
grant execute on all functions in schema pgmq to service_role;

-- Keep future queue objects closed to client roles and available to the
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

-- A pgmq_public schema is normally created only when queue exposure is
-- enabled in Supabase. If one already exists, make any existing wrappers
-- unusable by all client/API roles without creating or dropping the schema.
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
