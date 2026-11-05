// Firebase Cloud Messaging (Android) – HTTP v1.
// Secret FCM_SERVICE_ACCOUNT: kompletter Inhalt der JSON-Datei des Firebase-Dienstkontos.
import * as jose from "npm:jose@5";

type ServiceAccount = { project_id: string; client_email: string; private_key: string };

let cached: { token: string; until: number } | undefined;

function account(): ServiceAccount | undefined {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) return undefined;
  try { return JSON.parse(raw) as ServiceAccount; } catch { return undefined; }
}

export function fcmConfigured() { return !!account(); }

async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.until > Date.now() + 60_000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(await jose.importPKCS8(sa.private_key, "RS256"));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  const data = await res.json();
  cached = { token: data.access_token, until: Date.now() + (data.expires_in ?? 3600) * 1000 };
  return cached.token;
}

/**
 * Nachricht an ein Android-Gerät. notification = sichtbare Mitteilung (oder weglassen für stillen Push),
 * data = Werte für die App. Liefert „gone“, wenn das Token nicht mehr gilt (dann löschen).
 */
export async function sendFcm(
  token: string,
  data: Record<string, string>,
  notification?: { title: string; body: string },
): Promise<"ok" | "gone" | "error"> {
  const sa = account();
  if (!sa) return "error";
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${await accessToken(sa)}`, "content-type": "application/json" },
    body: JSON.stringify({
      message: {
        token,
        data,
        ...(notification ? { notification } : {}),
        android: { priority: "HIGH", ttl: notification ? "86400s" : "60s" },
      },
    }),
  });
  if (res.ok) return "ok";
  const text = await res.text();
  console.log(`FCM → ${res.status}: ${text.slice(0, 200)}`);
  // Nur „Gerät unbekannt“ heißt Token löschen – INVALID_ARGUMENT kann auch an der Nachricht liegen
  return res.status === 404 || text.includes("UNREGISTERED") ? "gone" : "error";
}
