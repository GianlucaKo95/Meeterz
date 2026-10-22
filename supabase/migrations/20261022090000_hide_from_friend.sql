-- Meeterz – Teilen pro Freund: Standort und Routen einzelnen Freunden verbergen.
-- Alle Sichtbarkeitsprüfungen (Live-Kanal, letzte Position, Routen, Treffpunkt-Vorschläge) laufen über
-- private.is_sharing(owner) mit auth.uid() als Betrachter – dort genügt eine zusätzliche Bedingung.

create table if not exists public.hidden_from (
  owner      uuid not null references public.profiles (id) on delete cascade,
  viewer     uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner, viewer),
  check (owner <> viewer)
);

alter table public.hidden_from enable row level security;

-- Nur die eigene Liste lesen; ändern ausschließlich über set_hidden_from
create policy "hidden_from: eigene lesen" on public.hidden_from
  for select to authenticated
  using ((select auth.uid()) = owner);

create or replace function private.is_sharing(uid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = uid and p.sharing_enabled
      and (p.sharing_until is null or p.sharing_until > now())
      and (p.incognito_until is null or p.incognito_until <= now())
  )
  and not exists (
    select 1 from public.hidden_from h
    where h.owner = uid and h.viewer = auth.uid()
  );
$$;

create or replace function public.set_hidden_from(friend_id uuid, hidden boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if hidden then
    if not private.are_friends(auth.uid(), friend_id) then
      raise exception 'Nur unter Freunden möglich';
    end if;
    insert into public.hidden_from (owner, viewer) values (auth.uid(), friend_id)
    on conflict do nothing;
  else
    delete from public.hidden_from where owner = auth.uid() and viewer = friend_id;
  end if;
end;
$$;

create or replace function public.my_hidden_friends()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select viewer from public.hidden_from where owner = auth.uid();
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

revoke execute on function public.set_hidden_from(uuid, boolean), public.my_hidden_friends() from public, anon;
grant execute on function public.set_hidden_from(uuid, boolean), public.my_hidden_friends() to authenticated;
