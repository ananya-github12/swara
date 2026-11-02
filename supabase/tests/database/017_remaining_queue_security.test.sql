begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(17);

select has_table('pgmq','q_billing-outbox','billing outbox queue exists');
select has_table('pgmq','a_billing-outbox','billing outbox archive exists');
select has_table('pgmq','q_usage-reconciliation','usage reconciliation queue exists');
select has_table('pgmq','a_usage-reconciliation','usage reconciliation archive exists');
select has_table('pgmq','q_account-export','account export queue exists');
select has_table('pgmq','a_account-export','account export archive exists');
select has_table('pgmq','q_account-deletion','account deletion queue exists');
select has_table('pgmq','a_account-deletion','account deletion archive exists');
select has_table('pgmq','q_artifact-retention','artifact retention queue exists');
select has_table('pgmq','a_artifact-retention','artifact retention archive exists');
select is((select count(*)::integer from pgmq.meta where queue_name in(
 'billing-outbox','usage-reconciliation','account-export','account-deletion','artifact-retention')),5,'all remaining queues registered');
select ok(not has_schema_privilege('authenticated','pgmq','USAGE'),'clients cannot use pgmq');
select ok(not has_schema_privilege('anon','pgmq','USAGE'),'anon cannot use pgmq');
select is(
 (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='pgmq' and has_function_privilege('authenticated',p.oid,'EXECUTE')),
 0,'clients cannot execute queue functions');
select ok(
 not has_schema_privilege('service_role','pgmq','USAGE'),
 'service cannot use pgmq'
);
select is(
 (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='pgmq' and has_function_privilege('service_role',p.oid,'EXECUTE')),
 0,
 'service cannot execute queue functions'
);
select is(
 (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='pgmq' and has_function_privilege('swara_worker_runtime',p.oid,'EXECUTE')),
 0,
 'worker cannot execute direct queue functions before queue gateways exist'
);

select * from finish();
rollback;
