begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

select has_table('public', 'workflows', 'workflows exists');
select has_table('public', 'workflow_versions', 'workflow_versions exists');
select has_column('public', 'workflows', 'current_version_id', 'workflow tracks its current version');
select has_column('public', 'workflow_versions', 'definition', 'versions store validated JSON');
select ok(to_regprocedure('private.validate_workflow_version()') is not null, 'workflow validator exists');
select ok(not has_function_privilege('authenticated', 'private.validate_workflow_version()', 'EXECUTE'), 'validator is not client-callable');

insert into auth.users (id) values ('11111111-1111-4111-8111-111111111111');
insert into public.workflows (id, user_id, name)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111', 'Safe workflow');

select lives_ok(
  $$insert into public.workflow_versions
      (workflow_id, user_id, schema_version, definition, content_hash)
    values
      ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       '11111111-1111-4111-8111-111111111111', 1,
       '{"steps":[{"action":"fill","value":"{{email}}"}]}'::jsonb,
       repeat('a', 64))$$,
  'strict runtime placeholders are allowed'
);

select throws_ok(
  $$insert into public.workflow_versions
      (workflow_id, user_id, schema_version, definition, content_hash)
    values
      ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       '11111111-1111-4111-8111-111111111111', 1,
       '{"apiKey":"sk-this-must-not-persist"}'::jsonb,
       repeat('b', 64))$$,
  '22023'
);

select throws_ok(
  $$insert into public.workflow_versions
      (workflow_id, user_id, schema_version, definition, content_hash)
    values
      ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       '11111111-1111-4111-8111-111111111111', 1,
       '{"variable":{"sensitive":true,"default":"{{secret}}"}}'::jsonb,
       repeat('c', 64))$$,
  '22023'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.workflows'::regclass
      and conname = 'workflows_current_version_same_owner_fkey'
  ),
  'current version is constrained to the same workflow owner'
);

select * from finish();
rollback;
