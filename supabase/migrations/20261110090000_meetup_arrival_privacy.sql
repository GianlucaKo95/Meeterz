-- 1) Treffen auflösen, sobald alle, die zugesagt haben, angekommen sind.
--    Jede App meldet ihre eigene Ankunft (< 100 m vom Treffpunkt); ist der Letzte da, wird das Treffen „completed“
--    und erscheint nicht mehr (my_meetups liefert nur pending/accepted).
-- 2) Gruppen-Treffen: Eingeladene sehen vom Rest der Gruppe nur, wer zugesagt hat – nicht, wer sonst noch
--    eingeladen wurde (offen oder abgesagt). Der Einladende sieht weiter alle.

alter table public.meetups drop constraint if exists meetups_status_check;
alter table public.meetups add constraint meetups_status_check
  check (status in ('pending', 'accepted', 'declined', 'cancelled', 'completed'));

create table if not exists public.meetup_arrivals (
  meeting    uuid not null,          -- group_id bei Gruppen, sonst die Treffen-ID
  user_id    uuid not null references public.profiles (id) on delete cascade,
  arrived_at timestamptz not null default now(),
  primary key (meeting, user_id)
);
alter table public.meetup_arrivals enable row level security;
-- keine Policies: Zugriff nur über arrive_at_meetup()

create or replace function public.arrive_at_meetup(p_meetup uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  m public.meetups;
  meeting_key uuid;
begin
  select * into m from public.meetups
  where id = p_meetup and auth.uid() in (from_user, to_user) and status = 'accepted';
  if not found then return false; end if;
  meeting_key := coalesce(m.group_id, m.id);

  insert into public.meetup_arrivals (meeting, user_id) values (meeting_key, auth.uid())
  on conflict do nothing;

  -- Alle mit Zusage (Einladender + angenommene Eingeladene) angekommen?
  if exists (
    select 1 from (
      select x.from_user as u from public.meetups x where coalesce(x.group_id, x.id) = meeting_key and x.status = 'accepted'
      union
      select x.to_user from public.meetups x where coalesce(x.group_id, x.id) = meeting_key and x.status = 'accepted'
    ) p
    where not exists (select 1 from public.meetup_arrivals a where a.meeting = meeting_key and a.user_id = p.u)
  ) then
    return false;
  end if;

  -- Offene Einladungen dieser Gruppe sind damit ebenfalls erledigt
  update public.meetups set status = 'completed', responded_at = coalesce(responded_at, now())
  where coalesce(group_id, id) = meeting_key and status in ('pending', 'accepted');
  return true;
end;
$$;

revoke execute on function public.arrive_at_meetup(uuid) from public, anon;
grant execute on function public.arrive_at_meetup(uuid) to authenticated;

-- Mitglieder: Einladender sieht alle, Eingeladene nur Einladenden, sich selbst und wer zugesagt hat
create or replace function public.group_members(gid uuid)
returns table (user_id uuid, display_name text, status text, organizer boolean)
language sql stable security definer set search_path = ''
as $$
  with g as (
    select * from public.meetups m
    where m.group_id = gid
      and exists (select 1 from public.meetups x
                  where x.group_id = gid and auth.uid() in (x.from_user, x.to_user))
  ),
  host as (select from_user as id from g limit 1)
  select distinct on (u.id) u.id, u.display_name,
         case when u.id = (select id from host) then 'organizer' else g.status end,
         u.id = (select id from host)
  from g
  join public.profiles u on u.id in (g.from_user, g.to_user)
  where auth.uid() = (select id from host)          -- Einladender: alle
     or u.id in ((select id from host), auth.uid())  -- Eingeladene: Einladender und sie selbst …
     or (u.id = g.to_user and g.status = 'accepted') -- … und wer zugesagt hat
  order by u.id, g.created_at desc;
$$;

-- Gruppengröße ebenso: für Eingeladene nur Einladender + sie selbst + andere mit Zusage
create or replace function public.my_meetups()
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
              when m.from_user = auth.uid() then
                (select count(*)::int + 1 from public.meetups g
                  where g.group_id = m.group_id and g.status in ('pending', 'accepted'))
              else
                (select count(*)::int + 2 from public.meetups g
                  where g.group_id = m.group_id and g.status = 'accepted' and g.to_user <> auth.uid()) end,
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
