begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(37);

-- Test-only grants for pgTAP under the role switches below. The transaction
-- rollback removes them before the next test runs.
grant usage on schema extensions to anon, authenticated, swara_api_runtime;
grant execute on all functions in schema extensions
  to anon, authenticated, swara_api_runtime;

select has_table('storage', 'buckets', 'Storage buckets table exists');
select has_table('storage', 'objects', 'Storage objects table exists');
select is(
  (select count(*)::integer from storage.buckets
    where id in ('vault-originals', 'vault-derived', 'task-artifacts', 'account-exports')),
  4,
  'all four Swara Storage buckets exist'
);
select is(
  (select count(*)::integer from storage.buckets
    where id in ('vault-originals', 'vault-derived', 'task-artifacts', 'account-exports')
      and public = false),
  4,
  'all four Swara Storage buckets are private'
);
select is(
  (select count(*)::integer from storage.objects
    where bucket_id = 'vault-originals'),
  0,
  'vault-originals starts empty'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_%'),
  6,
  'M022 installs exactly six final Swara Storage policies'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_%'
      and cmd = 'SELECT'),
  4,
  'originals, derived, artifacts, and exports are owner-readable'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_%'
      and cmd = 'INSERT'),
  1,
  'only Vault originals have an owner upload policy'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_%'
      and cmd = 'UPDATE'),
  1,
  'only Vault originals have an owner upsert policy'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_%'
      and cmd = 'DELETE'),
  0,
  'no authenticated Storage delete policy exists'
);
select ok(
  not exists (
    select 1
      from pg_catalog.pg_policies
     where schemaname = 'storage'
       and tablename = 'objects'
       and policyname like 'swara_%'
       and (coalesce(qual, '') || coalesce(with_check, '')) ~* $$bucket_id\\s*=\\s*'documents'$$
  ),
  'Swara Storage policies do not reference the legacy documents bucket'
);
select is(
  (select count(*)::integer from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'swara_%'
      and 'anon' = any(roles)),
  0,
  'Swara Storage policies grant no anonymous access'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'storage.objects'::regclass),
  'Storage objects RLS is enabled'
);
select ok(
  has_table_privilege('authenticated', 'storage.objects', 'SELECT')
  and has_table_privilege('authenticated', 'storage.objects', 'INSERT')
  and has_table_privilege('authenticated', 'storage.objects', 'UPDATE'),
  'authenticated Storage grants support the originals upsert path'
);

insert into auth.users (id)
values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

-- The API creates the pending metadata intent first. The browser upload below
-- uses the exact owner/document/filename path returned by that intent.
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.create_vault_upload_intent(
      '11111111-1111-4111-8111-111111111111',
      'upload.txt',
      'text/plain',
      42,
      repeat('a', 64),
      'local',
      'vault-intent-0061'
    )$$,
  'API runtime creates a pending Vault upload intent'
);
reset role;
select set_config(
  'm006.pending_path',
  (select storage_path from public.vault_documents
    where user_id = '11111111-1111-4111-8111-111111111111'
      and status = 'pending'),
  true
);
select ok(
  exists (
    select 1 from public.vault_documents
     where user_id = '11111111-1111-4111-8111-111111111111'
       and storage_bucket = 'vault-originals'
       and status = 'pending'
       and storage_path = current_setting('m006.pending_path')
  ),
  'the browser upload path is bound to a pending Vault upload intent'
);

insert into storage.objects (id, bucket_id, name, owner_id, metadata)
values
  ('30000000-0000-4000-8000-000000000001', 'vault-originals',
   '22222222-2222-4222-8222-222222222222/30000000-0000-4000-8000-000000000001/other.txt',
   '22222222-2222-4222-8222-222222222222', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000003', 'vault-derived',
   '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000003/derived.txt',
   '11111111-1111-4111-8111-111111111111', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000004', 'task-artifacts',
   '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000004/task.png',
   '11111111-1111-4111-8111-111111111111', '{}'::jsonb),
  ('30000000-0000-4000-8000-000000000005', 'account-exports',
   '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000005/export.zip',
   '11111111-1111-4111-8111-111111111111', '{}'::jsonb);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000006',
      'vault-originals',
      current_setting('m006.pending_path'),
      '11111111-1111-4111-8111-111111111111',
      '{}'::jsonb
    )$$,
  'an owner can upload only to an exact pending Vault originals path'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000007',
      'vault-originals',
      '11111111-1111-4111-8111-111111111111/not-a-resource/invalid.txt',
      '11111111-1111-4111-8111-111111111111',
      '{}'::jsonb
    )$$,
  '42501',
  null,
  'an owner cannot upload outside the exact Vault resource path'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000008',
      'vault-originals',
      '22222222-2222-4222-8222-222222222222/30000000-0000-4000-8000-000000000008/claimed.txt',
      '22222222-2222-4222-8222-222222222222',
      '{}'::jsonb
    )$$,
  '42501',
  null,
  'an owner cannot upload into another user Vault path'
);
select results_eq(
  $$select id from storage.objects
      where bucket_id = 'vault-originals'
      order by id$$,
  $$values ('30000000-0000-4000-8000-000000000006'::uuid)$$,
  'an owner can select only their own Vault original'
);
select results_eq(
  $$select id from storage.objects
      where id = '30000000-0000-4000-8000-000000000001'$$,
  $$select null::uuid where false$$,
  'cross-user Vault originals are not visible'
);
select lives_ok(
  $$update storage.objects
      set metadata = '{"upsert": true}'::jsonb
    where id = '30000000-0000-4000-8000-000000000006'$$,
  'an owner can update their Vault original for upsert'
);
select results_eq(
  $$select id from storage.objects where bucket_id = 'vault-derived'$$,
  $$values ('30000000-0000-4000-8000-000000000003'::uuid)$$,
  'an owner can read their derived output'
);
select results_eq(
  $$select id from storage.objects where bucket_id = 'task-artifacts'$$,
  $$values ('30000000-0000-4000-8000-000000000004'::uuid)$$,
  'an owner can read their task artifacts'
);
select results_eq(
  $$select id from storage.objects where bucket_id = 'account-exports'$$,
  $$values ('30000000-0000-4000-8000-000000000005'::uuid)$$,
  'an owner can read their account export'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000009', 'vault-derived',
      '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000009/derived.txt',
      '11111111-1111-4111-8111-111111111111', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owners cannot write derived outputs'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000010', 'task-artifacts',
      '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000010/task.png',
      '11111111-1111-4111-8111-111111111111', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owners cannot write task artifacts'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000011', 'account-exports',
      '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000011/export.zip',
      '11111111-1111-4111-8111-111111111111', '{}'::jsonb
    )$$,
  '42501',
  null,
  'authenticated owners cannot write account exports'
);
update storage.objects set metadata = '{"updated": true}'::jsonb
  where id = '30000000-0000-4000-8000-000000000003';
select is(
  (select metadata from storage.objects
    where id = '30000000-0000-4000-8000-000000000003'),
  '{}'::jsonb,
  'authenticated owners cannot update derived outputs'
);
update storage.objects set metadata = '{"updated": true}'::jsonb
  where id = '30000000-0000-4000-8000-000000000004';
select is(
  (select metadata from storage.objects
    where id = '30000000-0000-4000-8000-000000000004'),
  '{}'::jsonb,
  'authenticated owners cannot update task artifacts'
);
update storage.objects set metadata = '{"updated": true}'::jsonb
  where id = '30000000-0000-4000-8000-000000000005';
select is(
  (select metadata from storage.objects
    where id = '30000000-0000-4000-8000-000000000005'),
  '{}'::jsonb,
  'authenticated owners cannot update account exports'
);
select throws_ok(
  $$delete from storage.objects where id = '30000000-0000-4000-8000-000000000006'$$,
  '42501',
  null,
  'authenticated owners cannot delete Vault originals directly'
);
select throws_ok(
  $$delete from storage.objects where id = '30000000-0000-4000-8000-000000000003'$$,
  '42501',
  null,
  'authenticated owners cannot delete derived outputs directly'
);
select throws_ok(
  $$delete from storage.objects where id = '30000000-0000-4000-8000-000000000004'$$,
  '42501',
  null,
  'authenticated owners cannot delete task artifacts directly'
);
select throws_ok(
  $$delete from storage.objects where id = '30000000-0000-4000-8000-000000000005'$$,
  '42501',
  null,
  'authenticated owners cannot delete account exports directly'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select results_eq(
  $$select count(*) from storage.objects$$,
  $$values (0::bigint)$$,
  'anonymous clients cannot read Storage objects'
);
select throws_ok(
  $$insert into storage.objects (id, bucket_id, name, owner_id, metadata)
    values (
      '30000000-0000-4000-8000-000000000012', 'vault-originals',
      '11111111-1111-4111-8111-111111111111/30000000-0000-4000-8000-000000000012/anon.txt',
      '11111111-1111-4111-8111-111111111111', '{}'::jsonb
    )$$,
  '42501',
  null,
  'anonymous clients cannot write Storage objects'
);

select * from finish();
rollback;
