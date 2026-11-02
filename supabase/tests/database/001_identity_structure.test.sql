begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

select has_table('public', 'profiles', 'profiles exists');
select has_table('public', 'user_settings', 'user_settings exists');
select has_table('public', 'devices', 'devices exists');
select has_table('public', 'domain_policies', 'domain_policies exists');
select has_table('public', 'consent_records', 'consent_records exists');

select col_is_pk('public', 'profiles', 'user_id', 'profiles.user_id is the primary key');

select has_column('public', 'profiles', 'user_id', 'profiles is user-owned');
select has_column('public', 'user_settings', 'user_id', 'user_settings is user-owned');
select has_column('public', 'devices', 'user_id', 'devices is user-owned');
select has_column('public', 'domain_policies', 'user_id', 'domain_policies is user-owned');
select has_column('public', 'consent_records', 'user_id', 'consent_records is user-owned');

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.profiles'::regclass),
  'profiles has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.user_settings'::regclass),
  'user_settings has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.devices'::regclass),
  'devices has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.domain_policies'::regclass),
  'domain_policies has RLS enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.consent_records'::regclass),
  'consent_records has RLS enabled'
);

select is(
  (
    select count(*)::integer
    from information_schema.columns
    where table_schema = 'public'
      and table_name in (
        'profiles',
        'user_settings',
        'devices',
        'domain_policies',
        'consent_records'
      )
      and (
        column_name in ('tenant_id', 'client_id', 'sub_client_id', 'workspace_id', 'company_id')
        or column_name like '%company_role%'
      )
  ),
  0,
  'identity tables contain no tenant, client, workspace, or company identity columns'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_constraint
    where contype = 'f'
      and confrelid = 'auth.users'::regclass
      and conrelid in (
        'public.profiles'::regclass,
        'public.user_settings'::regclass,
        'public.devices'::regclass,
        'public.domain_policies'::regclass,
        'public.consent_records'::regclass
      )
  ),
  5,
  'every identity table references the Swara auth.users table'
);

select * from finish();
rollback;
