// curate-dispatch — the per-user "local midnight" sweep.
//
// Cloud Scheduler pokes this every 15 minutes. Each run it finds users whose
// LOCAL time is in the midnight hour (00:00–00:59) and hands each one off to
// curate-recipes with their LOCAL date as feed_date. curate-recipes is
// idempotent per (user, feed_date), so repeated ticks within that hour (and
// retries after a failure) never double-curate.
//
// Because users live in many timezones, this naturally spreads curation —
// and therefore image painting — across the whole day instead of one spike.
//
// POST {}                      — normal sweep (used by the scheduler)
// POST { ignore_hour: true }   — TEST: curate every pantry owner now
// POST { only_user_id: "..." } — TEST: restrict the sweep to one user

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Shared secret so only our scheduler can trigger paid curation. Optional:
// if unset (e.g. local dev) the guard is skipped.
const CRON_SECRET = Deno.env.get("CRON_SECRET") || "";

// Local clock for a timezone. Invalid zone → falls back to UTC.
function localParts(tz: string): { hour: number; date: string } {
  try {
    const fmt = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz, hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit",
    });
    const p = Object.fromEntries(fmt.formatToParts(new Date()).map((x) => [x.type, x.value]));
    return { hour: Number(p.hour), date: `${p.year}-${p.month}-${p.day}` };
  } catch {
    const now = new Date();
    return { hour: now.getUTCHours(), date: now.toISOString().slice(0, 10) };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: {
      "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST,OPTIONS", "Access-Control-Allow-Headers": "authorization,content-type",
    }});
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (CRON_SECRET && req.headers.get("X-Cron-Secret") !== CRON_SECRET) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    let body: { ignore_hour?: boolean; only_user_id?: string } = {};
    try { body = await req.json(); } catch { /* empty ok */ }

    // Curate-able universe = users who own a pantry (no pantry, nothing to match).
    const { data: pantryRows, error: pErr } = await supabase.from("pantry_items").select("user_id");
    if (pErr) throw new Error(`pantry scan failed: ${pErr.message}`);
    let userIds = Array.from(new Set((pantryRows || []).map((r) => r.user_id as string)));
    if (body.only_user_id) userIds = userIds.filter((u) => u === body.only_user_id);

    // Timezone per user (default UTC).
    const { data: prefRows } = await supabase.from("user_preferences").select("user_id, timezone");
    const tzMap = new Map<string, string>((prefRows || []).map((r) => [r.user_id as string, (r.timezone as string) || "UTC"]));

    const due: Array<{ user_id: string; tz: string; feed_date: string }> = [];
    for (const u of userIds) {
      const tz = tzMap.get(u) || "UTC";
      const { hour, date } = localParts(tz);
      if (body.ignore_hour || hour === 0) due.push({ user_id: u, tz, feed_date: date });
    }

    console.log(`[curate-dispatch] users=${userIds.length} due=${due.length}${body.ignore_hour ? " (ignore_hour)" : ""}`);

    // Hand each due user to curate-recipes (idempotent per user+date). Awaited
    // sequentially — fine at current scale; swap to a queue if user count grows.
    const results: Array<{ user_id: string; feed_date: string; ok: boolean; detail: unknown }> = [];
    for (const d of due) {
      try {
        const res = await fetch(`${SUPABASE_URL}/functions/v1/curate-recipes`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
          body: JSON.stringify({ user_id: d.user_id, feed_date: d.feed_date }),
        });
        const detail = await res.json().catch(() => ({}));
        results.push({ user_id: d.user_id, feed_date: d.feed_date, ok: res.ok, detail });
      } catch (e) {
        results.push({ user_id: d.user_id, feed_date: d.feed_date, ok: false, detail: e instanceof Error ? e.message : String(e) });
      }
    }

    return Response.json({ scanned: userIds.length, due: due.length, results });
  } catch (err) {
    console.error(`[curate-dispatch] error: ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
