-- Round 4B: private, idempotent usage counter transitions.
--
-- Quota buckets are provisioned from an entitlement snapshot by a trusted
-- billing worker.  These routines only consume existing buckets; they never
-- create a bucket with an unverified entitlement or limit.

begin;

create or replace function private.reserve_usage_atomic(
  p_user_id pg_catalog.uuid,
  p_meter pg_catalog.text,
  p_period_start pg_catalog.timestamptz,
  p_period_end pg_catalog.timestamptz,
  p_quantity pg_catalog.numeric,
  p_idempotency_key pg_catalog.text,
  p_expires_at pg_catalog.timestamptz
)
returns table (
  reservation_id pg_catalog.uuid,
  reservation_status pg_catalog.text,
  quota_bucket_id pg_catalog.uuid,
  reserved_quantity pg_catalog.numeric,
  expires_at pg_catalog.timestamptz
)
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_bucket private.quota_buckets%rowtype;
  v_reservation private.usage_reservations%rowtype;
begin
  if p_user_id is null
     or p_meter is null
     or p_meter <> pg_catalog.lower(pg_catalog.btrim(p_meter))
     or p_meter !~ '^[a-z0-9][a-z0-9._:-]{0,127}$'
     or p_period_start is null
     or p_period_end is null
     or p_period_end <= p_period_start
     or p_quantity is null
     or p_quantity <= 0
     or p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 1 and 512
     or p_expires_at is null then
    raise exception using
      errcode = '22023',
      message = 'Invalid usage reservation contract';
  end if;

  -- Serialize retries for this logical request before taking the quota lock.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-usage-reserve:%s:%s', p_user_id, p_idempotency_key),
      0::bigint
    )
  );

  select r.*
    into v_reservation
    from private.usage_reservations as r
   where r.user_id = p_user_id
     and r.idempotency_key = p_idempotency_key;

  if found then
    select q.*
      into v_bucket
      from private.quota_buckets as q
     where q.id = v_reservation.quota_bucket_id
       and q.user_id = v_reservation.user_id
       and q.meter = v_reservation.meter;

    if not found
       or v_reservation.meter <> p_meter
       or v_bucket.period_start is distinct from p_period_start
       or v_bucket.period_end is distinct from p_period_end
       or v_reservation.reserved_quantity is distinct from p_quantity
       or v_reservation.expires_at is distinct from p_expires_at then
      raise exception using
        errcode = '22023',
        message = 'Usage reservation idempotency key was reused with different input';
    end if;

    return query
      select v_reservation.id, v_reservation.status, v_reservation.quota_bucket_id,
             v_reservation.reserved_quantity, v_reservation.expires_at;
    return;
  end if;

  select q.*
    into v_bucket
    from private.quota_buckets as q
   where q.user_id = p_user_id
     and q.meter = p_meter
     and q.period_start = p_period_start
   for update;

  if not found
     or v_bucket.period_end is distinct from p_period_end
     or v_bucket.status <> 'open'
     or p_period_start > pg_catalog.clock_timestamp()
     or p_period_end <= pg_catalog.clock_timestamp()
     or p_expires_at <= pg_catalog.clock_timestamp()
     or p_expires_at > v_bucket.period_end
     or v_bucket.reserved_quantity + v_bucket.committed_quantity + p_quantity
          > v_bucket.limit_quantity then
    raise exception using
      errcode = '23514',
      message = 'Usage reservation cannot be covered by an open quota bucket';
  end if;

  insert into private.usage_reservations (
    user_id, quota_bucket_id, meter, idempotency_key, reserved_quantity, expires_at
  )
  values (
    p_user_id, v_bucket.id, p_meter, p_idempotency_key, p_quantity, p_expires_at
  )
  on conflict (user_id, idempotency_key) do nothing
  returning * into v_reservation;

  if not found then
    select r.*
      into v_reservation
      from private.usage_reservations as r
     where r.user_id = p_user_id
       and r.idempotency_key = p_idempotency_key;

    if not found
       or v_reservation.quota_bucket_id <> v_bucket.id
       or v_reservation.meter <> p_meter
       or v_reservation.reserved_quantity is distinct from p_quantity
       or v_reservation.expires_at is distinct from p_expires_at then
      raise exception using
        errcode = '22023',
        message = 'Usage reservation idempotency key was reused with different input';
    end if;
  else
    update private.quota_buckets as q
       set reserved_quantity = q.reserved_quantity + p_quantity
     where q.id = v_bucket.id
       and q.user_id = p_user_id
       and q.meter = p_meter;
  end if;

  return query
    select v_reservation.id, v_reservation.status, v_reservation.quota_bucket_id,
           v_reservation.reserved_quantity, v_reservation.expires_at;
end;
$function$;

create or replace function private.commit_usage_atomic(
  p_user_id pg_catalog.uuid,
  p_reservation_id pg_catalog.uuid,
  p_actual_quantity pg_catalog.numeric,
  p_idempotency_key pg_catalog.text,
  p_task_id pg_catalog.uuid default null,
  p_session_id pg_catalog.uuid default null
)
returns table (
  reservation_id pg_catalog.uuid,
  reservation_status pg_catalog.text,
  usage_event_id pg_catalog.uuid,
  billing_outbox_id pg_catalog.uuid,
  actual_quantity pg_catalog.numeric
)
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_bucket private.quota_buckets%rowtype;
  v_reservation private.usage_reservations%rowtype;
  v_event private.usage_events%rowtype;
  v_outbox private.billing_outbox%rowtype;
begin
  if p_user_id is null
     or p_reservation_id is null
     or p_actual_quantity is null
     or p_actual_quantity <= 0
     or p_idempotency_key is null
     or p_idempotency_key <> pg_catalog.btrim(p_idempotency_key)
     or pg_catalog.char_length(p_idempotency_key) not between 1 and 512 then
    raise exception using
      errcode = '22023',
      message = 'Invalid usage commit contract';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-usage-commit:%s:%s', p_user_id, p_idempotency_key),
      0::bigint
    )
  );

  select r.*
    into v_reservation
    from private.usage_reservations as r
   where r.id = p_reservation_id
     and r.user_id = p_user_id
   for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Usage reservation was not found for this owner';
  end if;

  if v_reservation.status = 'committed' then
    select e.*
      into v_event
      from private.usage_events as e
     where e.reservation_id = v_reservation.id
       and e.user_id = p_user_id;

    select o.*
      into v_outbox
      from private.billing_outbox as o
     where o.usage_event_id = v_event.id
       and o.user_id = p_user_id
       and o.event_type = 'usage.committed';

    if not found
       or v_event.idempotency_key <> p_idempotency_key
       or v_event.actual_quantity is distinct from p_actual_quantity
       or v_event.task_id is distinct from p_task_id
       or v_event.session_id is distinct from p_session_id then
      raise exception using
        errcode = '22023',
        message = 'Usage commit idempotency key was reused with different input';
    end if;

    return query
      select v_reservation.id, v_reservation.status, v_event.id, v_outbox.id,
             v_event.actual_quantity;
    return;
  end if;

  if v_reservation.status <> 'reserved' then
    raise exception using
      errcode = '23514',
      message = 'Only a reserved usage hold can be committed';
  end if;

  select q.*
    into v_bucket
    from private.quota_buckets as q
   where q.id = v_reservation.quota_bucket_id
     and q.user_id = v_reservation.user_id
     and q.meter = v_reservation.meter
   for update;

  if not found
     or v_bucket.status <> 'open'
     or v_bucket.period_start > pg_catalog.clock_timestamp()
     or v_bucket.period_end <= pg_catalog.clock_timestamp()
     or v_reservation.expires_at <= pg_catalog.clock_timestamp()
     or p_actual_quantity > v_reservation.reserved_quantity
     or v_bucket.reserved_quantity < v_reservation.reserved_quantity then
    raise exception using
      errcode = '23514',
      message = 'Usage reservation cannot be committed against its quota bucket';
  end if;

  if p_task_id is not null and not exists (
    select 1
      from private.agent_tasks as t
     where t.id = p_task_id
       and t.user_id = p_user_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'Usage task does not belong to the reservation owner';
  end if;

  if p_session_id is not null and not exists (
    select 1
      from private.browser_sessions as s
     where s.id = p_session_id
       and s.user_id = p_user_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'Usage session does not belong to the reservation owner';
  end if;

  if exists (
    select 1
      from private.usage_events as e
     where e.user_id = p_user_id
       and e.idempotency_key = p_idempotency_key
  ) then
    raise exception using
      errcode = '22023',
      message = 'Usage commit idempotency key belongs to another reservation';
  end if;

  update private.quota_buckets as q
     set reserved_quantity = q.reserved_quantity - v_reservation.reserved_quantity,
         committed_quantity = q.committed_quantity + p_actual_quantity
   where q.id = v_bucket.id
     and q.user_id = p_user_id
     and q.meter = v_reservation.meter;

  update private.usage_reservations
     set status = 'committed',
         committed_at = pg_catalog.clock_timestamp()
   where id = v_reservation.id
     and user_id = p_user_id
  returning * into v_reservation;

  insert into private.usage_events (
    user_id, reservation_id, task_id, session_id, meter, idempotency_key, actual_quantity
  )
  values (
    p_user_id, v_reservation.id, p_task_id, p_session_id, v_reservation.meter,
    p_idempotency_key, p_actual_quantity
  )
  returning * into v_event;

  insert into private.billing_outbox (
    user_id, usage_event_id, event_type, payload, idempotency_key
  )
  values (
    p_user_id,
    v_event.id,
    'usage.committed',
    pg_catalog.jsonb_build_object(
      'usage_event_id', v_event.id,
      'reservation_id', v_reservation.id,
      'meter', v_reservation.meter,
      'actual_quantity', v_event.actual_quantity
    ),
    pg_catalog.format('usage.committed:%s', v_event.id)
  )
  returning * into v_outbox;

  return query
    select v_reservation.id, v_reservation.status, v_event.id, v_outbox.id,
           v_event.actual_quantity;
end;
$function$;

create or replace function private.release_usage_reservation_atomic(
  p_user_id pg_catalog.uuid,
  p_reservation_id pg_catalog.uuid,
  p_release_reason pg_catalog.text
)
returns table (
  reservation_id pg_catalog.uuid,
  reservation_status pg_catalog.text,
  released_quantity pg_catalog.numeric,
  release_reason pg_catalog.text
)
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_bucket private.quota_buckets%rowtype;
  v_reservation private.usage_reservations%rowtype;
begin
  if p_user_id is null
     or p_reservation_id is null
     or p_release_reason is null
     or p_release_reason <> pg_catalog.lower(pg_catalog.btrim(p_release_reason))
     or p_release_reason !~ '^[a-z0-9][a-z0-9._:-]{0,127}$' then
    raise exception using
      errcode = '22023',
      message = 'Invalid usage release contract';
  end if;

  select r.*
    into v_reservation
    from private.usage_reservations as r
   where r.id = p_reservation_id
     and r.user_id = p_user_id
   for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Usage reservation was not found for this owner';
  end if;

  if v_reservation.status in ('released', 'expired') then
    if v_reservation.release_reason is distinct from p_release_reason then
      raise exception using
        errcode = '22023',
        message = 'Usage release was retried with a different reason';
    end if;

    return query
      select v_reservation.id, v_reservation.status, v_reservation.reserved_quantity,
             v_reservation.release_reason;
    return;
  end if;

  if v_reservation.status <> 'reserved' then
    raise exception using
      errcode = '23514',
      message = 'Only a reserved usage hold can be released';
  end if;

  select q.*
    into v_bucket
    from private.quota_buckets as q
   where q.id = v_reservation.quota_bucket_id
     and q.user_id = v_reservation.user_id
     and q.meter = v_reservation.meter
   for update;

  if not found or v_bucket.reserved_quantity < v_reservation.reserved_quantity then
    raise exception using
      errcode = '23514',
      message = 'Usage reservation cannot be released against its quota bucket';
  end if;

  update private.quota_buckets as q
     set reserved_quantity = q.reserved_quantity - v_reservation.reserved_quantity
   where q.id = v_bucket.id
     and q.user_id = p_user_id
     and q.meter = v_reservation.meter;

  update private.usage_reservations
     set status = 'released',
         released_at = pg_catalog.clock_timestamp(),
         release_reason = p_release_reason
   where id = v_reservation.id
     and user_id = p_user_id
  returning * into v_reservation;

  return query
    select v_reservation.id, v_reservation.status, v_reservation.reserved_quantity,
           v_reservation.release_reason;
end;
$function$;

-- Functions receive EXECUTE from PUBLIC by default.  Keep this private
-- accounting interface unavailable to clients even if a later migration adds
-- table grants or exposes another schema through the Data API.
revoke all privileges on function private.reserve_usage_atomic(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.timestamptz,
  pg_catalog.timestamptz, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.timestamptz
) from public, anon, authenticated, service_role;

revoke all privileges on function private.commit_usage_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.uuid, pg_catalog.uuid
) from public, anon, authenticated, service_role;

revoke all privileges on function private.release_usage_reservation_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.text
) from public, anon, authenticated, service_role;

grant execute on function private.reserve_usage_atomic(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.timestamptz,
  pg_catalog.timestamptz, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.timestamptz
) to service_role;

grant execute on function private.commit_usage_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.numeric, pg_catalog.text,
  pg_catalog.uuid, pg_catalog.uuid
) to service_role;

grant execute on function private.release_usage_reservation_atomic(
  pg_catalog.uuid, pg_catalog.uuid, pg_catalog.text
) to service_role;

commit;
