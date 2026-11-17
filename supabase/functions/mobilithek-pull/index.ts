import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const IDS = ["1056915110420725760","1056915179165368320","1056913546423484416","1056917947838021632","1056915353379979264","1056915306466463744","1056915693588140032","1056920167799017472","1056920190960160768","1056919536728457216","1056916219461586944","1056918955762827264","1056918851660201984","1056915138941964288","1056918149969694720","1056913657522180096","1056918039340929024","1056913437358997504","1056913498004439040","1056918928608874496","1056915778602713088","1056917917303263232","1056919356755066880","1056916095234887680","1056918636916002816","1056915073162498048","1056918420036960256","1056916406074757120","1056914847391698944","1056916033104662528","1056920042083368960","1056918810362859520","1056915607667822592","1056918542372225024","1056913228147113984","1056916252898578432","1056919482512855040","1056915263680368640","1056914944053432320","1056919099534954496","1056915903651467264","1056918671263158272","1056918700702978048","1056920074568253440","1056916064599691264","1056915957103902720","1056919041221545984","1056919623902842880","1056915543772020736","1056920007773933568","1056915395385905152","1056918601717432320","1056918497069322240","1056918461250162688","1056919507682873344","1056916183344631808","1056917977558831104","1056919132720484352","1056915810601029632","1056919438506246144","1056915440256372736","1056918769518727168","1056919396583952384","1056919003238125568","1056918734563397632","1056915210345795584","1056915861792509952","1056916370167349248","1056916124141834240","1056916151031517184"];
const BATCH_SIZE = 10;
const BASE = "https://mobilithek.info:8443/mobilithek/api/v1.0/subscription?subscriptionID=";
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const arr = (v: unknown): unknown[] => Array.isArray(v) ? v : v == null ? [] : [v];

function findAll(node: unknown, key: string, out: unknown[] = []): unknown[] {
  if (Array.isArray(node)) for (const n of node) findAll(n, key, out);
  else if (isObj(node)) for (const [k, v] of Object.entries(node)) {
    if (k === key) out.push(...arr(v));
    else findAll(v, key, out);
  }
  return out;
}
function idOf(o: unknown): string | undefined {
  if (!isObj(o)) return;
  if (typeof o.idG === "string") return o.idG;
  if (isObj(o.reference) && typeof o.reference.idG === "string") return o.reference.idG;
}
function coordinates(node: unknown): { lat: number; lng: number } | undefined {
  if (Array.isArray(node)) {
    for (const n of node) { const c = coordinates(n); if (c) return c; }
  } else if (isObj(node)) {
    const lat = Number(node.latitude), lng = Number(node.longitude);
    if (Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && (lat !== 0 || lng !== 0)) return { lat, lng };
    for (const v of Object.values(node)) { const c = coordinates(v); if (c) return c; }
  }
}
function textValue(node: unknown, key: string): string | undefined {
  for (const v of findAll(node, key)) {
    const t = findAll(v, "value").find(x => typeof x === "string");
    if (typeof t === "string") return t;
    if (typeof v === "string") return v;
    if (isObj(v) && Array.isArray(v.values)) {
      const nested = v.values.map(x => isObj(x) ? x.value : undefined).find(x => typeof x === "string");
      if (typeof nested === "string") return nested;
    }
  }
}
function maxKw(node: unknown): number | undefined {
  const values = [...findAll(node, "maxPowerAtSocket"), ...findAll(node, "availableChargingPower")]
    .map(Number).filter(n => Number.isFinite(n) && n > 0);
  if (!values.length) return;
  const m = Math.max(...values);
  return m > 1000 ? m / 1000 : m;
}
function pricePerKwh(point: Record<string, unknown>): number | undefined {
  for (const p of findAll(point, "energyPrice")) {
    if (!isObj(p)) continue;
    const type = isObj(p.priceType) ? p.priceType.value : p.priceType;
    const value = Number(p.value);
    if (type === "pricePerKWh" && Number.isFinite(value) && value > 0 && value < 5) {
      const tax = p.taxIncluded === false && Number.isFinite(Number(p.taxRate)) ? 1 + Number(p.taxRate) / 100 : 1;
      return Math.round(value * tax * 1000) / 1000;
    }
  }
}
function parseDynamic(json: unknown, now: string) {
  const rows: Record<string, unknown>[] = [];
  for (const site of findAll(json, "energyInfrastructureSiteStatus")) {
    const siteId = idOf(site);
    const operator = isObj(site) ? textValue(site.operator ?? {}, "name") ?? null : null;
    for (const point of findAll(site, "aegiElectricChargingPointStatus")) {
      if (!isObj(point)) continue;
      const pointId = idOf(point);
      const status = isObj(point.status) ? point.status.value : undefined;
      if (!pointId || typeof status !== "string") continue;
      rows.push({
        point_id: pointId, site_id: siteId ?? null, operator, status,
        price_kwh: pricePerKwh(point) ?? null,
        reported_at: typeof point.lastUpdated === "string" ? point.lastUpdated :
          (isObj(site) && typeof site.lastUpdated === "string" ? site.lastUpdated : null),
        received_at: now
      });
    }
  }
  return rows;
}
function parseStatic(json: unknown, now: string) {
  const sites: Record<string, unknown>[] = [], points: Record<string, unknown>[] = [], mappings: Record<string, unknown>[] = [];
  for (const site of findAll(json, "energyInfrastructureSite")) {
    if (!isObj(site)) continue;
    const siteId = idOf(site);
    const c = coordinates(site.locationReference ?? site);
    if (!siteId || !c) continue;
    const operator = textValue(site.operator ?? {}, "name") ?? null;
    sites.push({
      site_id: siteId, lat: c.lat, lng: c.lng,
      name: textValue(site, "name") ?? null,
      operator,
      max_kw: maxKw(site) ?? null, updated_at: now
    });
    for (const p of findAll(site, "aegiElectricChargingPoint")) {
      const pointId = idOf(p);
      if (pointId) {
        points.push({ point_id: pointId, site_id: siteId, max_kw: maxKw(p) ?? null, updated_at: now });
        mappings.push({ subscription_id: "", point_id: pointId, site_id: siteId, operator, publication_type: "STATIC_TABLE", updated_at: now });
      }
    }
  }
  return { sites, points, mappings };
}
/**
 * Liest die Mobilithek-Antwort als Strom und gibt nur die gesuchten Listenelemente (Standorte) einzeln weiter.
 * Vorher wurde die ganze Antwort als Text gelesen und komplett geparst – große Betreiber (über 100 MB entpackt)
 * sprengten das Speicherlimit der Funktion (WORKER_RESOURCE_LIMIT, 17.11.). So liegt immer nur ein Standort im Speicher.
 */
async function scanElements(body: ReadableStream<Uint8Array>, keys: Set<string>, onElement: (key: string, value: unknown) => void) {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let buf = "", inStr = false, strStart = -1, lastString: string | null = null;
  let depth = 0, armedKey: string | null = null, armedDepth = -1;
  let arrayKey: string | null = null, arrayDepth = -1;
  let capKey: string | null = null, capStart = -1, capDepth = -1;
  const publications = new Set<string>();
  let elements = 0, start = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    // weiter ab dem Ende des letzten Stücks (Positionen sind relativ zu buf)
    for (let i = start; i < buf.length; i++) {
      const c = buf.charCodeAt(i);
      if (inStr) {
        // Strings überspringen (der Großteil der Daten) – schnell per indexOf statt Zeichen für Zeichen
        let j = buf.indexOf('"', i);
        while (j >= 0) {
          let b = 0;
          while (buf.charCodeAt(j - 1 - b) === 92) b++;       // vorangestellte Backslashes
          if (b % 2 === 0) break;
          j = buf.indexOf('"', j + 1);
        }
        if (j < 0) {                                         // String geht im nächsten Stück weiter
          if (strStart >= 0 && buf.length - strStart > 200) strStart = -1;
          break;
        }
        inStr = false;
        if (capStart < 0 && strStart >= 0 && j - strStart <= 200) lastString = buf.slice(strStart, j);
        strStart = -1;
        i = j;
        continue;
      }
      if (c === 34) {
        inStr = true; lastString = null;
        strStart = capStart < 0 ? i + 1 : -1;
        if (capStart < 0 && armedKey !== null && depth === armedDepth) armedKey = null;   // Wert ist ein String
        continue;
      }
      if (c === 58) {                                        // :
        if (capStart < 0 && lastString !== null) {
          if (keys.has(lastString)) { armedKey = lastString; armedDepth = depth; }
          else if (/Publication$/.test(lastString)) publications.add(lastString);
        }
        lastString = null;
        continue;
      }
      if (c === 123 || c === 91) {                           // { [
        if (capStart < 0) {
          if (armedKey !== null && depth === armedDepth) {
            if (c === 91) { arrayKey = armedKey; arrayDepth = depth + 1; }
            else { capKey = armedKey; capStart = i; capDepth = depth; }
            armedKey = null;
          } else if (c === 123 && arrayKey !== null && depth === arrayDepth) {
            capKey = arrayKey; capStart = i; capDepth = depth;
          }
        }
        depth++;
        continue;
      }
      if (c === 125 || c === 93) {                           // } ]
        depth--;
        if (capStart >= 0 && depth === capDepth && c === 125) {
          onElement(capKey!, JSON.parse(buf.slice(capStart, i + 1)));
          elements++;
          capStart = -1; capKey = null;
        } else if (c === 93 && arrayKey !== null && depth === arrayDepth - 1) {
          arrayKey = null; arrayDepth = -1;
        }
        continue;
      }
      if (c > 32 && c !== 44) { armedKey = null; lastString = null; }   // anderer Wert nach dem Schlüssel
    }
    // Rest behalten: laufendes Element bzw. laufender (kurzer) String
    let keep = capStart >= 0 ? capStart : strStart >= 0 ? strStart - 1 : buf.length;
    if (inStr) keep = Math.min(keep, Math.max(0, buf.length - 8));   // Backslashes vor dem nächsten " erkennen
    buf = buf.slice(keep);
    start = buf.length;
    if (capStart >= 0) capStart -= keep;
    if (strStart >= 0) strStart -= keep;
  }
  return { publications: [...publications], elements };
}
async function upsertChunks(admin: ReturnType<typeof createClient>, table: string, rows: Record<string, unknown>[], key: string) {
  const unique = [...new Map(rows.map(row => [String(row[key]), row])).values()];
  for (let i = 0; i < unique.length; i += 500) {
    const { error } = await admin.from(table).upsert(unique.slice(i, i + 500), { onConflict: key });
    if (error) throw new Error(table + " upsert failed: " + error.message);
  }
}
function newestStatusRows(rows: Record<string, unknown>[]) {
  const byPoint = new Map<string, Record<string, unknown>>();
  for (const row of rows) {
    const id = String(row.point_id);
    const previous = byPoint.get(id);
    const incomingTime = Date.parse(String(row.reported_at ?? ""));
    const previousTime = Date.parse(String(previous?.reported_at ?? ""));
    if (!previous || (Number.isFinite(incomingTime) && (!Number.isFinite(previousTime) || incomingTime >= previousTime))) byPoint.set(id, row);
  }
  return [...byPoint.values()];
}
async function saveSubscriptionState(
  admin: ReturnType<typeof createClient>,
  subscriptionId: string,
  publicationType: string | null,
  httpStatus: number,
  lastSuccessAt: string | null
) {
  const { error } = await admin.from("mobilithek_subscription_state").upsert({
    subscription_id: subscriptionId,
    publication_type: publicationType,
    last_checked_at: new Date().toISOString(),
    last_success_at: lastSuccessAt,
    last_http_status: httpStatus,
    last_error: null
  }, { onConflict: "subscription_id" });
  if (error) throw new Error("subscription state update failed: " + error.message);
}
async function upsertStatusRows(admin: ReturnType<typeof createClient>, rows: Record<string, unknown>[]) {
  const unique = newestStatusRows(rows);
  let affected = 0;
  for (let i = 0; i < unique.length; i += 500) {
    const { data, error } = await admin.rpc("mobilithek_upsert_status", { p_rows: unique.slice(i, i + 500) });
    if (error) throw new Error("charge_point_status conditional upsert failed: " + error.message);
    affected += Number(data ?? 0);
  }
  return affected;
}
async function saveSubscriptionPoints(
  admin: ReturnType<typeof createClient>,
  subscriptionId: string,
  publicationType: string,
  mappings: Record<string, unknown>[]
) {
  const rows = mappings.map(row => ({ ...row, subscription_id: subscriptionId, publication_type: publicationType, updated_at: new Date().toISOString() }));
  const unique = [...new Map(rows.map(row => [String(row.point_id), row])).values()];
  for (let i = 0; i < unique.length; i += 500) {
    const { error } = await admin.from("mobilithek_subscription_points").upsert(unique.slice(i, i + 500), { onConflict: "subscription_id,point_id" });
    if (error) throw new Error("subscription point mapping upsert failed: " + error.message);
  }
}
Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "POST") return Response.json({ ok: false, error: "METHOD_NOT_ALLOWED" }, { status: 405 });
  const url = new URL(req.url);
  const batchParam = url.searchParams.get("batch");
  const mode = url.searchParams.get("mode") ?? "dry-run";
  const forceMapping = url.searchParams.get("forceMapping") === "1";
  let slice: string[];
  const idsParam = url.searchParams.get("ids");
  if (idsParam !== null) {
    const requested = [...new Set(idsParam.split(",").map(x => x.trim()).filter(Boolean))];
    if (requested.length < 1 || requested.length > BATCH_SIZE || requested.some(id => !IDS.includes(id))) {
      return Response.json({ ok: false, error: "INVALID_SUBSCRIPTION_IDS", maxPerRequest: BATCH_SIZE }, { status: 400 });
    }
    slice = requested;
  } else {
    const batch = Number(batchParam ?? "0");
    if (!Number.isInteger(batch) || batch < 0 || batch > 6) return Response.json({ ok: false, error: "INVALID_BATCH", validBatches: "0-6" }, { status: 400 });
    slice = IDS.slice(batch * BATCH_SIZE, (batch + 1) * BATCH_SIZE);
  }
  if (mode !== "dry-run" && mode !== "commit") return Response.json({ ok: false, error: "INVALID_MODE", allowed: ["dry-run", "commit"] }, { status: 400 });

  const cert = Deno.env.get("MOBILITHEK_CLIENT_CERT_PEM"), key = Deno.env.get("MOBILITHEK_CLIENT_KEY_PEM");
  const supabaseUrl = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!cert || !key || !supabaseUrl || !serviceKey) return Response.json({ ok: false, error: "MISSING_SERVER_CONFIGURATION" }, { status: 500 });

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const createHttpClient = (Deno as unknown as { createHttpClient: (options: { cert: string; key: string }) => Deno.HttpClient }).createHttpClient;
  if (typeof createHttpClient !== "function") return Response.json({ ok: false, error: "DENO_CREATE_HTTP_CLIENT_UNAVAILABLE" }, { status: 501 });
  let client: Deno.HttpClient | undefined;
  try {
    client = createHttpClient({ cert, key });
    const results: Record<string, unknown>[] = [];
    let cursor = 0;
    async function worker() {
      while (true) {
        const i = cursor++;
        if (i >= slice.length) return;
        const id = slice[i];
        try {
          let previousState: { publication_type: string | null; last_checked_at: string | null; last_success_at: string | null } | null = null;
          if (mode === "commit") {
            const { data, error } = await admin.from("mobilithek_subscription_state")
              .select("publication_type,last_checked_at,last_success_at")
              .eq("subscription_id", id).maybeSingle();
            if (error) throw new Error("subscription state read failed: " + error.message);
            previousState = data;
            const ageMs = previousState?.last_checked_at ? Date.now() - Date.parse(previousState.last_checked_at) : Infinity;
            const ttlMs = previousState?.publication_type === "DYNAMIC_STATUS" ? 3 * 60 * 1000
              : previousState?.publication_type === "STATIC_TABLE" ? 12 * 60 * 60 * 1000
              : previousState?.publication_type === "UNKNOWN" ? 3 * 60 * 1000 : 0;
            const { count: mappedCount, error: mappingReadError } = await admin.from("mobilithek_subscription_points")
              .select("point_id", { count: "exact", head: true }).eq("subscription_id", id);
            if (mappingReadError) throw new Error("subscription mapping read failed: " + mappingReadError.message);
            const mappingMissing = (mappedCount ?? 0) === 0;
            if (!forceMapping && !mappingMissing && ttlMs > 0 && ageMs >= 0 && ageMs < ttlMs) {
              results[i] = { subscriptionId: id, classification: "SKIPPED_FRESH", publicationType: previousState?.publication_type, ageSeconds: Math.floor(ageMs / 1000), written: false };
              continue;
            }
          }
          const upstream = await fetch(BASE + id, {
            method: "GET", headers: { "Accept-Encoding": "gzip" }, client,
            signal: AbortSignal.timeout(45000)
          });
          const baseResult: Record<string, unknown> = { subscriptionId: id, httpStatus: upstream.status };
          if (upstream.status === 204 || upstream.status === 304) {
            await upstream.body?.cancel();
            if (mode === "commit") await saveSubscriptionState(admin, id, previousState?.publication_type ?? null, upstream.status, previousState?.last_success_at ?? null);
            results[i] = { ...baseResult, classification: "NO_NEW_DATA", written: false };
            continue;
          }
          if (upstream.status !== 200) {
            const detail = (await upstream.text()).slice(0, 300);
            results[i] = { ...baseResult, classification: "HTTP_ERROR", error: detail };
            continue;
          }
          const now = new Date().toISOString();
          const statusRows: Record<string, unknown>[] = [];
          const staticParts = { sites: [] as Record<string, unknown>[], points: [] as Record<string, unknown>[], mappings: [] as Record<string, unknown>[] };
          let scan: { publications: string[]; elements: number };
          try {
            scan = await scanElements(upstream.body!, new Set(["energyInfrastructureSiteStatus", "energyInfrastructureSite"]), (key, value) => {
              if (key === "energyInfrastructureSiteStatus") statusRows.push(...parseDynamic({ energyInfrastructureSiteStatus: value }, now));
              else {
                const part = parseStatic({ energyInfrastructureSite: value }, now);
                staticParts.sites.push(...part.sites); staticParts.points.push(...part.points); staticParts.mappings.push(...part.mappings);
              }
            });
          } catch (e) {
            results[i] = { ...baseResult, classification: "NON_JSON", error: e instanceof Error ? e.message : String(e), written: false };
            continue;
          }
          const isDynamic = statusRows.length > 0 || scan.publications.some(k => /StatusPublication$/i.test(k));
          const isStatic = !isDynamic && (staticParts.sites.length > 0 || scan.publications.some(k => /TablePublication$/i.test(k)));
          if (isDynamic) {
            const rows = statusRows;
            const uniquePoints = newestStatusRows(rows);
            const pointsWritten = mode === "commit" && uniquePoints.length ? await upsertStatusRows(admin, uniquePoints) : 0;
            if (mode === "commit") {
              if (rows.length) await saveSubscriptionPoints(admin, id, "DYNAMIC_STATUS", rows.map(r => ({ point_id: r.point_id, site_id: r.site_id ?? null, operator: r.operator ?? null })));
              await saveSubscriptionState(admin, id, "DYNAMIC_STATUS", 200, now);
            }
            results[i] = { ...baseResult, classification: "DYNAMIC_STATUS", pointsParsed: rows.length, uniquePoints: uniquePoints.length, pointsUpserted: pointsWritten, pricedPoints: uniquePoints.filter(r => r.price_kwh !== null).length, written: mode === "commit" && pointsWritten > 0 };
          } else if (isStatic) {
            const { sites, points, mappings } = staticParts;
            if (mode === "commit") {
              if (sites.length) await upsertChunks(admin, "charge_site_static", sites, "site_id");
              if (points.length) await upsertChunks(admin, "charge_point_static", points, "point_id");
              if (mappings.length) await saveSubscriptionPoints(admin, id, "STATIC_TABLE", mappings);
              await saveSubscriptionState(admin, id, "STATIC_TABLE", 200, now);
            }
            results[i] = { ...baseResult, classification: "STATIC_TABLE", sitesParsed: sites.length, pointsParsed: points.length, written: mode === "commit" && (sites.length + points.length > 0) };
          } else {
            if (mode === "commit") await saveSubscriptionState(admin, id, "UNKNOWN", 200, previousState?.last_success_at ?? null);
            results[i] = { ...baseResult, classification: "UNKNOWN_PUBLICATION_TYPE", written: false };
          }
        } catch (e) {
          results[i] = { subscriptionId: id, classification: "PROCESSING_ERROR", error: e instanceof Error ? e.message : String(e), written: false };
        }
      }
    }
    // Eine Subscription nach der anderen verarbeiten. Große Mobilithek-Payloads
    // parallel im selben Edge-Worker haben WORKER_RESOURCE_LIMIT ausgelöst.
    await worker();
    const failures = results.filter(r => ["HTTP_ERROR", "NON_JSON", "UNKNOWN_PUBLICATION_TYPE", "PROCESSING_ERROR"].includes(String(r.classification))).length;
    return Response.json({
      ok: failures === 0, stage: mode === "commit" ? "mobilithek_batch_committed" : "mobilithek_batch_dry_run",
      batch: batchParam === null ? null : Number(batchParam), batchesTotal: 7, batchSize: slice.length, uniqueSubscriptionsTotal: IDS.length,
      subscriptionIds: slice, forceMapping, mode, failures, results,
      note: "Only idempotent upserts are used. No rows are deleted. Existing charge_availability() is not modified."
    });
  } catch (e) {
    console.error("mobilithek-pull failed", e);
    return Response.json({ ok: false, error: e instanceof Error ? e.message : String(e) }, { status: 502 });
  } finally {
    try { client?.close(); } catch { /* ignore */ }
  }
});