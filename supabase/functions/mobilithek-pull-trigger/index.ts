import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const IDS = ["1056915110420725760","1056915179165368320","1056913546423484416","1056917947838021632","1056915353379979264","1056915306466463744","1056915693588140032","1056920167799017472","1056920190960160768","1056919536728457216","1056916219461586944","1056918955762827264","1056918851660201984","1056915138941964288","1056918149969694720","1056913657522180096","1056918039340929024","1056913437358997504","1056913498004439040","1056918928608874496","1056915778602713088","1056917917303263232","1056919356755066880","1056916095234887680","1056918636916002816","1056915073162498048","1056918420036960256","1056916406074757120","1056914847391698944","1056916033104662528","1056920042083368960","1056918810362859520","1056915607667822592","1056918542372225024","1056913228147113984","1056916252898578432","1056919482512855040","1056915263680368640","1056914944053432320","1056919099534954496","1056915903651467264","1056918671263158272","1056918700702978048","1056920074568253440","1056916064599691264","1056915957103902720","1056919041221545984","1056919623902842880","1056915543772020736","1056920007773933568","1056915395385905152","1056918601717432320","1056918497069322240","1056918461250162688","1056919507682873344","1056916183344631808","1056917977558831104","1056919132720484352","1056915810601029632","1056919438506246144","1056915440256372736","1056918769518727168","1056919396583952384","1056919003238125568","1056918734563397632","1056915210345795584","1056915861792509952","1056916370167349248","1056916124141834240","1056916151031517184"];
const BATCH_SIZE = 10;

async function runPull(
  supabaseUrl: string,
  serviceKey: string,
  admin: ReturnType<typeof createClient>,
  subscriptionIds: string[],
  forceMapping: boolean
) {
  const failures: string[] = [];
  const completedIds = new Set<string>();
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
      if (!response.ok || !Array.isArray(payload.results)) {
        failures.push(`subscriptions ${ids.join(",")}: HTTP ${response.status} ${raw.slice(0, 500)}`);
      } else {
        for (const result of payload.results as Array<{ subscriptionId?: string; classification?: string }>) {
          if (result.subscriptionId && !["HTTP_ERROR", "NON_JSON", "PROCESSING_ERROR"].includes(String(result.classification))) {
            completedIds.add(result.subscriptionId);
          } else if (result.subscriptionId) {
            failures.push(`subscription ${result.subscriptionId}: ${result.classification ?? "unknown failure"}`);
          }
        }
        console.log("Mobilithek targeted group completed", ids.length, JSON.stringify(payload.results).slice(0, 1000));
      }
    } catch (error) {
      failures.push(`subscriptions ${ids.join(",")}: ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  try {
    for (let i = 0; i < groups.length; i += 2) {
      await Promise.all(groups.slice(i, i + 2).map(runGroup));
    }
    if (forceMapping) {
      const { data: current, error: readError } = await admin.from("mobilithek_mapping_bootstrap")
        .select("completed_subscriptions").eq("id", true).maybeSingle();
      if (readError) failures.push("mapping bootstrap progress read failed: " + readError.message);
      else {
        const merged = [...new Set([...(current?.completed_subscriptions ?? []), ...completedIds])];
        const isComplete = IDS.every(id => merged.includes(id));
        const { error } = await admin.from("mobilithek_mapping_bootstrap")
          .update({ completed_subscriptions: merged, completed_at: isComplete ? new Date().toISOString() : null }).eq("id", true);
        if (error) failures.push("mapping bootstrap progress update failed: " + error.message);
        if (!isComplete) console.log("Mobilithek mapping bootstrap remains partial", { completed: merged.length, total: IDS.length });
      }
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
    const body = await req.json().catch(() => ({})) as { operators?: unknown };
    const rawOperators = Array.isArray(body.operators) ? body.operators : [];
    if (rawOperators.length > 500 || rawOperators.some(name => typeof name !== "string" || !name.trim() || name.length > 100)) {
      return Response.json({ ok: false, error: "INVALID_OPERATORS", maxOperators: 500 }, { status: 400 });
    }
    const operators = [...new Set((rawOperators as string[]).map(name => name.trim().toLowerCase()))];

    const { data: bootstrap, error: bootstrapError } = await admin.from("mobilithek_mapping_bootstrap")
      .select("completed_at,completed_subscriptions").eq("id", true).maybeSingle();
    if (bootstrapError) throw new Error("Could not read mapping bootstrap state: " + bootstrapError.message);

    const forceMapping = !bootstrap?.completed_at;
    let subscriptionIds: string[];
    if (forceMapping) {
      // One-time initial mapping: learn which Mobilithek subscription contains each EVSE ID.
      // Successfully processed subscriptions are not fetched again if another batch fails.
      const completed = bootstrap?.completed_subscriptions ?? [];
      subscriptionIds = IDS.filter(id => !completed.includes(id));
      if (!subscriptionIds.length) {
        await admin.from("mobilithek_mapping_bootstrap")
          .update({ completed_at: new Date().toISOString() }).eq("id", true);
        return Response.json({ ok: true, status: "mapping_bootstrap_complete", targetedSubscriptions: 0 });
      }
    } else {
      if (!operators.length) return Response.json({ ok: true, status: "no_route_operators", targetedSubscriptions: 0 });
      const { data, error } = await admin.rpc("mobilithek_subscriptions_for_operators", { p_operator_keys: operators });
      if (error) throw new Error("Could not resolve route EVSE IDs to subscriptions: " + error.message);
      subscriptionIds = [...new Set((data ?? []).map((row: { subscription_id: string }) => row.subscription_id))]
        .filter(id => IDS.includes(id));
      if (!subscriptionIds.length) {
        return Response.json({ ok: true, status: "no_matching_subscriptions", routeOperators: operators.length, targetedSubscriptions: 0 });
      }
    }

    const cooldown = forceMapping ? 180 : 15;
    const { data: claimed, error } = await admin.rpc("claim_mobilithek_pull", { p_cooldown_seconds: cooldown, p_lease_seconds: 600 });
    if (error) throw new Error("Could not claim Mobilithek pull: " + error.message);
    if (!claimed) return Response.json({ ok: true, status: "already_running_or_recent", cooldownSeconds: cooldown, targetedSubscriptions: subscriptionIds.length });
    EdgeRuntime.waitUntil(runPull(supabaseUrl, serviceKey, admin, subscriptionIds, forceMapping));
    return Response.json({
      ok: true, status: "started", bootstrap: forceMapping, routeOperators: operators.length,
      targetedSubscriptions: subscriptionIds.length, batches: Math.ceil(subscriptionIds.length / BATCH_SIZE),
      cooldownSeconds: cooldown, dynamicRefreshSeconds: 180, staticRefreshSeconds: 43200
    }, { status: 202 });
  } catch (error) {
    console.error("mobilithek-pull-trigger failed", error);
    return Response.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});
