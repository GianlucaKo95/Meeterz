-- Konvoi-Feed: Einfügen schlug immer fehl mit „infinite recursion detected in policy for relation convoy_events“
-- (Diagnose 20.11.). Ursache: Die Einfüge-Regel zählte für die Drossel (30/Minute) Zeilen derselben Tabelle – dabei
-- greifen wieder deren Regeln. Die Zählung läuft jetzt in einer Funktion mit Eigentümerrechten (ohne Zeilenregeln).

create or replace function private.convoy_events_last_minute(uid uuid)
returns bigint
language sql stable security definer set search_path = ''
as $$
  select count(*) from public.convoy_events e
  where e.user_id = uid and e.created_at > now() - interval '1 minute';
$$;

revoke execute on function private.convoy_events_last_minute(uuid) from public, anon;
grant execute on function private.convoy_events_last_minute(uuid) to authenticated;

drop policy if exists "convoy_events: eigene an Freunde anlegen" on public.convoy_events;

create policy "convoy_events: eigene an Freunde anlegen" on public.convoy_events
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and not exists (select 1 from unnest(members) m where m <> (select auth.uid()) and not private.are_friends((select auth.uid()), m))
    and private.convoy_events_last_minute((select auth.uid())) < 30
  );
