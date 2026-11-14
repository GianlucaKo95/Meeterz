-- Serverseitige Steuerung des Mobilithek-Pulls.
-- Dynamische Statusmeldungen: maximal alle 3 Minuten je Subscription.
-- Statische Standort-/Ladepunktdaten: maximal alle 12 Stunden je Subscription.
-- Apps dürfen nur den authentifizierten Trigger aufrufen; Schreibzugriffe bleiben serverseitig.

create table if not exists public.mobilithek_subscription_state (
  subscription_id text primary key,
  publication_type text,
  last_checked_at timestamptz,
  last_success_at timestamptz,
  last_http_status integer,
  last_error text
);

alter table public.mobilithek_subscription_state enable row level security;
revoke all on public.mobilithek_subscription_state from anon, authenticated;

create table if not exists public.mobilithek_pull_control (
  id boolean primary key default true check (id),
  last_started_at timestamptz,
  last_completed_at timestamptz,
  lease_until timestamptz,
  last_error text
);

alter table public.mobilithek_pull_control enable row level security;
revoke all on public.mobilithek_pull_control from anon, authenticated;

create or replace function public.claim_mobilithek_pull(
  p_cooldown_seconds integer default 180,
  p_lease_seconds integer default 600
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  claimed boolean := false;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role required';
  end if;
  if p_cooldown_seconds < 30 or p_cooldown_seconds > 3600
     or p_lease_seconds < 60 or p_lease_seconds > 1800 then
    raise exception 'invalid lease or cooldown';
  end if;

  insert into public.mobilithek_pull_control (id, last_started_at, lease_until, last_error)
  values (true, now(), now() + make_interval(secs => p_lease_seconds), null)
  on conflict (id) do update
    set last_started_at = now(),
        lease_until = now() + make_interval(secs => p_lease_seconds),
        last_error = null
    where public.mobilithek_pull_control.lease_until < now()
      and (public.mobilithek_pull_control.last_started_at is null
           or public.mobilithek_pull_control.last_started_at < now() - make_interval(secs => p_cooldown_seconds))
  returning true into claimed;

  return coalesce(claimed, false);
end;
$$;

create or replace function public.complete_mobilithek_pull(p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role required';
  end if;

  update public.mobilithek_pull_control
  set lease_until = now(),
      last_completed_at = now(),
      last_error = nullif(left(p_error, 2000), '')
  where id = true;
end;
$$;

revoke all on function public.claim_mobilithek_pull(integer, integer) from public, anon, authenticated;
revoke all on function public.complete_mobilithek_pull(text) from public, anon, authenticated;
grant execute on function public.claim_mobilithek_pull(integer, integer) to service_role;
grant execute on function public.complete_mobilithek_pull(text) to service_role;

-- Bedingtes Status-Upsert: eine verspätete Betreiber-Meldung darf keinen neueren Status überschreiben.
create or replace function public.mobilithek_upsert_status(p_rows jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  affected bigint;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
    raise exception 'service_role required';
  end if;

  insert into public.charge_point_status
    (point_id, site_id, status, price_kwh, reported_at, received_at)
  select
    x.point_id, x.site_id, x.status, x.price_kwh, x.reported_at, x.received_at
  from jsonb_to_recordset(p_rows) as x(
    point_id text,
    site_id text,
    status text,
    price_kwh double precision,
    reported_at timestamptz,
    received_at timestamptz
  )
  where x.point_id is not null and x.status is not null
  on conflict (point_id) do update set
    site_id = excluded.site_id,
    status = excluded.status,
    price_kwh = excluded.price_kwh,
    reported_at = excluded.reported_at,
    received_at = excluded.received_at
  where public.charge_point_status.reported_at is null
     or (excluded.reported_at is not null
         and excluded.reported_at >= public.charge_point_status.reported_at);
  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function public.mobilithek_upsert_status(jsonb) from public, anon, authenticated;
grant execute on function public.mobilithek_upsert_status(jsonb) to service_role;
