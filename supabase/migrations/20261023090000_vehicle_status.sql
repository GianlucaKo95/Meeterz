-- Meeterz – Live-Fahrzeugdaten (E-Auto): Akkustand, Reichweite, Laden, Außentemperatur.
-- Quelle z. B. das Home-Assistant-Add-on „MG to ABRP Bridge“ (saic-python-mqtt-gateway, OsmAnd-Schnittstelle):
-- es ruft die Edge-Function vehicle-telemetry mit einem geheimen Gerätetoken auf. Lesen darf nur der Besitzer.

create table if not exists public.vehicle_links (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  token      text not null unique,
  created_at timestamptz not null default now()
);

alter table public.vehicle_links enable row level security;

create policy "vehicle_links: eigene lesen" on public.vehicle_links
  for select to authenticated
  using ((select auth.uid()) = user_id);

create table if not exists public.vehicle_status (
  user_id      uuid primary key references public.profiles (id) on delete cascade,
  soc          real,            -- Akkustand in %
  range_km     real,            -- Restreichweite laut Auto
  charging     boolean,
  power_kw     real,            -- Lade-/Entladeleistung (negativ = laden)
  ext_temp     real,            -- Außentemperatur °C
  odometer_km  real,
  speed_kmh    real,
  parked       boolean,
  lat          double precision,
  lng          double precision,
  reported_at  timestamptz,     -- Zeitpunkt der Messung im Auto
  updated_at   timestamptz not null default now()
);

alter table public.vehicle_status enable row level security;

create policy "vehicle_status: eigene lesen" on public.vehicle_status
  for select to authenticated
  using ((select auth.uid()) = user_id);

alter publication supabase_realtime add table public.vehicle_status;

-- Neues Gerätetoken erzeugen (ersetzt ein altes); geschrieben wird nur über die Edge-Function
create or replace function public.create_vehicle_link()
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  insert into public.vehicle_links (user_id, token) values (auth.uid(), t)
  on conflict (user_id) do update set token = excluded.token, created_at = now();
  return t;
end;
$$;

create or replace function public.remove_vehicle_link()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.vehicle_links where user_id = auth.uid();
  delete from public.vehicle_status where user_id = auth.uid();
$$;

revoke execute on function public.create_vehicle_link(), public.remove_vehicle_link() from public, anon;
grant execute on function public.create_vehicle_link(), public.remove_vehicle_link() to authenticated;
