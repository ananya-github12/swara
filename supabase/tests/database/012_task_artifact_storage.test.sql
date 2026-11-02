begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(20);

grant usage on schema extensions to anon, authenticated;
grant execute on all functions in schema extensions to anon, authenticated;

select is(
  (select count(*)::integer from storage.buckets where id = 'task-artifacts'),
  1,
  'task-artifacts bucket exists'
);
select is(
  (select count(*)::integer from storage.buckets
    where id = 'task-artifacts' and public = false),
  1,
  'task-artifacts is private'
);
select is(
  (select count(*)::integer from storage.objects where bucket_id = 'task-artifacts'),
  0,
  'task-artifacts starts empty'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_task_artifacts_%'),
  1,
  'task artifacts have one final owner-read policy'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_task_artifacts_%'
      and cmd = 'SELECT'),
  1,
  'task artifacts are readable by their owner'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_task_artifacts_%'
      and cmd in ('INSERT', 'UPDATE', 'DELETE')),
  0,
  'task artifacts have no browser write or delete policies'
);
select ok(
  not exists (
    select 1
      from pg_catalog.pg_policies
     where schemaname = 'storage'
       and tablename = 'objects'
       and policyname like 'swara_task_artifacts_%'
       and (coalesce(qual, '') || coalesce(with_check, '')) ilike '%documents%'
  ),
  'task artifact policies do not reference the legacy documents bucket'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_task_artifacts_%'
      and 'anon' = any(roles)),
  0,
  'task artifact policies grant no anonymous access'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'storage.objects'::regclass),
  'Storage objects RLS is enabled'
);
select ok(
  has_table_privilege('authenticated', 'storage.objects', 'SELECT'),
  'authenticated Storage read access is present'
);

insert into auth.users (id)
values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');
insert into storage.objects (id, bucket_id, name, owner_id, metadata)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'task-artifacts',
   '22222222-2222-4222-8222-222222222222/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/b.png',
   '22222222-2222-4222-8222-222222222222', '{}'::jsonb),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'task-artifacts',
   '11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a.png',
   '11111111-1111-4111-8111-111111111111', '{}'::jsonb);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select results_eq(
  $$select id from storage.objects where bucket_id = 'task-artifacts'$$,
  $$values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid)$$,
  'an owner can read only their own task artifact'
);
select results_eq(
  $$select id from storage.objects
      where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'$$,
  $$select null::uuid where false$$,
  'cross-user task artifacts are not visible'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'task-artifacts',
      '11111111-1111-4111-8111-111111111111/cccccccc-cccc-4ccc-8ccc-cccccccccccc/c.png',
      '11111111-1111-4111-8111-111111111111', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owners cannot write task artifacts'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'task-artifacts',
      '22222222-2222-4222-8222-222222222222/dddddddd-dddd-4ddd-8ddd-dddddddddddd/d.png',
      '22222222-2222-4222-8222-222222222222', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owners cannot write another user task artifacts'
);
update storage.objects set metadata = '{"updated": true}'::jsonb
  where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select is(
  (select metadata from storage.objects
    where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  '{}'::jsonb,
  'authenticated owners cannot update task artifacts'
);
update storage.objects set metadata = '{"claimed": true}'::jsonb
  where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
reset role;
select is(
  (select metadata from storage.objects
    where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  '{}'::jsonb,
  'authenticated owners cannot update another user task artifacts'
);
set local role authenticated;
select throws_ok(
  $$delete from storage.objects
      where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'$$,
  '42501',
  null,
  'authenticated owners cannot delete task artifacts'
);
select throws_ok(
  $$delete from storage.objects
      where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'$$,
  '42501',
  null,
  'authenticated owners cannot delete another user task artifacts'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select results_eq(
  $$select count(*) from storage.objects where bucket_id = 'task-artifacts'$$,
  $$values (0::bigint)$$,
  'anonymous clients cannot read task artifacts'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'task-artifacts',
      '11111111-1111-4111-8111-111111111111/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/e.png',
      '11111111-1111-4111-8111-111111111111', '{}'::jsonb
    )$$,
  '42501',
  null,
  'anonymous clients cannot write task artifacts'
);

select * from finish();
rollback;
