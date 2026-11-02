begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(33);

select ok(
  exists (select 1 from pg_catalog.pg_roles where rolname = 'swara_api_runtime'),
  'swara_api_runtime exists'
);
select ok(
  exists (select 1 from pg_catalog.pg_roles where rolname = 'swara_worker_runtime'),
  'swara_worker_runtime exists'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_roles
    where rolname in ('swara_api_runtime', 'swara_worker_runtime')
      and rolcanlogin
  ),
  0,
  'runtime permission groups cannot log in'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_roles
    where rolname in ('swara_api_runtime', 'swara_worker_runtime')
      and (rolsuper or rolcreatedb or rolcreaterole or rolreplication)
  ),
  0,
  'runtime permission groups have no elevated role attributes'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_roles
    where rolname in ('swara_api_runtime', 'swara_worker_runtime')
      and rolbypassrls
  ),
  0,
  'runtime permission groups cannot bypass RLS'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_roles as owner on owner.oid = relation.relowner
    where relation.relkind in ('r', 'p')
      and owner.rolname in ('swara_api_runtime', 'swara_worker_runtime')
  ),
  0,
  'runtime permission groups own no tables'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_roles as owner on owner.oid = routine.proowner
    where owner.rolname in ('swara_api_runtime', 'swara_worker_runtime')
  ),
  0,
  'runtime permission groups own no functions'
);

select ok(
  has_schema_privilege('swara_api_runtime', 'private', 'USAGE'),
  'API runtime can use only the private schema it needs'
);
select ok(
  has_schema_privilege('swara_worker_runtime', 'private', 'USAGE'),
  'worker runtime can use the private schema it needs'
);
select ok(
  has_schema_privilege('swara_worker_runtime', 'audit', 'USAGE'),
  'worker runtime can write the audit schema'
);
select ok(
  not has_schema_privilege('swara_api_runtime', 'audit', 'USAGE'),
  'API runtime cannot use the audit schema'
);
select ok(
  not has_schema_privilege('service_role', 'private', 'USAGE'),
  'service_role cannot use private'
);
select ok(
  not has_schema_privilege('service_role', 'audit', 'USAGE'),
  'service_role cannot use audit'
);
select ok(
  not has_schema_privilege('service_role', 'pgmq', 'USAGE'),
  'service_role cannot use pgmq'
);
select ok(
  not has_schema_privilege('swara_api_runtime', 'pgmq', 'USAGE'),
  'API runtime cannot use pgmq directly'
);
select ok(
  not has_schema_privilege('swara_worker_runtime', 'pgmq', 'USAGE'),
  'worker runtime cannot use pgmq directly'
);

select ok(
  has_table_privilege('swara_api_runtime', 'public.devices', 'SELECT'),
  'API runtime can verify registered devices'
);
select ok(
  has_table_privilege('swara_api_runtime', 'private.browser_sessions', 'SELECT'),
  'API runtime can read execution sessions'
);
select ok(
  has_table_privilege('swara_api_runtime', 'private.browser_sessions', 'INSERT'),
  'API runtime can create execution sessions'
);
select ok(
  has_table_privilege('swara_api_runtime', 'private.browser_sessions', 'UPDATE'),
  'API runtime can close execution sessions'
);
select ok(
  not has_table_privilege('swara_api_runtime', 'private.browser_sessions', 'DELETE'),
  'API runtime cannot delete execution sessions'
);
select ok(
  has_function_privilege(
    'swara_api_runtime',
    'private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'API runtime can reserve usage only through the atomic operation'
);
select ok(
  has_function_privilege(
    'swara_api_runtime',
    'private.request_account_export(uuid,text)',
    'EXECUTE'
  ),
  'API runtime can create a user export request through its private function'
);
select ok(
  has_table_privilege('swara_worker_runtime', 'private.document_chunks', 'SELECT')
  and has_table_privilege('swara_worker_runtime', 'private.document_chunks', 'INSERT')
  and has_table_privilege('swara_worker_runtime', 'private.document_chunks', 'UPDATE')
  and has_table_privilege('swara_worker_runtime', 'private.document_chunks', 'DELETE'),
  'worker runtime has the current document chunk maintenance verbs'
);
select ok(
  has_table_privilege('swara_worker_runtime', 'private.billing_outbox', 'SELECT')
  and has_table_privilege('swara_worker_runtime', 'private.billing_outbox', 'UPDATE'),
  'worker runtime can read and transition billing outbox rows'
);
select ok(
  has_function_privilege(
    'swara_worker_runtime',
    'private.claim_expired_task_artifacts(integer,integer,timestamp with time zone)',
    'EXECUTE'
  ),
  'worker runtime can claim the bounded artifact retention handoff'
);
select ok(
  has_function_privilege(
    'swara_worker_runtime',
    'private.enqueue_maintenance_dispatch(text,text,integer,integer)',
    'EXECUTE'
  ),
  'worker runtime can invoke the bounded maintenance dispatcher'
);
select ok(
  not has_function_privilege(
    'service_role',
    'private.reserve_usage_atomic(uuid,text,timestamp with time zone,timestamp with time zone,numeric,text,timestamp with time zone)',
    'EXECUTE'
  ),
  'service_role cannot execute atomic usage functions'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where namespace.nspname = 'pgmq'
      and has_function_privilege('service_role', routine.oid, 'EXECUTE')
  ),
  0,
  'service_role has no direct pgmq function execution'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where namespace.nspname = 'pgmq'
      and has_function_privilege('swara_api_runtime', routine.oid, 'EXECUTE')
  ),
  0,
  'API runtime has no direct pgmq function execution'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where namespace.nspname = 'pgmq'
      and has_function_privilege('swara_worker_runtime', routine.oid, 'EXECUTE')
  ),
  0,
  'worker runtime has no direct pgmq function execution'
);

-- Fresh objects prove the owner-scoped default ACLs do not silently regrant
-- blocked roles.  The test transaction rolls these probes back.
create table public.runtime_role_public_default_acl_probe (id integer);
create table private.runtime_role_private_default_acl_probe (id integer);
create table audit.runtime_role_audit_default_acl_probe (id integer);
create table pgmq.runtime_role_pgmq_default_acl_probe (id integer);

create function public.runtime_role_public_default_acl_probe()
returns void language plpgsql as $probe$ begin return; end; $probe$;
create function private.runtime_role_private_default_acl_probe()
returns void language plpgsql as $probe$ begin return; end; $probe$;
create function audit.runtime_role_audit_default_acl_probe()
returns void language plpgsql as $probe$ begin return; end; $probe$;
create function pgmq.runtime_role_pgmq_default_acl_probe()
returns void language plpgsql as $probe$ begin return; end; $probe$;

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl, pg_catalog.acldefault('r'::"char", relation.relowner))
    ) as privilege
    where relation.oid = any (
      array[
        'public.runtime_role_public_default_acl_probe'::regclass,
        'private.runtime_role_private_default_acl_probe'::regclass,
        'audit.runtime_role_audit_default_acl_probe'::regclass,
        'pgmq.runtime_role_pgmq_default_acl_probe'::regclass
      ]
    )
      and (
        privilege.grantee = 0
        or privilege.grantee in (
          select oid
          from pg_catalog.pg_roles
          where rolname in ('anon', 'authenticated', 'service_role')
        )
      )
  ),
  0,
  'new Swara-schema tables deny PUBLIC, anon, authenticated, and service_role by default'
);
select is(
  (
    select count(*)::integer
    from pg_catalog.pg_proc as routine
    cross join lateral pg_catalog.aclexplode(
      coalesce(routine.proacl, pg_catalog.acldefault('f'::"char", routine.proowner))
    ) as privilege
    where routine.oid = any (
      array[
        'public.runtime_role_public_default_acl_probe()'::regprocedure,
        'private.runtime_role_private_default_acl_probe()'::regprocedure,
        'audit.runtime_role_audit_default_acl_probe()'::regprocedure,
        'pgmq.runtime_role_pgmq_default_acl_probe()'::regprocedure
      ]
    )
      and privilege.privilege_type = 'EXECUTE'
      and (
        privilege.grantee = 0
        or privilege.grantee in (
          select oid
          from pg_catalog.pg_roles
          where rolname in ('anon', 'authenticated', 'service_role')
        )
      )
  ),
  0,
  'new Swara-schema functions deny PUBLIC, anon, authenticated, and service_role by default'
);

select * from finish();
rollback;
