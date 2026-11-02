-- Bounded, provider-neutral projection boundary for verified Alterity events.
--
-- Alterity remains the billing authority. Swara stores only an opaque customer
-- reference and the minimal entitlement cache needed by local quota checks. No
-- webhook body, provider payload, customer profile, invoice, or subscription
-- object is accepted or persisted here.

begin;

create or replace function private.establish_billing_link(
  p_user_id pg_catalog.uuid,
  p_customer_reference pg_catalog.text
)
returns table (
  link_created pg_catalog.bool
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_link private.billing_links%rowtype;
begin
  if p_user_id is null
     or p_customer_reference is null
     or p_customer_reference <> pg_catalog.btrim(p_customer_reference)
     or pg_catalog.char_length(p_customer_reference) not between 1 and 512
     or p_customer_reference ~ '[[:cntrl:]]' then
    raise exception using
      errcode = '22023',
      message = 'Billing link contract is invalid';
  end if;

  -- Serializing by user prevents a concurrently returned checkout/portal link
  -- from replacing a verified billing projection.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-billing-link:%s', p_user_id),
      8072026::bigint
    )
  );

  select *
    into v_link
    from private.billing_links
   where user_id = p_user_id
   for update;

  if found then
    if v_link.provider <> 'alterity'
       or v_link.external_customer_id <> p_customer_reference then
      raise exception using
        errcode = '22023',
        message = 'Billing link conflicts with the established customer reference';
    end if;

    return query select false;
    return;
  end if;

  insert into private.billing_links (
    user_id, provider, external_customer_id, link_status
  )
  values (
    p_user_id, 'alterity', p_customer_reference, 'pending'
  );

  return query select true;
end;
$function$;

create or replace function private.project_billing_entitlement(
  p_user_id pg_catalog.uuid,
  p_customer_reference pg_catalog.text,
  p_link_status pg_catalog.text,
  p_plan_code pg_catalog.text,
  p_subscription_status pg_catalog.text,
  p_capabilities pg_catalog.jsonb,
  p_limits pg_catalog.jsonb,
  p_valid_until pg_catalog.timestamptz,
  p_source_version pg_catalog.text
)
returns table (
  link_written pg_catalog.bool,
  snapshot_written pg_catalog.bool
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_snapshot private.entitlement_snapshots%rowtype;
  v_link private.billing_links%rowtype;
begin
  if p_user_id is null
     or p_customer_reference is null
     or p_customer_reference <> pg_catalog.btrim(p_customer_reference)
     or pg_catalog.char_length(p_customer_reference) not between 1 and 512
     or p_customer_reference ~ '[[:cntrl:]]'
     or p_link_status not in ('pending', 'active', 'suspended', 'revoked')
     or p_plan_code is null
     or p_plan_code <> pg_catalog.lower(pg_catalog.btrim(p_plan_code))
     or p_plan_code !~ '^[a-z0-9][a-z0-9._-]{0,127}$'
     or p_subscription_status not in (
       'none', 'trialing', 'active', 'past_due', 'paused', 'unpaid',
       'cancelled', 'expired', 'incomplete'
     )
     or p_capabilities is null
     or pg_catalog.jsonb_typeof(p_capabilities) <> 'object'
     or pg_catalog.octet_length(p_capabilities::pg_catalog.text) > 16384
     or p_limits is null
     or pg_catalog.jsonb_typeof(p_limits) <> 'object'
     or pg_catalog.octet_length(p_limits::pg_catalog.text) > 16384
     or p_valid_until is null
     or p_source_version is null
     or p_source_version <> pg_catalog.btrim(p_source_version)
     or pg_catalog.char_length(p_source_version) not between 1 and 128
     or p_source_version !~ '^[A-Za-z0-9][A-Za-z0-9._:-]*$' then
    raise exception using
      errcode = '22023',
      message = 'Billing entitlement projection contract is invalid';
  end if;

  -- A source version is idempotent only when every cache field agrees. The
  -- advisory lock also serializes two distinct versions updating one user's
  -- one-to-one billing link.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      pg_catalog.format('swara-billing-projection:%s', p_user_id),
      8072026::bigint
    )
  );

  select *
    into v_snapshot
    from private.entitlement_snapshots
   where user_id = p_user_id
     and source_version = p_source_version
   for update;

  if found then
    if v_snapshot.plan_code <> p_plan_code
       or v_snapshot.subscription_status <> p_subscription_status
       or v_snapshot.capabilities <> p_capabilities
       or v_snapshot.limits <> p_limits
       or v_snapshot.valid_until is distinct from p_valid_until then
      raise exception using
        errcode = '22023',
        message = 'Billing source version was reused with different entitlement data';
    end if;

    select *
      into v_link
      from private.billing_links
     where user_id = p_user_id
     for update;

    if not found
       or v_link.provider <> 'alterity'
       or v_link.external_customer_id <> p_customer_reference
       or v_link.link_status <> p_link_status then
      raise exception using
        errcode = '22023',
        message = 'Billing source version was reused with different link data';
    end if;

    return query select false, false;
    return;
  end if;

  insert into private.billing_links as link (
    user_id, provider, external_customer_id, link_status
  )
  values (
    p_user_id, 'alterity', p_customer_reference, p_link_status
  )
  on conflict (user_id) do update
    set external_customer_id = excluded.external_customer_id,
        link_status = excluded.link_status
  returning * into v_link;

  insert into private.entitlement_snapshots (
    user_id, plan_code, subscription_status, capabilities, limits, valid_until,
    source_version
  )
  values (
    p_user_id, p_plan_code, p_subscription_status, p_capabilities, p_limits,
    p_valid_until, p_source_version
  );

  return query select true, true;
end;
$function$;

alter function private.establish_billing_link(pg_catalog.uuid, pg_catalog.text)
  owner to postgres;
alter function private.project_billing_entitlement(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.text, pg_catalog.text,
  pg_catalog.text, pg_catalog.jsonb, pg_catalog.jsonb, pg_catalog.timestamptz,
  pg_catalog.text
) owner to postgres;

revoke all privileges on function private.establish_billing_link(pg_catalog.uuid, pg_catalog.text)
  from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;
revoke all privileges on function private.project_billing_entitlement(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.text, pg_catalog.text,
  pg_catalog.text, pg_catalog.jsonb, pg_catalog.jsonb, pg_catalog.timestamptz,
  pg_catalog.text
) from public, anon, authenticated, service_role, swara_api_runtime, swara_worker_runtime;

grant execute on function private.establish_billing_link(pg_catalog.uuid, pg_catalog.text)
  to swara_api_runtime;
grant execute on function private.project_billing_entitlement(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.text, pg_catalog.text,
  pg_catalog.text, pg_catalog.jsonb, pg_catalog.jsonb, pg_catalog.timestamptz,
  pg_catalog.text
) to swara_api_runtime;

comment on function private.establish_billing_link(pg_catalog.uuid, pg_catalog.text) is
  'API-runtime-only creation of a pending opaque Alterity customer link from a verified checkout or portal relay response. Provider bodies are never stored.';
comment on function private.project_billing_entitlement(
  pg_catalog.uuid, pg_catalog.text, pg_catalog.text, pg_catalog.text,
  pg_catalog.text, pg_catalog.jsonb, pg_catalog.jsonb, pg_catalog.timestamptz,
  pg_catalog.text
) is
  'API-runtime-only idempotent projection of a bounded provider-neutral entitlement contract after verified Alterity webhook delivery. Alterity remains authoritative; no raw webhook body or provider payload is stored.';

commit;
