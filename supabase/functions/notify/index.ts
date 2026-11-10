// Meeterz – Push-Benachrichtigungen über APNs (iPhone) und FCM (Android).
// Aufruf aus der App: functions.invoke("notify", { kind, target, meetup_id? })
// Prüft, ob der Aufrufer dem Empfänger wirklich etwas schicken darf, und sendet dann an alle Geräte des Empfängers.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (Inhalt der .p8-Datei), APNS_BUNDLE_ID (de.koeven.meeterz)
//   FCM_SERVICE_ACCOUNT (JSON des Firebase-Dienstkontos)
// Ohne Secrets antwortet die Funktion mit { skipped: true } – die App funktioniert normal weiter.

import { createClient } from "npm:@supabase/supabase-js@2";
import { apnsBundleId, apnsConfigured, apnsTokenGone, sendApns } from "../_shared/apns.ts";
import { fcmConfigured, sendFcm } from "../_shared/fcm.ts";

type Kind = "friend_request" | "friend_accepted" | "meetup_proposed" | "meetup_accepted" | "meetup_declined" | "meetup_departed"
  | "message";

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

  let body: { kind?: Kind; target?: string; meetup_id?: string; message_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid body" }, 400);
  }
  const { kind, target, meetup_id, message_id } = body;
  if (!kind || !target || target === user.id) return json({ error: "invalid body" }, 400);
  console.log(`notify: ${kind} von ${user.id} an ${target}`);

  const admin = createClient(url, serviceKey);

  // Darf der Aufrufer dem Ziel diese Nachricht schicken?
  const allowed = await isAllowed(admin, kind, user.id, target, meetup_id, message_id);
  if (!allowed) return json({ error: "forbidden" }, 403);

  const apns = apnsConfigured();
  if (!apns && !fcmConfigured()) return json({ skipped: true, reason: "push not configured" });

  const { data: sender } = await admin.from("profiles").select("display_name").eq("id", user.id).single();
  const name = sender?.display_name ?? "Jemand";

  let placeName: string | undefined;
  if (meetup_id) {
    const { data } = await admin.from("meetups").select("place_name").eq("id", meetup_id).single();
    placeName = data?.place_name;
  }
  let text: string | undefined;
  if (kind === "message" && message_id) {
    const { data } = await admin.from("messages").select("body").eq("id", message_id).single();
    text = data?.body;
  }
  const alert = message(kind, name, placeName, text);

  const { data: all } = await admin.from("device_tokens").select("token, environment, platform").eq("user_id", target);
  if (!all?.length) return json({ sent: 0 });

  let sent = 0;
  // Android (FCM): Texte kommen fertig auf Deutsch (title/body)
  for (const t of all.filter((t) => t.platform === "android")) {
    const r = await sendFcm(t.token, { kind, meetup_id: meetup_id ?? "", message_id: message_id ?? "" },
      { title: alert.title, body: alert.body });
    console.log(`notify: FCM → ${r} (${kind})`);
    if (r === "ok") sent++;
    if (r === "gone") await admin.from("device_tokens").delete().eq("token", t.token);
  }
  const tokens = all.filter((t) => t.platform !== "android");
  if (!tokens.length || !apns) return json({ sent });

  for (const t of tokens) {
    const r = await sendApns(t.token, t.environment, {
      "apns-topic": apnsBundleId(),
      "apns-push-type": "alert",
      "apns-priority": "10",
    }, { aps: { alert, sound: "default" }, kind });
    console.log(`notify: APNs ${r.host} → ${r.status} ${r.reason} nach ${Date.now() - started} ms (${kind})`);
    if (r.status === 200) sent++;
    if (apnsTokenGone(r)) await admin.from("device_tokens").delete().eq("token", t.token);
  }
  console.log(`notify: ${sent} von ${all.length} gesendet, gesamt ${Date.now() - started} ms`);
  return json({ sent });
});

async function isAllowed(
  admin: ReturnType<typeof createClient>,
  kind: Kind,
  me: string,
  target: string,
  meetupId?: string,
  messageId?: string,
): Promise<boolean> {
  switch (kind) {
    case "message": {
      if (!messageId) return false;
      const { data } = await admin.from("messages").select("id")
        .eq("id", messageId).eq("from_user", me).eq("to_user", target).limit(1);
      return !!data?.length;
    }
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
    case "meetup_departed": {
      // Nur an Treffpartner: angenommenes Treffen zwischen beiden – oder beide haben im selben Gruppen-Treffen zugesagt
      if (!meetupId) return false;
      const { data: m } = await admin.from("meetups").select("from_user, to_user, group_id, status").eq("id", meetupId).single();
      if (!m || m.status !== "accepted" || ![m.from_user, m.to_user].includes(me)) return false;
      if ([m.from_user, m.to_user].includes(target)) return true;
      if (!m.group_id) return false;
      const { data } = await admin.from("meetups").select("id").eq("group_id", m.group_id).eq("status", "accepted")
        .or(`from_user.eq.${target},to_user.eq.${target}`).limit(1);
      return !!data?.length;
    }
    case "meetup_accepted":
    case "meetup_declined": {
      if (!meetupId) return false;
      // Nur wenn das Treffen wirklich so entschieden ist (sonst ließe sich ein falsches „Treffen steht“ auslösen)
      const { data } = await admin.from("meetups").select("id")
        .eq("id", meetupId).eq("from_user", target).eq("to_user", me)
        .eq("status", kind === "meetup_accepted" ? "accepted" : "declined").limit(1);
      return !!data?.length;
    }
  }
}

// Texte übersetzt das iPhone selbst (in der Sprache der App): loc-key/loc-args verweisen auf Einträge in
// Localizable.xcstrings (push.*). title/body bleiben als Rückfall für ältere App-Versionen – und für Android.
function message(kind: Kind, name: string, place?: string, text?: string) {
  const loc = (key: string, args: string[], titleArgs: string[] = []) => ({
    "title-loc-key": `push.${key}.title`, "title-loc-args": titleArgs,
    "loc-key": `push.${key}.body`, "loc-args": args,
  });
  switch (kind) {
    case "message":
      return text
        ? { title: name, body: text }   // Nachricht selbst wird nicht übersetzt
        : { title: name, body: "Neue Nachricht", "loc-key": "push.message.empty", "loc-args": [] };
    case "friend_request":
      return { title: "Neue Freundschaftsanfrage", body: `${name} möchte dich bei Meeterz hinzufügen.`, ...loc("friend_request", [name]) };
    case "friend_accepted":
      return { title: "Anfrage angenommen", body: `${name} und du seht euch jetzt auf der Karte.`, ...loc("friend_accepted", [name]) };
    case "meetup_proposed":
      return place
        ? { title: `${name} möchte sich treffen`, body: `Vorschlag: ${place}`, ...loc("meetup_proposed", [place], [name]) }
        : { title: `${name} möchte sich treffen`, body: "Tippe, um den Vorschlag zu sehen.", ...loc("meetup_proposed_noplace", [], [name]) };
    case "meetup_accepted":
      return place
        ? { title: "Treffen steht", body: `${name} kommt zu ${place}.`, ...loc("meetup_accepted", [name, place]) }
        : { title: "Treffen steht", body: `${name} kommt.`, ...loc("meetup_accepted_noplace", [name]) };
    case "meetup_declined":
      return { title: "Treffen abgesagt", body: `${name} schafft es diesmal nicht.`, ...loc("meetup_declined", [name]) };
    case "meetup_departed":
      return place
        ? { title: `${name} ist losgefahren`, body: `Auf dem Weg zu ${place}.`, ...loc("meetup_departed", [place], [name]) }
        : { title: `${name} ist losgefahren`, body: "Auf dem Weg zum Treffpunkt.", ...loc("meetup_departed_noplace", [], [name]) };
  }
}
