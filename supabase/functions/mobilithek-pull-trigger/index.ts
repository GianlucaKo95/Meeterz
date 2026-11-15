import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const IDS = ["1056915110420725760","1056915179165368320","1056913546423484416","1056917947838021632","1056915353379979264","1056915306466463744","1056915693588140032","1056920167799017472","1056920190960160768","1056919536728457216","1056916219461586944","1056918955762827264","1056918851660201984","1056915138941964288","1056918149969694720","1056913657522180096","1056918039340929024","1056913437358997504","1056913498004439040","1056918928608874496","1056915778602713088","1056917917303263232","1056919356755066880","1056916095234887680","1056918636916002816","1056915073162498048","1056918420036960256","1056916406074754752","1056914847391698944","1056916033104662528","1056920042083368960","1056918810362859520","1056915607667822592","1056918542372225024","1056913228147113984","1056916252898578432","1056919482512855040","1056915263680368640","1056914944053432320","1056919099534954496","1056915903651467264","1056918671263158272","1056918700702978048","1056920074568253440","1056916064599691264","1056915957103902720","1056919041221545984","1056919623902842880","1056915543772020736","1056920007773933568","1056915395385905152","1056918601717432320","1056918497069322240","1056918461250162688","1056919507682873344","1056916183344631808","1056917977558831104","1056919132720484352","1056915810601029632","1056919438506246144","1056915440256372736","1056918769518727168","1056919396583952384","1056919003238125568","1056918734563397632","1056915210345795584","1056915861792509952","1056916370167349248","1056916124141834240","1056916151031517184"];
const BATCH_SIZE = 10;

async function runPull(
  supabaseUrl: string,
  serviceKey: string,
  admin: ReturnType<typeof createClient>,
  subscriptionIds: string[],
  forceMapping: boolean
) {
  const failures: string[] = [];
  const groups: string[][] = [];
  for (let i = 0; i < subscriptionIds.length; i += BATCH_SIZE) groups.push(subscriptionIds.slice(i, i + BATCH_SIZE));

  const runGroup = async (ids: string[]) => {
    try {
      const query = new URLSearchParams({ ids: ids.join(","), mode: "commit", ...(forceMapping ? { forceMapping: "1" } : {}) });
      const response = await fetch(`${supabaseUrl}/functions/v1/mobilithek-pull?${query.toString()}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey },
        signal: AbortSignal.timeout(140_000)
      });
      const raw = await response.text();
      let payload: Record<string, unknown> = {};
      try { payload = JSON.parse(raw); } catch { /* handled below */ }
      if (!response.ok || payload.ok !== true) failures.push(`subscriptions ${ids.join(",")}: HTTP ${response.status} ${raw.slice(0, 500)}`);
      else console.log("Mobilithek targeted group completed", ids.length, JSON.stringify(payload.results ?? []).slice(0, 1000));
    } catch (error) {
      failures.push(`subscriptions ${ids.join(",")}: ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  try {
    for (let i = 0; i < groups.length; i += 2) {
      await Promise.all(groups.slice(i, i + 2).map(runGroup));
    }
    if (forceMapping && failures.length === 0) {
      const { error } = await admin.from("mobilithek_mapping_bootstrap")
        .update({ completed_at: new Date().toISOString() }).eq("id", true);
      if (error) failures.push("mapping bootstrap completion failed: " + error.message);
    }
    const { error } = await admin.rpc("complete_mobilithek_pull", { p_error: failures.length ? failures.join("\n") : null });
    if (error) console.error("Could not finalize Mobilithek pull lease", error.message);
    if (failures.length) console.error("Mobilithek pull finished with failures", failures.join("\n"));
    else console.log("Mobilithek pull finished successfully", { subscriptions: subscriptionIds.length, bootstrap: forceMapping });
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
    const body = await req.json().catch(() => ({})) as { evseIds?: unknown };
    const rawIds = Array.isArray(body.evseIds) ? body.evseIds : [];
    if (rawIds.length > 2000 || rawIds.some(id => typeof id !== "string" || !id.trim() || id.length > 100)) {
      return Response.json({ ok: false, error: "INVALID_EVSE_IDS", maxIds: 2000 }, { status: 400 });
    }
    const evseIds = [...new Set((rawIds as string[]).map(id => id.trim()))];

    const { data: bootstrap, error: bootstrapError } = await admin.from("mobilithek_mapping_bootstrap")
      .select("completed_at").eq("id", true).maybeSingle();
    if (bootstrapError) throw new Error("Could not read mapping bootstrap state: " + bootstrapError.message);

    const forceMapping = !bootstrap?.completed_at;
    let subscriptionIds: string[];
    if (forceMapping) {
      // One-time initial mapping: learn which Mobilithek subscription contains each EVSE ID.
      subscriptionIds = IDS;
    } else {
      if (!evseIds.length) return Response.json({ ok: true, status: "no_route_evse_ids", targetedSubscriptions: 0 });
      const { data, error } = await admin.rpc("mobilithek_subscriptions_for_points", { p_point_ids: evseIds });
      if (error) throw new Error("Could not resolve route EVSE IDs to subscriptions: " + error.message);
      subscriptionIds = [...new Set((data ?? []).map((row: { subscription_id: string }) => row.subscription_id))]
        .filter(id => IDS.includes(id));
      if (!subscriptionIds.length) {
        return Response.json({ ok: true, status: "no_matching_subscriptions", routeEvseIds: evseIds.length, targetedSubscriptions: 0 });
      }
    }

    const cooldown = forceMapping ? 180 : 15;
    const { data: claimed, error } = await admin.rpc("claim_mobilithek_pull", { p_cooldown_seconds: cooldown, p_lease_seconds: 600 });
    if (error) throw new Error("Could not claim Mobilithek pull: " + error.message);
    if (!claimed) return Response.json({ ok: true, status: "already_running_or_recent", cooldownSeconds: cooldown, targetedSubscriptions: subscriptionIds.length });
    EdgeRuntime.waitUntil(runPull(supabaseUrl, serviceKey, admin, subscriptionIds, forceMapping));
    return Response.json({
      ok: true, status: "started", bootstrap: forceMapping, routeEvseIds: evseIds.length,
      targetedSubscriptions: subscriptionIds.length, batches: Math.ceil(subscriptionIds.length / BATCH_SIZE),
      cooldownSeconds: cooldown, dynamicRefreshSeconds: 180, staticRefreshSeconds: 43200
    }, { status: 202 });
  } catch (error) {
    console.error("mobilithek-pull-trigger failed", error);
    return Response.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});
