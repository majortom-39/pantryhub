// kitchen — My Kitchen backend (Saved + Cooked recipes).
// Actions: list | save | unsave

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const RECIPE_FIELDS =
  "id, name, author, category, difficulty, time_text, budget_text, servings_base, calories_per_serving, ingredients, steps, image_url, image_style, source";

async function handleList(supabase: SupabaseClient, userId: string) {
  const [saved, cooked] = await Promise.all([
    supabase.from("saved_recipes")
      .select(`saved_at, recipe:recipes(${RECIPE_FIELDS})`)
      .eq("user_id", userId)
      .order("saved_at", { ascending: false }),
    supabase.from("cooked_recipes")
      .select(`cooked_at, recipe:recipes(${RECIPE_FIELDS})`)
      .eq("user_id", userId)
      .order("cooked_at", { ascending: false }),
  ]);
  if (saved.error)  throw new Error(`saved fetch failed: ${saved.error.message}`);
  if (cooked.error) throw new Error(`cooked fetch failed: ${cooked.error.message}`);
  return { saved: saved.data || [], cooked: cooked.data || [] };
}

async function handleSave(supabase: SupabaseClient, userId: string, recipeId: string) {
  const { error } = await supabase.from("saved_recipes").upsert({
    user_id: userId, recipe_id: recipeId,
  }, { onConflict: "user_id,recipe_id" });
  if (error) throw new Error(`save failed: ${error.message}`);
  return { ok: true, recipe_id: recipeId };
}

async function handleUnsave(supabase: SupabaseClient, userId: string, recipeId: string) {
  const { error } = await supabase.from("saved_recipes")
    .delete().eq("user_id", userId).eq("recipe_id", recipeId);
  if (error) throw new Error(`unsave failed: ${error.message}`);
  return { ok: true, recipe_id: recipeId };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST,GET,OPTIONS",
      "Access-Control-Allow-Headers": "authorization,content-type",
    }});
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    // GET = list (matches iOS convention of using GET for read endpoints)
    if (req.method === "GET") {
      const result = await handleList(supabase, DEMO_USER_ID);
      return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
    }
    if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

    const body = await req.json();
    const action = body.action;
    const userId = body.user_id || DEMO_USER_ID;
    let result;
    switch (action) {
      case "list":   result = await handleList(supabase, userId); break;
      case "save":   result = await handleSave(supabase, userId, body.recipe_id); break;
      case "unsave": result = await handleUnsave(supabase, userId, body.recipe_id); break;
      default: return Response.json({ error: `unknown action: ${action}` }, { status: 400 });
    }
    return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    console.error(`[kitchen] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
