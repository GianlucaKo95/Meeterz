// Meeterz – Empfänger für Mobilithek-Push (AFIR-Ladesäulendaten, DATEX II v3 JSON).
// Die Mobilithek schickt abonnierte Datenpakete per HTTPS-POST (gzip) an diese Adresse:
//   https://jgtkyxlzroajtxboqgcn.supabase.co/functions/v1/mobilithek-push
// Schritt 1 (jetzt): Pakete annehmen und Aufbau protokollieren, damit die Auswertung an den echten Daten
// entsteht. Schritt 2: Belegung und Preise je Ladepunkt in eine Tabelle schreiben, die beide Apps abfragen.
// Ohne JWT (die Mobilithek hat keins) – darum nichts zurückgeben und nur lesen/protokollieren.

Deno.serve(async (req) => {
  if (req.method === "HEAD" || req.method === "GET") return new Response(null, { status: 200 });
  if (req.method !== "POST") return new Response(null, { status: 405 });
  const headers = Object.fromEntries([...req.headers].filter(([k]) => !/authorization|cookie/i.test(k)));
  let text = "";
  try {
    const raw = new Uint8Array(await req.arrayBuffer());
    // gzip (Content-Encoding oder ohne Kennzeichnung)
    const gz = raw.length > 2 && raw[0] === 0x1f && raw[1] === 0x8b;
    const bytes = gz
      ? new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new DecompressionStream("gzip"))).arrayBuffer())
      : raw;
    text = new TextDecoder().decode(bytes);
    console.log(`mobilithek-push: ${raw.length} B${gz ? " gzip" : ""} → ${bytes.length} B, Header ${JSON.stringify(headers)}`);
    // Struktur in Kurzform: Schlüssel der obersten Ebenen und ein Ausschnitt
    try {
      const json = JSON.parse(text);
      const keys = (o: unknown, depth: number): unknown =>
        depth === 0 || typeof o !== "object" || o === null ? typeof o
          : Array.isArray(o) ? [o.length, keys(o[0], depth - 1)]
          : Object.fromEntries(Object.entries(o).slice(0, 12).map(([k, v]) => [k, keys(v, depth - 1)]));
      console.log(`mobilithek-push: Aufbau ${JSON.stringify(keys(json, 6)).slice(0, 3000)}`);
    } catch {
      console.log("mobilithek-push: kein JSON");
    }
    console.log(`mobilithek-push: Ausschnitt ${text.slice(0, 2500)}`);
  } catch (e) {
    console.log(`mobilithek-push: Fehler beim Lesen: ${e}`);
  }
  return new Response(null, { status: 200 });
});
