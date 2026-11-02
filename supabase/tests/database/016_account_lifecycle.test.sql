begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(13);

insert into auth.users(id) values ('33333333-3333-4333-8333-333333333333');
select is((select count(*)::integer from storage.buckets where id='account-exports' and public=false),1,'export bucket is private');
select is((select count(*)::integer from storage.objects where bucket_id='account-exports'),0,'export bucket starts empty');
select ok(not has_schema_privilege('authenticated','audit','USAGE'),'clients cannot use audit schema');

select ok(
  not has_function_privilege('service_role','private.request_account_export(uuid,text)','EXECUTE'),
  'service cannot request an account export'
);

select lives_ok($$select private.request_account_export(
 '33333333-3333-4333-8333-333333333333','export-idempotency-0001')$$,'export request succeeds');
select lives_ok($$select private.request_account_export(
 '33333333-3333-4333-8333-333333333333','export-idempotency-0001')$$,'export retry succeeds');
select is((select count(*)::integer from private.account_export_requests),1,'export request is idempotent');
select is((select status from private.account_states where user_id='33333333-3333-4333-8333-333333333333'),'active','account begins active');

select lives_ok($$select private.request_account_deletion(
 '33333333-3333-4333-8333-333333333333','delete-idempotency-0001',null)$$,'deletion request succeeds');
select is((select status from private.account_states where user_id='33333333-3333-4333-8333-333333333333'),'deleting','deletion blocks new work first');
select throws_ok($$select private.ensure_account_active('33333333-3333-4333-8333-333333333333')$$,'55000');

select lives_ok($$select private.request_account_deletion(
 '33333333-3333-4333-8333-333333333333','delete-idempotency-0001',null)$$,'deletion retry succeeds');
select is((select count(*)::integer from private.account_deletion_requests),1,'deletion request is idempotent');

select * from finish();
rollback;
