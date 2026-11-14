import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const BATCHES = [0, 1, 2, 3, 4, 5, 6];

async function runPull(supabaseUrl: string, serviceKey: string, admin: ReturnType<typeof createClient>) {
  const failures: string[] = [];
  const runBatch = async (batch: number) => {
    try {
      const response = await fetch(
        `${supabaseUrl}/functions/v1/mobilithek-pull?batch=${batch}&mode=commit`,
        {
          method: "GET",
          headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey },
          signal: AbortSignal.timeout(140_000)
        }
      );
      const raw = await response.text();
      let payload: Record<string, unknown> = {};
      try { payload = JSON.parse(raw); } catch { /* handled below */ }
      if (!response.ok || payload.ok !== true) failures.push(`batch ${batch}: HTTP ${response.status} ${raw.slice(0, 500)}`);
      else console.log("Mobilithek batch completed", batch, JSON.stringify(payload.results ?? []).slice(0, 1200));
    } catch (error) {
      failures.push(`batch ${batch}: ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  try {
    await Promise.all([runBatch(0), runBatch(1)]);
    await Promise.all([runBatch(2), runBatch(3)]);
    await Promise.all([runBatch(4), runBatch(5)]);
    await runBatch(6);
    const { error } = await admin.rpc("complete_mobilithek_pull", { p_error: failures.length ? failures.join("\n") : null });
    if (error) console.error("Could not finalize Mobilithek pull lease", error.message);
    if (failures.length) console.error("Mobilithek pull finished with failures", failures.join("\n"));
    else console.log("Mobilithek pull finished successfully");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("Mobilithek pull orchestration failed", message);
    await admin.rpc("complete_mobilithek_pull", { p_error: message });
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return Response.json({ ok: false, error: "METHOD_NOT_ALLOWED" }, { status: 405 });
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return Response.json({ ok: false, error: "MISSING_SERVER_CONFIGURATION" }, { status: 500 });
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    const { data: claimed, error } = await admin.rpc("claim_mobilithek_pull", { p_cooldown_seconds: 180, p_lease_seconds: 600 });
    if (error) throw new Error("Could not claim Mobilithek pull: " + error.message);
    if (!claimed) return Response.json({ ok: true, status: "already_running_or_recent", cooldownSeconds: 180 }, { status: 202 });
    EdgeRuntime.waitUntil(runPull(supabaseUrl, serviceKey, admin));
    return Response.json({
      ok: true, status: "started", batches: BATCHES.length,
      cooldownSeconds: 180, dynamicRefreshSeconds: 180, staticRefreshSeconds: 43200
    }, { status: 202 });
  } catch (error) {
    console.error("mobilithek-pull-trigger failed", error);
    return Response.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});