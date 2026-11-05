-- Android: Push-Tokens von Firebase Cloud Messaging neben denen von Apple.
-- platform = 'ios' (APNs) oder 'android' (FCM). Bestehende Tokens sind alle iOS.

alter table public.device_tokens
  add column if not exists platform text not null default 'ios' check (platform in ('ios', 'android'));

-- Neue Fassung mit Plattform. Die alte (2 Parameter) muss weg: PostgREST fände sonst zwei passende Funktionen.
drop function if exists public.register_device(text, text);

create or replace function public.register_device(device_token text, env text default 'development', platform text default 'ios')
returns void
language sql security definer set search_path = ''
as $$
  insert into public.device_tokens (token, user_id, environment, platform, updated_at)
  values (device_token, auth.uid(), env, platform, now())
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, platform = excluded.platform, updated_at = now();
$$;

revoke execute on function public.register_device(text, text, text) from public, anon;
grant execute on function public.register_device(text, text, text) to authenticated;
