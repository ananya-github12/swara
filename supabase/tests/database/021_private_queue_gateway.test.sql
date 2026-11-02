begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(55);

select has_table('private', 'worker_job_runs', 'M020 creates the private worker run ledger');
select has_table('private', 'worker_dead_letters', 'M020 creates the private dead-letter ledger');

select ok(
  pg_catalog.to_regprocedure('private.enqueue_job(text,jsonb,integer)') is not null,
  'enqueue gateway exists'
);
select ok(
  pg_catalog.to_regprocedure('private.read_jobs(text,integer,integer)') is not null,
  'read gateway exists'
);
select ok(
  pg_catalog.to_regprocedure('private.claim_job(text,bigint,text,integer)') is not null,
  'claim gateway exists'
);
select ok(
  pg_catalog.to_regprocedure('private.extend_job_visibility(text,bigint,text,integer)') is not null,
  'visibility gateway exists'
);
select ok(
  pg_catalog.to_regprocedure('private.archive_job(text,bigint,text)') is not null,
  'archive gateway exists'
);
select ok(
  pg_catalog.to_regprocedure('private.dead_letter_job(text,bigint,text,text)') is not null,
  'dead-letter gateway exists'
);

select ok(
  (select relation.relrowsecurity
   from pg_catalog.pg_class as relation
   where relation.oid = 'private.worker_job_runs'::regclass),
  'worker ledger has RLS enabled'
);
select ok(
  (select relation.relrowsecurity
   from pg_catalog.pg_class as relation
   where relation.oid = 'private.worker_dead_letters'::regclass),
  'dead-letter ledger has RLS enabled'
);

select ok(
  not has_schema_privilege('service_role', 'pgmq', 'USAGE'),
  'service_role cannot use the PGMQ schema'
);
select ok(
  not has_schema_privilege('swara_api_runtime', 'pgmq', 'USAGE'),
  'API runtime cannot use the PGMQ schema'
);
select ok(
  not has_schema_privilege('swara_worker_runtime', 'pgmq', 'USAGE'),
  'worker runtime cannot use the PGMQ schema'
);
select is(
  (
    select pg_catalog.count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = routine.pronamespace
    where namespace.nspname = 'pgmq'
      and has_function_privilege('service_role', routine.oid, 'EXECUTE')
  ),
  0,
  'service_role cannot execute any PGMQ function'
);
select is(
  (
    select pg_catalog.count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = routine.pronamespace
    where namespace.nspname = 'pgmq'
      and has_function_privilege('swara_api_runtime', routine.oid, 'EXECUTE')
  ),
  0,
  'API runtime cannot execute any PGMQ function'
);
select is(
  (
    select pg_catalog.count(*)::integer
    from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = routine.pronamespace
    where namespace.nspname = 'pgmq'
      and has_function_privilege('swara_worker_runtime', routine.oid, 'EXECUTE')
  ),
  0,
  'worker runtime cannot execute any PGMQ function directly'
);
select ok(
  not has_table_privilege(
    'swara_worker_runtime',
    'private.worker_job_runs',
    'SELECT'
  ),
  'worker runtime cannot read the ledger directly'
);
select ok(
  not has_function_privilege(
    'swara_api_runtime',
    'private.enqueue_job(text,jsonb,integer)',
    'EXECUTE'
  ),
  'API runtime has no enqueue grant before a reviewed dispatcher needs it'
);
select ok(
  not has_function_privilege(
    'service_role',
    'private.enqueue_job(text,jsonb,integer)',
    'EXECUTE'
  ),
  'service_role has no enqueue grant'
);
select is(
  (
    select pg_catalog.count(*)::integer
    from (
      values
        ('private.enqueue_job(text,jsonb,integer)'),
        ('private.read_jobs(text,integer,integer)'),
        ('private.claim_job(text,bigint,text,integer)'),
        ('private.extend_job_visibility(text,bigint,text,integer)'),
        ('private.archive_job(text,bigint,text)'),
        ('private.dead_letter_job(text,bigint,text,text)')
    ) as gateway(signature)
    where has_function_privilege(
      'swara_worker_runtime',
      gateway.signature,
      'EXECUTE'
    )
  ),
  6,
  'worker runtime receives exactly the six reviewed M020 gateways'
);

-- M018 deliberately removes default PUBLIC execution from newly created
-- functions, including pgTAP functions created inside this rolled-back test
-- transaction.  These two grants are test harness plumbing only: rollback
-- removes them, and no production role receives extension privileges here.
grant usage on schema extensions to swara_worker_runtime;
grant execute on all functions in schema extensions to swara_worker_runtime;

set local role swara_worker_runtime;

select throws_ok(
  $$select pgmq.send('vault-ingest', '{}'::jsonb)$$::text,
  42501::integer,
  null::text,
  'worker cannot invoke PGMQ directly'::text
);

select ok(
  pg_catalog.set_config(
    'swara.test_claim_message_id',
    private.enqueue_job(
      'vault-ingest',
      pg_catalog.jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.claim',
        'job_id', '00000000-0000-4000-8000-000000000001',
        'idempotency_key', 'test-claim-001',
        'correlation_id', '00000000-0000-4000-8000-000000000101'
      ),
      0
    )::text,
    true
  ) is not null,
  'worker can enqueue a valid closed-envelope job'
);

select throws_ok(
  $$select private.enqueue_job(
      'unknown-queue',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.unknown',
        'job_id', '00000000-0000-4000-8000-000000000002',
        'idempotency_key', 'test-unknown-001',
        'correlation_id', '00000000-0000-4000-8000-000000000102'
      ),
      0
    )$$::text,
  22023::integer,
  null::text,
  'unknown queues are rejected'::text
);
select throws_ok(
  $$select private.enqueue_job(
      'vault-ingest',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.missing',
        'job_id', '00000000-0000-4000-8000-000000000003',
        'idempotency_key', 'test-missing-001'
      ),
      0
    )$$::text,
  22023::integer,
  null::text,
  'envelopes missing a required field are rejected'::text
);
select throws_ok(
  $$select private.enqueue_job(
      'vault-ingest',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.raw',
        'job_id', '00000000-0000-4000-8000-000000000004',
        'idempotency_key', 'test-raw-document-001',
        'correlation_id', '00000000-0000-4000-8000-000000000104',
        'document_text', 'never queue raw documents'
      ),
      0
    )$$::text,
  22023::integer,
  null::text,
  'raw document fields are rejected'::text
);
select throws_ok(
  $$select private.enqueue_job(
      'vault-ingest',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.provider',
        'job_id', '00000000-0000-4000-8000-000000000005',
        'idempotency_key', 'test-provider-payload-001',
        'correlation_id', '00000000-0000-4000-8000-000000000105',
        'provider_payload', jsonb_build_object('secret', 'not-permitted')
      ),
      0
    )$$::text,
  22023::integer,
  null::text,
  'provider payload and secret fields are rejected'::text
);
select throws_ok(
  $$select private.enqueue_job(
      'vault-ingest',
      jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.size',
        'job_id', '00000000-0000-4000-8000-000000000006',
        'idempotency_key', pg_catalog.repeat('x', 5000),
        'correlation_id', '00000000-0000-4000-8000-000000000106'
      ),
      0
    )$$::text,
  22023::integer,
  null::text,
  'oversize envelopes are rejected'::text
);

select is(
  private.enqueue_job(
    'vault-ingest',
    pg_catalog.jsonb_build_object(
      'schema_version', 1,
      'job_type', 'test.claim',
      'job_id', '00000000-0000-4000-8000-000000000001',
      'idempotency_key', 'test-claim-001',
      'correlation_id', '00000000-0000-4000-8000-000000000101'
    ),
    0
  ),
  pg_catalog.current_setting('swara.test_claim_message_id')::bigint,
  'a duplicate enqueue returns the original message id'
);

reset role;

select is(
  (
    select pg_catalog.count(*)::integer
    from private.worker_job_runs as job
    where job.queue_name = 'vault-ingest'
      and job.idempotency_key = 'test-claim-001'
  ),
  1,
  'idempotent enqueue stores one durable run row'
);

set local role swara_worker_runtime;

select ok(
  pg_catalog.set_config(
    'swara.test_claim_message_id',
    (
      select queued.message_id::text
      from private.read_jobs('vault-ingest', 30, 25) as queued
      where queued.envelope ->> 'idempotency_key' = 'test-claim-001'
      limit 1
    ),
    true
  ) is not null,
  'read_jobs returns and leases the queued message'
);
select is(
  private.claim_job(
    'vault-ingest',
    pg_catalog.current_setting('swara.test_claim_message_id')::bigint,
    'test-claim-001',
    120
  ),
  'claimed',
  'first claim succeeds'
);
select is(
  private.claim_job(
    'vault-ingest',
    pg_catalog.current_setting('swara.test_claim_message_id')::bigint,
    'test-claim-001',
    120
  ),
  'busy',
  'duplicate active claim is safely busy'
);
select ok(
  private.extend_job_visibility(
    'vault-ingest',
    pg_catalog.current_setting('swara.test_claim_message_id')::bigint,
    'test-claim-001',
    120
  ),
  'worker can extend an active lease'
);

reset role;

select ok(
  (
    select job.lease_expires_at > pg_catalog.clock_timestamp() + interval '100 seconds'
    from private.worker_job_runs as job
    where job.queue_name = 'vault-ingest'
      and job.idempotency_key = 'test-claim-001'
  ),
  'lease extension persists a bounded future deadline'
);

set local role swara_worker_runtime;

select ok(
  private.extend_job_visibility(
    'vault-ingest',
    pg_catalog.current_setting('swara.test_claim_message_id')::bigint,
    'test-claim-001',
    0
  ),
  'zero visibility explicitly releases a bounded retry lease'
);

reset role;

select ok(
  (
    select job.lease_expires_at <= pg_catalog.clock_timestamp() + interval '1 second'
    from private.worker_job_runs as job
    where job.queue_name = 'vault-ingest'
      and job.idempotency_key = 'test-claim-001'
  ),
  'retry release makes the durable lease immediately eligible again'
);

set local role swara_worker_runtime;

select ok(
  pg_catalog.set_config(
    'swara.test_archive_message_id',
    private.enqueue_job(
      'generate-embeddings',
      pg_catalog.jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.archive',
        'job_id', '00000000-0000-4000-8000-000000000007',
        'idempotency_key', 'test-archive-001',
        'correlation_id', '00000000-0000-4000-8000-000000000107'
      ),
      0
    )::text,
    true
  ) is not null,
  'archive test job is enqueued'
);
select throws_ok(
  $$select private.archive_job(
      'generate-embeddings',
      current_setting('swara.test_archive_message_id')::bigint,
      'test-archive-001'
    )$$::text,
  22023::integer,
  null::text,
  'archive is guarded until a job has a durable active claim'::text
);
select ok(
  exists (
    select 1
    from private.read_jobs('generate-embeddings', 30, 25) as queued
    where queued.message_id = pg_catalog.current_setting('swara.test_archive_message_id')::bigint
  ),
  'archive test job is read through the gateway'
);
select is(
  private.claim_job(
    'generate-embeddings',
    pg_catalog.current_setting('swara.test_archive_message_id')::bigint,
    'test-archive-001',
    120
  ),
  'claimed',
  'archive test job is claimed'
);
select ok(
  private.archive_job(
    'generate-embeddings',
    pg_catalog.current_setting('swara.test_archive_message_id')::bigint,
    'test-archive-001'
  ),
  'archive acknowledgement succeeds after a claim'
);

reset role;

select is(
  (
    select job.status
    from private.worker_job_runs as job
    where job.queue_name = 'generate-embeddings'
      and job.idempotency_key = 'test-archive-001'
  ),
  'completed',
  'archive records durable completion first'
);
select ok(
  exists (
    select 1
    from pgmq."a_generate-embeddings" as archived
    where archived.msg_id = pg_catalog.current_setting('swara.test_archive_message_id')::bigint
  ),
  'completed queue message is in the PGMQ archive'
);

set local role swara_worker_runtime;

select ok(
  private.archive_job(
    'generate-embeddings',
    pg_catalog.current_setting('swara.test_archive_message_id')::bigint,
    'test-archive-001'
  ),
  'archive acknowledgement is idempotent'
);
select ok(
  pg_catalog.set_config(
    'swara.test_dead_message_id',
    private.enqueue_job(
      'billing-outbox',
      pg_catalog.jsonb_build_object(
        'schema_version', 1,
        'job_type', 'test.dead-letter',
        'job_id', '00000000-0000-4000-8000-000000000008',
        'idempotency_key', 'test-dead-letter-001',
        'correlation_id', '00000000-0000-4000-8000-000000000108'
      ),
      0
    )::text,
    true
  ) is not null,
  'dead-letter test job is enqueued'
);
select ok(
  exists (
    select 1
    from private.read_jobs('billing-outbox', 1, 25) as queued
    where queued.message_id = pg_catalog.current_setting('swara.test_dead_message_id')::bigint
  ),
  'dead-letter test job is read through the gateway'
);
select is(
  private.claim_job(
    'billing-outbox',
    pg_catalog.current_setting('swara.test_dead_message_id')::bigint,
    'test-dead-letter-001',
    30
  ),
  'claimed',
  'dead-letter test job receives its first claim'
);
select throws_ok(
  $$select private.dead_letter_job(
      'billing-outbox',
      current_setting('swara.test_dead_message_id')::bigint,
      'test-dead-letter-001',
      'processing_failed'
    )$$::text,
  22023::integer,
  null::text,
  'dead-lettering before the bounded attempt limit is rejected'::text
);
select lives_ok(
  $sql$
    do $block$
    declare
      v_message_id bigint := pg_catalog.current_setting('swara.test_dead_message_id')::bigint;
      v_claim_status text;
      v_seen boolean;
      v_attempt integer;
    begin
      for v_attempt in 2..5 loop
        if not private.extend_job_visibility(
          'billing-outbox',
          v_message_id,
          'test-dead-letter-001',
          0
        ) then
          raise exception using
            errcode = 'P0001',
            message = 'retry release was unexpectedly unavailable';
        end if;

        select exists (
          select 1
          from private.read_jobs('billing-outbox', 1, 25) as queued
          where queued.message_id = v_message_id
        ) into v_seen;

        if not v_seen then
          raise exception using
            errcode = 'P0001',
            message = 'retry message was not visible to the gateway';
        end if;

        v_claim_status := private.claim_job(
          'billing-outbox',
          v_message_id,
          'test-dead-letter-001',
          30
        );

        if v_claim_status is distinct from 'claimed' then
          raise exception using
            errcode = 'P0001',
            message = 'retry claim did not succeed';
        end if;
      end loop;
    end;
    $block$;
  $sql$,
  'retry visibility and claims are bounded at five attempts'
);

reset role;

select is(
  (
    select job.attempt_count
    from private.worker_job_runs as job
    where job.queue_name = 'billing-outbox'
      and job.idempotency_key = 'test-dead-letter-001'
  ),
  5,
  'worker ledger records the configured maximum attempts'
);

set local role swara_worker_runtime;

select ok(
  private.dead_letter_job(
    'billing-outbox',
    pg_catalog.current_setting('swara.test_dead_message_id')::bigint,
    'test-dead-letter-001',
    'processing_failed'
  ),
  'fifth failed attempt is durably dead-lettered and archived'
);

reset role;

select ok(
  exists (
    select 1
    from private.worker_dead_letters as dead_letter
    where dead_letter.queue_name = 'billing-outbox'
      and dead_letter.message_id = pg_catalog.current_setting('swara.test_dead_message_id')::bigint
      and dead_letter.attempt_count = 5
      and dead_letter.final_error_code = 'processing_failed'
  ),
  'dead-letter record stores only the safe envelope and error code'
);
select ok(
  exists (
    select 1
    from pgmq."a_billing-outbox" as archived
    where archived.msg_id = pg_catalog.current_setting('swara.test_dead_message_id')::bigint
  ),
  'dead-lettered message is archived after its durable terminal state'
);

set local role swara_worker_runtime;

select ok(
  private.dead_letter_job(
    'billing-outbox',
    pg_catalog.current_setting('swara.test_dead_message_id')::bigint,
    'test-dead-letter-001',
    'processing_failed'
  ),
  'dead-letter acknowledgement is idempotent'
);
select is(
  (
    with allowed as (
      select queue_name, ordinal::integer
      from unnest(array[
        'vault-ingest',
        'ocr-fallback',
        'generate-embeddings',
        'billing-outbox',
        'usage-reconciliation',
        'account-export',
        'account-deletion',
        'artifact-retention'
      ]::text[]) with ordinality as item(queue_name, ordinal)
    ), sent as (
      select private.enqueue_job(
        allowed.queue_name,
        pg_catalog.jsonb_build_object(
          'schema_version', 1,
          'job_type', 'test.allowed',
          'job_id', pg_catalog.format(
            '00000000-0000-4000-8000-%s',
            pg_catalog.lpad(allowed.ordinal::text, 12, '0')
          ),
          'idempotency_key', 'test-allowed-' || allowed.ordinal::text,
          'correlation_id', pg_catalog.format(
            '00000000-0000-4000-8000-%s',
            pg_catalog.lpad((allowed.ordinal + 100)::text, 12, '0')
          )
        ),
        0
      ) as message_id
      from allowed
    )
    select pg_catalog.count(*)::integer
    from sent
  ),
  8,
  'exactly the eight declared queues accept closed envelopes'
);

reset role;

select * from finish();
rollback;
