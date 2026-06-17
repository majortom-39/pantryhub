// feed-actions — small endpoints for the warning UX.
//   { action: "clear_warning", feed_row_id }
//   { action: "regenerate_slot", slot }   → generates a single fresh recipe for that slot.
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const GEMINI_MODEL = "gemini-3.1-flash-lite";
// Calls now route through the keyless Cloud Run Vertex proxy so usage bills to
// the GCP project (free credits). URL + shared secret come from function secrets.
const VERTEX_PROXY_URL = Deno.env.get("VERTEX_PROXY_URL")!;
const VERTEX_PROXY_SECRET = Deno.env.get("VERTEX_PROXY_SECRET")!;
const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const PROMPT_VERSION = "v6-regen";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function geminiCall(body: object): Promise<string> {
  const maxRetries = 4;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const res = await fetch(VERTEX_PROXY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Proxy-Secret": VERTEX_PROXY_SECRET },
      body: JSON.stringify({ model: GEMINI_MODEL, ...body }),
    });
    if (res.ok) {
      const json = await res.json();
      return (json?.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text || "").join("");
    }
    if ((res.status === 429 || res.status >= 500) && attempt < maxRetries) {
      const delay = Math.min(1000 * Math.pow(2, attempt), 16_000) + Math.random() * 500;
      await new Promise((r) => setTimeout(r, delay));
      continue;
    }
    throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  throw new Error("Gemini retries exhausted");
}
function stripFences(t: string) { return t.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim(); }
function extractFirstJsonObject(text: string): string {
  const start = text.indexOf("{");
  if (start === -1) return text;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) { if (esc){esc=false;continue;} if(c==="\\"){esc=true;continue;} if(c==='"') inStr=false; continue; }
    if (c==='"') { inStr = true; continue; }
    if (c==='{') depth++;
    else if (c==='}') { depth--; if (depth===0) return text.substring(start, i+1); }
  }
  return text.substring(start);
}
async function hashRecipe(name: string, ingredients: any[]): Promise<string> {
  const norm = name.toLowerCase().trim() + "::" + ingredients.map((i) => i.name.toLowerCase().trim()).sort().join("|");
  const buf = new TextEncoder().encode(norm);
  const hash = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function matchScore(ingredients: any[]) { if (!ingredients.length) return 0; return Math.round((100 * ingredients.filter((i) => i.in_pantry).length) / ingredients.length); }
// Phase 2: canonicalise the structured per-serving amount the model emits.
function canonUnit(u: unknown): "g" | "ml" | "piece" | null {
  const s = String(u ?? "").toLowerCase().trim();
  if (s === "g" || s === "gram" || s === "grams") return "g";
  if (s === "ml" || s === "milliliter" || s === "millilitre") return "ml";
  if (s === "piece" || s === "pieces" || s === "pc" || s === "count") return "piece";
  return null;
}
function canonQty(q: unknown): number | null { const n = Number(q); return isFinite(n) && n > 0 ? Math.round(n * 100) / 100 : null; }

const REGEN_SYSTEM = `You are PantryHub's Recipe Curator regenerating ONE recipe for a single slot.

Return ONLY valid JSON, no fences. Shape:
{
  "recipe": {
    "category": "<slot>",
    "name": "...",
    "difficulty": "easy" | "medium" | "elaborate",
    "time_text": "15–20 min",
    "budget_text": "$5",
    "calories_per_serving": <int>,
    "servings_base": 1,
    "ingredients": [
      {"name": "...", "amount": "<friendly display string>", "in_pantry": true|false, "substitute": null OR {"name":"...","note":"..."}, "qty": <number for ONE serving>, "unit": "g"|"ml"|"piece"}
    ],
    "steps": ["detailed paragraph 1", "..."]
  }
}

Rules:
- ≥ 75% pantry match.
- Sized for ONE person (servings_base=1).
- MICRO-STEPS: 6–10 short steps, each describing ONE concrete action (or a tightly linked pair). Never bundle three actions into one step. Hands-busy users need to hear/read one micro-action at a time.
- Each step MUST include quantities and units for any ingredient it uses. Wrap each INGREDIENT amount that should scale with serving size in DOUBLE CURLY BRACES, e.g. "Whisk {{200 ml}} milk with {{1 tsp}} cinnamon in a shallow dish." Inside the braces use the friendly HOUSEHOLD amount the user reads (e.g. {{1 tbsp}}, {{1 tsp}}, {{1/2 cup}}, {{200 ml}}) — never tiny lab figures like {{2 g}}; for countable items put JUST the number, e.g. "Crack {{2}} eggs" (never "{{2 piece}}"). The app multiplies the number inside {{ }} when cooking for more people. NEVER wrap cooking times, temperatures, durations, or pan sizes — those do not scale; use plain **markdown bold** for those (e.g. bake at **180°C** for **20 min**).
- HOUSEHOLD MEASURES (what the user reads): the "amount" display string AND the {{ }} step tokens must use everyday kitchen measures — teaspoons, tablespoons, cups, pinches, whole counts, cloves, slices, "a handful" (e.g. "1 tsp", "2 tbsp", "1/2 cup", "a pinch", "3 cloves"). NEVER emit lab-style figures like "2 g mustard seeds" or "12 ml oil" — round to the natural amount a person measures ("1/2 tsp mustard seeds", "1 tbsp oil"). Spices/seasonings are tsp/tbsp/pinch, never grams.
- STRUCTURED AMOUNTS (app math only, never shown): for EVERY ingredient also emit "qty" (a plain number for ONE serving) and "unit" — canonical only: "g" (solids/weight), "ml" (liquids/volume), "piece" (countable items). Convert the household amount: 1 tbsp≈15 ml, 1 tsp≈5 ml, 1 cup≈240 ml, 1 kg=1000 g, 1 L=1000 ml, 1 oz≈28 g, 1 clove=1 piece. Keep "amount" as the friendly household string. If unquantifiable ("to taste"), set qty:null and unit:null.
- COOKING FLOW: include essential prep/setup steps where they belong — preheat the oven (with temp) before baking/roasting, bring water to a boil before pasta/eggs, heat the pan/oil before adding food, and thaw/marinate/rest when needed. Never jump straight to "bake it" without a preheat step.
- Mark in_pantry honestly. If false, fill substitute from the user's pantry or set null.
- NEVER use ingredients banned by allergies.
- Must be DIFFERENT from the previous recipe being replaced (if listed).`;

async function handleRegenerateSlot(supabase: SupabaseClient, userId: string, slot: string) {
  if (!['breakfast','lunch','dinner','snacks'].includes(slot)) throw new Error(`bad slot: ${slot}`);
  const today = new Date().toISOString().slice(0, 10);
  const [{ data: pantry }, { data: prefs }, { data: oldRows }] = await Promise.all([
    supabase.from("pantry_items").select("name, brand, quantity, expiry, fullness_levels").eq("user_id", userId),
    supabase.from("user_preferences").select("cuisines, dietary, allergies").eq("user_id", userId).maybeSingle(),
    supabase.from("daily_feed").select("id, recipe:recipes(name)").eq("user_id", userId).eq("feed_date", today).eq("slot", slot),
  ]);
  const pantryLines = (pantry || []).map((p: any) => {
    const lv = (p.fullness_levels as number[]) || [1.0];
    const avg = Math.round(100 * lv.reduce((a: number, b: number) => Number(a) + Number(b), 0) / lv.length);
    const exp = p.expiry ? ` (expires ${p.expiry})` : "";
    return `- ${p.name}: ${p.quantity || ""} ~${avg}% full${exp}`;
  }).join("\n");
  const prefBits: string[] = [];
  if (prefs?.cuisines?.length) prefBits.push(`Preferred cuisines: ${prefs.cuisines.join(", ")}.`);
  if (prefs?.dietary?.length) prefBits.push(`Dietary requirements (STRICT): ${prefs.dietary.join(", ")}.`);
  if (prefs?.allergies?.length) prefBits.push(`Allergies — NEVER use: ${prefs.allergies.join(", ")}.`);
  const prevNames = (oldRows || []).map((r: any) => r.recipe?.name).filter(Boolean).join(", ");
  const userPrompt = `Today is ${today}. Generate ONE ${slot} recipe.\n\nPantry (${(pantry || []).length} items):\n${pantryLines}\n\n${prefBits.join("\n")}${prevNames ? `\n\nDO NOT REPEAT THESE recipes the user just had: ${prevNames}` : ""}\n\nReturn the JSON now.`;
  const text = await geminiCall({
    contents: [{ role: "user", parts: [{ text: userPrompt }] }],
    systemInstruction: { parts: [{ text: REGEN_SYSTEM }] },
    generationConfig: { thinkingConfig: { thinkingLevel: "medium" }, responseMimeType: "application/json", temperature: 0.95 },
  });
  const parsed = JSON.parse(extractFirstJsonObject(stripFences(text)));
  const r = parsed.recipe;
  if (!r) throw new Error("no recipe returned");
  const ingredients = (r.ingredients || []).map((i: any) => ({
    name: i.name, amount: i.amount, in_pantry: !!i.in_pantry,
    substitute: (i.substitute && typeof i.substitute === "object" && i.substitute.name) ? i.substitute : null,
    qty: canonQty(i.qty), unit: canonUnit(i.unit),
  }));
  const hash = await hashRecipe(r.name, ingredients);
  const ms = matchScore(ingredients);
  // Recipes are per-user: only reuse a row if THIS user already owns an
  // identical one. Never reuse another user's recipe.
  const { data: existing } = await supabase.from("recipes")
    .select("id").eq("user_id", userId).eq("content_hash", hash).maybeSingle();
  let recipeId: string;
  let wasNew = false;
  if (existing) recipeId = existing.id;
  else {
    const { data: inserted, error } = await supabase.from("recipes").insert({
      user_id: userId,
      content_hash: hash, name: r.name, category: slot, difficulty: r.difficulty,
      time_text: r.time_text, budget_text: r.budget_text || "$5", servings_base: r.servings_base || 1,
      calories_per_serving: r.calories_per_serving, ingredients, steps: r.steps,
      curator_model: GEMINI_MODEL, curator_thinking: "medium", prompt_version: PROMPT_VERSION,
    }).select("id").single();
    if (error || !inserted) throw new Error(`recipe insert: ${error?.message}`);
    recipeId = inserted.id;
    wasNew = true;
  }
  await supabase.from("daily_feed").delete().eq("user_id", userId).eq("feed_date", today).eq("slot", slot);
  await supabase.from("daily_feed").insert({ user_id: userId, feed_date: today, slot, recipe_id: recipeId, match_score: ms, status: "active" });
  let painted: any = null;
  if (wasNew) {
    try {
      const res = await fetch(`${SUPABASE_URL}/functions/v1/paint-recipe`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
        body: JSON.stringify({ recipe_id: recipeId }),
      });
      painted = res.ok ? { ok: true } : { ok: false, error: `${res.status}` };
    } catch (e) { painted = { ok: false, error: String(e) }; }
  }
  return { slot, recipe_id: recipeId, name: r.name, match_score: ms, was_new: wasNew, painted };
}

async function handleClearWarning(supabase: SupabaseClient, feedRowId: string) {
  const { error } = await supabase.from("daily_feed").update({ pantry_warning: null }).eq("id", feedRowId);
  if (error) throw new Error(`clear failed: ${error.message}`);
  return { ok: true, feed_row_id: feedRowId };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST,OPTIONS", "Access-Control-Allow-Headers": "authorization,content-type" }});
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    const body = await req.json();
    const action = body.action;
    const userId = body.user_id || DEMO_USER_ID;
    let result;
    switch (action) {
      case "regenerate_slot": result = await handleRegenerateSlot(supabase, userId, body.slot); break;
      case "clear_warning":   result = await handleClearWarning(supabase, body.feed_row_id); break;
      default: return Response.json({ error: `unknown action: ${action}` }, { status: 400 });
    }
    return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    console.error(`[feed-actions] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
