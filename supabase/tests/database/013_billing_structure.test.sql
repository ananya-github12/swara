begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(16);

select has_table('private','billing_links','billing links exist');
select has_table('private','entitlement_snapshots','entitlements exist');
select has_table('private','quota_buckets','quota buckets exist');
select has_table('private','usage_reservations','usage reservations exist');
select has_table('private','usage_events','usage events exist');
select has_table('private','billing_outbox','billing outbox exists');
select is(
  (select count(*)::integer from information_schema.columns
   where table_schema='private'
     and table_name in ('billing_links','entitlement_snapshots','quota_buckets','usage_reservations','usage_events','billing_outbox')
     and column_name in ('tenant_id','client_id','sub_client_id','company_id','alterity_user_id','knowledge_base_id')),
  0,
  'billing schema contains no shared identity or company fields'
);
select ok(has_table_privilege('swara_worker_runtime','private.billing_outbox','UPDATE'),'worker can transition billing events');
select ok(not has_schema_privilege('authenticated','private','USAGE'),'clients cannot use billing schema');
select ok(not has_schema_privilege('anon','private','USAGE'),'anon cannot use billing schema');
select ok(not has_schema_privilege('service_role','private','USAGE'),'service cannot use billing schema');
select ok(not has_table_privilege('service_role','private.billing_outbox','INSERT'),'service cannot enqueue billing events');
select is(
  (select count(*)::integer from pg_class
   where oid in (
    'private.billing_links'::regclass,'private.entitlement_snapshots'::regclass,
    'private.quota_buckets'::regclass,'private.usage_reservations'::regclass,
    'private.usage_events'::regclass,'private.billing_outbox'::regclass)
   and relrowsecurity),
  6,
  'all billing tables use RLS defense in depth'
);
select ok(to_regprocedure('private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)') is not null,'reserve operation exists');
select ok(to_regprocedure('private.commit_usage_atomic(uuid,uuid,numeric,text,uuid,uuid)') is not null,'commit operation exists');
select ok(to_regprocedure('private.release_usage_reservation_atomic(uuid,uuid,text)') is not null,'release operation exists');

select * from finish();
rollback;
