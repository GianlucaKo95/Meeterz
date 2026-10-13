-- Meeterz – Phase 2: geteilte Routen, Treffpunkte, Treffen-Vorschläge,
-- zeitlich begrenztes Teilen, Push-Tokens, Konto löschen, Härtung.

-- ─────────────────────────────────────────────────────────────
-- Hilfsfunktionen aus der öffentlichen API nehmen
-- ─────────────────────────────────────────────────────────────

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

alter function public.are_friends(uuid, uuid) set schema private;
alter function public.can_receive_location(text) set schema private;

-- ─────────────────────────────────────────────────────────────
-- Zeitlich begrenztes Teilen
-- ─────────────────────────────────────────────────────────────

alter table public.profiles add column sharing_until timestamptz;  -- null = unbegrenzt

create or replace function private.is_sharing(uid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid and p.sharing_enabled
      and (p.sharing_until is null or p.sharing_until > now())
  );
$$;

create or replace function private.can_receive_location(topic text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  owner uuid;
begin
  if topic !~ '^loc:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  owner := substring(topic from 5)::uuid;
  if owner = auth.uid() then
    return true;
  end if;
  return private.are_friends(auth.uid(), owner) and private.is_sharing(owner);
end;
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- Die Realtime-Policy verweist per OID auf can_receive_location und folgt dem Schemawechsel automatisch.

create or replace function public.my_friends()
returns table (
  friendship_id        uuid,
  friend_id            uuid,
  handle               text,
  display_name         text,
  status               text,
  incoming             boolean,
  lat                  double precision,
  lng                  double precision,
  heading              double precision,
  speed                double precision,
  location_updated_at  timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select
    f.id, p.id, p.handle, p.display_name, f.status,
    f.addressee = auth.uid(),
    case when vis.ok then extensions.st_y(l.position::extensions.geometry) end,
    case when vis.ok then extensions.st_x(l.position::extensions.geometry) end,
    case when vis.ok then l.heading end,
    case when vis.ok then l.speed end,
    case when vis.ok then l.updated_at end
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  cross join lateral (select f.status = 'accepted' and private.is_sharing(p.id) as ok) vis
  left join public.last_locations l on l.user_id = p.id
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.display_name;
$$;

-- ─────────────────────────────────────────────────────────────
-- Geteilte Routen
-- route_points: Stützpunkte ca. alle 300 m mit voraussichtlicher Ankunftszeit
-- ─────────────────────────────────────────────────────────────

create table public.active_routes (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  destination_name  text,
  destination       extensions.geography(Point, 4326) not null,
  path              extensions.geography(LineString, 4326) not null,
  eta               timestamptz not null,
  updated_at        timestamptz not null default now()
);

create table public.route_points (
  user_id   uuid not null references public.active_routes (user_id) on delete cascade,
  seq       int not null,
  position  extensions.geography(Point, 4326) not null,
  eta       timestamptz not null,
  primary key (user_id, seq)
);

create index route_points_position_idx on public.route_points using gist (position);

alter table public.active_routes enable row level security;
alter table public.route_points  enable row level security;
-- keine Policies: Zugriff nur über RPCs

-- points: [[lng, lat, eta_unix_seconds], …] in Fahrtrichtung
create or replace function public.set_active_route(
  destination_name text,
  dest_lat double precision,
  dest_lng double precision,
  eta_unix double precision,
  points jsonb
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if jsonb_array_length(points) < 2 then
    raise exception 'Route braucht mindestens zwei Punkte';
  end if;

  insert into public.active_routes (user_id, destination_name, destination, path, eta, updated_at)
  values (
    me,
    destination_name,
    extensions.st_setsrid(extensions.st_makepoint(dest_lng, dest_lat), 4326)::extensions.geography,
    (select extensions.st_setsrid(
              extensions.st_makeline(array_agg(
                extensions.st_makepoint((p->>0)::float8, (p->>1)::float8) order by i)), 4326)::extensions.geography
       from jsonb_array_elements(points) with ordinality as t(p, i)),
    to_timestamp(eta_unix),
    now()
  )
  on conflict (user_id) do update
    set destination_name = excluded.destination_name,
        destination = excluded.destination,
        path = excluded.path,
        eta = excluded.eta,
        updated_at = excluded.updated_at;

  delete from public.route_points where user_id = me;
  insert into public.route_points (user_id, seq, position, eta)
  select me, i::int,
         extensions.st_setsrid(extensions.st_makepoint((p->>0)::float8, (p->>1)::float8), 4326)::extensions.geography,
         to_timestamp((p->>2)::float8)
  from jsonb_array_elements(points) with ordinality as t(p, i);
end;
$$;

create or replace function public.clear_active_route()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.active_routes where user_id = auth.uid();
$$;

-- Routen der Freunde (nur angenommene Freunde, die teilen, Route nicht älter als 3 Std.)
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
    and private.is_sharing(r.user_id)
    and r.updated_at > now() - interval '3 hours'
    and r.eta > now() - interval '10 minutes';
$$;

-- Treffpunkte: wo sind ich und ein Freund ungefähr zur gleichen Zeit in der Nähe?
-- Ohne eigene Route zählt mein letzter Standort (Freund fährt an mir vorbei).
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
      and private.is_sharing(rp.user_id)
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

-- ─────────────────────────────────────────────────────────────
-- Treffen-Vorschläge
-- ─────────────────────────────────────────────────────────────

create table public.meetups (
  id            uuid primary key default gen_random_uuid(),
  from_user     uuid not null references public.profiles (id) on delete cascade,
  to_user       uuid not null references public.profiles (id) on delete cascade,
  place_name    text not null check (char_length(place_name) between 1 and 120),
  position      extensions.geography(Point, 4326) not null,
  status        text not null default 'pending'
                check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  created_at    timestamptz not null default now(),
  responded_at  timestamptz,
  check (from_user <> to_user)
);

alter table public.meetups enable row level security;

create policy "meetups: eigene lesen" on public.meetups
  for select to authenticated
  using ((select auth.uid()) in (from_user, to_user));

alter publication supabase_realtime add table public.meetups;

create or replace function public.propose_meetup(
  to_user_id uuid, place_name text, lat double precision, lng double precision
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid;
begin
  if not private.are_friends(auth.uid(), to_user_id) then
    raise exception 'Nur unter Freunden möglich';
  end if;
  -- ältere offene Vorschläge an dieselbe Person ersetzen
  update public.meetups set status = 'cancelled', responded_at = now()
  where from_user = auth.uid() and to_user = to_user_id and status = 'pending';

  insert into public.meetups (from_user, to_user, place_name, position)
  values (auth.uid(), to_user_id, place_name,
          extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography)
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.respond_meetup(meetup_id uuid, accept boolean)
returns void
language sql security definer set search_path = ''
as $$
  update public.meetups
  set status = case when accept then 'accepted' else 'declined' end,
      responded_at = now()
  where id = meetup_id and to_user = auth.uid() and status = 'pending';
$$;

create or replace function public.cancel_meetup(meetup_id uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.meetups set status = 'cancelled', responded_at = now()
  where id = meetup_id and auth.uid() in (from_user, to_user) and status in ('pending', 'accepted');
$$;

-- Offene und angenommene Treffen der letzten 12 Std.
create or replace function public.my_meetups()
returns table (
  id            uuid,
  other_id      uuid,
  other_name    text,
  incoming      boolean,
  place_name    text,
  lat           double precision,
  lng           double precision,
  status        text,
  created_at    timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select m.id,
         case when m.from_user = auth.uid() then m.to_user else m.from_user end,
         p.display_name,
         m.to_user = auth.uid(),
         m.place_name,
         extensions.st_y(m.position::extensions.geometry),
         extensions.st_x(m.position::extensions.geometry),
         m.status,
         m.created_at
  from public.meetups m
  join public.profiles p
    on p.id = case when m.from_user = auth.uid() then m.to_user else m.from_user end
  where auth.uid() in (m.from_user, m.to_user)
    and m.status in ('pending', 'accepted')
    and m.created_at > now() - interval '12 hours'
  order by m.created_at desc;
$$;

-- ─────────────────────────────────────────────────────────────
-- Push-Tokens
-- ─────────────────────────────────────────────────────────────

create table public.device_tokens (
  token       text primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  environment text not null default 'development' check (environment in ('development', 'production')),
  updated_at  timestamptz not null default now()
);

alter table public.device_tokens enable row level security;
-- keine Policies: Zugriff über RPC bzw. Edge Function (Service Role)

create or replace function public.register_device(device_token text, env text default 'development')
returns void
language sql security definer set search_path = ''
as $$
  insert into public.device_tokens (token, user_id, environment, updated_at)
  values (device_token, auth.uid(), env, now())
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
$$;

-- ─────────────────────────────────────────────────────────────
-- Konto löschen (App-Store-Pflicht). Kaskadiert über profiles in alle Tabellen.
-- ─────────────────────────────────────────────────────────────

create or replace function public.delete_account()
returns void
language sql security definer set search_path = ''
as $$
  delete from auth.users where id = auth.uid();
$$;

-- ─────────────────────────────────────────────────────────────
-- Rechte
-- ─────────────────────────────────────────────────────────────

revoke execute on function
  public.set_active_route(text, double precision, double precision, double precision, jsonb),
  public.clear_active_route(),
  public.friends_routes(),
  public.find_meetups(double precision, double precision),
  public.propose_meetup(uuid, text, double precision, double precision),
  public.respond_meetup(uuid, boolean),
  public.cancel_meetup(uuid),
  public.my_meetups(),
  public.register_device(text, text),
  public.delete_account()
from public, anon;

grant execute on function
  public.set_active_route(text, double precision, double precision, double precision, jsonb),
  public.clear_active_route(),
  public.friends_routes(),
  public.find_meetups(double precision, double precision),
  public.propose_meetup(uuid, text, double precision, double precision),
  public.respond_meetup(uuid, boolean),
  public.cancel_meetup(uuid),
  public.my_meetups(),
  public.register_device(text, text),
  public.delete_account()
to authenticated;
