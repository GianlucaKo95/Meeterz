// Meeterz – Empfänger für Mobilithek-Push (AFIR-Ladesäulendaten, DATEX II v3 JSON).
// Die Mobilithek schickt abonnierte Datenpakete per HTTPS-POST (gzip) an
//   https://jgtkyxlzroajtxboqgcn.supabase.co/functions/v1/mobilithek-push
// Dynamisch (aegiEnergyInfrastructureStatusPublication): Status und Ad-hoc-Preis je Ladepunkt → charge_point_status.
// Statisch (aegiEnergyInfrastructureTablePublication): Standorte mit Koordinaten und ihre Ladepunkte →
// charge_site_static / charge_point_static. Die Apps lesen über die RPC charge_availability().
//
// Ohne JWT (die Mobilithek kann keins mitschicken): angenommen werden nur Pakete mit Abo-Kennung im Header
// und dem erwarteten Aufbau; zurückgegeben wird nichts.

import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : v === undefined || v === null ? [] : [v]);

/** Alle Objekte unter einem Schlüssel, egal wie tief (DATEX-Profile verschachteln unterschiedlich) */
function findAll(node: unknown, key: string, out: unknown[] = []): unknown[] {
  if (Array.isArray(node)) for (const n of node) findAll(n, key, out);
  else if (isObj(node)) {
    for (const [k, v] of Object.entries(node)) {
      if (k === key) out.push(...arr(v));
      else findAll(v, key, out);
    }
  }
  return out;
}

const idOf = (o: unknown): string | undefined =>
  isObj(o) ? (typeof o.idG === "string" ? o.idG : isObj(o.reference) && typeof o.reference.idG === "string" ? o.reference.idG : undefined) : undefined;

/** Erste Koordinate im Teilbaum */
function coordinates(node: unknown): { lat: number; lng: number } | undefined {
  if (Array.isArray(node)) {
    for (const n of node) { const c = coordinates(n); if (c) return c; }
  } else if (isObj(node)) {
    const lat = Number(node.latitude), lng = Number(node.longitude);
    if (Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && (lat !== 0 || lng !== 0)) {
      return { lat, lng };
    }
    for (const v of Object.values(node)) { const c = coordinates(v); if (c) return c; }
  }
  return undefined;
}

/** Erster Text eines mehrsprachigen DATEX-Werts ({ values: [{ value }] }) unter einem Schlüssel */
function text(node: unknown, key: string): string | undefined {
  for (const v of findAll(node, key)) {
    const t = findAll(v, "value").find((x) => typeof x === "string");
    if (typeof t === "string") return t;
    if (typeof v === "string") return v;
  }
  return undefined;
}

/** Höchste Leistung im Teilbaum in kW (DATEX gibt Watt an) */
function maxKw(node: unknown): number | undefined {
  const values = [...findAll(node, "maxPowerAtSocket"), ...findAll(node, "availableChargingPower")]
    .map(Number).filter((n) => Number.isFinite(n) && n > 0);
  if (!values.length) return undefined;
  const m = Math.max(...values);
  return m > 1000 ? m / 1000 : m;
}

/** Ad-hoc-Preis je kWh (inkl. MwSt.) */
function pricePerKwh(point: Obj): number | undefined {
  for (const p of findAll(point, "energyPrice")) {
    if (!isObj(p)) continue;
    const type = isObj(p.priceType) ? p.priceType.value : p.priceType;
    const value = Number(p.value);
    if (type === "pricePerKWh" && Number.isFinite(value) && value > 0 && value < 5) {
      const tax = p.taxIncluded === false && Number.isFinite(Number(p.taxRate)) ? 1 + Number(p.taxRate) / 100 : 1;
      return Math.round(value * tax * 1000) / 1000;
    }
  }
  return undefined;
}

async function upsert(table: string, rows: Obj[], key: string) {
  for (let i = 0; i < rows.length; i += 1000) {
    const { error } = await admin.from(table).upsert(rows.slice(i, i + 1000), { onConflict: key });
    if (error) { console.log(`mobilithek-push: ${table} fehlgeschlagen: ${error.message}`); return false; }
  }
  return true;
}

async function dynamic(json: unknown, publisher: string) {
  const now = new Date().toISOString();
  const rows: Obj[] = [];
  for (const site of findAll(json, "energyInfrastructureSiteStatus")) {
    const siteId = idOf(site);
    for (const point of findAll(site, "aegiElectricChargingPointStatus")) {
      if (!isObj(point)) continue;
      const pointId = idOf(point);
      const status = isObj(point.status) ? point.status.value : undefined;
      if (!pointId || typeof status !== "string") continue;
      rows.push({
        point_id: pointId, site_id: siteId ?? null, status, price_kwh: pricePerKwh(point) ?? null,
        reported_at: typeof point.lastUpdated === "string" ? point.lastUpdated : null, received_at: now,
      });
    }
  }
  const ok = rows.length ? await upsert("charge_point_status", rows, "point_id") : true;
  const priced = rows.filter((r) => r.price_kwh !== null).length;
  console.log(`mobilithek-push: dynamisch ${publisher}: ${rows.length} Ladepunkte (${priced} mit Preis)${ok ? "" : " – nicht gespeichert"}`);
}

async function staticData(json: unknown, publisher: string) {
  const sites: Obj[] = [];
  const points: Obj[] = [];
  const now = new Date().toISOString();
  for (const site of findAll(json, "energyInfrastructureSite")) {
    if (!isObj(site)) continue;
    const siteId = idOf(site);
    const c = coordinates(site.locationReference ?? site);
    if (!siteId || !c) continue;
    sites.push({
      site_id: siteId, lat: c.lat, lng: c.lng,
      name: text(site, "name") ?? null, operator: text(site.operator ?? {}, "name") ?? null,
      max_kw: maxKw(site) ?? null, updated_at: now,
    });
    for (const p of findAll(site, "aegiElectricChargingPoint")) {
      const pointId = idOf(p);
      if (pointId) points.push({ point_id: pointId, site_id: siteId, max_kw: maxKw(p) ?? null, updated_at: now });
    }
  }
  const ok = (sites.length ? await upsert("charge_site_static", sites, "site_id") : true)
    && (points.length ? await upsert("charge_point_static", points, "point_id") : true);
  console.log(`mobilithek-push: statisch ${publisher}: ${sites.length} Standorte, ${points.length} Ladepunkte${ok ? "" : " – nicht gespeichert"}`);
  if (!sites.length) console.log(`mobilithek-push: statisch ohne erkannte Standorte, Ausschnitt ${JSON.stringify(json).slice(0, 2500)}`);
}

Deno.serve(async (req) => {
  if (req.method === "HEAD" || req.method === "GET") return new Response(null, { status: 200 });
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const subscription = req.headers.get("subscriptionid") ?? "";
  if (!/^\d{6,25}$/.test(subscription)) return new Response(null, { status: 400 });
  try {
    const raw = new Uint8Array(await req.arrayBuffer());
    if (raw.length > 50_000_000) return new Response(null, { status: 413 });
    const gz = raw.length > 2 && raw[0] === 0x1f && raw[1] === 0x8b;
    const bytes = gz
      ? new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new DecompressionStream("gzip"))).arrayBuffer())
      : raw;
    const json = JSON.parse(new TextDecoder().decode(bytes));
    const publisher = String(findAll(json, "profileNameG")[0] ?? "?").replace(/^AFIR Energy Infrastructure\s*G?\s*/, "") || "?";
    if (findAll(json, "aegiEnergyInfrastructureStatusPublication").length) await dynamic(json, publisher);
    else if (findAll(json, "energyInfrastructureSite").length) await staticData(json, publisher);
    else console.log(`mobilithek-push: unbekannter Inhalt (Abo ${subscription}), Ausschnitt ${JSON.stringify(json).slice(0, 1500)}`);
  } catch (e) {
    console.log(`mobilithek-push: Fehler (Abo ${subscription}): ${e}`);
  }
  return new Response(null, { status: 200 });
});
