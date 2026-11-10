// Meeterz – Live-Aktivität der Navigation per Push starten (APNs „push-to-start“, iOS 17.2+).
// iOS lässt Apps Live-Aktivitäten nur im Vordergrund starten. CarPlay-Fahrten beginnen aber meist bei gesperrtem
// iPhone – dann bittet die App hier darum, die Aktivität für ihr eigenes Gerät per Push zu starten. Danach
// aktualisiert die App sie selbst.
// Aufruf: functions.invoke("live_activity", { token, env, attributes_type, attributes_json, content_state_json, title, body })
// Secrets: dieselben wie bei „notify“ (APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID).

import { createClient } from "npm:@supabase/supabase-js@2";
import { apnsBundleId, apnsConfigured, sendApns } from "../_shared/apns.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let b: Record<string, string>;
  try { b = await req.json(); } catch { return json({ error: "invalid body" }, 400); }
  const token = String(b.token ?? "");
  // Nur Live-Aktivitäten der Navigation, nur gültige Gerätetokens
  if (!/^[0-9a-f]{32,200}$/.test(token) || b.attributes_type !== "NavigationActivityAttributes") return json({ error: "invalid body" }, 400);
  let attributes: unknown, contentState: unknown;
  try { attributes = JSON.parse(b.attributes_json); contentState = JSON.parse(b.content_state_json); } catch { return json({ error: "invalid body" }, 400); }
  if (String(b.attributes_json).length > 2000 || String(b.content_state_json).length > 3000) return json({ error: "too large" }, 400);

  if (!apnsConfigured()) return json({ skipped: true, reason: "apns not configured" });

  const payload = {
    aps: {
      timestamp: Math.floor(Date.now() / 1000),
      event: "start",
      "content-state": contentState,
      "attributes-type": "NavigationActivityAttributes",
      attributes,
      // Pflicht beim Start per Push; ohne Ton
      alert: { title: String(b.title ?? "Navigation").slice(0, 60), body: String(b.body ?? "").slice(0, 120) },
    },
  };
  const r = await sendApns(token, b.env, {
    "apns-topic": `${apnsBundleId()}.push-type.liveactivity`,
    "apns-push-type": "liveactivity",
    "apns-priority": "10",
  }, payload);
  console.log(`live_activity: ${user.id} → APNs ${r.host} ${r.status} ${r.reason}`);
  return json({ status: r.status }, r.status === 200 ? 200 : 502);
});
