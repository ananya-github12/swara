begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(16);

insert into auth.users (id)
values ('33333333-3333-4333-8333-333333333333');

select has_function(
  'private',
  'establish_billing_link',
  array['uuid', 'text'],
  'opaque billing-link establishment function exists'
);
select has_function(
  'private',
  'project_billing_entitlement',
  array['uuid', 'text', 'text', 'text', 'text', 'jsonb', 'jsonb', 'timestamp with time zone', 'text'],
  'bounded entitlement projection function exists'
);
select ok(
  (select prosecdef from pg_proc where oid = 'private.project_billing_entitlement(uuid,text,text,text,text,jsonb,jsonb,timestamp with time zone,text)'::regprocedure),
  'entitlement projection is a reviewed security definer boundary'
);
select ok(
  exists (
    select 1
      from pg_proc as routine,
           unnest(coalesce(routine.proconfig, '{}'::text[])) as setting(value)
     where routine.oid = 'private.project_billing_entitlement(uuid,text,text,text,text,jsonb,jsonb,timestamp with time zone,text)'::regprocedure
       and setting.value = 'search_path=""'
  ),
  'entitlement projection pins an empty search path'
);
select ok(
  has_function_privilege('swara_api_runtime', 'private.establish_billing_link(uuid,text)', 'EXECUTE')
  and has_function_privilege('swara_api_runtime', 'private.project_billing_entitlement(uuid,text,text,text,text,jsonb,jsonb,timestamp with time zone,text)', 'EXECUTE'),
  'only the API runtime receives the billing projection wrappers'
);
select ok(
  not has_function_privilege('anon', 'private.project_billing_entitlement(uuid,text,text,text,text,jsonb,jsonb,timestamp with time zone,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.establish_billing_link(uuid,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'private.project_billing_entitlement(uuid,text,text,text,text,jsonb,jsonb,timestamp with time zone,text)', 'EXECUTE'),
  'browser and service roles cannot invoke billing projection wrappers'
);

select is(
  (select snapshot_written from private.project_billing_entitlement(
    '33333333-3333-4333-8333-333333333333', 'cus_alterity_001', 'active',
    'pro', 'active', '{"vault_search":true}'::jsonb, '{"actions_per_month":1000}'::jsonb,
    '2026-10-01T00:00:00Z'::timestamptz, 'entitlement-2026-10-01'
  )),
  true,
  'a bounded entitlement projection writes a cache snapshot'
);
select is(
  (select link_status from private.billing_links where user_id = '33333333-3333-4333-8333-333333333333'),
  'active',
  'projection writes only the opaque customer link state'
);
select is(
  (select source_version from private.entitlement_snapshots where user_id = '33333333-3333-4333-8333-333333333333'),
  'entitlement-2026-10-01',
  'projection stores the bounded source version'
);
select is(
  (select snapshot_written from private.project_billing_entitlement(
    '33333333-3333-4333-8333-333333333333', 'cus_alterity_001', 'active',
    'pro', 'active', '{"vault_search":true}'::jsonb, '{"actions_per_month":1000}'::jsonb,
    '2026-10-01T00:00:00Z'::timestamptz, 'entitlement-2026-10-01'
  )),
  false,
  'the same source version is idempotent'
);
select is(
  (select count(*)::integer from private.entitlement_snapshots where user_id = '33333333-3333-4333-8333-333333333333'),
  1,
  'idempotent source-version replay does not duplicate a snapshot'
);
select throws_ok(
  $$select * from private.project_billing_entitlement(
    '33333333-3333-4333-8333-333333333333', 'cus_alterity_001', 'active',
    'team', 'active', '{"vault_search":true}'::jsonb, '{"actions_per_month":1000}'::jsonb,
    '2026-10-01T00:00:00Z'::timestamptz, 'entitlement-2026-10-01'
  )$$,
  '22023',
  null,
  'a source version cannot be reused with different entitlement data'
);
select throws_ok(
  $$select * from private.project_billing_entitlement(
    '33333333-3333-4333-8333-333333333333', 'cus_alterity_001', 'active',
    'pro', 'active', '[]'::jsonb, '{"actions_per_month":1000}'::jsonb,
    '2026-10-01T00:00:00Z'::timestamptz, 'entitlement-2026-10-02'
  )$$,
  '22023',
  null,
  'arrays are rejected where bounded capability objects are required'
);
select is(
  (select link_created from private.establish_billing_link(
    '33333333-3333-4333-8333-333333333333', 'cus_alterity_001'
  )),
  false,
  'relay link establishment is idempotent for the same opaque reference'
);
select throws_ok(
  $$select * from private.establish_billing_link(
    '33333333-3333-4333-8333-333333333333', 'cus_other'
  )$$,
  '22023',
  null,
  'relay responses cannot replace an established opaque customer reference'
);
select ok(
  not exists (
    select 1 from information_schema.columns
     where table_schema = 'private'
       and table_name in ('billing_links', 'entitlement_snapshots')
       and column_name in ('raw_body', 'webhook_body', 'provider_payload', 'payload')
  ),
  'billing projection tables contain no raw webhook or provider payload column'
);

select * from finish();
rollback;
