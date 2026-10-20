// Meeterz – Standort-Abruf per stillem Push.
// Aufruf aus der App: functions.invoke("request_location", { targets: [<user_id>, …] })
// Weckt die Geräte der angegebenen Freunde (APNs „background“-Push), damit sie kurz ihren Standort senden –
// so muss das GPS im Hintergrund nicht dauernd laufen. Nur für Freunde, die gerade teilen, und höchstens
// wenn ihre letzte Position älter als 45 Sekunden ist.
//
// Secrets: dieselben wie bei „notify“ (APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID).

import { createClient } from "npm:@supabase/supabase-js@2";
import * as jose from "npm:jose@5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const started = Date.now();

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: { targets?: string[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  const requested = Array.from(new Set(body.targets ?? [])).filter((t) => t && t !== user.id).slice(0, 20);
  if (!requested.length) return json({ requested: 0 });

  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID") ?? "de.koeven.meeterz";
  if (!keyId || !teamId || !privateKey) return json({ skipped: true, reason: "apns not configured" });

  const admin = createClient(url, serviceKey);

  // 1) nur angenommene Freunde
  const { data: ships } = await admin.from("friendships").select("requester, addressee")
    .eq("status", "accepted").or(`requester.eq.${user.id},addressee.eq.${user.id}`);
  const friends = new Set((ships ?? []).map((s) => (s.requester === user.id ? s.addressee : s.requester)));
  let targets = requested.filter((t) => friends.has(t));

  // 2) nur wer gerade teilt (nicht pausiert, nicht inkognito)
  const now = Date.now();
  const { data: profiles } = await admin.from("profiles")
    .select("id, sharing_enabled, sharing_until, incognito_until").in("id", targets);
  const sharing = new Set((profiles ?? []).filter((p) =>
    p.sharing_enabled &&
    (!p.sharing_until || new Date(p.sharing_until).getTime() > now) &&
    (!p.incognito_until || new Date(p.incognito_until).getTime() <= now)
  ).map((p) => p.id));
  targets = targets.filter((t) => sharing.has(t));

  // 3) nur wenn die letzte Position nicht ohnehin frisch ist
  const { data: lasts } = await admin.from("last_locations").select("user_id, updated_at").in("user_id", targets);
  const fresh = new Set((lasts ?? []).filter((l) => now - new Date(l.updated_at).getTime() < 45_000).map((l) => l.user_id));
  targets = targets.filter((t) => !fresh.has(t));
  if (!targets.length) {
    console.log(`request_location: nichts zu tun (${requested.length} angefragt)`);
    return json({ requested: 0 });
  }

  const { data: tokens } = await admin.from("device_tokens").select("token, environment").in("user_id", targets);
  if (!tokens?.length) return json({ requested: 0 });

  const jwt = await new jose.SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(await jose.importPKCS8(privateKey, "ES256"));

  let sent = 0;
  for (const t of tokens) {
    const host = t.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const res = await fetch(`https://${host}/3/device/${t.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-expiration": String(Math.floor(now / 1000) + 60), // nach einer Minute verfallen lassen
      },
      body: JSON.stringify({ aps: { "content-available": 1 }, kind: "locate" }),
    });
    console.log(`request_location: APNs ${host} → ${res.status} nach ${Date.now() - started} ms`);
    if (res.ok) sent++;
    if (res.status === 410 || res.status === 400) {
      await admin.from("device_tokens").delete().eq("token", t.token);
    }
  }
  console.log(`request_location: ${sent} Geräte geweckt für ${targets.length} Freunde`);
  return json({ requested: targets.length, sent });
});
