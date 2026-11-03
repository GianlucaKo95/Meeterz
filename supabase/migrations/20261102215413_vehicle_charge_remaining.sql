-- Restladezeit, wie das Auto sie meldet (Sekunden), samt Zeitpunkt der Meldung
alter table public.vehicle_status
  add column if not exists charge_remaining_s real,
  add column if not exists charge_remaining_at timestamptz;
