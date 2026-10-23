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

  const ts = num(params.get("timestamp"));
  const odometer = num(params.get("odometer"));
  const row: Record<string, unknown> = {
    user_id: link.user_id,
    reported_at: ts ? new Date(ts * 1000).toISOString() : new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  const set = (key: string, value: unknown) => { if (value !== null && value !== undefined) row[key] = value; };
  set("soc", num(params.get("soc")));
  set("range_km", num(params.get("est_battery_range")));
  set("charging", bool(params.get("is_charging")));
  set("power_kw", num(params.get("power")));
  // Geparkt meldet das Auto oft 0 °C (Sensor aus) – dann den letzten echten Wert behalten
  const parked = bool(params.get("is_parked"));
  const temp = num(params.get("ext_temp"));
  if (!(parked && temp === 0)) set("ext_temp", temp);
  set("odometer_km", odometer === null ? null : odometer / 1000);
  set("speed_kmh", num(params.get("speed")));
  set("parked", bool(params.get("is_parked")));
  set("lat", num(params.get("lat")));
  set("lng", num(params.get("lon")));

  const { error } = await db.from("vehicle_status").upsert(row, { onConflict: "user_id" });
  if (error) return new Response(error.message, { status: 500 });
  return new Response("OK");
});
