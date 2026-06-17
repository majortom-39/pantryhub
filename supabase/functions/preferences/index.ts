// preferences — get/set user preferences (cuisines, dietary, allergies, unit default).
//
// GET  → returns the demo user's preferences
// POST → updates them. Body: { cuisines?, dietary?, allergies?, unit_default? }
//
// The Curator and Recipe Author read this table directly on every turn.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function handleGet(supabase: SupabaseClient, userId: string) {
  const { data, error } = await supabase.from("user_preferences")
    .select("cuisines, dietary, allergies, unit_default, timezone, updated_at")
    .eq("user_id", userId).maybeSingle();
  if (error) throw new Error(`prefs fetch failed: ${error.message}`);
  return data || { cuisines: [], dietary: [], allergies: [], unit_default: "metric", timezone: "UTC", updated_at: null };
}

async function handleSet(supabase: SupabaseClient, userId: string, body: any) {
  const payload: Record<string, unknown> = { user_id: userId };
  if (Array.isArray(body.cuisines))  payload.cuisines  = body.cuisines;
  if (Array.isArray(body.dietary))   payload.dietary   = body.dietary;
  if (Array.isArray(body.allergies)) payload.allergies = body.allergies;
  if (body.unit_default === "metric" || body.unit_default === "imperial") {
    payload.unit_default = body.unit_default;
  }
  // IANA timezone (e.g. "America/New_York") — drives the per-user midnight
  // curation sweep. Validated loosely: must look like a zone name.
  if (typeof body.timezone === "string" && /^[A-Za-z]+\/[A-Za-z0-9_+\-\/]+$|^UTC$/.test(body.timezone)) {
    payload.timezone = body.timezone;
  }
  const { error } = await supabase.from("user_preferences")
    .upsert(payload, { onConflict: "user_id" });
  if (error) throw new Error(`prefs upsert failed: ${error.message}`);
  return await handleGet(supabase, userId);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
      "Access-Control-Allow-Headers": "authorization,content-type",
    }});
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    if (req.method === "GET") {
      const result = await handleGet(supabase, DEMO_USER_ID);
      return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
    }
    if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

    const body = await req.json();
    const userId = body.user_id || DEMO_USER_ID;
    const result = await handleSet(supabase, userId, body);
    return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    console.error(`[preferences] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
