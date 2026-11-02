-- Swara foundation: internal schemas and reusable timestamp trigger support.
-- This migration deliberately makes no Auth, Storage, extension, queue, or
-- legacy `documents` bucket changes.

begin;

create schema if not exists private;
create schema if not exists audit;

-- These schemas are server-only. Explicit revokes make that boundary clear
-- even if a role gains privileges through a future database configuration.
revoke all privileges on schema private from public, anon, authenticated;
revoke all privileges on schema audit from public, anon, authenticated;

-- Lock down any objects already present in these schemas. The schemas are new
-- today, but the statements make the migration safe to re-run in a reset or
-- restored environment.
revoke all privileges on all tables in schema private from public, anon, authenticated;
revoke all privileges on all sequences in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

revoke all privileges on all tables in schema audit from public, anon, authenticated;
revoke all privileges on all sequences in schema audit from public, anon, authenticated;
revoke execute on all functions in schema audit from public, anon, authenticated;

-- Future application functions need an explicit, reviewed grant. Function
-- defaults are role-wide in Postgres, so revoke the default at the creating
-- role level; later migrations must grant execution deliberately.
alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema private
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres in schema private
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema private
  revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema audit
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres in schema audit
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema audit
  revoke execute on functions from public, anon, authenticated;

-- This trigger helper is invoked only by table triggers created in later
-- migrations. It is SECURITY INVOKER and resolves no caller-controlled names.
create or replace function private.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$function$;

revoke execute on function private.set_updated_at() from public, anon, authenticated;

comment on function private.set_updated_at() is
  'Internal trigger helper for updated_at columns; not callable by client roles.';

commit;
