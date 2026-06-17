// get-daily-feed — read endpoint the iOS app hits to load today's Recipes tab.
// Returns the MOST RECENT feed (regardless of date) for the demo user, joined
// to full recipe details. No auth in Phase 1.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        "Access-Control-Allow-Headers": "authorization,content-type",
      },
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const userId = DEMO_USER_ID; // hardcoded until auth

  // Find the most recent feed_date for this user.
  const { data: latest, error: latestErr } = await supabase
    .from("daily_feed")
    .select("feed_date")
    .eq("user_id", userId)
    .order("feed_date", { ascending: false })
    .limit(1);
  if (latestErr) {
    return Response.json({ error: latestErr.message }, { status: 500 });
  }
  if (!latest || latest.length === 0) {
    return Response.json({ feed_date: null, recipes: [] }, {
      headers: { "Access-Control-Allow-Origin": "*" },
    });
  }
  const feedDate = latest[0].feed_date;

  // Pull all 4 feed rows + joined recipe details.
  const { data, error } = await supabase
    .from("daily_feed")
    .select(`
      id,
      slot,
      match_score,
      status,
      pantry_warning,
      recipe:recipes (
        id,
        name,
        author,
        category,
        difficulty,
        time_text,
        budget_text,
        servings_base,
        calories_per_serving,
        ingredients,
        steps,
        image_url,
        image_style,
        source
      )
    `)
    .eq("user_id", userId)
    .eq("feed_date", feedDate)
    .eq("status", "active");

  if (error) {
    return Response.json({ error: error.message }, { status: 500 });
  }

  return Response.json(
    { feed_date: feedDate, recipes: data || [] },
    { headers: { "Access-Control-Allow-Origin": "*" } },
  );
});
