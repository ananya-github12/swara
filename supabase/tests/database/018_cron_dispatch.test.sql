begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(11);

select is((select count(*)::integer from cron.job where jobname like 'swara-%-dispatch'),7,'seven bounded Swara Cron jobs exist');
select is((select count(*)::integer from cron.job where jobname='swara-billing-retry-dispatch' and schedule='* * * * *'),1,'billing retry runs each minute');
select is((select count(*)::integer from cron.job where jobname='swara-expired-reservation-release-dispatch' and schedule='*/5 * * * *'),1,'reservation release runs every five minutes');
select is((select count(*)::integer from cron.job where jobname='swara-stuck-ingestion-detection-dispatch' and schedule='*/10 * * * *'),1,'stuck ingestion detection runs every ten minutes');
select is((select count(*)::integer from cron.job where command not ilike '%enqueue_maintenance_dispatch%'),0,'all Swara Cron jobs only call the dispatcher');
select ok(not has_schema_privilege('authenticated','cron','USAGE'),'clients cannot use cron schema');
select ok(not has_function_privilege('authenticated','private.enqueue_maintenance_dispatch(text,text,integer,integer)','EXECUTE'),'clients cannot execute dispatcher');
select ok(not has_function_privilege('service_role','private.enqueue_maintenance_dispatch(text,text,integer,integer)','EXECUTE'),'service cannot execute dispatcher');
select ok(has_function_privilege('swara_worker_runtime','private.enqueue_maintenance_dispatch(text,text,integer,integer)','EXECUTE'),'worker can execute dispatcher');

select lives_ok($$select private.enqueue_maintenance_dispatch(
 'billing-outbox','retry_due_billing_outbox',50,60)$$,'exact reviewed dispatch maximum enqueues');
select throws_ok($$select private.enqueue_maintenance_dispatch(
 'billing-outbox','retry_due_billing_outbox',51,60)$$,'22023');

select * from finish();
rollback;
