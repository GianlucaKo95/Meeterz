-- Meeterz Phase 4: Sound-Pack
-- Kurze Sprachschnipsel (max. 5 s) je Moment. Privater Bucket "sounds", Pfad "<user_id>/<moment>.m4a".
-- Lesen dürfen nur der Besitzer und angenommene Freunde, schreiben nur der Besitzer.

create table if not exists public.sound_clips (
  user_id  uuid not null references public.profiles (id) on delete cascade,
  moment   text not null check (moment in ('pass', 'soon', 'arrived', 'accepted')),
  version  integer not null default 1,
  primary key (user_id, moment)
);

alter table public.sound_clips enable row level security;
-- keine direkten Policies: Zugriff nur über die RPCs unten

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sounds', 'sounds', false, 262144, array['audio/mp4', 'audio/x-m4a', 'audio/m4a', 'audio/aac'])
on conflict (id) do update
  set public = false, file_size_limit = 262144,
      allowed_mime_types = array['audio/mp4', 'audio/x-m4a', 'audio/m4a', 'audio/aac'];

create policy "sounds: eigene und Freunde lesen" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'sounds'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or private.are_friends((select auth.uid()), ((storage.foldername(name))[1])::uuid)
    )
  );

create policy "sounds: eigene anlegen" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'sounds' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "sounds: eigene ändern" on storage.objects
  for update to authenticated
  using (bucket_id = 'sounds' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'sounds' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "sounds: eigene löschen" on storage.objects
  for delete to authenticated
  using (bucket_id = 'sounds' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Eigenes Schnipsel anlegen/erneuern (Version hochzählen) oder entfernen
create or replace function public.set_sound(p_moment text, remove boolean default false)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_moment not in ('pass', 'soon', 'arrived', 'accepted') then raise exception 'invalid moment'; end if;
  if remove then
    delete from public.sound_clips where user_id = auth.uid() and moment = p_moment;
    return 0;
  end if;
  insert into public.sound_clips (user_id, moment) values (auth.uid(), p_moment)
  on conflict (user_id, moment) do update set version = public.sound_clips.version + 1
  returning version into v;
  return v;
end;
$$;

revoke execute on function public.set_sound(text, boolean) from public, anon;
grant execute on function public.set_sound(text, boolean) to authenticated;

-- Schnipsel von mir und angenommenen Freunden
create or replace function public.friend_sounds()
returns table (user_id uuid, moment text, version integer)
language sql stable security definer set search_path = ''
as $$
  select s.user_id, s.moment, s.version
  from public.sound_clips s
  where s.user_id = auth.uid()
     or private.are_friends(auth.uid(), s.user_id);
$$;

revoke execute on function public.friend_sounds() from public, anon;
grant execute on function public.friend_sounds() to authenticated;
