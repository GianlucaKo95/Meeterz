// Meeterz – Live-Aktivität der Navigation per Push starten (APNs „push-to-start“, iOS 17.2+).
// iOS lässt Apps Live-Aktivitäten nur im Vordergrund starten. CarPlay-Fahrten beginnen aber meist bei gesperrtem
// iPhone – dann bittet die App hier darum, die Aktivität für ihr eigenes Gerät per Push zu starten. Danach
// aktualisiert die App sie selbst.
// Aufruf: functions.invoke("live_activity", { token, env, attributes_type, attributes_json, content_state_json, title, body })
// Secrets: dieselben wie bei „notify“ (APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID).

import { createClient } from "npm:@supabase/supabase-js@2";
import * as jose from "npm:jose@5";

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

  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID") ?? "de.koeven.meeterz";
  if (!keyId || !teamId || !privateKey) return json({ skipped: true, reason: "apns not configured" });

  const jwt = await new jose.SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(await jose.importPKCS8(privateKey, "ES256"));

  const host = b.env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
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
  const res = await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": `${bundleId}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
    },
    body: JSON.stringify(payload),
  });
  const text = res.ok ? "" : await res.text();
  console.log(`live_activity: ${user.id} → APNs ${host} ${res.status} ${text}`);
  return json({ status: res.status }, res.ok ? 200 : 502);
});
