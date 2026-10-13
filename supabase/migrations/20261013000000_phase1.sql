-- Meeterz – Phase 1: Profile, Freunde, Live-Standorte
-- Ausführen im Supabase SQL Editor oder via `supabase db push`.

create extension if not exists postgis with schema extensions;

-- ─────────────────────────────────────────────────────────────
-- Tabellen
-- ─────────────────────────────────────────────────────────────

create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  handle           text not null unique check (handle ~ '^[a-z0-9_]{3,20}$'),
  display_name     text not null check (char_length(display_name) between 1 and 40),
  sharing_enabled  boolean not null default true,
  created_at       timestamptz not null default now()
);

create table public.friendships (
  id          uuid primary key default gen_random_uuid(),
  requester   uuid not null references public.profiles (id) on delete cascade,
  addressee   uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at  timestamptz not null default now(),
  check (requester <> addressee)
);

-- Pro Paar nur eine Beziehung, egal in welche Richtung
create unique index friendships_pair_uniq
  on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table public.last_locations (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  position    extensions.geography(Point, 4326) not null,
  heading     double precision,
  speed       double precision,
  updated_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────
-- Row Level Security
-- Schreibzugriffe auf friendships/last_locations laufen nur über RPCs.
-- ─────────────────────────────────────────────────────────────

alter table public.profiles       enable row level security;
alter table public.friendships    enable row level security;
alter table public.last_locations enable row level security;

create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a))
  );
$$;

create policy "profiles: eigenes lesen" on public.profiles
  for select to authenticated using (id = (select auth.uid()));

create policy "profiles: eigenes anlegen" on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));

create policy "profiles: eigenes ändern" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "friendships: eigene lesen" on public.friendships
  for select to authenticated
  using ((select auth.uid()) in (requester, addressee));

-- last_locations: keine Policies → nur über RPCs erreichbar

-- ─────────────────────────────────────────────────────────────
-- RPCs
-- ─────────────────────────────────────────────────────────────

-- Freundschaftsanfrage per Handle. Gibt es bereits eine Gegenanfrage, wird sie angenommen.
create or replace function public.send_friend_request(target_handle text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me     uuid := auth.uid();
  target uuid;
  existing public.friendships%rowtype;
begin
  select id into target from public.profiles where handle = lower(trim(target_handle));
  if target is null then
    raise exception 'Nutzer nicht gefunden' using errcode = 'P0002';
  end if;
  if target = me then
    raise exception 'Du kannst dich nicht selbst hinzufügen';
  end if;

  select * into existing from public.friendships
  where least(requester, addressee) = least(me, target)
    and greatest(requester, addressee) = greatest(me, target);

  if existing.id is null then
    insert into public.friendships (requester, addressee) values (me, target);
  elsif existing.status = 'pending' and existing.addressee = me then
    update public.friendships set status = 'accepted' where id = existing.id;
  end if;
end;
$$;

create or replace function public.respond_friend_request(request_id uuid, accept boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if accept then
    update public.friendships set status = 'accepted'
    where id = request_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships
    where id = request_id and addressee = auth.uid() and status = 'pending';
  end if;
end;
$$;

-- Entfernt Freund oder zieht eigene Anfrage zurück
create or replace function public.remove_friend(friend_id uuid)
returns void
language sql security definer set search_path = ''
as $$
  delete from public.friendships
  where (requester = auth.uid() and addressee = friend_id)
     or (requester = friend_id and addressee = auth.uid());
$$;

-- Alle Beziehungen inkl. letzter bekannter Position (nur bei angenommener Freundschaft + aktivem Teilen)
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
    f.id,
    p.id,
    p.handle,
    p.display_name,
    f.status,
    f.addressee = auth.uid(),
    case when f.status = 'accepted' and p.sharing_enabled then extensions.st_y(l.position::extensions.geometry) end,
    case when f.status = 'accepted' and p.sharing_enabled then extensions.st_x(l.position::extensions.geometry) end,
    case when f.status = 'accepted' and p.sharing_enabled then l.heading end,
    case when f.status = 'accepted' and p.sharing_enabled then l.speed end,
    case when f.status = 'accepted' and p.sharing_enabled then l.updated_at end
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  left join public.last_locations l on l.user_id = p.id
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.display_name;
$$;

create or replace function public.update_last_location(
  lat double precision, lng double precision,
  heading double precision default null, speed double precision default null
)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.last_locations (user_id, position, heading, speed, updated_at)
  values (
    auth.uid(),
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography,
    heading, speed, now()
  )
  on conflict (user_id) do update
    set position = excluded.position,
        heading = excluded.heading,
        speed = excluded.speed,
        updated_at = excluded.updated_at;
$$;

revoke execute on function
  public.are_friends(uuid, uuid),
  public.send_friend_request(text),
  public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid),
  public.my_friends(),
  public.update_last_location(double precision, double precision, double precision, double precision)
from public, anon;

grant execute on function
  public.are_friends(uuid, uuid),
  public.send_friend_request(text),
  public.respond_friend_request(uuid, boolean),
  public.remove_friend(uuid),
  public.my_friends(),
  public.update_last_location(double precision, double precision, double precision, double precision)
to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Realtime: private Broadcast-Kanäle "loc:<user_id>"
-- Senden nur in den eigenen Kanal, Empfangen nur von Freunden, die teilen.
-- ─────────────────────────────────────────────────────────────

create or replace function public.can_receive_location(topic text)
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
  return public.are_friends(auth.uid(), owner)
     and exists (select 1 from public.profiles where id = owner and sharing_enabled);
end;
$$;

grant execute on function public.can_receive_location(text) to authenticated;

create policy "loc: Freunde empfangen" on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and public.can_receive_location((select realtime.topic()))
  );

create policy "loc: nur in eigenen Kanal senden" on realtime.messages
  for insert to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'loc:' || (select auth.uid())::text
  );
