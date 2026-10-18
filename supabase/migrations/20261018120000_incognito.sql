-- Meeterz – Inkognito-Modus
-- 1) Kurz unsichtbar: Standort UND Routen sind für Freunde nicht abrufbar (zeitlich begrenzt oder bis zum Ausschalten).
-- 2) Routen verbergen: eigene Routen bleiben dauerhaft privat, der Standort wird weiter geteilt.
-- Freunde sehen keinen Unterschied zu „teilt gerade nicht" (kein Hinweis auf Inkognito).

alter table public.profiles add column incognito_until timestamptz;           -- null = nicht inkognito
alter table public.profiles add column hide_routes boolean not null default false;

-- Wer inkognito ist, teilt nicht (Standort, Realtime-Kanal, Routen, Treffpunkt-Vorschläge)
create or replace function private.is_sharing(uid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid and p.sharing_enabled
      and (p.sharing_until is null or p.sharing_until > now())
      and (p.incognito_until is null or p.incognito_until <= now())
  );
$$;

-- Routen sind nur sichtbar, wenn geteilt wird UND der Nutzer sie nicht verbirgt
create or replace function private.routes_visible(uid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select private.is_sharing(uid)
     and exists (select 1 from public.profiles p where p.id = uid and not p.hide_routes);
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- Routen der Freunde und Treffpunkt-Suche: nur sichtbare Routen
create or replace function public.friends_routes()
returns table (
  friend_id         uuid,
  destination_name  text,
  dest_lat          double precision,
  dest_lng          double precision,
  eta               timestamptz,
  path_geojson      text,
  updated_at        timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select r.user_id, r.destination_name,
         extensions.st_y(r.destination::extensions.geometry),
         extensions.st_x(r.destination::extensions.geometry),
         r.eta,
         extensions.st_asgeojson(r.path),
         r.updated_at
  from public.active_routes r
  where r.user_id <> auth.uid()
    and private.are_friends(auth.uid(), r.user_id)
    and private.routes_visible(r.user_id)
    and r.updated_at > now() - interval '3 hours'
    and r.eta > now() - interval '10 minutes';
$$;

create or replace function public.find_meetups(
  max_distance_m double precision default 1500,
  max_wait_min   double precision default 20
)
returns table (
  friend_id   uuid,
  lat         double precision,
  lng         double precision,
  my_eta      timestamptz,
  friend_eta  timestamptz,
  distance_m  double precision
)
language sql stable security definer set search_path = ''
as $$
  with mine as (
    select rp.position, rp.eta, false as stationary
    from public.route_points rp
    join public.active_routes ar on ar.user_id = rp.user_id
    where rp.user_id = auth.uid()
      and ar.updated_at > now() - interval '3 hours'
      and rp.eta > now()
    union all
    select l.position, now(), true
    from public.last_locations l
    where l.user_id = auth.uid()
      and l.updated_at > now() - interval '30 minutes'
      and not exists (select 1 from public.active_routes a where a.user_id = auth.uid())
  ),
  theirs as (
    select rp.user_id, rp.position, rp.eta
    from public.route_points rp
    join public.active_routes ar on ar.user_id = rp.user_id
    where rp.user_id <> auth.uid()
      and ar.updated_at > now() - interval '3 hours'
      and rp.eta > now()
      and private.are_friends(auth.uid(), rp.user_id)
      and private.routes_visible(rp.user_id)
  ),
  pairs as (
    select t.user_id,
           m.position as my_pos, m.eta as my_eta, t.eta as friend_eta,
           extensions.st_distance(m.position, t.position) as dist
    from mine m
    join theirs t on extensions.st_dwithin(m.position, t.position, max_distance_m)
    where m.stationary
       or abs(extract(epoch from (m.eta - t.eta))) <= max_wait_min * 60
  )
  select distinct on (p.user_id)
         p.user_id,
         extensions.st_y(p.my_pos::extensions.geometry),
         extensions.st_x(p.my_pos::extensions.geometry),
         p.my_eta, p.friend_eta, p.dist
  from pairs p
  order by p.user_id, greatest(p.my_eta, p.friend_eta), p.dist;
$$;

