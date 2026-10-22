-- Meeterz – Kurznachrichten unter Freunden: Schnellantworten (auch aus CarPlay) und
-- automatische Verspätungsmeldung zu einem Treffen. Kein Chat-Verlauf: nur die letzten 12 Stunden.

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  from_user  uuid not null references public.profiles (id) on delete cascade,
  to_user    uuid not null references public.profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 140),
  meetup_id  uuid references public.meetups (id) on delete set null,
  automatic  boolean not null default false,
  created_at timestamptz not null default now(),
  check (from_user <> to_user)
);

create index if not exists messages_to_user_idx on public.messages (to_user, created_at desc);

alter table public.messages enable row level security;

create policy "messages: eigene lesen" on public.messages
  for select to authenticated
  using ((select auth.uid()) in (from_user, to_user));

alter publication supabase_realtime add table public.messages;

create or replace function public.send_message(
  to_user_id uuid, body text, meetup_id uuid default null, automatic boolean default false
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
  -- Schutz vor Endlosschleifen/Spam: höchstens 10 Nachrichten pro Minute
  if (select count(*) from public.messages
      where from_user = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'Zu viele Nachrichten – kurz warten';
  end if;
  insert into public.messages (from_user, to_user, body, meetup_id, automatic)
  values (auth.uid(), to_user_id, left(body, 140), meetup_id, automatic)
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.my_messages()
returns table (
  id uuid, other_id uuid, other_name text, incoming boolean, body text,
  meetup_id uuid, automatic boolean, created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select m.id,
         case when m.from_user = auth.uid() then m.to_user else m.from_user end,
         p.display_name,
         m.to_user = auth.uid(),
         m.body, m.meetup_id, m.automatic, m.created_at
  from public.messages m
  join public.profiles p
    on p.id = case when m.from_user = auth.uid() then m.to_user else m.from_user end
  where auth.uid() in (m.from_user, m.to_user)
    and m.created_at > now() - interval '12 hours'
  order by m.created_at desc
  limit 100;
$$;

revoke execute on function public.send_message(uuid, text, uuid, boolean), public.my_messages() from public, anon;
grant execute on function public.send_message(uuid, text, uuid, boolean), public.my_messages() to authenticated;
