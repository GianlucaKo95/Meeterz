-- Neuer Soundpack-Moment „catchup“: Freund holt unterwegs auf (gleiche Richtung) – bisher fälschlich „fährt vorbei“.

alter table public.sound_clips drop constraint if exists sound_clips_moment_check;
alter table public.sound_clips
  add constraint sound_clips_moment_check check (moment in ('pass', 'catchup', 'soon', 'arrived', 'accepted'));

create or replace function public.set_sound(p_moment text, remove boolean default false)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_moment not in ('pass', 'catchup', 'soon', 'arrived', 'accepted') then raise exception 'invalid moment'; end if;
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
