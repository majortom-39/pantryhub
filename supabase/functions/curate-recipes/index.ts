// curate-recipes — Recipe Curator (daily auto-curation).
//
// Generates the day's feed for ONE user: 2–3 recipes per slot
// (breakfast/lunch/dinner/snacks), each scoring ≥75% pantry match, with
// pantry-based substitutes for missing ingredients, then a grounded
// validation pass to drop fake/inedible dishes and tighten calories.
//
// Painting is DECOUPLED: recipes are written with image_url=null and a
// separate throttled painter-drain fills them in (avoids deAPI rate limits).
//
// POST { user_id?, feed_date?, paint? }
//   user_id   — defaults to DEMO_USER_ID
//   feed_date — the user's LOCAL date (YYYY-MM-DD); defaults to server today.
//               One feed per (user, feed_date); re-running replaces that day.
//   paint     — default false. The drain paints; set true only for ad-hoc runs.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const GEMINI_MODEL = "gemini-3.1-flash-lite";
// Routes through the keyless Cloud Run Vertex proxy (bills to GCP credits).
const VERTEX_PROXY_URL = Deno.env.get("VERTEX_PROXY_URL")!;
const VERTEX_PROXY_SECRET = Deno.env.get("VERTEX_PROXY_SECRET")!;
const THINKING_LEVEL = "medium";
const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const PROMPT_VERSION = "v2";

const MIN_PER_SLOT = 2;     // goal — but we never pad below threshold
const MAX_PER_SLOT = 3;     // hard cap kept per slot
const MATCH_THRESHOLD = 75; // strict: recipes below this are dropped
const SLOTS = ["breakfast", "lunch", "dinner", "snacks"] as const;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Slot = (typeof SLOTS)[number];
type PantryItem = { name: string; brand: string; category: string; quantity: string; expiry: string | null; fullness: number };
type Substitute = { name: string; note: string } | null;
type Ingredient = { name: string; amount: string; in_pantry: boolean; substitute?: Substitute; qty?: number | null; unit?: string | null };

// Phase 2: canonicalise the structured amount the model emits per ingredient.
// qty must be a finite positive number; unit one of g|ml|piece. Anything else
// (e.g. "to taste") → null/null so the app falls back to the display string.
function canonUnit(u: unknown): "g" | "ml" | "piece" | null {
  const s = String(u ?? "").toLowerCase().trim();
  if (s === "g" || s === "gram" || s === "grams") return "g";
  if (s === "ml" || s === "milliliter" || s === "millilitre") return "ml";
  if (s === "piece" || s === "pieces" || s === "pc" || s === "count") return "piece";
  return null;
}
function canonQty(q: unknown): number | null {
  const n = Number(q);
  return isFinite(n) && n > 0 ? Math.round(n * 100) / 100 : null;
}
type CuratedRecipe = {
  category: Slot;
  name: string; difficulty: "easy" | "medium" | "elaborate";
  time_text: string; budget_text: string;
  calories_per_serving: number; servings_base: number;
  ingredients: Ingredient[]; steps: string[];
};

const SYSTEM_PROMPT = `You are PantryHub's Recipe Curator. Given a user's pantry, generate exactly ${MAX_PER_SLOT} recipes for EACH of the four meal slots — breakfast, lunch, dinner, snacks (so ${MAX_PER_SLOT * 4} recipes total). Every recipe must:

1. Score at least 75% pantry-match — at least 3 of every 4 ingredients should already be in the user's pantry.
2. Prioritise ingredients expiring within 7 days when possible.
3. Be a real, well-known dish a person would actually want to eat. Only dishes you are confident exist and are widely cooked.
4. Be sized for ONE person (servings_base = 1).
5. Have **MICRO-STEPS** the user can follow hands-busy: typically 6–10 short steps. Each step is ONE concrete action (or one tightly linked pair like "whisk and pour"). Never bundle three actions into one step.
6. Every step MUST mention quantities and units for any ingredient it uses. Wrap each INGREDIENT amount that should scale with serving size in DOUBLE CURLY BRACES, e.g. "Whisk {{200 ml}} milk with {{1 tsp}} cinnamon in a shallow dish." Inside the braces use the friendly HOUSEHOLD amount the user reads (e.g. {{1 tbsp}}, {{1 tsp}}, {{1/2 cup}}, {{200 ml}}) — never tiny lab figures like {{2 g}}; for countable items put JUST the number, e.g. "Crack {{2}} eggs" (never "{{2 piece}}"). The app multiplies the number inside {{ }} when the user cooks for more people. NEVER wrap cooking times, temperatures, durations, or pan/dish sizes — those do NOT scale; emphasise those with plain **markdown bold** instead (e.g. bake at **180°C** for **20 min**). You may also **bold** ingredient names on first mention. (This is what the user sees on screen.)
7. Be varied within a slot (don't give three near-identical dishes) and avoid any names listed as recently served.
8. HOUSEHOLD MEASURES (what the user reads): the "amount" display string AND every {{ }} step token must use everyday home-kitchen measures, NOT lab-style precision — teaspoons, tablespoons, cups, pinches, whole counts, cloves, slices, "a handful", "a splash" (e.g. "1 tsp", "2 tbsp", "1/2 cup", "a pinch", "3 cloves"). NEVER emit tiny scientific figures like "2 g mustard seeds", "12 ml oil", or "7 g garlic" — round to the natural kitchen amount a person would actually measure ("1/2 tsp mustard seeds", "1 tbsp oil", "2 cloves garlic"). Spices/seasonings are tsp/tbsp/pinch, never grams.
9. SEPARATELY, for EVERY ingredient also emit a structured "qty" (a plain number for ONE serving) and "unit" (canonical: "g" for solids/weight, "ml" for liquids/volume, "piece" for countable items like eggs/cloves/slices) — this is for the app's math only, never shown. Convert the household amount: 1 tbsp≈15 ml, 1 tsp≈5 ml, 1 cup≈240 ml, 1 kg=1000 g, 1 L=1000 ml, 1 oz≈28 g, 1 clove=1 piece. Keep "amount" as the friendly household string. If an amount truly can't be quantified ("to taste", "a pinch"), set qty:null and unit:null.

What counts as a micro-step
- "Crack the **2 eggs** into a bowl and beat well." (good — one action, with quantity)
- "Heat **1 tbsp** olive oil in a pan over medium heat." (good)
- "Whisk eggs, season, add cheese, pour into pan, fold." (bad — that's five micro-steps; split them)

COOKING-FLOW STEPS (don't skip the basics)
- Include the essential prep/setup steps a real recipe needs, placed where they belong:
  • Preheat the oven (with the temperature) as an early step before anything is baked/roasted.
  • Bring water to a boil before adding pasta/eggs/vegetables.
  • Heat the pan/oil before adding food.
  • Thaw/marinate/bring-to-room-temp/rest steps when the dish needs them (e.g. rest meat after cooking).
- Put preheating/boiling early so it's ready in time. Never jump straight to "bake the chicken" without a preheat step.

For EVERY ingredient set "in_pantry" honestly (true if the user clearly has it, else false).
For each ingredient with in_pantry=false, set "substitute" to a real stand-in the user ALREADY HAS in their pantry: {"name": "<pantry item>", "note": "<short why/how, e.g. 'milder — use a bit more'>"}. If the pantry has no sensible stand-in, set "substitute": null.

Return ONLY valid JSON. NO markdown fences, NO commentary, NO preamble, NO trailing text.

Exact JSON shape:
{
  "recipes": [
    {
      "category": "breakfast",
      "name": "Spinach & Mushroom Omelette",
      "difficulty": "easy",
      "time_text": "10 min",
      "budget_text": "$2",
      "calories_per_serving": 320,
      "servings_base": 1,
      "ingredients": [
        {"name": "Eggs", "amount": "2", "in_pantry": true, "substitute": null, "qty": 2, "unit": "piece"},
        {"name": "Goat Cheese", "amount": "30 g", "in_pantry": false, "substitute": {"name": "Cheddar", "note": "sharper — use a little less"}, "qty": 30, "unit": "g"}
      ],
      "steps": [
        "Crack {{2}} eggs into a bowl and beat them with a pinch of salt.",
        "Heat {{1 tbsp}} olive oil in a non-stick pan over medium heat.",
        "Pour the eggs into the pan and let them set for about **30 seconds**.",
        "Scatter the {{30 g}} goat cheese over one half of the omelette.",
        "Fold the omelette in half and slide it onto a plate."
      ]
    }
  ]
}

Constraints:
- "category" must be exactly one of: breakfast, lunch, dinner, snacks.
- "difficulty" must be exactly one of: easy, medium, elaborate.
- Return ${MAX_PER_SLOT} recipes per slot covering all four slots.`;

interface Prefs { cuisines?: string[]; dietary?: string[]; allergies?: string[] }

function buildUserPrompt(pantry: PantryItem[], today: string, prefs: Prefs | null | undefined, recentNames: string[]): string {
  const expiringSoon = pantry.filter((p) => {
    if (!p.expiry) return false;
    const days = (new Date(p.expiry).getTime() - new Date(today).getTime()) / 86_400_000;
    return days <= 7;
  });
  const pantryLines = pantry.map((p) => {
    const expBit = p.expiry ? ` (expires ${p.expiry})` : "";
    const fillBit = ` ~${Math.round(p.fullness * 100)}% full`;
    const brandBit = p.brand ? ` [${p.brand}]` : "";
    return `- ${p.name}${brandBit}: ${p.quantity}${fillBit}${expBit}`;
  }).join("\n");
  const expiringBlock = expiringSoon.length
    ? `\n\nEXPIRING SOON (use these first):\n${expiringSoon.map((p) => `- ${p.name} (${p.expiry})`).join("\n")}`
    : "";

  const prefBits: string[] = [];
  if (prefs?.cuisines?.length)  prefBits.push(`Preferred cuisines: ${prefs.cuisines.join(", ")} (lean these flavors when possible).`);
  if (prefs?.dietary?.length)   prefBits.push(`Dietary requirements (STRICT): ${prefs.dietary.join(", ")}.`);
  if (prefs?.allergies?.length) prefBits.push(`Allergies — NEVER use these ingredients in any recipe: ${prefs.allergies.join(", ")}.`);
  const prefBlock = prefBits.length ? `\n\nUSER PREFERENCES:\n${prefBits.join("\n")}` : "";

  const recentBlock = recentNames.length
    ? `\n\nRECENTLY SERVED (do NOT repeat these — keep today fresh):\n${recentNames.map((n) => `- ${n}`).join("\n")}`
    : "";

  return `Today is ${today}.\n\nThe user's pantry has ${pantry.length} items:\n\n${pantryLines}${expiringBlock}${prefBlock}${recentBlock}\n\nGenerate the recipes now.`;
}

// --- pantry matching (same fuzzy rule the chefs / recipe-ledger use) ---
function inPantry(name: string, pantry: { name: string }[]): boolean {
  const n = name.toLowerCase().trim();
  if (!n) return false;
  return pantry.some((p) => {
    const a = p.name.toLowerCase().trim();
    return a.includes(n) || n.includes(a);
  });
}

async function hashRecipe(name: string, ingredients: Ingredient[]): Promise<string> {
  const normalized = name.toLowerCase().trim() + "::" + ingredients.map((i) => i.name.toLowerCase().trim()).sort().join("|");
  const buf = new TextEncoder().encode(normalized);
  const hash = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function matchScore(ingredients: Ingredient[]): number {
  if (ingredients.length === 0) return 0;
  return Math.round((100 * ingredients.filter((i) => i.in_pantry).length) / ingredients.length);
}

function stripJsonFences(t: string): string {
  return t.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();
}

// Extract first balanced {...} JSON object, ignoring trailing prose.
function extractFirstJsonObject(text: string): string {
  const start = text.indexOf("{");
  if (start === -1) return text;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) { esc = false; continue; }
      if (c === "\\") { esc = true; continue; }
      if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return text.substring(start, i + 1);
    }
  }
  return text.substring(start);
}

async function callProxy(body: Record<string, unknown>): Promise<string> {
  const res = await fetch(VERTEX_PROXY_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Proxy-Secret": VERTEX_PROXY_SECRET },
    body: JSON.stringify({ model: GEMINI_MODEL, ...body }),
  });
  if (!res.ok) throw new Error(`Gemini call failed: ${res.status} ${await res.text()}`);
  const json = await res.json();
  const text: string | undefined = json?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text || "").join("");
  if (!text) throw new Error(`Gemini returned no text. Raw: ${JSON.stringify(json).slice(0, 500)}`);
  return text;
}

async function generateRecipes(systemPrompt: string, userPrompt: string): Promise<CuratedRecipe[]> {
  const text = await callProxy({
    contents: [{ role: "user", parts: [{ text: userPrompt }] }],
    systemInstruction: { parts: [{ text: systemPrompt }] },
    generationConfig: {
      thinkingConfig: { thinkingLevel: THINKING_LEVEL },
      responseMimeType: "application/json",
      temperature: 0.95,
    },
  });
  let parsed: { recipes: CuratedRecipe[] };
  try { parsed = JSON.parse(extractFirstJsonObject(stripJsonFences(text))); }
  catch (e) { throw new Error(`Gemini JSON parse failed: ${e}. Raw: ${text.slice(0, 2000)}`); }
  if (!parsed?.recipes || !Array.isArray(parsed.recipes)) throw new Error(`Gemini response missing 'recipes' array.`);
  return parsed.recipes;
}

// Grounded validation: confirm each dish is real/edible and refine calories.
// Single call, googleSearch tool + JSON (verified to coexist on this model).
// Soft-fails: if the call breaks, we keep the recipes as-is rather than block.
async function validateRecipes(
  recipes: { name: string; calories_per_serving: number }[],
): Promise<Map<string, { real: boolean; calories: number }>> {
  const out = new Map<string, { real: boolean; calories: number }>();
  if (recipes.length === 0) return out;
  try {
    const list = recipes.map((r, i) => `${i + 1}. ${r.name} (~${r.calories_per_serving} kcal/serving)`).join("\n");
    const text = await callProxy({
      contents: [{ role: "user", parts: [{ text:
        `For each dish below, decide if it is a REAL, edible, widely-known dish (not invented "AI fluff"), and give a realistic calories-per-serving for ONE serving. Use search if unsure.\n\n${list}\n\nReturn ONLY JSON: {"results":[{"name":"<exact name>","real":true|false,"calories_per_serving":<int>}]}` }] }],
      generationConfig: { responseMimeType: "application/json", temperature: 0.2 },
      tools: [{ googleSearch: {} }],
    });
    const parsed = JSON.parse(extractFirstJsonObject(stripJsonFences(text)));
    for (const r of (parsed?.results || [])) {
      if (r?.name) out.set(String(r.name).toLowerCase().trim(), {
        real: r.real !== false,
        calories: Number(r.calories_per_serving) || 0,
      });
    }
  } catch (e) {
    console.warn(`[curate-recipes] validation pass failed (keeping all): ${e instanceof Error ? e.message : e}`);
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST,OPTIONS", "Access-Control-Allow-Headers": "authorization,content-type" },
    });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    let body: { user_id?: string; feed_date?: string; paint?: boolean; force?: boolean } = {};
    try { body = await req.json(); } catch { /* empty body ok */ }
    const userId = body.user_id || DEMO_USER_ID;
    const shouldPaint = body.paint === true; // painting is the drain's job by default
    const force = body.force === true;       // re-curate even if today's feed exists
    const feedDate = body.feed_date || new Date().toISOString().slice(0, 10);

    // Idempotent per (user, feed_date): if this day already has an active feed,
    // skip — unless force=true (manual re-curation).
    if (!force) {
      const { count: existingCount } = await supabase.from("daily_feed")
        .select("id", { count: "exact", head: true })
        .eq("user_id", userId).eq("feed_date", feedDate).eq("status", "active");
      if ((existingCount || 0) > 0) {
        return Response.json({ user_id: userId, feed_date: feedDate, skipped: true, reason: "feed already exists for this date" });
      }
    }

    // Recent names (last 5 feeds) so the model keeps the day fresh.
    const { data: pantryRows, error: pantryErr } = await supabase.from("pantry_items")
      .select("name, brand, category, quantity, expiry, fullness_levels").eq("user_id", userId);
    const { data: prefs } = await supabase.from("user_preferences")
      .select("cuisines, dietary, allergies").eq("user_id", userId).maybeSingle();
    const { data: recentFeeds } = await supabase.from("daily_feed")
      .select("recipe:recipes(name)").eq("user_id", userId)
      .order("feed_date", { ascending: false }).limit(40);
    if (pantryErr) throw new Error(`pantry fetch failed: ${pantryErr.message}`);
    if (!pantryRows || pantryRows.length === 0) return Response.json({ error: "pantry is empty" }, { status: 400 });

    const recentNames = Array.from(new Set(
      (recentFeeds || []).map((r: { recipe?: { name?: string } | null }) => r.recipe?.name).filter((n): n is string => !!n),
    )).slice(0, 20);

    const pantry: PantryItem[] = pantryRows.map((p) => {
      const lv = (p.fullness_levels as number[]) || [1.0];
      const avg = lv.reduce((a, b) => Number(a) + Number(b), 0) / lv.length;
      return { name: p.name, brand: p.brand || "", category: p.category, quantity: p.quantity || "", expiry: p.expiry, fullness: avg };
    });
    console.log(`[curate-recipes] user=${userId} date=${feedDate} pantry=${pantry.length} recent=${recentNames.length}`);

    const userPrompt = buildUserPrompt(pantry, feedDate, prefs, recentNames);
    const rawRecipes = await generateRecipes(SYSTEM_PROMPT, userPrompt);
    console.log(`[curate-recipes] model returned ${rawRecipes.length} recipes`);

    // Normalise: recompute in_pantry server-side (honest match gate), keep a
    // substitute only when the item is missing AND the stand-in is really in
    // the pantry. Then attach the true match score.
    type Norm = { r: CuratedRecipe; ingredients: Ingredient[]; match: number };
    const normalised: Norm[] = rawRecipes
      .filter((r) => SLOTS.includes(r.category) && Array.isArray(r.ingredients) && r.ingredients.length > 0)
      .map((r) => {
        const ingredients: Ingredient[] = r.ingredients.map((i) => {
          const has = inPantry(i.name, pantry);
          let substitute: Substitute = null;
          if (!has && i.substitute && typeof i.substitute === "object" && i.substitute.name && inPantry(i.substitute.name, pantry)) {
            substitute = { name: i.substitute.name, note: i.substitute.note || "" };
          }
          return { name: i.name, amount: i.amount, in_pantry: has, substitute, qty: canonQty(i.qty), unit: canonUnit(i.unit) };
        });
        return { r, ingredients, match: matchScore(ingredients) };
      });

    // Strict ≥75% filter, then cap per slot (no padding below threshold).
    const bySlot = new Map<Slot, Norm[]>();
    for (const s of SLOTS) bySlot.set(s, []);
    for (const n of normalised.filter((n) => n.match >= MATCH_THRESHOLD)) {
      const arr = bySlot.get(n.r.category)!;
      if (arr.length < MAX_PER_SLOT) arr.push(n);
    }
    let kept = SLOTS.flatMap((s) => bySlot.get(s)!);

    // Grounded validation — drop fake dishes, refine calories.
    const verdicts = await validateRecipes(kept.map((n) => ({ name: n.r.name, calories_per_serving: n.r.calories_per_serving })));
    kept = kept.filter((n) => {
      const v = verdicts.get(n.r.name.toLowerCase().trim());
      if (v && v.real === false) { console.log(`[curate-recipes] dropped (not real): ${n.r.name}`); return false; }
      if (v && v.calories > 0) n.r.calories_per_serving = v.calories;
      return true;
    });

    const slotCounts = SLOTS.map((s) => `${s}:${kept.filter((n) => n.r.category === s).length}`).join(" ");
    console.log(`[curate-recipes] kept ${kept.length} after filter+validation (${slotCounts})`);
    if (kept.length === 0) throw new Error("no recipes survived the 75% + validation gate");

    // Fresh day = one active feed. Clear ALL of the user's existing feed rows
    // (every date), not just today's — yesterday's picks shouldn't linger.
    // Cooked/saved recipes survive via their own tables (cooked_recipes /
    // saved_recipes) and are protected by the orphan sweep below. We only reach
    // here once we KNOW we have new recipes to show (kept.length > 0 checked
    // above), so a failed curation never leaves the user feed-less.
    const { error: clearErr } = await supabase.from("daily_feed")
      .delete().eq("user_id", userId);
    if (clearErr) throw new Error(`daily_feed clear failed: ${clearErr.message}`);

    const upserted: Array<{ recipe_id: string; slot: string; match: number; wasNew: boolean; name: string }> = [];
    for (const n of kept) {
      const { r, ingredients, match } = n;
      const hash = await hashRecipe(r.name, ingredients);
      const { data: existing, error: lookupErr } = await supabase.from("recipes")
        .select("id, image_url").eq("user_id", userId).eq("content_hash", hash).maybeSingle();
      if (lookupErr) throw new Error(`recipe lookup failed: ${lookupErr.message}`);

      let recipeId: string;
      let wasNew = false;
      if (existing) {
        recipeId = existing.id;
        // Refresh editable fields in case the model improved them.
        await supabase.from("recipes").update({
          ingredients, steps: r.steps, calories_per_serving: r.calories_per_serving,
          time_text: r.time_text, budget_text: r.budget_text, difficulty: r.difficulty,
        }).eq("id", recipeId);
      } else {
        const { data: inserted, error: insertErr } = await supabase.from("recipes").insert({
          user_id: userId,
          content_hash: hash, name: r.name, category: r.category, difficulty: r.difficulty,
          time_text: r.time_text, budget_text: r.budget_text, servings_base: r.servings_base || 1,
          calories_per_serving: r.calories_per_serving, ingredients, steps: r.steps,
          curator_model: GEMINI_MODEL, curator_thinking: THINKING_LEVEL, prompt_version: PROMPT_VERSION,
        }).select("id").single();
        if (insertErr || !inserted) throw new Error(`recipe insert failed: ${insertErr?.message}`);
        recipeId = inserted.id;
        wasNew = true;
      }

      const { error: feedErr } = await supabase.from("daily_feed").insert({
        user_id: userId, feed_date: feedDate, slot: r.category, recipe_id: recipeId, match_score: match, status: "active",
      });
      if (feedErr) throw new Error(`daily_feed insert failed: ${feedErr.message}`);

      upserted.push({ recipe_id: recipeId, slot: r.category, match, wasNew, name: r.name });
    }

    // Painting is normally the drain's job (rate-limit safe). Only paint inline
    // when explicitly asked (ad-hoc runs), and even then sequentially.
    let painted: Array<{ recipe_id: string; ok: boolean; error?: string }> = [];
    if (shouldPaint) {
      const newOnes = upserted.filter((u) => u.wasNew);
      for (const u of newOnes) {
        try {
          const res = await fetch(`${SUPABASE_URL}/functions/v1/paint-recipe`, {
            method: "POST",
            headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
            body: JSON.stringify({ recipe_id: u.recipe_id }),
          });
          painted.push({ recipe_id: u.recipe_id, ok: res.ok, error: res.ok ? undefined : `${res.status}` });
        } catch (e) { painted.push({ recipe_id: u.recipe_id, ok: false, error: e instanceof Error ? e.message : String(e) }); }
      }
    }

    // Fresh day, fresh slate: wipe the user's Recipe Author chat so it only
    // ever holds one curation-day's conversation. The cooking chef sessions
    // (kind='chef') are tied to specific recipes and are left untouched. Also
    // sweep orphan "preview" recipes (suggestions the user viewed — which vault
    // + paint on view — but never added to a feed, saved, or cooked), so they
    // don't accumulate. This runs AFTER the new feed is written, so today's
    // freshly-curated recipes are protected by the daily_feed reference check.
    try {
      const { data: authorSessions } = await supabase.from("chat_sessions")
        .select("id").eq("user_id", userId).eq("kind", "recipe_author");
      const ids = (authorSessions || []).map((s) => s.id);
      if (ids.length) {
        await supabase.from("chat_messages").delete().in("session_id", ids);
        await supabase.from("chat_sessions").delete().in("id", ids);
      }
      // Orphan preview recipes: not in any feed, not saved, not cooked.
      const { data: refsFeed } = await supabase.from("daily_feed").select("recipe_id").eq("user_id", userId);
      const { data: refsSaved } = await supabase.from("saved_recipes").select("recipe_id").eq("user_id", userId);
      const { data: refsCooked } = await supabase.from("cooked_recipes").select("recipe_id").eq("user_id", userId);
      const keep = new Set<string>([
        ...(refsFeed || []).map((r) => r.recipe_id as string),
        ...(refsSaved || []).map((r) => r.recipe_id as string),
        ...(refsCooked || []).map((r) => r.recipe_id as string),
      ]);
      const { data: allRecipes } = await supabase.from("recipes").select("id").eq("user_id", userId);
      const orphans = (allRecipes || []).map((r) => r.id as string).filter((id) => !keep.has(id));
      if (orphans.length) {
        await supabase.from("recipes").delete().in("id", orphans);
      }
      console.log(`[curate-recipes] fresh-day cleanup: ${ids.length} author session(s), ${orphans.length} orphan recipe(s)`);
    } catch (e) {
      console.warn(`[curate-recipes] fresh-day cleanup failed (non-fatal): ${e instanceof Error ? e.message : String(e)}`);
    }

    const slots = SLOTS.map((s) => `${s}:${upserted.filter((u) => u.slot === s).length}`).join(" ");
    return Response.json({ user_id: userId, feed_date: feedDate, pantry_size: pantry.length, counts: slots, recipes: upserted, painted });
  } catch (err) {
    console.error(`[curate-recipes] error: ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
