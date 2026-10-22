-- Meeterz – Testkonten der UI-Tests wiederverwenden statt bei jedem Lauf neu anlegen.
--
-- Feste Testkonten heißen ci-fix-<rolle>@example.com. Zu Beginn eines Laufs setzt der Test sie mit
-- reset_test_account() zurück: Das Profil wird gelöscht, damit verschwinden per Kaskade Freundschaften,
-- Standort, Routen, Treffen, Nachrichten usw. Das Anmeldekonto selbst bleibt bestehen.

create or replace function public.reset_test_account()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from auth.users where id = auth.uid() and email like 'ci-%@example.com') then
    raise exception 'Nur für Testkonten';
  end if;
  delete from public.profiles where id = auth.uid();
end;
$$;

revoke execute on function public.reset_test_account() from public, anon;
grant execute on function public.reset_test_account() to authenticated;

-- Einmalig: Reste früherer Testläufe entfernen (jede Ausführung hatte eigene Konten angelegt)
delete from auth.users where email like 'ci-%@example.com' and email not like 'ci-fix-%';

-- Sicherheitsnetz: stündlich übrig gebliebene Wegwerf-Testkonten (abgebrochene Läufe) löschen,
-- feste Testkonten nur, wenn sie zwei Wochen lang nicht benutzt wurden.
create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'meeterz-ci-cleanup',
  '17 * * * *',
  $job$
    delete from auth.users
    where email like 'ci-%@example.com'
      and (
        (email not like 'ci-fix-%' and created_at < now() - interval '2 hours')
        or (email like 'ci-fix-%' and coalesce(last_sign_in_at, created_at) < now() - interval '14 days')
      );
  $job$
);
