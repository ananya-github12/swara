begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

select has_schema('private', 'private schema exists');
select has_schema('audit', 'audit schema exists');

select ok(
  not has_schema_privilege('authenticated', 'private', 'USAGE'),
  'authenticated has no private schema usage'
);
select ok(
  not has_schema_privilege('anon', 'private', 'USAGE'),
  'anon has no private schema usage'
);
select ok(
  not has_schema_privilege('authenticated', 'audit', 'USAGE'),
  'authenticated has no audit schema usage'
);
select ok(
  not has_schema_privilege('anon', 'audit', 'USAGE'),
  'anon has no audit schema usage'
);

select ok(
  not has_function_privilege('authenticated', 'private.set_updated_at()', 'EXECUTE'),
  'authenticated cannot execute the private trigger helper'
);
select ok(
  not has_function_privilege('anon', 'private.set_updated_at()', 'EXECUTE'),
  'anon cannot execute the private trigger helper'
);

select is(
  (
    select count(*)::integer
    from information_schema.table_privileges
    where table_schema = 'public'
      and table_name in (
        'profiles',
        'user_settings',
        'devices',
        'domain_policies',
        'consent_records'
      )
      and grantee = 'anon'
  ),
  0,
  'anon has no identity table privileges'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'graphql_public')
      and p.prosecdef
  ),
  0,
  'no exposed-schema function is security definer'
);

select * from finish();
rollback;
