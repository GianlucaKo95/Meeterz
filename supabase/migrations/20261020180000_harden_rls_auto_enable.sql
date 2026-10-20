-- Meeterz – Sicherheits-Hinweis des Supabase-Advisors: rls_auto_enable() ist eine SECURITY-DEFINER-Funktion
-- (Event-Trigger, schaltet RLS für neue Tabellen automatisch ein) und darf nicht über die API aufrufbar sein.
-- Der Event-Trigger läuft weiter; nur der direkte Aufruf durch anon/authenticated wird gesperrt.
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'rls_auto_enable'
  ) then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;
