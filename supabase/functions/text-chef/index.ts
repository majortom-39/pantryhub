// text-chef — guides a user through cooking one recipe, step by step.
//
// One endpoint, four actions:
//   { action: "start",   recipe_id }              → creates cook+chat sessions, returns first chef line
//   { action: "send",    cook_session_id, text }  → user typed a message → chef replies
//   { action: "advance", cook_session_id, direction: "next"|"back" } → step nav, chef narrates
//   { action: "finish",  cook_session_id }        → auto-deduct pantry, log to cooked_recipes
//
// All Gemini calls use a shared retry helper with exponential backoff on 429 / 5xx.
// TODO(secrets): GEMINI_API_KEY hardcoded — migrate to function secrets later.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const GEMINI_MODEL = "gemini-3.1-flash-lite";
// Routes through the keyless Cloud Run Vertex proxy (bills to GCP credits).
const VERTEX_PROXY_URL = Deno.env.get("VERTEX_PROXY_URL")!;
const VERTEX_PROXY_SECRET = Deno.env.get("VERTEX_PROXY_SECRET")!;
const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// The single shared writer of recipe-ledger edits (see supabase/functions/recipe-ledger).
const LEDGER_URL = "https://uipgydhflvxpxfuqzdxm.functions.supabase.co/recipe-ledger";
const LEDGER_SECRET = Deno.env.get("LEDGER_SECRET") || "";

// Ledger-edit tools the chef can call. KEEP IN SYNC with voice-chef + recipe-ledger ops.
const LEDGER_TOOLS = [{
  functionDeclarations: [
    {
      name: "edit_ingredient",
      description: "Change an existing ingredient's name and/or amount (e.g. swap butter for oil, or change '2 cups' to '1 cup'). Use when the user wants to substitute or adjust an ingredient.",
      parameters: {
        type: "object",
        properties: {
          name: { type: "string", description: "Current name of the ingredient to change, as it appears in the list." },
          new_name: { type: "string", description: "New ingredient name. Omit if only changing the amount." },
          new_amount: { type: "string", description: "New amount, e.g. '1 tbsp'. Omit if only changing the name." },
        },
        required: ["name"],
      },
    },
    {
      name: "add_ingredient",
      description: "Add a new ingredient to the recipe.",
      parameters: {
        type: "object",
        properties: {
          name: { type: "string" },
          amount: { type: "string", description: "Amount, e.g. '2 cloves' or '1 cup'." },
        },
        required: ["name", "amount"],
      },
    },
    {
      name: "remove_ingredient",
      description: "Remove an ingredient from the recipe entirely.",
      parameters: {
        type: "object",
        properties: { name: { type: "string", description: "Name of the ingredient to remove." } },
        required: ["name"],
      },
    },
    {
      name: "substitute_ingredient",
      description: "Set or REPLACE the substitute for a missing ingredient, in place. Use this whenever the user wants a different substitute, or wants to substitute a missing ingredient with something from their pantry. NEVER use add_ingredient for a substitution — that wrongly adds a separate ingredient. The original ingredient stays (shown struck-through) with the new substitute beneath it. Pass an empty substitute_name to clear the substitute.",
      parameters: {
        type: "object",
        properties: {
          name: { type: "string", description: "The original (missing) ingredient to attach the substitute to, exactly as it appears, e.g. 'Berries'." },
          substitute_name: { type: "string", description: "The substitute to use instead — must be something in the user's pantry, e.g. 'Cinnamon'. Empty string removes the substitute." },
          note: { type: "string", description: "Optional short note, e.g. 'a light sprinkle'." },
        },
        required: ["name", "substitute_name"],
      },
    },
    {
      name: "edit_step",
      description: "Rewrite the text of an existing step.",
      parameters: {
        type: "object",
        properties: {
          step_number: { type: "integer", description: "1-based step number to rewrite." },
          new_text: { type: "string" },
        },
        required: ["step_number", "new_text"],
      },
    },
    {
      name: "add_step",
      description: "Insert a new step.",
      parameters: {
        type: "object",
        properties: {
          text: { type: "string" },
          after_step_number: { type: "integer", description: "Insert AFTER this 1-based step number. Use 0 for the very beginning. Omit to append at the end." },
        },
        required: ["text"],
      },
    },
    {
      name: "remove_step",
      description: "Delete a step.",
      parameters: {
        type: "object",
        properties: { step_number: { type: "integer", description: "1-based step number to delete." } },
        required: ["step_number"],
      },
    },
    // ─── session navigation ──────────────────────────────────────────────
    // These don't change the recipe — they move the user's progress pointer
    // for the cook in flight. Use them when the user signals they finished a
    // step, want to go back, redo something, or jump to a specific step.
    {
      name: "mark_step_done",
      description: "Mark a step as completed and advance to the next one. Use when the user signals they're done with a step ('done', 'okay', 'ready', 'finished', 'next', 'got it'). ALWAYS use this instead of just saying 'great, next step' — the app's checklist and step pointer move only through this tool.",
      parameters: {
        type: "object",
        properties: { step_number: { type: "integer", description: "1-based step number the user just finished." } },
        required: ["step_number"],
      },
    },
    {
      name: "mark_step_undone",
      description: "Uncheck a step (mark not done) and move the pointer back to it. Use when the user says 'wait, I haven't done that yet' or 'undo'.",
      parameters: {
        type: "object",
        properties: { step_number: { type: "integer", description: "1-based step number to mark not done." } },
        required: ["step_number"],
      },
    },
    {
      name: "set_current_step",
      description: "Jump the pointer to a specific step without changing what's checked off. Use when the user says 'go back to step 2' or 'let's redo step 3'.",
      parameters: {
        type: "object",
        properties: { step_number: { type: "integer", description: "1-based step number to focus on." } },
        required: ["step_number"],
      },
    },
    // ─── timers ───────────────────────────────────────────────────────────
    // In-app cooking timers that appear as cards on the user's screen and ring
    // (even on the lock screen). Each has a clear label/topic.
    {
      name: "start_timer",
      description: "Start an in-app cooking timer with a descriptive label. Use when the user AGREES to a timer you offered (e.g. for a simmer, bake, rest, or boil). Offer first when a step has a duration; set it once they say yes (or set immediately if they explicitly ask).",
      parameters: {
        type: "object",
        properties: {
          label: { type: "string", description: "Short topic for the timer, e.g. 'Simmering beef', 'Resting dough', 'Boiling pasta'." },
          seconds: { type: "integer", description: "Total duration in seconds (e.g. 10 minutes = 600)." },
        },
        required: ["label", "seconds"],
      },
    },
    {
      name: "cancel_timer",
      description: "Cancel/stop a running timer. Match by its label.",
      parameters: {
        type: "object",
        properties: { label: { type: "string", description: "Label of the timer to cancel, as it was set." } },
        required: ["label"],
      },
    },
  ],
}];

const TIMER_OPS = new Set(["start_timer", "cancel_timer"]);

const TIMERS_URL = "https://uipgydhflvxpxfuqzdxm.functions.supabase.co/cook-timers";

// Calls the cook-timers writer for the chef's timer tools. Maps tool name →
// action. Returns { ok, timers, summary } so the model can confirm.
// deno-lint-ignore no-explicit-any
async function callTimers(cookSessionId: string, op: string, args: Record<string, unknown>): Promise<any> {
  try {
    const action = op === "start_timer" ? "create" : "cancel";
    const payload: Record<string, unknown> = { action, cook_session_id: cookSessionId, created_by: "text_chef" };
    if (op === "start_timer") { payload.label = args.label; payload.seconds = args.seconds; }
    else { payload.label = args.label; }
    const res = await fetch(TIMERS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
      body: JSON.stringify(payload),
    });
    const j = await res.json();
    if (j.error) return { ok: false, error: j.error, timers: j.timers || [] };
    const summary = op === "start_timer"
      ? `Started timer "${args.label}".`
      : `Cancelled timer "${args.label}".`;
    return { ok: true, summary, timers: j.timers || [] };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

// Calls the single shared ledger writer. Returns { ok, summary, ingredients, steps } | { ok:false, error }.
async function callLedger(cookSessionId: string, op: string, args: Record<string, unknown>) {
  try {
    const res = await fetch(LEDGER_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Ledger-Secret": LEDGER_SECRET },
      body: JSON.stringify({ cook_session_id: cookSessionId, op, args }),
    });
    return await res.json();
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

// ---------------------------------------------------------------------------
// Shared LLM helper — retry-aware Gemini caller.
// Inlined into each LLM function (Supabase edge functions are isolated bundles).
// ---------------------------------------------------------------------------
// deno-lint-ignore no-explicit-any
async function geminiGenerate(body: object): Promise<{ parts: any[]; thinkingTokens: number }> {
  const maxRetries = 4;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const res = await fetch(VERTEX_PROXY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Proxy-Secret": VERTEX_PROXY_SECRET },
      body: JSON.stringify({ model: GEMINI_MODEL, ...body }),
    });
    if (res.ok) {
      const json = await res.json();
      const parts = json?.candidates?.[0]?.content?.parts ?? [];
      const thinkingTokens = json?.usageMetadata?.thoughtsTokenCount ?? 0;
      return { parts, thinkingTokens };
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

// ---------------------------------------------------------------------------
// Pantry deduction heuristics
// ---------------------------------------------------------------------------
function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}
function parseFraction(s: string): number {
  if (s.includes("/")) {
    const [a, b] = s.split("/").map(parseFloat);
    return b !== 0 ? a / b : 0;
  }
  return parseFloat(s) || 0;
}
/**
 * Rough estimate of what fraction of a pantry item's total stock to deduct,
 * given a recipe's ingredient amount string. Pessimistically clamped so we
 * never empty a pantry item from a single recipe.
 *
 * v1 heuristic — future: replace with an LLM-driven unit converter using
 * the actual pantry quantity (e.g. "1 tbsp from 500 ml bottle 65% full").
 */
function estimateDeductionFraction(amountText: string): number {
  const t = amountText.toLowerCase().trim();
  if (/to\s+taste|pinch|sprinkle|garnish|drizzle/.test(t)) return 0.01;
  const numMatch = t.match(/^([\d.\/]+)/);
  const num = numMatch ? parseFraction(numMatch[1]) : 1;
  if (/tsp|teaspoon/.test(t))     return clamp(num * 0.01,  0.005, 0.5);
  if (/tbsp|tablespoon/.test(t))  return clamp(num * 0.025, 0.01,  0.5);
  if (/cup/.test(t))              return clamp(num * 0.2,   0.05,  0.8);
  if (/\bml\b/.test(t))           return clamp(num * 0.002, 0.005, 0.8);
  if (/gram|\bg\b/.test(t))       return clamp(num * 0.001, 0.005, 0.8);
  if (/\bkg\b/.test(t))           return clamp(num * 1.0,   0.1,   0.95);
  if (/liter|\bl\b/.test(t))      return clamp(num * 1.0,   0.1,   0.95);
  if (/clove|slice|piece|pcs|pc/.test(t)) return clamp(num * 0.1, 0.05, 0.5);
  if (numMatch)                    return clamp(num * 0.17, 0.05, 0.6); // bare count
  return 0.1;
}
function applyDeduction(fullness: number[], fractionTotal: number): number[] {
  const out = fullness.map(Number);
  let r = fractionTotal;
  for (let i = 0; i < out.length && r > 0; i++) {
    const take = Math.min(out[i], r);
    out[i] = Math.max(0, +(out[i] - take).toFixed(4));
    r -= take;
  }
  return out;
}
function pantryMatch(pantryName: string, recipeName: string): boolean {
  const a = pantryName.toLowerCase();
  const b = recipeName.toLowerCase();
  return a.includes(b) || b.includes(a);
}

// ---------------------------------------------------------------------------
// Chef prompts
// ---------------------------------------------------------------------------
const CHEF_SYSTEM = `You are PantryHub's Cooking Chef — the user's personal chef in their pocket, walking them through cooking ONE recipe right now.

WHO YOU ARE
A calm, warm friend in their kitchen. The phone is on the counter; their hands are busy. You adapt to THEIR pace, not the other way around. Finishing fast isn't the goal — helping them cook well and enjoy it is.

HOW YOU TALK
- 1–2 short sentences per reply. Never paragraphs.
- Warm, natural, no formality. Contractions are good.
- Use **markdown bold** ONLY to emphasise quantities, units, and ingredient names inside step instructions, e.g. "Whisk **200 ml** milk with **1 tsp** cinnamon." This is what the user sees on screen; it helps them scan while cooking.
- Never use other markdown (no headings, lists, code, emoji), and never use bold for filler words.
- Don't say "Sure!", "Of course!", "Absolutely!" — just answer.

MAIN STEPS vs MICRO-ACTIONS (this is how you stay in sync)
- The numbered steps are the MAIN steps (the shared checklist). A single main step often bundles several actions (e.g. "Toast the bread, then cut it into strips.").
- Break each main step into MICRO-ACTIONS and give ONE at a time, with quantities. Track which micro-action you're on using the conversation so far — that's your working memory.
- Only call mark_step_done(step_number) when the user has completed EVERY micro-action of that main step. Do NOT advance the main step just because they finished one part of it.
- After a micro-action, STOP and wait.

SOURCE OF TRUTH
- The "CURRENTLY ON STEP" line and the [done]/[NOW]/[ ] markers in your context reflect the user's REAL checklist — they may have checked or jumped steps themselves. ALWAYS treat that as the truth: narrate the step marked [NOW], never an earlier one, and never assume you're on a different step than shown.
- The ACTIVE TIMERS line shows the LIVE remaining time. If asked "how long is left", read it straight from there; "(DONE — rang)" means that timer already finished.

STEP NAVIGATION (you control progress — KEEP THE CHECKLIST IN SYNC)
- The checklist/pointer in your context is the SOURCE OF TRUTH and it moves ONLY when you call a tool. Before you introduce or move to ANY next step (micro or main), reconcile it: if the user has finished the current MAIN step, you MUST call mark_step_done(step_number) for it FIRST, then speak the next step. Reconcile every turn — never let your words get ahead of the checklist.
- When the user signals done ("done", "okay", "ready", "next", "got it", "finished") OR the app sends a Done signal: look at the conversation — if the current main step still has parts left, give the NEXT micro-action; the moment the whole step is complete, CALL mark_step_done(step_number) and only then introduce the next step. Never skip a part of a step, and never advance two steps at once.
- ONE AT A TIME — CRITICAL: in a single reply, call mark_step_done for AT MOST ONE step, and ONLY for a step the user actually confirmed finished. NEVER mark several steps done in one turn, never "catch up" or batch-advance through the recipe, and never advance a step the user hasn't confirmed. After marking a step done, STOP and wait for the user before going further.
- When they want to go back ("wait", "go back", "I didn't do that"), use set_current_step or mark_step_undone.
- Never say "I've moved you forward" / "next step" / "great, done" without actually calling the matching tool that same turn — the checklist + pointer move only through these tools.
- If they ask "repeat that" — just repeat the last micro-action. Sensory cues over quizzing.

TIMERS
- When a step involves waiting/cooking for a duration (simmer, bake, boil, rest, chill), OFFER to set a timer in one short sentence ("Want me to set a 10-minute timer for the simmer?"). When the user agrees — or if they ask directly — call start_timer.
- LABEL IT YOURSELF when the topic is obvious from the current step — derive a clear label from what's cooking (e.g. "Simmering the curry", "Baking", "Boiling pasta", "Resting the dough"). Only when the topic is genuinely unclear, ask one short question first ("What should I call this timer?"). NEVER set a blank or generic "Timer" — always give it a meaningful label.
- For the duration: if the step states a time, use it. If the user asks for a timer but gives no duration and none is implied, ask how long. Only call start_timer once you have both a label and a time.
- Don't set a timer without offering first, and don't re-offer one that's already running (check ACTIVE TIMERS in context).
- To stop one, call cancel_timer with its label. If the user asks to cancel the "done"/"finished" timers, cancel ONLY timers that have actually finished — never a running one. Before cancelling a timer that is STILL RUNNING, CONFIRM with the user first (name it + how long is left). Never cancel more timers than the user clearly asked for. After setting/cancelling, mention it in one short sentence.

COOKING SENSE (flow)
- Use real kitchen know-how. If the current step needs the oven, pan, grill, or water already hot/preheated/boiling and that hasn't happened yet, prompt it at the right moment (e.g. "let's get the oven preheating to 200°C first so it's ready"). Account for prep that must happen before a step works (thawing, marinating, resting). Guide it in naturally — don't dump it all at once.

PERSIST WHAT YOU DECIDE TOGETHER
- If you and the user agree on a NEW micro-step that isn't in the recipe (e.g. "let's toast the bread sticks first and cut them into strips"), CALL add_step to write it into the recipe at the right position. The recipe is a living document.
- If you change a step in conversation ("let's actually fry it instead of bake"), call edit_step.

INGREDIENTS, SUBSTITUTIONS & PANTRY (non-negotiable)
- Before suggesting ANY ingredient or substitute, look at the USER'S PANTRY and DIETARY PREFERENCES below. Only suggest items that are actually in their pantry. If nothing fits, say so honestly.
- Never suggest anything that breaks their allergies or dietary preferences.
- Don't claim something is in their pantry unless it's listed below.

EDITING THE RECIPE (use the tools)
- edit_ingredient, add_ingredient, remove_ingredient, substitute_ingredient, edit_step, add_step, remove_step.
- To substitute a missing ingredient, or to change an existing substitute, ALWAYS use substitute_ingredient (original ingredient name + new substitute). NEVER use add_ingredient for a substitution — that creates a duplicate.
- CASCADE EVERY INGREDIENT CHANGE THROUGH THE STEPS. After you edit/substitute/remove an ingredient, the tool result will include "affected_steps" listing every step that still names the old ingredient. You MUST then call edit_step for EACH of those steps so they reference the new ingredient (and its amount/unit). Don't stop at one step. Don't skip the ones further down the list. Do them all in the same turn.
- This recipe is LIVE and SHARED: edits update the on-screen ingredients and steps and the voice chef sees the same recipe. Never say you "can't change it" — you can.
- Only edit when the user actually asks for a change.`;

interface Recipe {
  id: string;
  name: string;
  ingredients: Array<{ name: string; amount: string; in_pantry?: boolean; qty?: number | null; unit?: string | null }>;
  steps: string[];
}
interface PantryItem {
  id: string;
  name: string;
  brand?: string;
  fullness_levels: number[];
  stock_qty?: number | null;
  stock_unit?: string | null;
  expiry?: string | null;
}
interface UserPrefs {
  dietary: string[];
  allergies: string[];
  cuisines: string[];
}

// Fetch the user's dietary preferences / allergies / cuisines so the chef can
// ground its suggestions in them. Soft-fails to empty arrays.
async function fetchPrefs(supabase: SupabaseClient, userId: string): Promise<UserPrefs> {
  const { data } = await supabase.from("user_preferences")
    .select("dietary, allergies, cuisines").eq("user_id", userId).maybeSingle();
  return {
    dietary: Array.isArray(data?.dietary) ? data!.dietary : [],
    allergies: Array.isArray(data?.allergies) ? data!.allergies : [],
    cuisines: Array.isArray(data?.cuisines) ? data!.cuisines : [],
  };
}

// Active running timers for the session — so the chef knows what's already
// going and doesn't double-set, and can reference them.
// deno-lint-ignore no-explicit-any
async function fetchTimers(supabase: SupabaseClient, cookSessionId: string): Promise<any[]> {
  const { data } = await supabase.from("cook_timers")
    .select("label, ends_at").eq("cook_session_id", cookSessionId).eq("status", "running");
  return data || [];
}

function timersLine(timers: { label: string; ends_at: string }[]): string {
  if (!timers || timers.length === 0) return "none";
  const now = Date.now();
  return timers.map((t) => {
    const secs = Math.max(0, Math.round((new Date(t.ends_at).getTime() - now) / 1000));
    if (secs <= 0) return `${t.label} (DONE — rang)`;
    const m = Math.floor(secs / 60), s = secs % 60;
    return `${t.label} (${m}:${String(s).padStart(2, "0")} left)`;
  }).join(", ");
}

// Tidy number: whole when near-integer, else 2dp.
function fmtNum(n: number): string {
  return Math.abs(n - Math.round(n)) < 0.01 ? String(Math.round(n)) : String(Math.round(n * 100) / 100);
}

// Scale a free-text amount ("200 g", "1 1/2 tbsp", "to taste") by a factor.
// Non-numeric amounts pass through unchanged. Used as the graceful fallback
// when an ingredient has no structured qty/unit.
function scaleAmount(amount: string, factor: number): string {
  if (!amount || !isFinite(factor) || factor === 1) return amount;
  const m = amount.trim().match(/^(\d+\s+\d+\/\d+|\d+\/\d+|\d*\.?\d+)\s*(.*)$/);
  if (!m) return amount;
  let value: number;
  const numStr = m[1];
  if (numStr.includes("/")) {
    const parts = numStr.split(/\s+/);
    if (parts.length === 2) {
      const [a, b] = parts[1].split("/").map(Number);
      value = Number(parts[0]) + (b ? a / b : 0);
    } else {
      const [a, b] = numStr.split("/").map(Number);
      value = b ? a / b : 0;
    }
  } else value = Number(numStr);
  if (!isFinite(value)) return amount;
  const rest = m[2] || "";
  const num = fmtNum(value * factor);
  return rest ? `${num} ${rest}` : num;
}

// Phase 2: scale ONE ingredient's display amount to the chosen servings.
// Prefers structured qty×factor (precise); falls back to the string scaler.
// deno-lint-ignore no-explicit-any
function scaleIngredientDisplay(i: any, factor: number): string {
  if (typeof i?.qty === "number" && isFinite(i.qty) && i.unit) {
    return `${fmtNum(i.qty * factor)} ${i.unit}`;
  }
  return scaleAmount(i?.amount || "", factor);
}

// Phase 2: scale the {{...}} ingredient-amount tokens inside step text, leaving
// times/temperatures (plain **bold**) untouched. Strips the braces so the chef
// reads natural, already-scaled amounts.
function scaleStepText(text: string, factor: number): string {
  if (!text) return text;
  return text.replace(/\{\{([^}]*)\}\}/g, (_m, inner) => scaleAmount(String(inner).trim(), factor));
}

// Recompute canonical stock from a package-size string × container fullness,
// so stock_qty stays in sync when a cook deducts from the pantry. Mirrors the
// `pantry` function's normaliser. Returns null when the size is unparseable.
function recomputeStock(quantity: string, fullnessLevels: number[]): { stock_qty: number; stock_unit: string } | null {
  const q = (quantity || "").toLowerCase().trim();
  const m = q.match(/(\d+\s+\d+\/\d+|\d+\/\d+|\d*\.?\d+)/);
  if (!m) return null;
  let value: number;
  const numStr = m[1];
  if (numStr.includes("/")) {
    const parts = numStr.split(/\s+/);
    if (parts.length === 2) { const [a, b] = parts[1].split("/").map(Number); value = Number(parts[0]) + (b ? a / b : 0); }
    else { const [a, b] = numStr.split("/").map(Number); value = b ? a / b : 0; }
  } else value = Number(numStr);
  if (!isFinite(value) || value <= 0) return null;
  const rest = q.slice((m.index || 0) + numStr.length);
  let amount = value, unit = "piece";
  if (/\bkg\b|kilogram/.test(rest)) { amount = value * 1000; unit = "g"; }
  else if (/\bmg\b|milligram/.test(rest)) { amount = value / 1000; unit = "g"; }
  else if (/\bg\b|gram/.test(rest)) { amount = value; unit = "g"; }
  else if (/\boz\b|ounce/.test(rest)) { amount = value * 28.35; unit = "g"; }
  else if (/\blb\b|pound/.test(rest)) { amount = value * 453.6; unit = "g"; }
  else if (/\bml\b|millilit/.test(rest)) { amount = value; unit = "ml"; }
  else if (/\b(l|litre|liter)\b/.test(rest)) { amount = value * 1000; unit = "ml"; }
  else if (/\bdozen\b/.test(rest)) { amount = value * 12; unit = "piece"; }
  const lv = (Array.isArray(fullnessLevels) && fullnessLevels.length ? fullnessLevels : [1]).map(Number).filter((n) => isFinite(n));
  const fillSum = lv.reduce((a, b) => a + b, 0) || 1;
  const stock = amount * fillSum;
  return { stock_qty: unit === "piece" ? Math.round(stock) : Math.round(stock * 10) / 10, stock_unit: unit };
}

// Loose pantry name match (same rule the curator uses).
function matchPantry(name: string, pantry: PantryItem[]): PantryItem | undefined {
  const n = (name || "").toLowerCase().trim();
  if (!n) return undefined;
  return pantry.find((p) => { const a = p.name.toLowerCase().trim(); return a.includes(n) || n.includes(a); });
}

// "2 adults + 1 child (≈ 2.5 servings)" — human serving summary.
function servingLabel(adults: number, children: number): string {
  const eff = adults + 0.5 * children;
  const parts: string[] = [`${adults} adult${adults === 1 ? "" : "s"}`];
  if (children > 0) parts.push(`${children} child${children === 1 ? "" : "ren"}`);
  return `${parts.join(" + ")} (≈ ${eff % 1 === 0 ? eff : eff.toFixed(1)} servings)`;
}

function buildContextBlock(
  recipe: Recipe,
  pantry: PantryItem[],
  currentStep: number,
  doneStepIdxs: number[],
  prefs?: UserPrefs,
  // deno-lint-ignore no-explicit-any
  timers?: any[],
  servingFactor = 1,
  servingSummary = "",
): string {
  // Step amounts are scaled inline too: the {{...}} tokens become the scaled
  // quantity so the chef reads exactly what the user sees on screen.
  const stepsList = recipe.steps.map((s, i) => {
    const mark = doneStepIdxs.includes(i) ? "[done]" : i === currentStep ? "[NOW]" : "[ ]";
    return `${mark} Step ${i + 1}: ${scaleStepText(s, servingFactor)}`;
  }).join("\n");
  // Amounts are scaled to the chosen servings so the chef guides with the SAME
  // quantities the user sees on the recipe page (structured qty×factor when
  // available, else the string scaler).
  const ingList = recipe.ingredients.map((i) =>
    `- ${i.name} (${scaleIngredientDisplay(i, servingFactor)})${i.in_pantry === false ? " [MISSING from pantry]" : ""}`
  ).join("\n");

  // Quantity-aware shortfall: where we have BOTH a structured recipe qty and a
  // canonical pantry stock in the same unit, flag any ingredient the user
  // doesn't have enough of at this serving size.
  const shortfalls: string[] = [];
  for (const i of recipe.ingredients) {
    if (typeof i.qty !== "number" || !isFinite(i.qty) || !i.unit) continue;
    const need = i.qty * servingFactor;
    const p = matchPantry(i.name, pantry);
    if (!p || typeof p.stock_qty !== "number" || !p.stock_unit || p.stock_unit !== i.unit) continue;
    if (need > p.stock_qty + 0.001) {
      shortfalls.push(`- ${i.name}: need ${fmtNum(need)} ${i.unit}, pantry has only ${fmtNum(p.stock_qty)} ${p.stock_unit} (short ~${fmtNum(need - p.stock_qty)} ${i.unit})`);
    }
  }
  const shortfallBlock = shortfalls.length
    ? `\n\nPANTRY SHORTFALLS (not enough on hand at this serving size):\n${shortfalls.join("\n")}\nProactively warn the user about these and offer a concrete fix — cook fewer servings, scale the dish down, or substitute from the pantry. Say exactly how much they're short.`
    : "";
  // Pantry as a clear bulleted list (with brand + how much they have) so the
  // model grounds substitutions in what the user actually owns AND knows the
  // quantity on hand. READ-ONLY: the chef can see these amounts but has no tool
  // to change the pantry.
  const pantryList = pantry.length
    ? pantry.map((p) => {
        const have = (typeof p.stock_qty === "number" && isFinite(p.stock_qty) && p.stock_unit)
          ? ` — have ${fmtNum(p.stock_qty)} ${p.stock_unit}`
          : "";
        return `- ${p.name}${p.brand ? ` (${p.brand})` : ""}${have}`;
      }).join("\n")
    : "(pantry is empty)";
  // Lean expiry: only surface items expiring within 7 days, so the chef gets the
  // "use these first" signal without the noise of listing every pantry date.
  const nowMs = Date.now();
  const expiringSoon = pantry.filter((p) => {
    if (!p.expiry) return false;
    const days = (new Date(p.expiry).getTime() - nowMs) / 86_400_000;
    return days >= 0 && days <= 7;
  });
  const expiringLine = expiringSoon.length
    ? `\n\nEXPIRING SOON (gently prefer using these if they fit the dish): ${expiringSoon.map((p) => `${p.name} (${p.expiry})`).join(", ")}`
    : "";
  const allergies = prefs?.allergies?.length ? prefs.allergies.join(", ") : "none";
  const dietary = prefs?.dietary?.length ? prefs.dietary.join(", ") : "none";
  const cuisines = prefs?.cuisines?.length ? prefs.cuisines.join(", ") : "no specific preference";
  return `RECIPE: ${recipe.name}

COOKING FOR: ${servingSummary || "1 serving"} — BOTH the INGREDIENTS list and the STEP amounts below are ALREADY scaled to this serving size. Cooking times and temperatures are NOT scaled. Guide the user with exactly these scaled amounts.

INGREDIENTS:
${ingList}

STEPS:
${stepsList}${shortfallBlock}

USER'S PANTRY — only suggest substitutes from this list. The amount after each item ("have X") is how much they currently have on hand; use it to judge whether they have enough. This is READ-ONLY — you cannot change the pantry:
${pantryList}${expiringLine}

DIETARY PREFERENCES: ${dietary}
ALLERGIES (never suggest these): ${allergies}
PREFERRED CUISINES: ${cuisines}

ACTIVE TIMERS: ${timersLine(timers || [])}

CURRENTLY ON STEP ${currentStep + 1} OF ${recipe.steps.length}.`;
}

// Effective servings + scale factor + label from a cook session row.
// deno-lint-ignore no-explicit-any
function servingInfo(cook: any, recipe: any): { factor: number; summary: string } {
  const adults = Math.max(1, cook?.cooked_servings ?? recipe?.servings_base ?? 1);
  const children = Math.max(0, cook?.cooked_children ?? 0);
  const base = Math.max(1, recipe?.servings_base ?? 1);
  const effective = adults + 0.5 * children;
  return { factor: effective / base, summary: servingLabel(adults, children) };
}

// ---------------------------------------------------------------------------
// Chef call: builds history + context, calls Gemini, returns text
// ---------------------------------------------------------------------------
interface LedgerSnapshot {
  ingredients: unknown[];
  steps: unknown[];
  current_step: number | null;
  done_step_idxs: number[] | null;
}
async function callChef(
  supabase: SupabaseClient,
  chatSessionId: string,
  cookSessionId: string,
  contextBlock: string,
): Promise<{ text: string; thinkingTokens: number; ledgerChanged: boolean; updatedLedger: LedgerSnapshot | null; timers: unknown[] | null }> {
  const { data: history } = await supabase
    .from("chat_messages")
    .select("role, text")
    .eq("session_id", chatSessionId)
    .order("created_at", { ascending: true });

  // Keep only the last 20 turns to bound context.
  const trimmed = (history || []).slice(-20);

  // deno-lint-ignore no-explicit-any
  const contents: any[] = trimmed
    .filter((m) => m.text && (m.role === "user" || m.role === "model"))
    .map((m) => ({
      role: m.role === "model" ? "model" : "user",
      parts: [{ text: m.text as string }],
    }));

  const systemInstruction = { parts: [{ text: `${CHEF_SYSTEM}\n\n=== LIVE COOKING CONTEXT ===\n${contextBlock}` }] };

  let totalThinking = 0;
  let ledgerChanged = false;
  let updatedLedger: LedgerSnapshot | null = null;
  let timers: unknown[] | null = null;

  // Tool loop: model may chain several ledger tools (e.g. substitute_ingredient
  // + edit_step for every dependent step + mark_step_done) before producing
  // its final spoken reply. 10 iterations is plenty for a single user turn.
  for (let i = 0; i < 10; i++) {
    const { parts, thinkingTokens } = await geminiGenerate({
      systemInstruction,
      contents,
      tools: LEDGER_TOOLS,
      generationConfig: {
        thinkingConfig: { thinkingLevel: "minimal" }, // Text Chef is high-volume; keep cheap
        temperature: 0.7,
      },
    });
    totalThinking += thinkingTokens;

    // deno-lint-ignore no-explicit-any
    const fcs = parts.filter((p: any) => p.functionCall).map((p: any) => p.functionCall);
    if (fcs.length === 0) {
      // deno-lint-ignore no-explicit-any
      const text = parts.map((p: any) => p.text || "").join("").trim();
      return { text: text || "Sounds good — what's next?", thinkingTokens: totalThinking, ledgerChanged, updatedLedger, timers };
    }

    // Echo the model's tool-call turn, then feed back each tool result.
    contents.push({ role: "model", parts });
    // deno-lint-ignore no-explicit-any
    const respParts: any[] = [];
    for (const fc of fcs) {
      if (TIMER_OPS.has(fc.name)) {
        const result = await callTimers(cookSessionId, fc.name, fc.args || {});
        if (result?.ok || Array.isArray(result?.timers)) timers = result.timers ?? timers;
        respParts.push({ functionResponse: { name: fc.name, response: result } });
        continue;
      }
      const result = await callLedger(cookSessionId, fc.name, fc.args || {});
      if (result?.ok) {
        ledgerChanged = true;
        updatedLedger = {
          ingredients: result.ingredients,
          steps: result.steps,
          current_step: typeof result.current_step === "number" ? result.current_step : null,
          done_step_idxs: Array.isArray(result.done_step_idxs) ? result.done_step_idxs : null,
        };
      }
      respParts.push({ functionResponse: { name: fc.name, response: result } });
    }
    contents.push({ role: "function", parts: respParts });
  }

  return { text: "Okay, done — what's next?", thinkingTokens: totalThinking, ledgerChanged, updatedLedger, timers };
}

// ---------------------------------------------------------------------------
// Shared chat session
// ---------------------------------------------------------------------------
// A cook session has exactly ONE conversation, shared by the text chef AND the
// voice chef (kind="chef"). Both read and append to it, so switching between
// text and voice carries the full context — neither restarts. We look up by
// cook_session_id regardless of kind (older rows may be "text_chef"/"voice_chef")
// and create a unified "chef" row if none exists.
async function getOrCreateChatSession(
  supabase: SupabaseClient, cookSessionId: string, userId: string, recipeId: string,
): Promise<{ id: string }> {
  const { data: existing } = await supabase.from("chat_sessions")
    .select("id").eq("cook_session_id", cookSessionId)
    .order("started_at", { ascending: true }).limit(1).maybeSingle();
  if (existing) return existing;
  const { data: created, error } = await supabase.from("chat_sessions").insert({
    user_id: userId, kind: "chef", cook_session_id: cookSessionId, recipe_id: recipeId,
  }).select("id").single();
  if (error || !created) throw new Error(`chat session create failed: ${error?.message}`);
  return created;
}

// ---------------------------------------------------------------------------
// Action handlers
// ---------------------------------------------------------------------------
async function handleStart(supabase: SupabaseClient, recipeId: string, userId: string, servings?: number, children?: number) {
  const { data: recipe, error: re } = await supabase.from("recipes").select("*").eq("id", recipeId).single();
  if (re || !recipe) throw new Error(`recipe not found: ${re?.message}`);
  const { data: pantry } = await supabase.from("pantry_items").select("id, name, fullness_levels, stock_qty, stock_unit, expiry").eq("user_id", userId);

  const cookedServings = Math.max(1, Math.min(20, Number(servings) || recipe.servings_base || 1));
  const cookedChildren = Math.max(0, Math.min(20, Number(children) || 0));
  const { data: cook, error: ce } = await supabase.from("cook_sessions").insert({
    user_id: userId, recipe_id: recipeId, current_step: 0, status: "active",
    cooked_servings: cookedServings, cooked_children: cookedChildren,
  }).select().single();
  if (ce || !cook) throw new Error(`cook_session insert failed: ${ce?.message}`);

  const chat = await getOrCreateChatSession(supabase, cook.id, userId, recipeId);

  // Seed with a synthetic user opener so the chef knows to introduce the first step.
  await supabase.from("chat_messages").insert({
    session_id: chat.id, role: "user",
    text: "Let's start cooking! Briefly say hello in one short sentence, then walk me through step 1.",
  });

  const prefs = await fetchPrefs(supabase, userId);
  const sv = servingInfo(cook, recipe);
  const contextBlock = buildContextBlock(recipe, pantry || [], 0, [], prefs, [], sv.factor, sv.summary);
  const { text, thinkingTokens } = await callChef(supabase, chat.id, cook.id, contextBlock);
  await supabase.from("chat_messages").insert({
    session_id: chat.id, role: "model", text, model: GEMINI_MODEL, thinking_tokens: thinkingTokens,
  });

  return {
    cook_session_id: cook.id,
    chat_session_id: chat.id,
    current_step: 0,
    total_steps: recipe.steps.length,
    message: text,
  };
}

async function handleSend(supabase: SupabaseClient, cookSessionId: string, userText: string) {
  const { data: cook } = await supabase.from("cook_sessions").select("*").eq("id", cookSessionId).single();
  if (!cook) throw new Error("cook session not found");
  const chat = await getOrCreateChatSession(supabase, cookSessionId, cook.user_id, cook.recipe_id);
  const { data: recipe } = await supabase.from("recipes").select("*").eq("id", cook.recipe_id).single();
  const { data: pantry } = await supabase.from("pantry_items")
    .select("id, name, fullness_levels, stock_qty, stock_unit, expiry").eq("user_id", cook.user_id);

  await supabase.from("chat_messages").insert({ session_id: chat.id, role: "user", text: userText });

  const prefs = await fetchPrefs(supabase, cook.user_id);
  const activeTimers = await fetchTimers(supabase, cookSessionId);
  const sv = servingInfo(cook, recipe);
  const ctx = buildContextBlock(recipe, pantry || [], cook.current_step, cook.done_step_idxs || [], prefs, activeTimers, sv.factor, sv.summary);
  const { text, thinkingTokens, ledgerChanged, updatedLedger, timers } = await callChef(supabase, chat.id, cookSessionId, ctx);
  await supabase.from("chat_messages").insert({
    session_id: chat.id, role: "model", text, model: GEMINI_MODEL, thinking_tokens: thinkingTokens,
  });

  // The chef may have called step-nav tools (mark_step_done, set_current_step,
  // etc.) — re-read so the response carries the AUTHORITATIVE current_step /
  // done_step_idxs even when no recipe edit happened.
  const { data: cookAfter } = await supabase.from("cook_sessions")
    .select("current_step, done_step_idxs").eq("id", cookSessionId).maybeSingle();
  const curStep = cookAfter?.current_step ?? cook.current_step;
  const doneIdxs = cookAfter?.done_step_idxs ?? cook.done_step_idxs ?? [];
  const stepsAfter = updatedLedger?.steps as string[] | undefined;
  return {
    current_step: curStep,
    done_step_idxs: doneIdxs,
    total_steps: (stepsAfter ?? (recipe.steps as string[]) ?? []).length,
    message: text,
    ledger_changed: ledgerChanged,
    ...(updatedLedger ? { ingredients: updatedLedger.ingredients, steps: updatedLedger.steps } : {}),
    ...(timers ? { timers } : {}),
  };
}

async function handleAdvance(supabase: SupabaseClient, cookSessionId: string, direction: string) {
  const { data: cook } = await supabase.from("cook_sessions").select("*").eq("id", cookSessionId).single();
  if (!cook) throw new Error("cook session not found");
  const { data: recipe } = await supabase.from("recipes").select("*").eq("id", cook.recipe_id).single();
  const total = (recipe.steps as string[]).length;

  let newStep = cook.current_step;
  let doneIdxs: number[] = cook.done_step_idxs || [];

  if (direction === "next") {
    if (cook.current_step < total) {
      if (!doneIdxs.includes(cook.current_step)) doneIdxs = [...doneIdxs, cook.current_step];
      newStep = Math.min(cook.current_step + 1, total);
    }
  } else if (direction === "back") {
    newStep = Math.max(0, cook.current_step - 1);
    doneIdxs = doneIdxs.filter((i) => i !== newStep);
  } else {
    throw new Error(`unknown direction: ${direction}`);
  }

  await supabase.from("cook_sessions").update({
    current_step: newStep, done_step_idxs: doneIdxs,
  }).eq("id", cookSessionId);

  const chat = await getOrCreateChatSession(supabase, cookSessionId, cook.user_id, cook.recipe_id);
  const { data: pantry } = await supabase.from("pantry_items")
    .select("id, name, fullness_levels, stock_qty, stock_unit, expiry").eq("user_id", cook.user_id);
  const prefs = await fetchPrefs(supabase, cook.user_id);
  const activeTimers = await fetchTimers(supabase, cookSessionId);
  const sv = servingInfo(cook, recipe);
  const ctx = buildContextBlock(recipe, pantry || [], newStep, doneIdxs, prefs, activeTimers, sv.factor, sv.summary);

  const opener = newStep >= total
    ? "The user just marked the final step done. Congratulate them in one warm short sentence."
    : direction === "next"
      ? `The user just finished step ${cook.current_step + 1}. In one short sentence, transition them into step ${newStep + 1}.`
      : `The user wants to go back to step ${newStep + 1}. Briefly re-explain that step.`;

  await supabase.from("chat_messages").insert({ session_id: chat.id, role: "user", text: opener });
  const { text, thinkingTokens, ledgerChanged, updatedLedger, timers } = await callChef(supabase, chat.id, cookSessionId, ctx);
  await supabase.from("chat_messages").insert({
    session_id: chat.id, role: "model", text, model: GEMINI_MODEL, thinking_tokens: thinkingTokens,
  });

  // Re-read state after callChef (the chef may have invoked step-nav tools).
  const { data: cookAfter } = await supabase.from("cook_sessions")
    .select("current_step, done_step_idxs").eq("id", cookSessionId).maybeSingle();
  const curStep = cookAfter?.current_step ?? newStep;
  const finalDone = cookAfter?.done_step_idxs ?? doneIdxs;
  const stepsAfter = updatedLedger?.steps as string[] | undefined;
  return {
    current_step: curStep,
    total_steps: (stepsAfter ?? (recipe.steps as string[])).length,
    done_step_idxs: finalDone,
    message: text,
    ledger_changed: ledgerChanged,
    ...(updatedLedger ? { ingredients: updatedLedger.ingredients, steps: updatedLedger.steps } : {}),
    ...(timers ? { timers } : {}),
  };
}

async function handleFinish(supabase: SupabaseClient, cookSessionId: string) {
  const { data: cook } = await supabase.from("cook_sessions").select("*").eq("id", cookSessionId).single();
  if (!cook) throw new Error("cook session not found");
  if (cook.status === "finished") return { already_finished: true, deductions: [] };

  const { data: recipe } = await supabase.from("recipes").select("*").eq("id", cook.recipe_id).single();
  const { data: pantry } = await supabase.from("pantry_items").select("*").eq("user_id", cook.user_id);

  const deductions: Array<Record<string, unknown>> = [];
  for (const ing of recipe.ingredients as Array<{ name: string; amount: string; in_pantry?: boolean }>) {
    if (ing.in_pantry === false) {
      deductions.push({ ingredient: ing.name, amount: ing.amount, skipped: true, reason: "not in pantry" });
      continue;
    }
    const pantryItem = (pantry || []).find((p) => pantryMatch(p.name, ing.name));
    if (!pantryItem) {
      deductions.push({ ingredient: ing.name, amount: ing.amount, skipped: true, reason: "no fuzzy match" });
      continue;
    }
    const frac = estimateDeductionFraction(ing.amount);
    const before = (pantryItem.fullness_levels as number[]).map(Number);
    const after = applyDeduction(before, frac);

    // Keep canonical stock in sync with the new fullness so shortfall stays accurate.
    const newStock = recomputeStock(pantryItem.quantity || "", after);
    await supabase.from("pantry_items").update({
      fullness_levels: after,
      ...(newStock ? { stock_qty: newStock.stock_qty, stock_unit: newStock.stock_unit } : {}),
    }).eq("id", pantryItem.id);
    await supabase.from("pantry_deduction_log").insert({
      user_id: cook.user_id, cook_session_id: cookSessionId,
      pantry_item_id: pantryItem.id, pantry_item_name: pantryItem.name,
      recipe_ingredient: ing.name, ingredient_amount: ing.amount,
      fullness_before: before, fullness_after: after, reduced_by: frac,
    });

    deductions.push({
      ingredient: ing.name, amount: ing.amount, pantry_item: pantryItem.name,
      fullness_before: before, fullness_after: after, reduced_by: frac,
    });
  }

  await supabase.from("cook_sessions").update({
    status: "finished", finished_at: new Date().toISOString(),
  }).eq("id", cookSessionId);

  await supabase.from("cooked_recipes").upsert({
    user_id: cook.user_id, recipe_id: cook.recipe_id,
    cooked_at: new Date().toISOString(), cook_session_id: cookSessionId,
  }, { onConflict: "user_id,recipe_id" });

  const today = new Date().toISOString().slice(0, 10);
  await supabase.from("daily_feed").update({ status: "cooked" })
    .eq("user_id", cook.user_id).eq("feed_date", today).eq("recipe_id", cook.recipe_id);

  return { deductions, cook_session_id: cookSessionId };
}

// Synthetic prompts we inject as "user" turns to steer the chef. They should
// never be shown back to the user when resuming a session.
function isSyntheticOpener(text: string): boolean {
  return /^Let's start cooking!|^The user just finished step|^The user wants to go back|^The user just marked the final step done/.test(text);
}

// Resume an in-flight (status='active') cook session for this user+recipe, if
// one exists. Returns { found:false } otherwise so the client falls back to start.
async function handleResume(supabase: SupabaseClient, recipeId: string, userId: string) {
  const { data: cook } = await supabase.from("cook_sessions")
    .select("*").eq("user_id", userId).eq("recipe_id", recipeId).eq("status", "active")
    .order("started_at", { ascending: false }).limit(1).maybeSingle();
  if (!cook) return { found: false };

  const { data: recipe } = await supabase.from("recipes").select("steps").eq("id", recipeId).maybeSingle();
  if (!recipe) return { found: false }; // recipe gone — nothing to resume
  const total = (recipe.steps as string[] | null)?.length ?? 0;

  // Shared session (any kind) — so resuming the text chef also shows turns
  // that happened in the voice chef, and vice versa.
  const { data: chat } = await supabase.from("chat_sessions")
    .select("id").eq("cook_session_id", cook.id)
    .order("started_at", { ascending: true }).limit(1).maybeSingle();

  let messages: Array<{ role: string; text: string }> = [];
  if (chat) {
    const { data: history } = await supabase.from("chat_messages")
      .select("role, text, created_at").eq("session_id", chat.id)
      .order("created_at", { ascending: true });
    messages = (history || [])
      .filter((m) => m.text && !(m.role === "user" && isSyntheticOpener(m.text as string)))
      .map((m) => ({ role: m.role as string, text: m.text as string }));
  }

  return {
    found: true,
    cook_session_id: cook.id,
    chat_session_id: chat?.id ?? null,
    current_step: cook.current_step ?? 0,
    total_steps: total,
    done_step_idxs: cook.done_step_idxs || [],
    cooked_servings: cook.cooked_servings ?? null,
    cooked_children: cook.cooked_children ?? 0,
    is_finished: (cook.current_step ?? 0) >= total,
    messages,
  };
}

// Toggle a single step's done state from the checklist. Adjusts current_step to
// match (mirrors the client's optimistic logic). No LLM call — cheap + instant.
async function handleToggleStep(supabase: SupabaseClient, cookSessionId: string, stepIdx: number) {
  const { data: cook } = await supabase.from("cook_sessions").select("*").eq("id", cookSessionId).single();
  if (!cook) throw new Error("cook session not found");
  const { data: recipe } = await supabase.from("recipes").select("steps").eq("id", cook.recipe_id).single();
  const total = (recipe.steps as string[]).length;

  let doneIdxs: number[] = cook.done_step_idxs || [];
  let current = cook.current_step ?? 0;
  const wasDone = doneIdxs.includes(stepIdx);
  if (wasDone) {
    doneIdxs = doneIdxs.filter((i) => i !== stepIdx);
    if (stepIdx < current) current = stepIdx;
  } else {
    if (!doneIdxs.includes(stepIdx)) doneIdxs = [...doneIdxs, stepIdx];
    if (stepIdx === current) current = Math.min(stepIdx + 1, total);
  }

  await supabase.from("cook_sessions").update({
    current_step: current, done_step_idxs: doneIdxs,
  }).eq("id", cookSessionId);

  return { current_step: current, total_steps: total, done_step_idxs: doneIdxs, toggled: stepIdx, now_done: !wasDone };
}

// Update how many servings the user is cooking. Cheap; no LLM.
async function handleUpdateServings(supabase: SupabaseClient, cookSessionId: string, servings: number, children?: number) {
  const adults = Math.max(1, Math.min(20, Number(servings) || 1));
  const kids = Math.max(0, Math.min(20, Number(children) || 0));
  await supabase.from("cook_sessions")
    .update({ cooked_servings: adults, cooked_children: kids }).eq("id", cookSessionId);
  return { ok: true, cooked_servings: adults, cooked_children: kids };
}

// ---------------------------------------------------------------------------
// HTTP entrypoint
// ---------------------------------------------------------------------------
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
      case "start":           result = await handleStart(supabase, body.recipe_id, userId, body.servings, body.children); break;
      case "resume":          result = await handleResume(supabase, body.recipe_id, userId); break;
      case "send":            result = await handleSend(supabase, body.cook_session_id, body.text); break;
      case "advance":         result = await handleAdvance(supabase, body.cook_session_id, body.direction); break;
      case "toggle_step":     result = await handleToggleStep(supabase, body.cook_session_id, body.step_idx); break;
      case "update_servings": result = await handleUpdateServings(supabase, body.cook_session_id, body.servings, body.children); break;
      case "finish":          result = await handleFinish(supabase, body.cook_session_id); break;
      default: return Response.json({ error: `unknown action: ${action}` }, { status: 400 });
    }
    return Response.json(result, { headers: { "Access-Control-Allow-Origin": "*" } });
  } catch (err) {
    console.error(`[text-chef] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
});
