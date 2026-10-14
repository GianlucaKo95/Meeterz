-- Meeterz Phase 3: Profilbilder
-- Privater Storage-Bucket "avatars", Pfad "<user_id>/avatar.jpg".
-- Lesen dürfen nur der Besitzer und angenommene Freunde, schreiben nur der Besitzer.

alter table public.profiles add column if not exists avatar_version integer not null default 0;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 262144, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = 262144, allowed_mime_types = array['image/jpeg'];

create policy "avatars: eigene und Freunde lesen" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or private.are_friends((select auth.uid()), ((storage.foldername(name))[1])::uuid)
    )
  );

create policy "avatars: eigene anlegen" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: eigene ändern" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: eigene löschen" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Version hochzählen (Freunde laden das Bild neu, wenn sich die Zahl ändert); 0 = kein Bild
create or replace function public.set_avatar_version(remove boolean default false)
returns integer
language sql security definer set search_path = ''
as $$
  update public.profiles
  set avatar_version = case when remove then 0 else avatar_version + 1 end
  where id = auth.uid()
  returning avatar_version;
$$;

revoke execute on function public.set_avatar_version(boolean) from public, anon;
grant execute on function public.set_avatar_version(boolean) to authenticated;

-- my_friends() liefert zusätzlich die Bildversion des Freundes
drop function if exists public.my_friends();

create function public.my_friends()
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
  location_updated_at  timestamptz,
  avatar_version       integer
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
    case when vis.ok then l.updated_at end,
    -- Bild nur für angenommene Freunde
    case when f.status = 'accepted' then p.avatar_version else 0 end
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  cross join lateral (select f.status = 'accepted' and private.is_sharing(p.id) as ok) vis
  left join public.last_locations l on l.user_id = p.id
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.display_name;
$$;

revoke execute on function public.my_friends() from public, anon;
grant execute on function public.my_friends() to authenticated;
