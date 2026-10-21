-- Meeterz – Gruppen-Treffen: ein Vorschlag an mehrere Freunde.
-- Jede Einladung bleibt eine eigene Zeile (annehmen/ablehnen je Person wie bisher), verbunden über group_id.

alter table public.meetups add column if not exists group_id uuid;
create index if not exists meetups_group_id_idx on public.meetups (group_id) where group_id is not null;

-- Vorschlag an mehrere Freunde; liefert die Gruppen-ID
create or replace function public.propose_group_meetup(
  friend_ids uuid[], place_name text, lat double precision, lng double precision
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  gid uuid := gen_random_uuid();
  fid uuid;
begin
  if friend_ids is null or array_length(friend_ids, 1) is null then
    raise exception 'Mindestens ein Freund nötig';
  end if;
  if array_length(friend_ids, 1) > 10 then
    raise exception 'Höchstens 10 Freunde';
  end if;
  foreach fid in array friend_ids loop
    if not private.are_friends(auth.uid(), fid) then
      raise exception 'Nur unter Freunden möglich';
    end if;
  end loop;

  insert into public.meetups (from_user, to_user, place_name, position, group_id)
  select auth.uid(), f, place_name,
         extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography,
         gid
  from (select distinct unnest(friend_ids) as f) t
  where f <> auth.uid();
  return gid;
end;
$$;

-- Wer gehört zur Gruppe und wie hat jeder geantwortet? Nur für Beteiligte.
create or replace function public.group_members(gid uuid)
returns table (user_id uuid, display_name text, status text, organizer boolean)
language sql stable security definer set search_path = ''
as $$
  with g as (
    select * from public.meetups m
    where m.group_id = gid
      and exists (select 1 from public.meetups x
                  where x.group_id = gid and auth.uid() in (x.from_user, x.to_user))
  )
  select distinct on (u.id) u.id, u.display_name,
         case when u.id = (select from_user from g limit 1) then 'organizer' else g.status end,
         u.id = (select from_user from g limit 1)
  from g
  join public.profiles u on u.id in (g.from_user, g.to_user)
  order by u.id, g.created_at desc;
$$;

-- my_meetups: zusätzlich group_id und Gruppengröße (alle Beteiligten inkl. Einladendem)
drop function if exists public.my_meetups();
create function public.my_meetups()
returns table (
  id            uuid,
  other_id      uuid,
  other_name    text,
  incoming      boolean,
  place_name    text,
  lat           double precision,
  lng           double precision,
  status        text,
  created_at    timestamptz,
  group_id      uuid,
  group_size    integer
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
         m.created_at,
         m.group_id,
         case when m.group_id is null then 2
              else (select count(*)::int + 1 from public.meetups g
                    where g.group_id = m.group_id and g.status in ('pending', 'accepted')) end
  from public.meetups m
  join public.profiles p
    on p.id = case when m.from_user = auth.uid() then m.to_user else m.from_user end
  where auth.uid() in (m.from_user, m.to_user)
    and m.status in ('pending', 'accepted')
    and m.created_at > now() - interval '12 hours'
  order by m.created_at desc;
$$;

revoke execute on function
  public.propose_group_meetup(uuid[], text, double precision, double precision),
  public.group_members(uuid),
  public.my_meetups()
from public, anon;

grant execute on function
  public.propose_group_meetup(uuid[], text, double precision, double precision),
  public.group_members(uuid),
  public.my_meetups()
to authenticated;
