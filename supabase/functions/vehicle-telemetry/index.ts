// Meeterz – Live-Fahrzeugdaten empfangen (OsmAnd-Protokoll, wie Traccar).
//
// Das Home-Assistant-Add-on (saic-python-mqtt-gateway) schickt bei jeder Aktualisierung einen POST mit
// Query-Parametern: id, timestamp, soc, est_battery_range, is_charging, power, ext_temp, odometer (m),
// speed (km/h), lat, lon, is_parked, …  „id“ ist das geheime Gerätetoken aus der App (Einstellungen → E-Auto).
//
// Bereitstellen ohne JWT-Prüfung (das Gateway hat keinen Supabase-Login):
//   supabase functions deploy vehicle-telemetry --no-verify-jwt

import { createClient } from "npm:@supabase/supabase-js@2";

const num = (v: string | null) => {
  if (v === null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const bool = (v: string | null) => (v === null ? null : ["true", "1", "True"].includes(v));
// Nur plausible Werte übernehmen; ein unsinniger Einzelwert fällt weg, der Rest der Meldung bleibt
const within = (v: number | null, min: number, max: number) => (v !== null && v >= min && v <= max ? v : null);

Deno.serve(async (req) => {
  const params = new URL(req.url).searchParams;
  // Manche Clients schicken die Werte als Formular statt in der URL
  if (req.method === "POST" && (req.headers.get("content-type") ?? "").includes("form")) {
    for (const [k, v] of new URLSearchParams(await req.text())) if (!params.has(k)) params.set(k, v);
  }
  const token = params.get("id") ?? params.get("deviceid") ?? "";
  if (!/^[0-9a-f]{64}$/.test(token)) return new Response("unknown device", { status: 401 });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: link } = await db.from("vehicle_links").select("user_id").eq("token", token).maybeSingle();
  if (!link) return new Response("unknown device", { status: 401 });

  // Restladezeit laut Auto (Sekunden) – kommt als eigene Meldung vom Add-on (MQTT des Gateways), nicht über OsmAnd.
  // Dann nur diese Spalten setzen, damit Akkustand und Zeitstempel der letzten Vollmeldung erhalten bleiben.
  // Ebenso das im Auto eingestellte Ladeziel (%), auf das sich die Restladezeit bezieht.
  const remaining = within(num(params.get("remaining_charging_time")), 0, 48 * 3600);
  const target = within(num(params.get("charge_target")), 0, 100);
  if ((params.has("remaining_charging_time") || params.has("charge_target")) && !params.has("soc")) {
    if (remaining === null && target === null) return new Response("OK (ungültiger Wert)");
    const patch: Record<string, unknown> = { user_id: link.user_id };
    if (remaining !== null) { patch.charge_remaining_s = remaining; patch.charge_remaining_at = new Date().toISOString(); }
    if (target !== null) patch.charge_target_percent = target;
    const { error } = await db.from("vehicle_status").upsert(patch, { onConflict: "user_id" });
    if (error) { console.error(error.message); return new Response("error", { status: 500 }); }
    return new Response("OK");
  }

  // Messzeitpunkt: nie in der Zukunft (Uhr des Gateways falsch → jetzt)
  const ts = num(params.get("timestamp"));
  const now = Date.now();
  const measured = ts && ts > 0 ? Math.min(ts * 1000, now) : now;
  // Ältere Meldung (verspätet oder doppelt zugestellt) überschreibt keine neuere
  const { data: existing } = await db.from("vehicle_status").select("reported_at").eq("user_id", link.user_id).maybeSingle();
  if (existing?.reported_at && new Date(existing.reported_at).getTime() > measured) return new Response("OK (älter als gespeichert)");

  const odometer = within(num(params.get("odometer")), 0, 5_000_000_000);
  const row: Record<string, unknown> = {
    user_id: link.user_id,
    reported_at: new Date(measured).toISOString(),
    updated_at: new Date().toISOString(),
  };
  const set = (key: string, value: unknown) => { if (value !== null && value !== undefined) row[key] = value; };
  set("soc", within(num(params.get("soc")), 0, 100));
  set("range_km", within(num(params.get("est_battery_range")), 0, 2000));
  set("charging", bool(params.get("is_charging")));
  set("power_kw", within(num(params.get("power")), -1000, 1000));
  // Geparkt meldet das Auto oft 0 °C (Sensor aus) – dann den letzten echten Wert behalten
  const parked = bool(params.get("is_parked"));
  const temp = within(num(params.get("ext_temp")), -60, 70);
  if (!(parked && temp === 0)) set("ext_temp", temp);
  set("odometer_km", odometer === null ? null : odometer / 1000);
  set("speed_kmh", within(num(params.get("speed")), 0, 400));
  set("parked", bool(params.get("is_parked")));
  // Position nur als Paar und im gültigen Bereich (0/0 = kein GPS)
  const lat = within(num(params.get("lat")), -90, 90), lng = within(num(params.get("lon")), -180, 180);
  if (lat !== null && lng !== null && !(lat === 0 && lng === 0)) { set("lat", lat); set("lng", lng); }

  const { error } = await db.from("vehicle_status").upsert(row, { onConflict: "user_id" });
  if (error) { console.error(error.message); return new Response("error", { status: 500 }); }
  return new Response("OK");
});
