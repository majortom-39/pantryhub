// paint-drain — throttled image worker.
//
// The curator writes recipes with image_url=null; this drains them at a
// controlled pace so we never hammer deAPI (which 429s easily). Designed to be
// poked on a schedule (Cloud Scheduler every few minutes): each run paints a
// small batch, one image at a time, with exponential backoff + retry on rate
// limits. Idempotent — paint-recipe skips anything already painted.
//
// POST { limit?, user_id? }
//   limit   — max recipes to paint this run (default 6)
//   user_id — restrict to one user (optional; default: any user)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Shared secret so only our scheduler can trigger paid painting. Optional.
const CRON_SECRET = Deno.env.get("CRON_SECRET") || "";

const DEFAULT_LIMIT = 6;
const GAP_MS = 1_500;          // breather between successful paints
const MAX_RETRIES = 4;         // per recipe, on rate-limit / transient error
const BACKOFF_BASE_MS = 4_000; // 4s, 8s, 16s, 32s

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const isRateLimited = (status: number, bodyText: string) =>
  status === 429 || /too many|rate limit|429/i.test(bodyText);

async function paintOne(recipeId: string): Promise<{ ok: boolean; skipped?: boolean; error?: string; attempts: number }> {
  let attempt = 0;
  while (attempt <= MAX_RETRIES) {
    attempt++;
    try {
      const res = await fetch(`${SUPABASE_URL}/functions/v1/paint-recipe`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
        body: JSON.stringify({ recipe_id: recipeId }),
      });
      const text = await res.text();
      if (res.ok) {
        let skipped = false;
        try { skipped = !!JSON.parse(text).skipped; } catch { /* ignore */ }
        return { ok: true, skipped, attempts: attempt };
      }
      if (isRateLimited(res.status, text) && attempt <= MAX_RETRIES) {
        const wait = BACKOFF_BASE_MS * 2 ** (attempt - 1);
        console.warn(`[paint-drain] ${recipeId} rate-limited (try ${attempt}); waiting ${wait}ms`);
        await sleep(wait);
        continue;
      }
      return { ok: false, error: `${res.status}: ${text.slice(0, 200)}`, attempts: attempt };
    } catch (e) {
      if (attempt <= MAX_RETRIES) { await sleep(BACKOFF_BASE_MS * 2 ** (attempt - 1)); continue; }
      return { ok: false, error: e instanceof Error ? e.message : String(e), attempts: attempt };
    }
  }
  return { ok: false, error: "exhausted retries", attempts: attempt };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST,OPTIONS", "Access-Control-Allow-Headers": "authorization,content-type" },
    });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (CRON_SECRET && req.headers.get("X-Cron-Secret") !== CRON_SECRET) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    let body: { limit?: number; user_id?: string } = {};
    try { body = await req.json(); } catch { /* empty ok */ }
    const limit = Math.max(1, Math.min(Number(body.limit) || DEFAULT_LIMIT, 20));

    let q = supabase.from("recipes").select("id, name").is("image_url", null)
      .order("created_at", { ascending: true }).limit(limit);
    if (body.user_id) q = q.eq("user_id", body.user_id);
    const { data: pending, error } = await q;
    if (error) throw new Error(`pending query failed: ${error.message}`);

    if (!pending || pending.length === 0) {
      return Response.json({ drained: 0, remaining: 0, results: [] });
    }

    const results: Array<{ recipe_id: string; name: string; ok: boolean; skipped?: boolean; error?: string; attempts: number }> = [];
    for (let i = 0; i < pending.length; i++) {
      const r = pending[i];
      const out = await paintOne(r.id);
      results.push({ recipe_id: r.id, name: r.name, ...out });
      if (out.ok && !out.skipped && i < pending.length - 1) await sleep(GAP_MS);
    }

    // How many still need painting after this run (so a scheduler knows to keep going)?
    let remQ = supabase.from("recipes").select("id", { count: "exact", head: true }).is("image_url", null);
    if (body.user_id) remQ = remQ.eq("user_id", body.user_id);
    const { count: remaining } = await remQ;

    const ok = results.filter((r) => r.ok).length;
    console.log(`[paint-drain] painted ${ok}/${results.length}, remaining=${remaining || 0}`);
    return Response.json({ drained: ok, attempted: results.length, remaining: remaining || 0, results });
  } catch (err) {
    console.error(`[paint-drain] error: ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
