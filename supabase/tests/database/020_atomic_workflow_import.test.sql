begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(24);

select has_table(
  'private',
  'workflow_import_requests',
  'workflow import idempotency ledger exists'
);
select ok(
  to_regprocedure(
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'
  ) is not null,
  'atomic workflow import function exists'
);
select ok(
  (
    select prosecdef
    from pg_catalog.pg_proc
    where oid = 'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure
  ),
  'atomic workflow import is security definer'
);
select ok(
  exists (
    select 1
    from pg_catalog.pg_proc
    where oid = 'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure
      and 'search_path=""' = any(proconfig)
  ),
  'atomic workflow import fixes an empty search path'
);
select is(
  (
    select pg_catalog.pg_get_userbyid(proowner)::text
    from pg_catalog.pg_proc
    where oid = 'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure
  ),
  current_user::text,
  'atomic workflow import is owned by the migration owner'
);
select ok(
  (
    select relrowsecurity
    from pg_catalog.pg_class
    where oid = 'private.workflow_import_requests'::regclass
  ),
  'workflow import ledger has RLS enabled'
);
select ok(
  has_function_privilege(
    'swara_api_runtime',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure,
    'EXECUTE'
  ),
  'API runtime role can execute atomic workflow import'
);
select ok(
  not has_function_privilege(
    'anon',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure,
    'EXECUTE'
  ),
  'anon cannot execute atomic workflow import'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure,
    'EXECUTE'
  ),
  'authenticated cannot execute atomic workflow import'
);
select ok(
  not has_function_privilege(
    'service_role',
    'private.import_workflow_atomic(uuid,uuid,text,integer,jsonb,uuid,text,uuid)'::regprocedure,
    'EXECUTE'
  ),
  'service role cannot execute atomic workflow import'
);
select ok(
  not has_table_privilege(
    'swara_api_runtime',
    'private.workflow_import_requests',
    'SELECT'
  ),
  'API runtime role has no direct ledger read access'
);

insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

select lives_ok(
  $$select * from private.import_workflow_atomic(
      '11111111-1111-4111-8111-111111111111',
      null,
      'Initial workflow',
      1,
      '{"steps":[{"action":"click"},{"action":"fill","value":"{{email}}"}]}'::jsonb,
      null,
      'workflow-import-0001',
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    )$$,
  'API runtime can create an owned workflow atomically'
);

select is(
  (select count(*)::integer from public.workflows
    where id = (
      select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'
    )),
  1,
  'create import creates one workflow'
);
select is(
  (select name from public.workflows
    where id = (
      select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'
    )),
  'Initial workflow',
  'create import writes the validated workflow name'
);
select is(
  (select step_count from public.workflows
    where id = (
      select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'
    )),
  2,
  'step count is derived inside PostgreSQL'
);
select ok(
  (
    select workflow.current_version_id = version.id
    from public.workflows as workflow
    join public.workflow_versions as version
      on version.workflow_id = workflow.id
     and version.user_id = workflow.user_id
    where workflow.id = (
      select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'
    )
  ),
  'create import atomically points the workflow to its immutable version'
);
select is(
  (select version.content_hash from public.workflow_versions as version
    where version.workflow_id = (
      select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'
    )),
  pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        '{"steps":[{"action":"click"},{"action":"fill","value":"{{email}}"}]}'::jsonb::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  ),
  'content hash is canonical JSONB SHA-256 computed in PostgreSQL'
);

select ok(
  (select duplicate from private.import_workflow_atomic(
    '11111111-1111-4111-8111-111111111111',
    (select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'),
    'Renamed workflow',
    1,
    '{"steps":[{"action":"click"},{"action":"fill","value":"{{email}}"}]}'::jsonb,
    (select version_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'),
    'workflow-import-0002',
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
  )),
  'identical workflow content reuses the immutable version'
);

select is(
  (select count(*)::integer from public.workflow_versions
    where workflow_id = (
      select workflow_id from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'
    )),
  1,
  'duplicate content does not create a second immutable version'
);
select results_eq(
  $$select workflow_id, version_id, content_hash, step_count
      from private.import_workflow_atomic(
        '11111111-1111-4111-8111-111111111111',
        null,
        'Initial workflow',
        1,
        '{"steps":[{"action":"click"},{"action":"fill","value":"{{email}}"}]}'::jsonb,
        null,
        'workflow-import-0001',
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
      )$$,
  $$select workflow_id, version_id, content_hash, step_count
      from private.workflow_import_requests
      where user_id = '11111111-1111-4111-8111-111111111111'
        and idempotency_key = 'workflow-import-0001'$$,
  'same-key retry returns its original durable result even with a new correlation ID'
);
select throws_ok(
  $$select * from private.import_workflow_atomic(
      '11111111-1111-4111-8111-111111111111',
      null,
      'Changed workflow',
      1,
      '{"steps":[]}'::jsonb,
      null,
      'workflow-import-0001',
      'ffffffff-ffff-4fff-8fff-ffffffffffff'
    )$$,
  '22023',
  'Idempotency key is already bound to a different workflow import',
  'same key with changed input is rejected without echoing the definition'
);
select throws_ok(
  $$select * from private.import_workflow_atomic(
      '11111111-1111-4111-8111-111111111111',
      (select workflow_id from private.workflow_import_requests
        where user_id = '11111111-1111-4111-8111-111111111111'
          and idempotency_key = 'workflow-import-0001'),
      'Concurrent workflow',
      1,
      '{"steps":[]}'::jsonb,
      'ffffffff-ffff-4fff-8fff-ffffffffffff',
      'workflow-import-0003',
      '99999999-9999-4999-8999-999999999999'
    )$$,
  '40001'
);
select throws_ok(
  $$select * from private.import_workflow_atomic(
      '22222222-2222-4222-8222-222222222222',
      (select workflow_id from private.workflow_import_requests
        where user_id = '11111111-1111-4111-8111-111111111111'
          and idempotency_key = 'workflow-import-0001'),
      'Foreign workflow',
      1,
      '{"steps":[]}'::jsonb,
      null,
      'workflow-import-0004',
      '88888888-8888-4888-8888-888888888888'
    )$$,
  '42501'
);
select throws_ok(
  $$select * from private.import_workflow_atomic(
      '11111111-1111-4111-8111-111111111111',
      null,
      'Secret workflow',
      1,
      '{"steps":[],"apiKey":"sk-this-must-not-persist"}'::jsonb,
      null,
      'workflow-import-0005',
      '77777777-7777-4777-8777-777777777777'
    )$$,
  '22023'
);

select * from finish();
rollback;
