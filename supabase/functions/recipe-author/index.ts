// recipe-author — the "Ask Chef for a recipe" chatbot at the top of Recipes.
//
// Actions:
//   { action: "start" }                                 → creates chat_session, returns id
//   { action: "send", chat_session_id, text }           → chat turn, may include a recipe suggestion JSON
//   { action: "add_to_feed", recipe, slot? }            → vault + daily_feed + paint
//
// Model is forced to JSON output: { reply: string, recipe?: {...} }.
// Has access to: user pantry, today's feed, user preferences.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const GEMINI_MODEL = "gemini-3.1-flash-lite";
// Routes through the keyless Cloud Run Vertex proxy (bills to GCP credits).
const VERTEX_PROXY_URL = Deno.env.get("VERTEX_PROXY_URL")!;
const VERTEX_PROXY_SECRET = Deno.env.get("VERTEX_PROXY_SECRET")!;
const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function geminiCall(body: object): Promise<{ text: string }> {
  const maxRetries = 4;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const res = await fetch(VERTEX_PROXY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Proxy-Secret": VERTEX_PROXY_SECRET },
      body: JSON.stringify({ model: GEMINI_MODEL, ...body }),
    });
    if (res.ok) {
      const json = await res.json();
      const text = (json?.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text || "").join("");
      return { text };
    }
    if ((res.status === 429 || res.status >= 500) && attempt < maxRetries) {
      const delay = Math.min(1000 * Math.pow(2, attempt), 16_000) + Math.random() * 500;
      console.warn(`[gemini] ${res.status}, retry ${attempt + 1}/${maxRetries} in ${Math.round(delay)}ms`);
      await new Promise((r) => setTimeout(r, delay));
      continue;
    }
    throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 500)}`);
  }
  throw new Error("Gemini retries exhausted");
}

function extractFirstJsonObject(text: string): string {
  const stripped = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();
  const start = stripped.indexOf("{");
  if (start === -1) return stripped;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < stripped.length; i++) {
    const c = stripped[i];
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
      if (depth === 0) return stripped.substring(start, i + 1);
    }
  }
  return stripped.substring(start);
}

async function hashRecipe(name: string, ingredients: Array<{ name: string }>): Promise<string> {
  const norm = name.toLowerCase().trim() + "::" +
    ingredients.map((i) => i.name.toLowerCase().trim()).sort().join("|");
  const buf = new TextEncoder().encode(norm);
  const hash = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const AUTHOR_SYSTEM = `You are PantryHub's Recipe Author — a warm, knowledgeable chef who suggests new recipes on demand.

The user is browsing the Recipes tab and has tapped "Ask the chef for a recipe" because they want something different from today's auto-curated 4 picks. Your job: chat with them, understand what they want (cuisine, dish, mood, constraint), and suggest a recipe that matches.

You always know:
- The user's pantry (so you can lean on what they have)
- Today's currently-curated 4 recipes (so you don't suggest the same thing)
- The user's preferences (cuisines they like, dietary, allergies)
- The chat history so far

Output rules (non-negotiable):
- ALWAYS respond as a JSON object with this exact shape:
  { "reply": "<friendly chat text>", "recipe": null OR <full recipe object> }
- The "reply" field is what the user sees in the chat bubble. Keep it 1–3 short, warm sentences.
- Set "recipe" ONLY when you are proposing a brand-NEW dish, or a MODIFIED version the user EXPLICITLY asked you to change (e.g. "make it spicier", "swap the chicken for paneer"). In EVERY other case set "recipe": null and reply in words only. This includes: the user asking a QUESTION about a dish you already suggested ("what do I eat it with?", "how long does it keep?", "is it spicy?", "can I prep it ahead?"), acknowledging, thanking, or chatting. Re-sending the same dish (even slightly renamed) is a BUG — answer such questions with words and recipe:null. Only attach a card when the dish itself genuinely changed.
- Never wrap the JSON in markdown fences. Never add commentary outside the JSON.

Recipe shape (when present):
{
  "category": "breakfast" | "lunch" | "dinner" | "snacks",
  "name": "<dish name>",
  "difficulty": "easy" | "medium" | "elaborate",
  "time_text": "20–25 min",
  "budget_text": "$5",
  "calories_per_serving": <int>,
  "servings_base": 1,
  "ingredients": [{"name": "...", "amount": "<friendly display string>", "in_pantry": true|false, "qty": <number for ONE serving>, "unit": "g"|"ml"|"piece"}, ...],
  "steps": ["...", "..."]
}

Recipe constraints:
- Sized for ONE person (servings_base = 1).
- Mark in_pantry=true ONLY for ingredients that are actually in the user's pantry. Be honest.
- Real, well-known dishes only.
- MICRO-STEPS: 6–10 short steps, each ONE concrete action (or a tightly linked pair). Never bundle multiple actions into one step. Each step that uses an ingredient MUST state its quantity and unit. Wrap each INGREDIENT amount that should scale with serving size in DOUBLE CURLY BRACES, e.g. "Heat {{1 tbsp}} olive oil in a pan." Inside the braces use the friendly amount the user reads (e.g. {{200 ml}}, {{1 tbsp}}, {{30 g}}); for countable items put JUST the number, e.g. "Crack {{2}} eggs" (never "{{2 piece}}"). The app multiplies the number inside {{ }} when cooking for more people. NEVER wrap cooking times, temperatures, durations, or pan sizes — those do not scale; use plain **markdown bold** for those (e.g. simmer for **10 min**). (This matches how the cooking chef guides the user.)
- HOUSEHOLD MEASURES (what the user reads): the "amount" display string AND every {{ }} step token must use everyday home-kitchen measures, NOT lab-style precision. Use teaspoons, tablespoons, cups, pinches, whole counts, cloves, slices, "a handful", "a splash" — e.g. "1 tsp", "2 tbsp", "1/2 cup", "a pinch", "3 cloves", "1/4 cup". NEVER emit tiny scientific figures like "2 g mustard seeds", "12 ml oil", or "7 g garlic" — round to the nearest natural kitchen amount a person would actually measure (≈ "1/2 tsp mustard seeds", "1 tbsp oil", "2 cloves garlic"). Spices/seasonings are almost always tsp/tbsp/pinch, never grams.
- STRUCTURED AMOUNTS: SEPARATELY, for EVERY ingredient also emit "qty" (a plain number for ONE serving) and "unit" — canonical only: "g" for solids/weight, "ml" for liquids/volume, "piece" for countable items (eggs, cloves, slices). This is for the app's math only (not shown to the user). Convert the household amount: 1 tbsp≈15 ml, 1 tsp≈5 ml, 1 cup≈240 ml, 1 kg=1000 g, 1 L=1000 ml, 1 oz≈28 g, 1 clove=1 piece. Keep "amount" as the friendly household string. If unquantifiable ("to taste"), set qty:null and unit:null.
- COOKING FLOW: include the essential prep/setup steps, placed where they belong — preheat the oven (with temperature) early before baking/roasting, bring water to a boil before adding pasta/eggs, heat the pan/oil before adding food, and thaw/marinate/rest when the dish needs it. Never jump straight to "bake it" without a preheat step.
- Respect dietary restrictions and allergies STRICTLY.`;

interface RecipeSuggestion {
  category: "breakfast" | "lunch" | "dinner" | "snacks";
  name: string;
  difficulty: "easy" | "medium" | "elaborate";
  time_text: string;
  budget_text?: string;
  calories_per_serving: number;
  servings_base?: number;
  ingredients: Array<{ name: string; amount: string; in_pantry: boolean; qty?: number | null; unit?: string | null }>;
  steps: string[];
}

// Phase 2: canonicalise the structured per-serving amount the model emits.
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

// A normalized fingerprint of a recipe's ingredient set, used to detect when
// the author re-sends the same dish (vs. a genuine modification).
// deno-lint-ignore no-explicit-any
function ingredientKey(r: any): string {
  return (r?.ingredients || [])
    .map((i: any) => String(i?.name || "").toLowerCase().trim())
    .filter((s: string) => s)
    .sort()
    .join("|");
}

// Normalized dish name (drops parentheticals, punctuation, filler words) so
// "Punjabi-Style Chickpea Curry (Chole)" and "Punjabi Chickpea Curry (Chole)"
// compare equal — they're the same dish.
const NAME_FILLER = new Set(["style", "inspired", "classic", "homemade", "easy", "simple", "quick", "the", "a", "an", "with", "and", "of", "spiced", "authentic"]);
function normName(s: unknown): string {
  return String(s || "")
    .toLowerCase()
    .replace(/\(.*?\)/g, " ")
    .replace(/[^a-z0-9 ]/g, " ")
    .split(/\s+/)
    .filter((w) => w && !NAME_FILLER.has(w))
    .sort()
    .join(" ");
}
// Words that signal the user actually wants the dish CHANGED (so a new/updated
// card is warranted) vs. just asking a question about it.
const CHANGE_INTENT = /\b(spicier|milder|hotter|less|more|swap|replace|instead|without|add|remove|change|modify|make it|vegan|vegetarian|gluten|dairy|healthier|lighter|bigger|smaller|double|halve|extra|reduce)\b/i;

async function buildContextBlock(supabase: SupabaseClient, userId: string): Promise<string> {
  const today = new Date().toISOString().slice(0, 10);
  const [{ data: pantry }, { data: prefs }, { data: feed }] = await Promise.all([
    supabase.from("pantry_items").select("name, brand, stock_qty, stock_unit, expiry").eq("user_id", userId),
    supabase.from("user_preferences").select("*").eq("user_id", userId).maybeSingle(),
    supabase.from("daily_feed").select("slot, recipe:recipes(name, category)").eq("user_id", userId).eq("feed_date", today),
  ]);
  // Include how much the user has on hand + expiry date so the author can
  // favour ingredients they actually own and prioritise ones expiring soon.
  // READ-ONLY — the author never changes the pantry.
  const pantryStr = (pantry || []).map((p: any) => {
    const have = (typeof p.stock_qty === "number" && isFinite(p.stock_qty) && p.stock_unit)
      ? ` — have ${p.stock_qty} ${p.stock_unit}` : "";
    const exp = p.expiry ? ` (expires ${p.expiry})` : "";
    return `${p.name}${have}${exp}`;
  }).join(", ");
  const prefStr = prefs
    ? `Cuisines liked: ${(prefs.cuisines || []).join(", ") || "(none set)"}. Dietary: ${(prefs.dietary || []).join(", ") || "(none)"}. Allergies: ${(prefs.allergies || []).join(", ") || "(none)"}.`
    : "No preferences set.";
  const feedStr = (feed || []).map((f: any) => `${f.slot}: ${f.recipe?.name || "?"}`).join(" | ");
  return `USER PANTRY (quantity on hand + expiry shown — prefer ingredients they own and those expiring soon): ${pantryStr}\n\nUSER PREFERENCES: ${prefStr}\n\nTODAY'S CURRENT FEED: ${feedStr}`;
}

async function loadChatHistory(supabase: SupabaseClient, chatSessionId: string) {
  const { data } = await supabase.from("chat_messages")
    .select("role, text").eq("session_id", chatSessionId).order("created_at", { ascending: true });
  return (data || []).slice(-20);
}

// The Recipe Author chat persists across app opens until the next midnight
// curation wipes it (see curate-recipes). So "start" RESUMES the user's current
// author session — returning its full history (incl. suggestion cards stored in
// parts.recipe) — and only creates a fresh one when none exists.
async function handleStart(supabase: SupabaseClient, userId: string) {
  const { data: existing } = await supabase.from("chat_sessions")
    .select("id").eq("user_id", userId).eq("kind", "recipe_author")
    .order("started_at", { ascending: false }).limit(1).maybeSingle();

  let chatId: string;
  if (existing) {
    chatId = existing.id;
  } else {
    const { data: created, error } = await supabase.from("chat_sessions")
      .insert({ user_id: userId, kind: "recipe_author" }).select("id").single();
    if (error || !created) throw new Error(`chat session insert failed: ${error?.message}`);
    chatId = created.id;
  }

  // Rebuild the conversation for the client: text + any suggestion card.
  const { data: msgs } = await supabase.from("chat_messages")
    .select("role, text, parts, created_at").eq("session_id", chatId)
    .order("created_at", { ascending: true });
  const messages = (msgs || [])
    .filter((m) => m.text)
    .map((m) => ({
      role: m.role as string,
      text: m.text as string,
      // deno-lint-ignore no-explicit-any
      recipe: (m.parts && (m.parts as any).recipe) ? (m.parts as any).recipe : null,
    }));

  // Refresh each card's image_url from its vaulted row. The url stored on the
  // card at suggest-time was usually null (we paint lazily), so a card whose
  // image has since been painted shows its photo immediately on resume.
  const ids = Array.from(new Set(
    // deno-lint-ignore no-explicit-any
    messages.map((m: any) => m.recipe?.recipe_id).filter((x: unknown): x is string => typeof x === "string"),
  ));
  if (ids.length) {
    const { data: rows } = await supabase.from("recipes").select("id, image_url").in("id", ids);
    const urlById = new Map((rows || []).map((r) => [r.id as string, (r.image_url as string | null) ?? null]));
    for (const m of messages) {
      // deno-lint-ignore no-explicit-any
      const rec = (m as any).recipe;
      if (rec?.recipe_id && urlById.has(rec.recipe_id)) rec.image_url = urlById.get(rec.recipe_id);
    }
  }

  return { chat_session_id: chatId, messages };
}

async function handleSend(supabase: SupabaseClient, chatSessionId: string, userText: string, userId: string) {
  const { data: chat } = await supabase.from("chat_sessions").select("*").eq("id", chatSessionId).single();
  if (!chat) throw new Error("chat session not found");

  await supabase.from("chat_messages").insert({ session_id: chatSessionId, role: "user", text: userText });

  const context = await buildContextBlock(supabase, userId);
  const history = await loadChatHistory(supabase, chatSessionId);
  const contents = history
    .filter((m: any) => m.text && (m.role === "user" || m.role === "model"))
    .map((m: any) => ({ role: m.role === "model" ? "model" : "user", parts: [{ text: m.text as string }] }));

  const body = {
    systemInstruction: { parts: [{ text: `${AUTHOR_SYSTEM}\n\n=== LIVE CONTEXT ===\n${context}` }] },
    contents,
    generationConfig: {
      // Match the curator: more reasoning for richer, more accurate recipes.
      thinkingConfig: { thinkingLevel: "medium" },
      responseMimeType: "application/json",
      temperature: 0.8,
    },
    // Google Search grounding — lets the author verify real dishes and pull
    // facts it's unsure about, autonomously. (googleSearch + JSON output coexist
    // on this model — same pattern the curator's validateRecipes uses.)
    tools: [{ googleSearch: {} }],
  };

  const { text } = await geminiCall(body);
  let parsed: { reply: string; recipe?: RecipeSuggestion | null };
  try {
    parsed = JSON.parse(extractFirstJsonObject(text));
  } catch (e) {
    parsed = { reply: text.trim() || "Hmm, I had trouble formatting that. Could you rephrase?", recipe: null };
  }

  // Safety net for re-sent cards: if the model attached a recipe whose
  // ingredient set is identical to the LAST one it already suggested in this
  // chat, it's just re-showing the same dish for a follow-up question — drop
  // the card and keep the words. (A real modification changes ingredients, so
  // it still gets a card.)
  if (parsed.recipe) {
    const { data: prev } = await supabase.from("chat_messages")
      .select("parts").eq("session_id", chatSessionId).eq("role", "model")
      .not("parts", "is", null).order("created_at", { ascending: false }).limit(1).maybeSingle();
    // deno-lint-ignore no-explicit-any
    const prevRecipe = (prev?.parts as any)?.recipe;
    if (prevRecipe) {
      const sameDish = normName(prevRecipe.name) === normName(parsed.recipe.name) ||
        (ingredientKey(prevRecipe) !== "" && ingredientKey(prevRecipe) === ingredientKey(parsed.recipe));
      const wantsChange = CHANGE_INTENT.test(userText);
      // Same dish as the last card AND the user didn't ask to change it → this
      // is a re-send for a follow-up question. Drop the card, keep the words.
      // (A real modification — "make it spicier" — keeps the card so the app can
      // update it in place.)
      if (sameDish && !wantsChange) parsed.recipe = null;
    }
  }

  // Give every suggested recipe its own durable home (a recipes row) the moment
  // it's suggested, and stamp that row's id ONTO the chat card. This id is the
  // "dedicated slot" the rest of the flow keys off: preview + add-to-feed reuse
  // this exact row (no re-vaulting, no duplicate rows), and the card shows the
  // painted photo as soon as it's ready — no longer only after "Add to today".
  // We do NOT paint here: painting stays lazy (on first preview) so we never pay
  // for an image on a suggestion the user never opens.
  let cardRecipe:
    | (RecipeSuggestion & { recipe_id?: string; image_url?: string | null })
    | null = null;
  if (parsed.recipe) {
    try {
      const { recipeId, imageUrl } = await vaultRecipe(supabase, parsed.recipe, userId);
      cardRecipe = { ...parsed.recipe, recipe_id: recipeId, image_url: imageUrl };
    } catch (e) {
      console.error(`[recipe-author] vault-on-suggest failed: ${e instanceof Error ? e.message : String(e)}`);
      cardRecipe = parsed.recipe; // graceful fallback: card with no id (legacy path)
    }
  }

  // Never surface a blank "(no reply)" to the user. With grounding on, the model
  // occasionally returns a recipe card but no sentence — in that case introduce
  // the card; if it produced nothing usable at all, ask them to rephrase.
  const replyText = (parsed.reply && parsed.reply.trim())
    ? parsed.reply.trim()
    : (cardRecipe ? `Here's a ${cardRecipe.name} idea — take a look.` : "Sorry, I didn't quite catch that — could you say it another way?");
  await supabase.from("chat_messages").insert({
    session_id: chatSessionId,
    role: "model",
    text: replyText,
    parts: cardRecipe ? { recipe: cardRecipe } : null,
    model: GEMINI_MODEL,
  });

  return { reply: replyText, recipe: cardRecipe || null };
}

// Save a suggested recipe into the user's recipe vault (per-user, deduped by
// content hash). Returns the row id, whether it was newly created, and its
// current image_url (null until painted). Shared by `preview` and `add_to_feed`.
async function vaultRecipe(
  supabase: SupabaseClient, recipe: RecipeSuggestion, userId: string,
): Promise<{ recipeId: string; wasNew: boolean; imageUrl: string | null }> {
  const hash = await hashRecipe(recipe.name, recipe.ingredients);
  const { data: existing } = await supabase.from("recipes")
    .select("id, image_url").eq("user_id", userId).eq("content_hash", hash).maybeSingle();
  if (existing) return { recipeId: existing.id, wasNew: false, imageUrl: existing.image_url ?? null };

  const { data: inserted, error } = await supabase.from("recipes").insert({
    user_id: userId,
    content_hash: hash,
    name: recipe.name,
    category: recipe.category,
    difficulty: recipe.difficulty,
    time_text: recipe.time_text,
    budget_text: recipe.budget_text || "$5",
    servings_base: recipe.servings_base || 1,
    calories_per_serving: recipe.calories_per_serving,
    ingredients: recipe.ingredients.map((i) => ({
      name: i.name, amount: i.amount, in_pantry: !!i.in_pantry,
      qty: canonQty(i.qty), unit: canonUnit(i.unit),
    })),
    steps: recipe.steps,
    curator_model: `${GEMINI_MODEL} (via recipe-author)`,
    curator_thinking: "low",
    prompt_version: "v1",
    source: "author",
  }).select("id").single();
  if (error || !inserted) throw new Error(`vault insert failed: ${error?.message}`);
  return { recipeId: inserted.id, wasNew: true, imageUrl: null };
}

// Paint a recipe's image. paint-recipe runs as its OWN isolate, so once this
// request reaches it the painting completes even if our caller (or the user's
// app) goes away — satisfying "don't stop midway if the user exits".
async function paintRecipe(recipeId: string): Promise<void> {
  await fetch(`${SUPABASE_URL}/functions/v1/paint-recipe`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
    body: JSON.stringify({ recipe_id: recipeId }),
  });
}

// Preview a suggestion in the detail page: vault it (so it has an id) and kick
// off painting IN THE BACKGROUND, returning immediately. The client then polls
// `recipe_image` for the URL as it lands. Painting runs to completion even if
// the user backs out of the preview (EdgeRuntime.waitUntil keeps the worker
// alive; the paint-recipe call also runs in its own isolate).
async function handlePreview(supabase: SupabaseClient, recipe: RecipeSuggestion, userId: string) {
  // Reuse the row already vaulted when this recipe was suggested — its id rides
  // along on the card now. Only vault here as a fallback for legacy cards from
  // before that change (or a stale id that no longer exists).
  let recipeId = (recipe as { recipe_id?: string })?.recipe_id;
  let imageUrl: string | null = null;
  if (recipeId) {
    const { data: r } = await supabase.from("recipes")
      .select("id, image_url").eq("id", recipeId).eq("user_id", userId).maybeSingle();
    if (r) imageUrl = (r.image_url as string | null) ?? null;
    else recipeId = undefined; // stale — re-vault below
  }
  if (!recipeId) {
    const v = await vaultRecipe(supabase, recipe, userId);
    recipeId = v.recipeId;
    imageUrl = v.imageUrl;
  }

  // Already painted → hand it back straight away.
  if (imageUrl) return { recipe_id: recipeId, image_url: imageUrl };

  // Not painted yet: fire the paint in its OWN isolate and return IMMEDIATELY.
  // We deliberately do NOT block on the ~30–120s paint here — that long
  // synchronous wait is what made the request time out so the preview showed no
  // image. paint-recipe runs to completion independently of us; the client then
  // polls `recipe_image` until the URL lands. EdgeRuntime.waitUntil keeps this
  // worker alive just long enough to dispatch the call.
  try {
    // deno-lint-ignore no-explicit-any
    const er = (globalThis as any).EdgeRuntime;
    if (er && typeof er.waitUntil === "function") er.waitUntil(paintRecipe(recipeId));
    else void paintRecipe(recipeId);
  } catch (_) { /* fire and forget */ }
  return { recipe_id: recipeId, image_url: null };
}

// Lightweight poll: current image_url for a recipe the user owns.
async function handleRecipeImage(supabase: SupabaseClient, recipeId: string, userId: string) {
  const { data } = await supabase.from("recipes")
    .select("image_url").eq("id", recipeId).eq("user_id", userId).maybeSingle();
  return { recipe_id: recipeId, image_url: data?.image_url ?? null };
}

async function handleAddToFeed(
  supabase: SupabaseClient,
  recipe: RecipeSuggestion,
  slot: string | undefined,
  userId: string,
) {
  const targetSlot = (slot || recipe.category) as "breakfast" | "lunch" | "dinner" | "snacks";
  const { recipeId, wasNew, imageUrl } = await vaultRecipe(supabase, recipe, userId);

  const matchScore = recipe.ingredients.length === 0
    ? 0
    : Math.round((100 * recipe.ingredients.filter((i) => i.in_pantry).length) / recipe.ingredients.length);

  // Add it to the feed the user is CURRENTLY SEEING. get-daily-feed returns the
  // most-recent feed_date, so we target that (it's normally today, but the
  // nightly curator may have pre-generated a future date). Falling back to
  // today only when the user has no feed yet. Targeting `new Date()` blindly is
  // what made adds "disappear" when the displayed feed was a different date.
  const today = new Date().toISOString().slice(0, 10);
  // Target the SAME feed the user is currently seeing. get-daily-feed returns the
  // most-recent feed_date, so we add to exactly that one. (The previous
  // `>= today` guard sent adds to UTC-today whenever the user's local feed was
  // "yesterday" in UTC — creating a stray separate-date feed that shadowed the
  // real one and made the feed look empty / "disconnected".)
  const { data: latestFeed } = await supabase.from("daily_feed")
    .select("feed_date").eq("user_id", userId)
    .order("feed_date", { ascending: false }).limit(1).maybeSingle();
  const targetDate = latestFeed?.feed_date ?? today;
  // Add ALONGSIDE existing slot entries (migration 004 allows multiple per slot).
  // Skip the insert silently if the exact same recipe is already pinned.
  const { error: feedErr } = await supabase.from("daily_feed").upsert(
    {
      user_id: userId,
      feed_date: targetDate,
      slot: targetSlot,
      recipe_id: recipeId,
      match_score: matchScore,
      status: "active",
    },
    { onConflict: "user_id,feed_date,slot,recipe_id", ignoreDuplicates: true },
  );
  if (feedErr) throw new Error(`daily_feed upsert failed: ${feedErr.message}`);

  // The feed row is already committed above — return NOW so the app's feed
  // refresh + the "added" confirmation appear instantly. If the image isn't
  // painted yet, paint it in the BACKGROUND (its own isolate) rather than
  // blocking this response for the ~30–120s paint. Blocking here was what made
  // the recipe seem to "not appear" — the client didn't refresh until the slow
  // call returned. (A previewed recipe is usually already painted → no-op.)
  if (!imageUrl) {
    try {
      // deno-lint-ignore no-explicit-any
      const er = (globalThis as any).EdgeRuntime;
      if (er && typeof er.waitUntil === "function") er.waitUntil(paintRecipe(recipeId));
      else void paintRecipe(recipeId);
    } catch (_) { /* fire and forget */ }
  }

  return { recipe_id: recipeId, slot: targetSlot, match_score: matchScore, was_new: wasNew, painted: imageUrl ? { ok: true } : null };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST,OPTIONS",
      "Access-Control-Allow-Headers": "authorization,content-type",
    }});
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    const body = await req.json();
    const action = body.action;
    const userId = body.user_id || DEMO_USER_ID;
    let result;
    switch (action) {
      case "start":
        result = await handleStart(supabase, userId); break;
      case "send":
        result = await handleSend(supabase, body.chat_session_id, body.text, userId); break;
      case "preview":
        result = await handlePreview(supabase, body.recipe, userId); break;
      case "recipe_image":
        result = await handleRecipeImage(supabase, body.recipe_id, userId); break;
      case "add_to_feed":
        result = await handleAddToFeed(supabase, body.recipe, body.slot, userId); break;
      default:
        return Response.json({ error: `unknown action: ${action}` }, { status: 400 });
    }
    return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    console.error(`[recipe-author] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
