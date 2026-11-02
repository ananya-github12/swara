begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(24);

select has_schema('pgmq', 'pgmq schema exists');
select has_table('pgmq', 'q_vault-ingest', 'vault-ingest queue exists');
select has_table('pgmq', 'a_vault-ingest', 'vault-ingest archive exists');
select has_table('pgmq', 'q_ocr-fallback', 'ocr-fallback queue exists');
select has_table('pgmq', 'a_ocr-fallback', 'ocr-fallback archive exists');
select has_table('pgmq', 'q_generate-embeddings', 'generate-embeddings queue exists');
select has_table('pgmq', 'a_generate-embeddings', 'generate-embeddings archive exists');

select ok(
  exists (select 1 from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'pgmq' and p.proname = 'send'),
  'pgmq.send exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'pgmq' and p.proname = 'read'),
  'pgmq.read exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'pgmq' and p.proname = 'archive'),
  'pgmq.archive exists'
);

select ok(
  not has_schema_privilege('authenticated', 'pgmq', 'USAGE'),
  'authenticated has no pgmq schema usage'
);
select ok(
  not has_schema_privilege('anon', 'pgmq', 'USAGE'),
  'anon has no pgmq schema usage'
);
select ok(
  not has_table_privilege('authenticated', 'pgmq."q_vault-ingest"', 'SELECT'),
  'authenticated cannot read queue internals'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pgmq'
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  0,
  'authenticated cannot execute pgmq functions'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pgmq'
      and has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  0,
  'anon cannot execute pgmq functions'
);

select ok(
  not exists (select 1 from pg_catalog.pg_namespace where nspname = 'pgmq_public')
  or not has_schema_privilege('authenticated', 'pgmq_public', 'USAGE'),
  'authenticated cannot use pgmq_public'
);
select ok(
  not exists (select 1 from pg_catalog.pg_namespace where nspname = 'pgmq_public')
  or not has_schema_privilege('anon', 'pgmq_public', 'USAGE'),
  'anon cannot use pgmq_public'
);

select ok(
  not has_schema_privilege('service_role', 'pgmq', 'USAGE'),
  'service_role has no pgmq schema usage'
);
select ok(
  not has_table_privilege('service_role', 'pgmq."q_vault-ingest"', 'SELECT'),
  'service_role cannot read queue internals'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pgmq'
      and has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  0,
  'service_role cannot execute pgmq functions'
);
select ok(
  not has_schema_privilege('swara_api_runtime', 'pgmq', 'USAGE'),
  'API runtime has no direct pgmq schema usage'
);
select ok(
  not has_schema_privilege('swara_worker_runtime', 'pgmq', 'USAGE'),
  'worker runtime has no direct pgmq schema usage'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pgmq'
      and has_function_privilege('swara_api_runtime', p.oid, 'EXECUTE')
  ),
  0,
  'API runtime cannot execute pgmq functions'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pgmq'
      and has_function_privilege('swara_worker_runtime', p.oid, 'EXECUTE')
  ),
  0,
  'worker runtime cannot execute pgmq functions before queue gateways exist'
);

select * from finish();
rollback;
