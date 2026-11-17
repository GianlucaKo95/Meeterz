-- Meeterz – Stories und Konvoi-Feed
--
-- Stories: Foto oder kurzes Video am Ort, 24 Stunden für angenommene Freunde sichtbar (nicht für Freunde,
-- vor denen man seinen Standort verbirgt – die Story verrät den Ort). Dateien im privaten Bucket „stories“,
-- Pfad "<user_id>/<story_id>.jpg|mp4".
--
-- Konvoi-Feed: Ereignisse einer gemeinsamen Fahrt (mitfahren, Pause, Ladestopp, Nachricht, Story, Ankunft).
-- convoy_key fasst eine Fahrt zusammen (Treffen-ID oder gerundetes Ziel + Tag), members = wer den Eintrag sieht.
-- Bleibt gespeichert (Fahrt-Chronik).

-- ─── Sichtbarkeit ────────────────────────────────────────────

-- Darf der Aufrufer Inhalte von owner sehen? Freunde und nicht verborgen
create or replace function private.can_see(owner uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select owner = auth.uid()
    or (private.are_friends(auth.uid(), owner)
        and not exists (select 1 from public.hidden_from h where h.owner = can_see.owner and h.viewer = auth.uid()));
$$;

-- ─── Stories ─────────────────────────────────────────────────

create table if not exists public.stories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('photo', 'video')),
  media_path  text not null,
  lat         double precision,
  lng         double precision,
  place_name  text check (char_length(place_name) <= 120),
  caption     text check (char_length(caption) <= 140),
  convoy_key  text check (char_length(convoy_key) <= 80),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '24 hours'
);

create index if not exists stories_user_idx on public.stories (user_id, created_at desc);
create index if not exists stories_expires_idx on public.stories (expires_at);

alter table public.stories enable row level security;

create policy "stories: eigene und Freunde lesen" on public.stories
  for select to authenticated
  using (user_id = (select auth.uid()) or (expires_at > now() and private.can_see(user_id)));

create policy "stories: eigene anlegen" on public.stories
  for insert to authenticated
  with check (user_id = (select auth.uid()) and media_path like (select auth.uid())::text || '/%'
              and expires_at <= now() + interval '25 hours');

create policy "stories: eigene löschen" on public.stories
  for delete to authenticated
  using (user_id = (select auth.uid()));

grant select, insert, delete on public.stories to authenticated;

-- Gesehen (für den Ring: nur ungesehene Stories leuchten)
create table if not exists public.story_views (
  story_id   uuid not null references public.stories (id) on delete cascade,
  viewer     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  seen_at    timestamptz not null default now(),
  primary key (story_id, viewer)
);

alter table public.story_views enable row level security;

create policy "story_views: eigene und zu eigenen Stories lesen" on public.story_views
  for select to authenticated
  using (viewer = (select auth.uid())
         or exists (select 1 from public.stories s where s.id = story_id and s.user_id = (select auth.uid())));

create policy "story_views: eigene anlegen" on public.story_views
  for insert to authenticated
  with check (viewer = (select auth.uid())
              and exists (select 1 from public.stories s where s.id = story_id));

grant select, insert on public.story_views to authenticated;

-- Aktuelle Stories der Freunde (und eigene) mit Name und „gesehen“
create or replace function public.friend_stories()
returns table (
  id uuid, user_id uuid, display_name text, kind text, media_path text, lat double precision, lng double precision,
  place_name text, caption text, convoy_key text, created_at timestamptz, expires_at timestamptz, seen boolean
)
language sql stable security definer set search_path = ''
as $$
  select s.id, s.user_id, p.display_name, s.kind, s.media_path, s.lat, s.lng, s.place_name, s.caption, s.convoy_key,
         s.created_at, s.expires_at,
         exists (select 1 from public.story_views v where v.story_id = s.id and v.viewer = auth.uid())
  from public.stories s
  join public.profiles p on p.id = s.user_id
  where s.expires_at > now() and private.can_see(s.user_id)
  order by s.created_at;
$$;

revoke execute on function public.friend_stories() from public, anon;
grant execute on function public.friend_stories() to authenticated;

-- Speicher
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('stories', 'stories', false, 26214400, array['image/jpeg', 'video/mp4'])
on conflict (id) do update
  set public = false, file_size_limit = 26214400, allowed_mime_types = array['image/jpeg', 'video/mp4'];

create policy "stories: Dateien eigene und Freunde lesen" on storage.objects
  for select to authenticated
  using (bucket_id = 'stories' and private.can_see(((storage.foldername(name))[1])::uuid));

create policy "stories: Dateien eigene anlegen" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'stories' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "stories: Dateien eigene löschen" on storage.objects
  for delete to authenticated
  using (bucket_id = 'stories' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ─── Konvoi-Feed ─────────────────────────────────────────────

create table if not exists public.convoy_events (
  id          uuid primary key default gen_random_uuid(),
  convoy_key  text not null check (char_length(convoy_key) <= 80),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  members     uuid[] not null check (cardinality(members) <= 20),
  kind        text not null check (kind in ('joined', 'pause', 'charge', 'message', 'story', 'arrived')),
  text        text check (char_length(text) <= 200),
  dest_name   text check (char_length(dest_name) <= 120),
  story_id    uuid references public.stories (id) on delete set null,
  lat         double precision,
  lng         double precision,
  created_at  timestamptz not null default now()
);

create index if not exists convoy_events_key_idx on public.convoy_events (convoy_key, created_at);
create index if not exists convoy_events_members_idx on public.convoy_events using gin (members);

alter table public.convoy_events enable row level security;

create policy "convoy_events: eigene und als Mitfahrer lesen" on public.convoy_events
  for select to authenticated
  using (user_id = (select auth.uid()) or (select auth.uid()) = any (members));

-- Nur an Freunde schicken, höchstens 30 Einträge pro Minute (Schutz vor Schleifen)
create policy "convoy_events: eigene an Freunde anlegen" on public.convoy_events
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and not exists (select 1 from unnest(members) m where m <> (select auth.uid()) and not private.are_friends((select auth.uid()), m))
    and (select count(*) from public.convoy_events e
         where e.user_id = (select auth.uid()) and e.created_at > now() - interval '1 minute') < 30
  );

grant select, insert on public.convoy_events to authenticated;

-- Fahrten (Chronik): je convoy_key Ziel, Zeitraum, Teilnehmer und Zahl der Einträge
create or replace function public.my_convoys(max_count integer default 30)
returns table (convoy_key text, dest_name text, started_at timestamptz, last_at timestamptz,
               members uuid[], entries bigint)
language sql stable security invoker set search_path = ''
as $$
  select e.convoy_key,
         (array_agg(e.dest_name order by e.created_at) filter (where e.dest_name is not null))[1],
         min(e.created_at), max(e.created_at),
         array(select distinct u from public.convoy_events x, unnest(x.members || x.user_id) u where x.convoy_key = e.convoy_key),
         count(*)
  from public.convoy_events e
  group by e.convoy_key
  order by max(e.created_at) desc
  limit least(max_count, 100);
$$;

revoke execute on function public.my_convoys(integer) from public, anon;
grant execute on function public.my_convoys(integer) to authenticated;

alter publication supabase_realtime add table public.stories;
alter publication supabase_realtime add table public.convoy_events;
