// Meeterz – Spritpreise für Tankstellen (Markttransparenzstelle für Kraftstoffe über Tankerkönig, CC BY 4.0).
// Aufruf aus der App: functions.invoke("fuel-prices", { points: [{ lat, lng }, …] })   (höchstens 10)
// Antwort: { prices: [{ e5, e10, diesel, open, brand } | null, …] } in derselben Reihenfolge – null, wenn im
// Umkreis von 150 m keine gemeldete Tankstelle liegt. Ohne Secret TANKERKOENIG_API_KEY: { prices: [] }.
// Schreibt nichts in die Datenbank.

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

type Station = { lat: number; lng: number; dist: number; brand?: string; e5?: number | false; e10?: number | false; diesel?: number | false; isOpen?: boolean };

const num = (v: unknown) => (typeof v === "number" && v > 0 ? v : null);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const key = Deno.env.get("TANKERKOENIG_API_KEY");
  if (!key) return json({ prices: [] });

  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let points: { lat: number; lng: number }[];
  try {
    points = ((await req.json()).points ?? []).slice(0, 10);
  } catch {
    return json({ error: "invalid body" }, 400);
  }

  const prices = await Promise.all(points.map(async (p) => {
    if (typeof p?.lat !== "number" || typeof p?.lng !== "number") return null;
    try {
      const url = `https://creativecommons.tankerkoenig.de/json/list.php?lat=${p.lat}&lng=${p.lng}&rad=1&sort=dist&type=all&apikey=${key}`;
      const res = await fetch(url, { signal: AbortSignal.timeout(4000) });
      const body = await res.json();
      const s: Station | undefined = body?.ok ? body.stations?.[0] : undefined;
      if (!s || s.dist > 0.15) return null;
      return { e5: num(s.e5), e10: num(s.e10), diesel: num(s.diesel), open: s.isOpen ?? null, brand: s.brand || null };
    } catch {
      return null;
    }
  }));
  return json({ prices });
});
