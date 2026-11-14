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
