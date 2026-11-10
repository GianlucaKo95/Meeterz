-- Live-Belegung und Ad-hoc-Preise der Ladesäulen aus der Mobilithek (AFIR, DATEX II v3).
-- Die Edge Function „mobilithek-push“ schreibt hinein (Dienstschlüssel), die Apps lesen nur über
-- charge_availability(): je Standort freie/belegte/gestörte Ladepunkte und der günstigste kWh-Preis.
--
-- Statisch (selten): Standort mit Koordinaten, Betreiber, Leistung; Ladepunkte gehören zu einem Standort.
-- Dynamisch (laufend): Status und Preis je Ladepunkt. Die IDs sind die der Betreiber (EVSE-ID oder UUID) –
-- statisch und dynamisch verweisen auf dieselben.

create table if not exists public.charge_site_static (
  site_id     text primary key,
  lat         double precision not null,
  lng         double precision not null,
  name        text,
  operator    text,
  max_kw      double precision,
  updated_at  timestamptz not null default now()
);
create index if not exists charge_site_static_lat_lng on public.charge_site_static (lat, lng);

create table if not exists public.charge_point_static (
  point_id    text primary key,
  site_id     text not null,
  max_kw      double precision,
  updated_at  timestamptz not null default now()
);
create index if not exists charge_point_static_site on public.charge_point_static (site_id);

create table if not exists public.charge_point_status (
  point_id    text primary key,
  site_id     text,                 -- aus der dynamischen Meldung (falls der Betreiber ihn mitschickt)
  status      text not null,        -- available, charging, occupied, reserved, faulted, …
  price_kwh   double precision,     -- Ad-hoc-Preis inkl. MwSt., €/kWh
  reported_at timestamptz,          -- lastUpdated laut Betreiber
  received_at timestamptz not null default now()
);
create index if not exists charge_point_status_site on public.charge_point_status (site_id);

alter table public.charge_site_static enable row level security;
alter table public.charge_point_static enable row level security;
alter table public.charge_point_status enable row level security;
-- keine Policies: Schreiben nur mit Dienstschlüssel, Lesen über charge_availability()

-- Standorte im Korridor um Punkte entlang der Route (alle ~5 km, höchstens 400) mit aktueller Belegung.
-- Meldungen älter als 2 Stunden gelten als unbekannt.
create or replace function public.charge_availability(
  lats double precision[], lngs double precision[], radius_m double precision default 3000
)
returns table (
  site_id text, lat double precision, lng double precision, operator text, max_kw double precision,
  free int, occupied int, out_of_service int, price_kwh double precision, updated_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  with route as (
    select t.lat, t.lng from unnest(lats[1:400], lngs[1:400]) as t(lat, lng)
  ),
  sites as (
    select distinct s.* from public.charge_site_static s
    join route r on s.lat between r.lat - radius_m / 111000 and r.lat + radius_m / 111000
                and s.lng between r.lng - radius_m / (111000 * cos(radians(r.lat))) and r.lng + radius_m / (111000 * cos(radians(r.lat)))
  ),
  points as (
    select s.site_id, ps.status, ps.price_kwh, ps.received_at
    from sites s
    join public.charge_point_static p on p.site_id = s.site_id
    join public.charge_point_status ps on ps.point_id = p.point_id
    where ps.received_at > now() - interval '2 hours'
    union all
    -- Betreiber, die den Standort in der dynamischen Meldung mitschicken (ohne statische Ladepunkte)
    select s.site_id, ps.status, ps.price_kwh, ps.received_at
    from sites s
    join public.charge_point_status ps on ps.site_id = s.site_id
    where ps.received_at > now() - interval '2 hours'
      and not exists (select 1 from public.charge_point_static p where p.point_id = ps.point_id)
  )
  select s.site_id, s.lat, s.lng, s.operator, s.max_kw,
    count(*) filter (where p.status = 'available')::int,
    count(*) filter (where p.status in ('charging', 'occupied', 'reserved', 'blocked', 'suspendedEV', 'suspendedEVSE', 'finishing', 'preparing'))::int,
    count(*) filter (where p.status in ('faulted', 'outOfOrder', 'inoperative', 'unavailable', 'outOfService', 'notInOperation', 'closed', 'removed'))::int,
    min(p.price_kwh),
    max(p.received_at)
  from sites s join points p on p.site_id = s.site_id
  group by s.site_id, s.lat, s.lng, s.operator, s.max_kw;
$$;

revoke execute on function public.charge_availability(double precision[], double precision[], double precision) from public, anon;
grant execute on function public.charge_availability(double precision[], double precision[], double precision) to authenticated;
