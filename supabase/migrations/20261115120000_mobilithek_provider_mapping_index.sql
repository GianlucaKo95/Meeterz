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
      lower(split_part(regexp_replace(trim(coalesce(m.operator, '')), '[^a-z0-9äöüéèčß. ]', ' ', 'g'), ' ', 1))
        = any(coalesce(p_operator_keys, '{}'::text[]))
      or
      lower(split_part(regexp_replace(trim(coalesce(s.operator, '')), '[^a-z0-9äöüéèčß. ]', ' ', 'g'), ' ', 1))
        = any(coalesce(p_operator_keys, '{}'::text[]))
    );
$$;
revoke all on function public.mobilithek_subscriptions_for_operators(text[]) from public, anon, authenticated;
grant execute on function public.mobilithek_subscriptions_for_operators(text[]) to service_role;

drop index if exists public.mobilithek_subscription_points_point_id_idx;
create index if not exists mobilithek_subscription_points_type_site_idx
  on public.mobilithek_subscription_points (publication_type, site_id);
