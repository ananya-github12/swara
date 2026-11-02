begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(21);

grant usage on schema extensions to anon, authenticated, service_role, swara_api_runtime;
grant execute on all functions in schema extensions
  to anon, authenticated, service_role, swara_api_runtime;

insert into auth.users (id)
values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');
insert into public.workflows (id, user_id, name)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '11111111-1111-4111-8111-111111111111',
   'User A'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '22222222-2222-4222-8222-222222222222',
   'User B');

-- M023 requires an expected current version for every existing workflow.
-- Seed the fixture with the version the import below must lock before it can
-- atomically replace the current pointer.
insert into public.workflow_versions
  (id, workflow_id, user_id, schema_version, definition, content_hash)
values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '11111111-1111-4111-8111-111111111111',
   1,
   '{"steps":[]}'::jsonb,
   repeat('c', 64));
update public.workflows
   set current_version_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.workflows'::regclass),
  'workflow RLS is enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.workflow_versions'::regclass),
  'workflow version RLS is enabled'
);
select ok(
  has_table_privilege('authenticated', 'public.workflows', 'SELECT')
  and not has_table_privilege('authenticated', 'public.workflows', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workflows', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workflows', 'DELETE')
  and has_table_privilege('authenticated', 'public.workflow_versions', 'SELECT')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workflow_versions', 'DELETE'),
  'authenticated workflow access is SELECT only'
);
select ok(
  has_function_privilege(
    'swara_api_runtime',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)',
    'EXECUTE'
  ),
  'atomic workflow import is private to the API runtime'
);

set local role swara_api_runtime;
select lives_ok(
  $$select * from private.import_workflow_atomic(
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'User A',
      1,
      '{"steps":[{"type":"click"}]}'::jsonb,
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'workflow-import-0091',
      '99999999-9999-4999-8999-999999999999'
    )$$,
  'API runtime can atomically import a workflow and version'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select results_eq(
  $$select id from public.workflows$$,
  $$values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid)$$,
  'an owner can select only their own workflow'
);
select is(
  (select version.definition
     from public.workflows as workflow
     join public.workflow_versions as version
       on version.id = workflow.current_version_id
    where workflow.id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  '{"steps":[{"type":"click"}]}'::jsonb,
  'an owner can select the version made current by atomic import'
);
select results_eq(
  $$select id from public.workflows
      where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'$$,
  $$select null::uuid where false$$,
  'cross-user workflows are not visible'
);
select is(
  (select count(*)::integer from public.workflow_versions
    where workflow_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  0,
  'cross-user workflow versions are not visible'
);
select throws_ok(
  $$insert into public.workflows (id, user_id, name)
      values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              '11111111-1111-4111-8111-111111111111', 'Direct')$$,
  '42501',
  null,
  'authenticated users cannot create workflows directly'
);
select throws_ok(
  $$insert into public.workflows (user_id, name)
      values ('22222222-2222-4222-8222-222222222222', 'Claimed')$$,
  '42501',
  null,
  'authenticated users cannot create a workflow for another user'
);
select throws_ok(
  $$update public.workflows set name = 'rewritten'
      where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  '42501',
  null,
  'authenticated users cannot update workflows directly'
);
select throws_ok(
  $$delete from public.workflows
      where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  '42501',
  null,
  'authenticated users cannot delete workflows directly'
);
select throws_ok(
  $$insert into public.workflow_versions
      (workflow_id, user_id, schema_version, definition, content_hash)
    values
      ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       '11111111-1111-4111-8111-111111111111',
       1, '{"steps":[]}'::jsonb, repeat('a', 64))$$,
  '42501',
  null,
  'authenticated users cannot append workflow versions directly'
);
select throws_ok(
  $$update public.workflow_versions set schema_version = 2
      where workflow_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  '42501',
  null,
  'authenticated users cannot update workflow versions directly'
);
select throws_ok(
  $$delete from public.workflow_versions
      where workflow_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  '42501',
  null,
  'authenticated users cannot delete workflow versions directly'
);

reset role;
set local role service_role;
select throws_ok(
  $$select count(*) from public.workflows$$,
  '42501',
  null,
  'service_role has no direct workflow read path'
);
select throws_ok(
  $$insert into public.workflows (user_id, name)
      values ('11111111-1111-4111-8111-111111111111', 'Service direct')$$,
  '42501',
  null,
  'service_role cannot bypass atomic workflow import'
);
select throws_ok(
  $$insert into public.workflow_versions
      (workflow_id, user_id, schema_version, definition, content_hash)
    values
      ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       '11111111-1111-4111-8111-111111111111',
       1, '{"steps":[]}'::jsonb, repeat('b', 64))$$,
  '42501',
  null,
  'service_role cannot append workflow versions directly'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select throws_ok(
  $$select count(*) from public.workflows$$,
  '42501',
  null,
  'anonymous clients cannot read workflows'
);
select ok(
  not has_table_privilege('anon', 'public.workflows', 'SELECT')
  and not has_table_privilege('anon', 'public.workflow_versions', 'SELECT'),
  'anonymous clients have no workflow table grants'
);

select * from finish();
rollback;
