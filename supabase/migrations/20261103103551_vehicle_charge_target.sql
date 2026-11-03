-- Ladeziel, das im Auto eingestellt ist (%), für die Restladezeit des Autos
alter table public.vehicle_status
  add column if not exists charge_target_percent real;
