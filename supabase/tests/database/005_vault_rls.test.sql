begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(27);

-- These grants are test-harness-only and roll back with this transaction. They
-- let pgTAP run after the role switches used to prove each boundary.
grant usage on schema extensions to anon, authenticated, service_role, swara_api_runtime;
grant execute on all functions in schema extensions
  to anon, authenticated, service_role, swara_api_runtime;

insert into auth.users (id)
values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

insert into public.vault_documents
  (id, user_id, filename, mime_type, size_bytes, sha256, storage_bucket,
   storage_path, extraction_method)
values
  ('33333333-3333-4333-8333-333333333333',
   '22222222-2222-4222-8222-222222222222',
   'user-b.txt', 'text/plain', 1, repeat('b', 64), 'vault-originals',
   '22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/user-b.txt',
   'local');

insert into public.swara_context_items
  (id, user_id, type, key, value)
values
  ('55555555-5555-4555-8555-555555555555',
   '22222222-2222-4222-8222-222222222222',
   'fact', 'owner', 'User B');

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.vault_documents'::regclass),
  'vault_documents RLS is enabled'
);
select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.swara_context_items'::regclass),
  'context_items RLS is enabled'
);
select ok(
  has_function_privilege(
    'swara_api_runtime',
    'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'private.create_vault_upload_intent(uuid,text,text,bigint,text,text,text)',
    'EXECUTE'
  ),
  'Vault metadata mutation is exposed only through the API runtime function'
);

-- The browser receives metadata only after the trusted API creates a pending
-- upload intent. The browser does not insert Vault metadata itself.
set local role swara_api_runtime;
select lives_ok(
  $$select * from private.create_vault_upload_intent(
      '11111111-1111-4111-8111-111111111111',
      'user-a.txt',
      'text/plain',
      1,
      repeat('a', 64),
      'local',
      'vault-intent-0051'
    )$$,
  'API runtime creates the owner Vault upload intent'
);
reset role;
select is(
  (select status from public.vault_documents
    where user_id = '11111111-1111-4111-8111-111111111111'),
  'pending',
  'API-created Vault metadata starts in pending state'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select results_eq(
  $$select id from public.vault_documents order by id$$,
  $$select id from public.vault_documents
      where user_id = '11111111-1111-4111-8111-111111111111'$$,
  'an owner can select only their own Vault metadata'
);
select results_eq(
  $$select id from public.vault_documents
      where id = '33333333-3333-4333-8333-333333333333'$$,
  $$select null::uuid where false$$,
  'cross-user Vault metadata is not visible'
);

select throws_ok(
  $$insert into public.vault_documents
      (user_id, filename, mime_type, size_bytes, sha256, storage_path, extraction_method)
    values
      ('11111111-1111-4111-8111-111111111111', 'direct.txt', 'text/plain', 1,
       repeat('c', 64), 'direct.txt', 'local')$$,
  '42501',
  null,
  'authenticated users cannot insert Vault metadata directly'
);
select throws_ok(
  $$update public.vault_documents
      set filename = 'rewritten.txt'
    where user_id = '11111111-1111-4111-8111-111111111111'$$,
  '42501',
  null,
  'authenticated users cannot update Vault metadata directly'
);
select throws_ok(
  $$delete from public.vault_documents
    where user_id = '11111111-1111-4111-8111-111111111111'$$,
  '42501',
  null,
  'authenticated users cannot delete Vault metadata directly'
);
select throws_ok(
  $$update public.vault_documents
      set filename = 'cross-user.txt'
    where id = '33333333-3333-4333-8333-333333333333'$$,
  '42501',
  null,
  'authenticated users cannot mutate another user Vault metadata'
);
select throws_ok(
  $$delete from public.vault_documents
    where id = '33333333-3333-4333-8333-333333333333'$$,
  '42501',
  null,
  'authenticated users cannot delete another user Vault metadata'
);

select lives_ok(
  $$insert into public.swara_context_items
      (id, user_id, type, key, value, version)
    values
      ('66666666-6666-4666-8666-666666666666',
       '11111111-1111-4111-8111-111111111111',
       'fact', 'color', 'blue', 1)$$,
  'an owner can append an initial context item'
);
select throws_ok(
  $$insert into public.swara_context_items
      (user_id, type, key, value, version)
    values
      ('22222222-2222-4222-8222-222222222222', 'fact', 'claimed', 'no', 1)$$,
  '42501',
  null,
  'an owner cannot append context for another user'
);
select lives_ok(
  $$insert into public.swara_context_items
      (id, user_id, type, key, value, version, supersedes_id)
    values
      ('77777777-7777-4777-8777-777777777777',
       '11111111-1111-4111-8111-111111111111',
       'correction', 'color', 'green', 2,
       '66666666-6666-4666-8666-666666666666')$$,
  'an owner can append a controlled context correction'
);
select results_eq(
  $$select status from public.swara_context_items
      where user_id = '11111111-1111-4111-8111-111111111111'
      order by version$$,
  $$values ('superseded'::text), ('active'::text)$$,
  'a correction atomically supersedes the prior active context version'
);
select is(
  (select count(*)::integer from public.swara_context_items
    where user_id = '11111111-1111-4111-8111-111111111111'
      and status = 'active'),
  1,
  'only one active context version remains'
);
select throws_ok(
  $$update public.swara_context_items set value = 'destructive overwrite'
    where id = '77777777-7777-4777-8777-777777777777'$$,
  '42501',
  null,
  'authenticated users cannot update context rows directly'
);
select throws_ok(
  $$delete from public.swara_context_items
    where id = '77777777-7777-4777-8777-777777777777'$$,
  '42501',
  null,
  'authenticated users cannot delete context rows directly'
);
select results_eq(
  $$select id from public.swara_context_items
      where user_id = '22222222-2222-4222-8222-222222222222'$$,
  $$select null::uuid where false$$,
  'cross-user context remains hidden'
);

select throws_ok(
  $$select count(*) from private.document_chunks$$,
  '42501',
  null,
  'authenticated clients cannot read private document chunks'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select results_eq(
  $$select id from public.vault_documents$$,
  $$values ('33333333-3333-4333-8333-333333333333'::uuid)$$,
  'User B sees only the User B Vault metadata'
);
select results_eq(
  $$select id from public.swara_context_items$$,
  $$values ('55555555-5555-4555-8555-555555555555'::uuid)$$,
  'User B sees only User B context'
);

reset role;
set local role service_role;
select throws_ok(
  $$select count(*) from public.vault_documents$$,
  '42501',
  null,
  'service_role has no direct Vault metadata read path'
);
select throws_ok(
  $$insert into public.vault_documents
      (user_id, filename, mime_type, size_bytes, sha256, storage_path, extraction_method)
    values
      ('11111111-1111-4111-8111-111111111111', 'service.txt', 'text/plain', 1,
       repeat('d', 64), 'service.txt', 'local')$$,
  '42501',
  null,
  'service_role cannot mutate Vault metadata directly'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select throws_ok(
  $$select count(*) from public.vault_documents$$,
  '42501',
  null,
  'anonymous clients cannot read Vault metadata'
);
select throws_ok(
  $$select count(*) from public.swara_context_items$$,
  '42501',
  null,
  'anonymous clients cannot read context metadata'
);

select * from finish();
rollback;
