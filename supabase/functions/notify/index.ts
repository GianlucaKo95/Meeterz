// Meeterz – Push-Benachrichtigungen über APNs.
// Aufruf aus der App: functions.invoke("notify", { kind, target, meetup_id? })
// Prüft, ob der Aufrufer dem Empfänger wirklich etwas schicken darf, und sendet dann an alle Geräte des Empfängers.
//
// Secrets (Supabase → Edge Functions → Secrets), erst nötig mit bezahltem Apple Developer Account:
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (Inhalt der .p8-Datei), APNS_BUNDLE_ID (de.koeven.meeterz)
// Ohne Secrets antwortet die Funktion mit { skipped: true } – die App funktioniert normal weiter.

import { createClient } from "npm:@supabase/supabase-js@2";
import * as jose from "npm:jose@5";

type Kind = "friend_request" | "friend_accepted" | "meetup_proposed" | "meetup_accepted" | "meetup_declined";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  const started = Date.now();
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  // Aufrufer bestimmen
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: { kind?: Kind; target?: string; meetup_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  const { kind, target, meetup_id } = body;
  if (!kind || !target || target === user.id) return json({ error: "invalid body" }, 400);
  console.log(`notify: ${kind} von ${user.id} an ${target}`);

  const admin = createClient(url, serviceKey);

  // Darf der Aufrufer dem Ziel diese Nachricht schicken?
  const allowed = await isAllowed(admin, kind, user.id, target, meetup_id);
  if (!allowed) return json({ error: "forbidden" }, 403);

  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID") ?? "de.koeven.meeterz";
  if (!keyId || !teamId || !privateKey) return json({ skipped: true, reason: "apns not configured" });

  const { data: sender } = await admin.from("profiles").select("display_name").eq("id", user.id).single();
  const name = sender?.display_name ?? "Jemand";

  let placeName: string | undefined;
  if (meetup_id) {
    const { data } = await admin.from("meetups").select("place_name").eq("id", meetup_id).single();
    placeName = data?.place_name;
  }
  const alert = message(kind, name, placeName);

  const { data: tokens } = await admin.from("device_tokens").select("token, environment").eq("user_id", target);
  if (!tokens?.length) return json({ sent: 0 });

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
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: JSON.stringify({ aps: { alert, sound: "default" }, kind }),
    });
    console.log(`notify: APNs ${host} → ${res.status} nach ${Date.now() - started} ms (${kind})`);
    if (res.ok) sent++;
    // Gerät abgemeldet oder Token ungültig → aufräumen
    if (res.status === 410 || res.status === 400) {
      await admin.from("device_tokens").delete().eq("token", t.token);
    }
  }
  console.log(`notify: ${sent} von ${tokens.length} gesendet, gesamt ${Date.now() - started} ms`);
  return json({ sent });
});

async function isAllowed(
  admin: ReturnType<typeof createClient>,
  kind: Kind,
  me: string,
  target: string,
  meetupId?: string,
): Promise<boolean> {
  switch (kind) {
    case "friend_request": {
      const { data } = await admin.from("friendships").select("id")
        .eq("requester", me).eq("addressee", target).limit(1);
      return !!data?.length;
    }
    case "friend_accepted": {
      const { data } = await admin.from("friendships").select("id")
        .eq("requester", target).eq("addressee", me).eq("status", "accepted").limit(1);
      return !!data?.length;
    }
    case "meetup_proposed": {
      if (!meetupId) return false;
      const { data } = await admin.from("meetups").select("id")
        .eq("id", meetupId).eq("from_user", me).eq("to_user", target).limit(1);
      return !!data?.length;
    }
    case "meetup_accepted":
    case "meetup_declined": {
      if (!meetupId) return false;
      const { data } = await admin.from("meetups").select("id")
        .eq("id", meetupId).eq("from_user", target).eq("to_user", me).limit(1);
      return !!data?.length;
    }
  }
}

function message(kind: Kind, name: string, place?: string) {
  switch (kind) {
    case "friend_request":
      return { title: "Neue Freundschaftsanfrage", body: `${name} möchte dich bei Meeterz hinzufügen.` };
    case "friend_accepted":
      return { title: "Anfrage angenommen", body: `${name} und du seht euch jetzt auf der Karte.` };
    case "meetup_proposed":
      return { title: `${name} möchte sich treffen`, body: place ? `Vorschlag: ${place}` : "Tippe, um den Vorschlag zu sehen." };
    case "meetup_accepted":
      return { title: "Treffen steht", body: `${name} kommt${place ? ` zu ${place}` : ""}.` };
    case "meetup_declined":
      return { title: "Treffen abgesagt", body: `${name} schafft es diesmal nicht.` };
  }
}
