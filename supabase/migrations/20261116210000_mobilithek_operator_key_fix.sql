-- Betreiber-Schlüssel wie ChargeNetworks.key in den Apps: erst klein schreiben, dann säubern, erstes Wort
-- (zwei Wörter, wenn das erste höchstens 2 Zeichen hat – außer bp/ok).
-- Vorher wurde vor lower() gesäubert: Großbuchstaben wurden zu Leerzeichen, „EnBW …“ ergab einen leeren Schlüssel,
-- und die gezielten Pulls fanden für fast keinen Betreiber eine Subscription.
create or replace function public.charge_network_key(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  with w as (
    select array_remove(regexp_split_to_array(
      regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9äöüéèčß. ]', ' ', 'g'), '\s+'), '') as a
  )
  select case
    when coalesce(cardinality(a), 0) = 0 then ''
    when length(a[1]) <= 2 and a[1] not in ('bp', 'ok') and cardinality(a) > 1 then a[1] || ' ' || a[2]
    else a[1]
  end
  from w;
$$;

create or replace function public.mobilithek_subscriptions_for_operators(p_operator_keys text[])
returns table(subscription_id text)
language sql
stable
security invoker
set search_path = ''
as $$
  select distinct m.subscription_id
  from public.mobilithek_subscription_points as m
  left join public.charge_site_static as s on s.site_id = m.site_id
  where m.publication_type = 'DYNAMIC_STATUS'
    and (
      public.charge_network_key(m.operator) = any(coalesce(p_operator_keys, '{}'::text[]))
      or public.charge_network_key(s.operator) = any(coalesce(p_operator_keys, '{}'::text[]))
    );
$$;

revoke all on function public.mobilithek_subscriptions_for_operators(text[]) from public, anon, authenticated;
grant execute on function public.mobilithek_subscriptions_for_operators(text[]) to service_role;
