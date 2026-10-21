-- Meeterz – Fortbewegungsart (Auto / Fahrrad / zu Fuß) der geteilten Route.
-- Treffpunkte müssen für beide erreichbar sein; dafür braucht die App die Art des Freundes.

alter table public.active_routes
  add column if not exists travel_mode text not null default 'car'
  check (travel_mode in ('car', 'bike', 'walk'));

-- set_active_route: neuer optionaler Parameter. Alte App-Versionen rufen weiter mit fünf Argumenten auf (Standard: Auto).
drop function if exists public.set_active_route(text, double precision, double precision, double precision, jsonb);

create function public.set_active_route(
  destination_name text,
  dest_lat double precision,
  dest_lng double precision,
  eta_unix double precision,
  points jsonb,
  travel_mode text default 'car'
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := auth.uid();
  mode text := case when travel_mode in ('car', 'bike', 'walk') then travel_mode else 'car' end;
begin
  if jsonb_array_length(points) < 2 then
    raise exception 'Route braucht mindestens zwei Punkte';
  end if;

  insert into public.active_routes (user_id, destination_name, destination, path, eta, updated_at, travel_mode)
  values (
    me,
    destination_name,
    extensions.st_setsrid(extensions.st_makepoint(dest_lng, dest_lat), 4326)::extensions.geography,
    (select extensions.st_setsrid(
              extensions.st_makeline(array_agg(
                extensions.st_makepoint((p->>0)::float8, (p->>1)::float8) order by i)), 4326)::extensions.geography
       from jsonb_array_elements(points) with ordinality as t(p, i)),
    to_timestamp(eta_unix),
    now(),
    mode
  )
  on conflict (user_id) do update
    set destination_name = excluded.destination_name,
        destination = excluded.destination,
        path = excluded.path,
        eta = excluded.eta,
        updated_at = excluded.updated_at,
        travel_mode = excluded.travel_mode;

  delete from public.route_points where user_id = me;
  insert into public.route_points (user_id, seq, position, eta)
  select me, i::int,
         extensions.st_setsrid(extensions.st_makepoint((p->>0)::float8, (p->>1)::float8), 4326)::extensions.geography,
         to_timestamp((p->>2)::float8)
  from jsonb_array_elements(points) with ordinality as t(p, i);
end;
$$;

-- find_meetups: liefert zusätzlich die Fortbewegungsart des Freundes
drop function if exists public.find_meetups(double precision, double precision);

create function public.find_meetups(
  max_distance_m double precision default 1500,
  max_wait_min   double precision default 20
)
returns table (
  friend_id   uuid,
  lat         double precision,
  lng         double precision,
  my_eta      timestamptz,
  friend_eta  timestamptz,
  distance_m  double precision,
  friend_mode text
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
    select rp.user_id, rp.position, rp.eta, ar.travel_mode
    from public.route_points rp
    join public.active_routes ar on ar.user_id = rp.user_id
    where rp.user_id <> auth.uid()
      and ar.updated_at > now() - interval '3 hours'
      and rp.eta > now()
      and private.are_friends(auth.uid(), rp.user_id)
      and private.routes_visible(rp.user_id)
  ),
  pairs as (
    select t.user_id, t.travel_mode,
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
         p.my_eta, p.friend_eta, p.dist, p.travel_mode
  from pairs p
  order by p.user_id, greatest(p.my_eta, p.friend_eta), p.dist;
$$;

revoke execute on function
  public.set_active_route(text, double precision, double precision, double precision, jsonb, text),
  public.find_meetups(double precision, double precision)
from public, anon;

grant execute on function
  public.set_active_route(text, double precision, double precision, double precision, jsonb, text),
  public.find_meetups(double precision, double precision)
to authenticated;
