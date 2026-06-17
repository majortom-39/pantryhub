// cook-timers — the single writer/reader for in-app cooking timers.
//
// Timers belong to a cook_session and are shared by BOTH chefs and the manual
// UI, so a timer set by voice shows on the text screen and vice-versa. The
// actual countdown is computed on-device from `ends_at`; this function just
// owns the list.
//
// Callable by:
//   • the app (anon key) — manual create / cancel / list
//   • the chefs (service key, server-side) — start_timer / cancel_timer tools
//
// POST { action, cook_session_id, ... }
//   list    { cook_session_id }                                   → { timers }
//   create  { cook_session_id, label, seconds, created_by? }      → { timer, timers }
//   cancel  { cook_session_id, timer_id }                         → { timers }
// Every response returns the current running timers so callers stay in sync.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const MAX_SECONDS = 24 * 60 * 60; // 24h ceiling
const MAX_ACTIVE = 8;             // sane cap on concurrent timers per session

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
  "Access-Control-Allow-Headers": "authorization,content-type",
};

async function runningTimers(supabase: SupabaseClient, cookSessionId: string) {
  const { data } = await supabase.from("cook_timers")
    .select("id, label, duration_seconds, started_at, ends_at, status, created_by")
    .eq("cook_session_id", cookSessionId).eq("status", "running")
    .order("created_at", { ascending: true });
  return data || [];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    const body = await req.json();
    const { action, cook_session_id } = body;
    if (!cook_session_id) return Response.json({ error: "cook_session_id required" }, { status: 400, headers: cors });

    // Ownership / existence: derive the user from the cook session.
    const { data: cook } = await supabase.from("cook_sessions")
      .select("user_id").eq("id", cook_session_id).single();
    if (!cook) return Response.json({ error: "cook session not found" }, { status: 404, headers: cors });

    if (action === "list") {
      return Response.json({ timers: await runningTimers(supabase, cook_session_id) }, { headers: cors });
    }

    if (action === "create") {
      const label = String(body.label || "Timer").trim().slice(0, 60) || "Timer";
      const seconds = Math.max(1, Math.min(Number(body.seconds) || 0, MAX_SECONDS));
      if (seconds < 1) return Response.json({ error: "seconds required" }, { status: 400, headers: cors });
      const createdBy = ["user", "text_chef", "voice_chef"].includes(body.created_by) ? body.created_by : "user";

      const active = await runningTimers(supabase, cook_session_id);
      if (active.length >= MAX_ACTIVE) {
        return Response.json({ error: `too many timers (max ${MAX_ACTIVE})`, timers: active }, { headers: cors });
      }

      const now = Date.now();
      const ends = new Date(now + seconds * 1000).toISOString();
      const { data: inserted, error } = await supabase.from("cook_timers").insert({
        cook_session_id, user_id: cook.user_id, label, duration_seconds: seconds,
        started_at: new Date(now).toISOString(), ends_at: ends, status: "running", created_by: createdBy,
      }).select("id, label, duration_seconds, started_at, ends_at, status, created_by").single();
      if (error || !inserted) return Response.json({ error: `create failed: ${error?.message}` }, { status: 500, headers: cors });

      return Response.json({ timer: inserted, timers: await runningTimers(supabase, cook_session_id) }, { headers: cors });
    }

    if (action === "cancel") {
      const timerId = String(body.timer_id || "");
      if (timerId) {
        await supabase.from("cook_timers").update({ status: "cancelled" })
          .eq("id", timerId).eq("cook_session_id", cook_session_id);
      } else if (body.label) {
        // Cancel the most recent running timer whose label matches (chef path).
        const needle = String(body.label).toLowerCase().trim();
        const active = await runningTimers(supabase, cook_session_id);
        const match = active.reverse().find((t) => (t.label as string).toLowerCase().includes(needle) || needle.includes((t.label as string).toLowerCase()));
        if (match) {
          await supabase.from("cook_timers").update({ status: "cancelled" }).eq("id", match.id);
        }
      }
      return Response.json({ timers: await runningTimers(supabase, cook_session_id) }, { headers: cors });
    }

    return Response.json({ error: `unknown action: ${action}` }, { status: 400, headers: cors });
  } catch (e) {
    return Response.json({ error: e instanceof Error ? e.message : String(e) }, { status: 500, headers: cors });
  }
});
