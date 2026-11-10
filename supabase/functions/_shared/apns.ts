// Apple Push (APNs) – gemeinsames Anmeldetoken für notify, request_location und live_activity.
// Apple erlaubt höchstens alle 20 Minuten ein neues Anmeldetoken; wer öfter neu signiert, bekommt
// 429 „TooManyProviderTokenUpdates“ – genau so ging eine Treffen-Einladung verloren.
// Deshalb: Ausstellungszeit (iat) auf feste 40-Minuten-Fenster runden – alle Funktionen und Instanzen
// nutzen dann dieselbe Zeit – und das Token pro Instanz zwischenspeichern. Apple akzeptiert es bis 60 Minuten.
import * as jose from "npm:jose@5";

const WINDOW = 40 * 60;
let cached: { iat: number; jwt: string } | undefined;

export const apnsBundleId = () => Deno.env.get("APNS_BUNDLE_ID") ?? "de.koeven.meeterz";

export function apnsConfigured() {
  return !!(Deno.env.get("APNS_KEY_ID") && Deno.env.get("APNS_TEAM_ID") && Deno.env.get("APNS_PRIVATE_KEY"));
}

async function jwt(): Promise<string> {
  const iat = Math.floor(Date.now() / 1000 / WINDOW) * WINDOW;
  if (cached?.iat === iat) return cached.jwt;
  const token = await new jose.SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID")! })
    .setIssuer(Deno.env.get("APNS_TEAM_ID")!)
    .setIssuedAt(iat)
    .sign(await jose.importPKCS8(Deno.env.get("APNS_PRIVATE_KEY")!, "ES256"));
  cached = { iat, jwt: token };
  return token;
}

/** Sendet an ein Gerät. reason = Apples Begründung bei Fehlern (z. B. „BadDeviceToken“, „TooManyProviderTokenUpdates“). */
export async function sendApns(
  deviceToken: string,
  environment: string | null | undefined,
  headers: Record<string, string>,
  payload: unknown,
): Promise<{ status: number; reason: string; host: string }> {
  const host = environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: { authorization: `bearer ${await jwt()}`, ...headers },
    body: JSON.stringify(payload),
  });
  let reason = "";
  if (!res.ok) {
    try { reason = (await res.json()).reason ?? ""; } catch { /* leerer Body */ }
  }
  return { status: res.status, reason, host };
}

/** Token gilt nicht mehr → aus device_tokens löschen. Nicht bei 400 aus anderen Gründen (z. B. kaputte Nachricht). */
export const apnsTokenGone = (r: { status: number; reason: string }) =>
  r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "DeviceTokenNotForTopic";
