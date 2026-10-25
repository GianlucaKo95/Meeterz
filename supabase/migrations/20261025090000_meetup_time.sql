-- Treffen mit Uhrzeit (optional): Grundlage für die „Losfahren“-Erinnerung.
-- Ohne Uhrzeit bleibt alles wie bisher (Treffen „jetzt“, nach 12 Stunden weg).

alter table public.meetups add column if not exists meet_at timestamptz;

-- propose_meetup: optionaler Zeitpunkt. Alte App-Versionen rufen ohne meet_at auf – der Standardwert deckt das ab.
drop function if exists public.propose_meetup(uuid, text, double precision, double precision);

create or replace function public.propose_meetup(
  to_user_id uuid, place_name text, lat double precision, lng double precision, meet_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  if not private.are_friends(auth.uid(), to_user_id) then
    raise exception 'Nur unter Freunden möglich';
  end if;
  if meet_at is not null and (meet_at < now() - interval '5 minutes' or meet_at > now() + interval '14 days') then
    raise exception 'Zeitpunkt muss in den nächsten 14 Tagen liegen';
  end if;
  -- ältere offene Vorschläge an dieselbe Person ersetzen
  update public.meetups set status = 'cancelled', responded_at = now()
  where from_user = auth.uid() and to_user = to_user_id and status = 'pending';

  insert into public.meetups (from_user, to_user, place_name, position, meet_at)
  values (auth.uid(), to_user_id, place_name,
          extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography,
          meet_at)
  returning id into new_id;
  return new_id;
end;
$$;

-- my_meetups: liefert meet_at mit; Treffen mit Uhrzeit bleiben bis 2 Stunden nach dem Zeitpunkt sichtbar
drop function if exists public.my_meetups();

create function public.my_meetups()
returns table(id uuid, other_id uuid, other_name text, incoming boolean, place_name text,
              lat double precision, lng double precision, status text, created_at timestamptz,
              group_id uuid, group_size integer, meet_at timestamptz)
language sql
stable
security definer
set search_path = ''
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
                    where g.group_id = m.group_id and g.status in ('pending', 'accepted')) end,
         m.meet_at
  from public.meetups m
  join public.profiles p
    on p.id = case when m.from_user = auth.uid() then m.to_user else m.from_user end
  where auth.uid() in (m.from_user, m.to_user)
    and m.status in ('pending', 'accepted')
    and (case when m.meet_at is null then m.created_at > now() - interval '12 hours'
              else m.meet_at > now() - interval '2 hours' end)
  order by coalesce(m.meet_at, m.created_at) desc;
$$;

revoke execute on function
  public.propose_meetup(uuid, text, double precision, double precision, timestamptz),
  public.my_meetups()
from public, anon;

grant execute on function
  public.propose_meetup(uuid, text, double precision, double precision, timestamptz),
  public.my_meetups()
to authenticated;
