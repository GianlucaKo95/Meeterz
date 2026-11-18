-- Meeterz – Gefahren melden und gespeicherte Listen
--
-- Gefahren: Unfall, Stau, Gegenstand, Panne, Glätte – von allen Meeterz-Fahrern gemeldet, eine Stunde gültig.
-- Gelesen wird nur über hazards_in() (ohne Melder-ID, nur „von einem Freund“), nicht direkt aus der Tabelle.
-- Geschrieben wird nur über report_hazard() (höchstens eine Meldung je Minute, räumt Abgelaufenes mit auf).
--
-- Listen: eigene Ortslisten („Lieblingscafés“), optional mit Freunden geteilt (lesen; ändern nur der Besitzer).

-- ─── Gefahren ────────────────────────────────────────────────

create table if not exists public.hazards (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('accident', 'jam', 'object', 'breakdown', 'ice')),
  lat         double precision not null,
  lng         double precision not null,
  heading     double precision,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '1 hour'
);

create index if not exists hazards_expires_idx on public.hazards (expires_at);
create index if not exists hazards_pos_idx on public.hazards (lat, lng);

alter table public.hazards enable row level security;   -- keine Policies: nur über die Funktionen

create or replace function public.report_hazard(kind text, lat double precision, lng double precision, heading double precision)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from public.hazards h where h.user_id = auth.uid() and h.created_at > now() - interval '1 minute') then
    raise exception 'too many reports';
  end if;
  delete from public.hazards where expires_at < now();
  insert into public.hazards (kind, lat, lng, heading)
  values (report_hazard.kind, report_hazard.lat, report_hazard.lng, report_hazard.heading)
  returning id into new_id;
  return new_id;
end;
$$;

-- Gültige Meldungen im Rechteck (Route voraus), ohne die eigenen
create or replace function public.hazards_in(min_lat double precision, min_lng double precision,
                                             max_lat double precision, max_lng double precision)
returns table (id uuid, kind text, lat double precision, lng double precision, heading double precision,
               created_at timestamptz, by_friend boolean)
language sql stable security definer set search_path = ''
as $$
  select h.id, h.kind, h.lat, h.lng, h.heading, h.created_at, private.can_see(h.user_id)
  from public.hazards h
  where h.expires_at > now() and h.user_id <> auth.uid()
    and h.lat between min_lat and max_lat and h.lng between min_lng and max_lng
  order by h.created_at desc
  limit 200;
$$;

revoke all on function public.report_hazard(text, double precision, double precision, double precision) from public, anon;
revoke all on function public.hazards_in(double precision, double precision, double precision, double precision) from public, anon;
grant execute on function public.report_hazard(text, double precision, double precision, double precision) to authenticated;
grant execute on function public.hazards_in(double precision, double precision, double precision, double precision) to authenticated;

-- ─── Listen ──────────────────────────────────────────────────

create table if not exists public.place_lists (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 60),
  shared      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.place_list_items (
  id          uuid primary key default gen_random_uuid(),
  list_id     uuid not null references public.place_lists (id) on delete cascade,
  name        text not null check (char_length(name) <= 120),
  address     text check (char_length(address) <= 200),
  lat         double precision not null,
  lng         double precision not null,
  added_at    timestamptz not null default now()
);

create index if not exists place_lists_owner_idx on public.place_lists (owner);
create index if not exists place_list_items_list_idx on public.place_list_items (list_id);

alter table public.place_lists enable row level security;
alter table public.place_list_items enable row level security;

create policy "place_lists: eigene und geteilte lesen" on public.place_lists
  for select to authenticated
  using (owner = (select auth.uid()) or (shared and private.can_see(owner)));

create policy "place_lists: eigene ändern" on public.place_lists
  for all to authenticated
  using (owner = (select auth.uid()))
  with check (owner = (select auth.uid()));

create policy "place_list_items: lesen wie die Liste" on public.place_list_items
  for select to authenticated
  using (exists (select 1 from public.place_lists l where l.id = list_id
                 and (l.owner = (select auth.uid()) or (l.shared and private.can_see(l.owner)))));

create policy "place_list_items: in eigenen Listen ändern" on public.place_list_items
  for all to authenticated
  using (exists (select 1 from public.place_lists l where l.id = list_id and l.owner = (select auth.uid())))
  with check (exists (select 1 from public.place_lists l where l.id = list_id and l.owner = (select auth.uid())));

grant select, insert, update, delete on public.place_lists, public.place_list_items to authenticated;
