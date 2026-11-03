-- set_active_route: Eingaben begrenzen (angemeldet, max. 10 000 Punkte ≈ 3000 km bei 300 m Abstand, gültige Koordinaten)
create or replace function public.set_active_route(destination_name text, dest_lat double precision, dest_lng double precision,
                                                  eta_unix double precision, points jsonb, travel_mode text default 'car'::text)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  me uuid := auth.uid();
  mode text := case when travel_mode in ('car', 'bike', 'walk') then travel_mode else 'car' end;
begin
  if me is null then
    raise exception 'nicht angemeldet';
  end if;
  if jsonb_typeof(points) <> 'array' or jsonb_array_length(points) < 2 then
    raise exception 'Route braucht mindestens zwei Punkte';
  end if;
  if jsonb_array_length(points) > 10000 then
    raise exception 'Route zu lang';
  end if;
  if char_length(coalesce(destination_name, '')) > 200
     or dest_lat not between -90 and 90 or dest_lng not between -180 and 180 then
    raise exception 'ungültiges Ziel';
  end if;
  if exists (select 1 from jsonb_array_elements(points) p
             where jsonb_typeof(p) <> 'array'
                or (p->>0)::float8 not between -180 and 180
                or (p->>1)::float8 not between -90 and 90) then
    raise exception 'ungültiger Routenpunkt';
  end if;

  insert into public.active_routes (user_id, destination_name, destination, path, eta, updated_at, travel_mode)
  values (
    me,
    destination_name,
    extensions.st_setsrid(extensions.st_makepoint(dest_lng, dest_lat), 4326)::extensions.geography,
    (select extensions.st_setsrid(
              extensions.st_makeline(array_agg(
                extensions.st_makepoint((p->>0)::float8, (p->>1)::float8) order by i)), 4326)::extensions.geography
       from jsonb_array_elements(points) with ordinality as t(p, i)),
    to_timestamp(eta_unix),
    now(),
    mode
  )
  on conflict (user_id) do update
    set destination_name = excluded.destination_name,
        destination = excluded.destination,
        path = excluded.path,
        eta = excluded.eta,
        updated_at = excluded.updated_at,
        travel_mode = excluded.travel_mode;

  delete from public.route_points where user_id = me;
  insert into public.route_points (user_id, seq, position, eta)
  select me, i::int,
         extensions.st_setsrid(extensions.st_makepoint((p->>0)::float8, (p->>1)::float8), 4326)::extensions.geography,
         to_timestamp((p->>2)::float8)
  from jsonb_array_elements(points) with ordinality as t(p, i);
end;
$function$;
