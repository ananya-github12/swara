-- Round 4E: bounded, queue-backed maintenance dispatch.
--
-- These jobs only publish one small typed message to an existing durable queue;
-- the trusted worker owns the actual work.

begin;

-- Do not pin the extension version.  Supabase supplies the supported pg_cron
-- version for the target Postgres image/project.
create extension if not exists pg_cron;

-- The dispatcher has a deliberately closed contract: it may publish only the
-- seven bounded maintenance operations scheduled below.  A one-at-a-time
-- transaction advisory lock is defence in depth for accidental concurrent
-- manual dispatches; pg_cron itself also serializes runs of each individual
-- job.  Its fixed search_path prevents caller-controlled name resolution.
create or replace function private.enqueue_maintenance_dispatch(
  p_queue_name text,
  p_operation text,
  p_max_items integer,
  p_interval_seconds integer
)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_expected_queue_name text;
  v_expected_interval_seconds integer;
  v_max_allowed_items integer;
  v_window_start timestamptz;
  v_idempotency_key text;
  v_message_id bigint;
begin
  case p_operation
    when 'retry_due_billing_outbox' then
      v_expected_queue_name := 'billing-outbox';
      v_expected_interval_seconds := 60;
      v_max_allowed_items := 50;
    when 'release_expired_usage_reservations' then
      v_expected_queue_name := 'usage-reconciliation';
      v_expected_interval_seconds := 300;
      v_max_allowed_items := 100;
    when 'detect_stuck_vault_ingestion' then
      v_expected_queue_name := 'vault-ingest';
      v_expected_interval_seconds := 600;
      v_max_allowed_items := 50;
    when 'refresh_near_expiry_entitlements' then
      v_expected_queue_name := 'billing-outbox';
      v_expected_interval_seconds := 900;
      v_max_allowed_items := 50;
    when 'purge_expired_task_artifacts' then
      v_expected_queue_name := 'artifact-retention';
      v_expected_interval_seconds := 3600;
      v_max_allowed_items := 100;
    when 'reconcile_usage' then
      v_expected_queue_name := 'usage-reconciliation';
      v_expected_interval_seconds := 86400;
      v_max_allowed_items := 100;
    when 'cleanup_expired_account_exports' then
      v_expected_queue_name := 'account-export';
      v_expected_interval_seconds := 86400;
      v_max_allowed_items := 100;
    else
      raise exception using
        errcode = '22023',
        message = 'Unknown Swara maintenance dispatch operation';
  end case;

  if p_queue_name is distinct from v_expected_queue_name
     or p_interval_seconds is distinct from v_expected_interval_seconds
     or p_max_items is null
     or p_max_items < 1
     or p_max_items > v_max_allowed_items then
    raise exception using
      errcode = '22023',
      message = 'Invalid Swara maintenance dispatch contract';
  end if;

  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-maintenance-dispatch:%s', p_operation),
      0::bigint
    )
  ) then
    return null;
  end if;

  v_window_start := pg_catalog.to_timestamp(
    (
      pg_catalog.floor(
        extract(epoch from pg_catalog.clock_timestamp()) / p_interval_seconds
      ) * p_interval_seconds
    )::double precision
  );

  v_idempotency_key := pg_catalog.format(
    'swara-maintenance:%s:%s',
    p_operation,
    pg_catalog.to_char(
      v_window_start at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS"Z"'
    )
  );

  select pgmq.send(
    p_queue_name,
    pg_catalog.jsonb_build_object(
      'operation', p_operation,
      'source', 'cron',
      'idempotency_key', v_idempotency_key,
      'max_items', p_max_items,
      'dispatch_window_start', v_window_start,
      'dispatch_interval_seconds', p_interval_seconds
    )
  )
  into v_message_id;

  return v_message_id;
end;
$function$;

comment on function private.enqueue_maintenance_dispatch(text, text, integer, integer) is
  'Server-only, bounded pgmq dispatch helper for Swara maintenance Cron jobs.';

-- Cron management is never a Data API surface.  The migration owner creates
-- and runs jobs; the trusted service role may call the narrow dispatcher for
-- an operational replay, but browser-facing roles cannot invoke either path.
revoke all privileges on schema cron from public, anon, authenticated;
revoke all privileges on all tables in schema cron from public, anon, authenticated;
revoke all privileges on all sequences in schema cron from public, anon, authenticated;
revoke execute on all functions in schema cron from public, anon, authenticated;

revoke execute on function private.enqueue_maintenance_dispatch(text, text, integer, integer)
  from public, anon, authenticated;
grant usage on schema private to service_role;
grant execute on function private.enqueue_maintenance_dispatch(text, text, integer, integer)
  to service_role;

-- Named pg_cron schedules are idempotent on current pg_cron: a second
-- schedule call from the same role with the same name updates the job.  This
-- safely replaces the stable job definitions during a reset or restore,
-- without writing to cron.job directly.
--
-- There are seven jobs (under Supabase's eight-concurrent-job guidance) and
-- their minute offsets avoid piling all daily/hourly work onto the same tick.
select cron.schedule(
  'swara-billing-retry-dispatch',
  '* * * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'billing-outbox', 'retry_due_billing_outbox', 50, 60
  );$command$
);

select cron.schedule(
  'swara-expired-reservation-release-dispatch',
  '*/5 * * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'usage-reconciliation', 'release_expired_usage_reservations', 100, 300
  );$command$
);

select cron.schedule(
  'swara-stuck-ingestion-detection-dispatch',
  '*/10 * * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'vault-ingest', 'detect_stuck_vault_ingestion', 50, 600
  );$command$
);

select cron.schedule(
  'swara-near-expiry-entitlement-refresh-dispatch',
  '*/15 * * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'billing-outbox', 'refresh_near_expiry_entitlements', 50, 900
  );$command$
);

select cron.schedule(
  'swara-artifact-purge-dispatch',
  '13 * * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'artifact-retention', 'purge_expired_task_artifacts', 100, 3600
  );$command$
);

select cron.schedule(
  'swara-usage-reconciliation-dispatch',
  '17 2 * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'usage-reconciliation', 'reconcile_usage', 100, 86400
  );$command$
);

select cron.schedule(
  'swara-expired-export-cleanup-dispatch',
  '31 2 * * *',
  $command$select private.enqueue_maintenance_dispatch(
    'account-export', 'cleanup_expired_account_exports', 100, 86400
  );$command$
);

commit;
