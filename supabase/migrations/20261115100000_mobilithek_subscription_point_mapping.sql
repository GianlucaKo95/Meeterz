create table if not exists public.mobilithek_subscription_points (
  subscription_id text not null,
  point_id text not null,
  site_id text,
  operator text,
  publication_type text not null,
  updated_at timestamptz not null default now(),
  primary key (subscription_id, point_id)
);

create index if not exists mobilithek_subscription_points_point_id_idx
  on public.mobilithek_subscription_points (point_id);

alter table public.mobilithek_subscription_points enable row level security;
revoke all on table public.mobilithek_subscription_points from anon, authenticated;
grant all on table public.mobilithek_subscription_points to service_role;

create table if not exists public.mobilithek_mapping_bootstrap (
  id boolean primary key default true check (id),
  completed_at timestamptz,
  completed_subscriptions text[] not null default '{}'::text[]
);

insert into public.mobilithek_mapping_bootstrap (id, completed_at)
values (true, null)
on conflict (id) do nothing;

alter table public.mobilithek_mapping_bootstrap enable row level security;
revoke all on table public.mobilithek_mapping_bootstrap from anon, authenticated;
grant all on table public.mobilithek_mapping_bootstrap to service_role;

create or replace function public.mobilithek_subscriptions_for_points(p_point_ids text[])
returns table(subscription_id text)
language sql
stable
security invoker
set search_path = ''
as $$
  select distinct m.subscription_id
  from public.mobilithek_subscription_points as m
  where m.point_id = any(coalesce(p_point_ids, '{}'::text[]))
    and m.publication_type = 'DYNAMIC_STATUS';
$$;

revoke all on function public.mobilithek_subscriptions_for_points(text[]) from public, anon, authenticated;
grant execute on function public.mobilithek_subscriptions_for_points(text[]) to service_role;
