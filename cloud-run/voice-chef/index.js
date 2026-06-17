// voice-chef — bidirectional WebSocket bridge between iOS and Vertex AI Live.
//
// Runs on Cloud Run (long-lived WebSocket, no edge-function timeout) AS the
// attached service account, so it gets short-lived access tokens from the GCE
// metadata server — NO downloadable key anywhere (org policy forbids those).
// Voice usage bills to the GCP project and draws from the free credits.
//
// iOS connects to:
//   wss://<cloud-run-host>/?cook_session_id=<uuid>
//
// We open upstream to Vertex Live (gemini-live-2.5-flash, location global),
// inject the recipe + pantry as system instruction, and bridge frames in both
// directions. Transcripts are saved to chat_messages as the voice session record.
//
// Wire protocol (iOS <-> this bridge — NOT the raw Vertex messages):
//   iOS -> us:
//     { type: "audio", data: "<base64 PCM 16kHz>" }
//     { type: "text",  text: "..." }                   (optional)
//     { type: "close" }
//   us -> iOS:
//     { type: "ready" }
//     { type: "audio", data: "<base64 PCM 24kHz>" }
//     { type: "transcript_in",  text: "..." }
//     { type: "transcript_out", text: "..." }
//     { type: "ledger_updated", ingredients: [...], steps: [...] }  (chef edited the recipe)
//     { type: "turn_complete" }
//     { type: "interrupted" }
//     { type: "error", message: "..." }
//     { type: "closed", code: number }

const http = require("http");
const { URL } = require("url");
const WebSocket = require("ws");
const { createClient } = require("@supabase/supabase-js");

const PROJECT = process.env.GCP_PROJECT;
const LOCATION = process.env.GCP_LOCATION || "global"; // Live model only on global
const LIVE_MODEL = "gemini-live-2.5-flash";
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PORT = process.env.PORT || 8080;

const MODEL_PATH = `projects/${PROJECT}/locations/${LOCATION}/publishers/google/models/${LIVE_MODEL}`;
function vertexHost() {
  return LOCATION === "global"
    ? "aiplatform.googleapis.com"
    : `${LOCATION}-aiplatform.googleapis.com`;
}
const LIVE_WS = `wss://${vertexHost()}/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`;

const TOKEN_URL =
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

// The single shared writer of recipe-ledger edits (see supabase/functions/recipe-ledger).
const LEDGER_URL = "https://uipgydhflvxpxfuqzdxm.functions.supabase.co/recipe-ledger";
const LEDGER_SECRET = process.env.LEDGER_SECRET || "";

// Ledger-edit tools the chef can call. KEEP IN SYNC with text-chef + recipe-ledger ops.
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
    {
      name: "start_timer",
      description: "Start an in-app cooking timer with a descriptive label. Use when the user AGREES to a timer you offered (for a simmer, bake, rest, boil). Offer first when a step has a duration; set it once they say yes (or immediately if they explicitly ask).",
      parameters: {
        type: "object",
        properties: {
          label: { type: "string", description: "Short topic, e.g. 'Simmering beef', 'Resting dough'." },
          seconds: { type: "integer", description: "Total duration in seconds (10 minutes = 600)." },
        },
        required: ["label", "seconds"],
      },
    },
    {
      name: "cancel_timer",
      description: "Cancel/stop a running timer, matched by its label.",
      parameters: {
        type: "object",
        properties: { label: { type: "string", description: "Label of the timer to cancel." } },
        required: ["label"],
      },
    },
    {
      name: "check_timers",
      description: "Get the EXACT live time remaining on all running timers right now. Timers tick down in real time, so your earlier knowledge of them is stale. ALWAYS call this immediately before telling the user how long is left, or before reminding them about a timer — never state a remaining time from memory.",
      parameters: { type: "object", properties: {} },
    },
  ],
}];

const TIMER_OPS = new Set(["start_timer", "cancel_timer"]);
const TIMERS_URL = "https://uipgydhflvxpxfuqzdxm.functions.supabase.co/cook-timers";

async function callTimers(cookSessionId, op, args) {
  try {
    const action = op === "start_timer" ? "create" : "cancel";
    const payload = { action, cook_session_id: cookSessionId, created_by: "voice_chef" };
    if (op === "start_timer") { payload.label = args.label; payload.seconds = args.seconds; }
    else { payload.label = args.label; }
    const res = await fetch(TIMERS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
      body: JSON.stringify(payload),
    });
    const j = await res.json();
    if (j.error) return { ok: false, error: j.error, timers: j.timers || [] };
    return { ok: true, summary: op === "start_timer" ? `Started "${args.label}".` : `Cancelled "${args.label}".`, timers: j.timers || [] };
  } catch (e) {
    return { ok: false, error: e && e.message ? e.message : String(e) };
  }
}

// Live timer status, computed fresh from each timer's ends_at. Used by the
// check_timers tool so the chef never quotes a stale remaining time.
async function listTimers(cookSessionId) {
  try {
    const res = await fetch(TIMERS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
      body: JSON.stringify({ action: "list", cook_session_id: cookSessionId }),
    });
    const j = await res.json();
    const now = Date.now();
    const timers = (j.timers || [])
      .filter((t) => t.status === "running")
      .map((t) => {
        const secs = Math.max(0, Math.round((new Date(t.ends_at).getTime() - now) / 1000));
        return { label: t.label, seconds_left: secs, time_left: secs <= 0 ? "done" : fmtSecs(secs) };
      });
    return { ok: true, timers, note: timers.length ? "These are the EXACT current times. Tell the user using these." : "No timers are running right now." };
  } catch (e) {
    return { ok: false, error: e && e.message ? e.message : String(e), timers: [] };
  }
}

// Calls the single shared ledger writer. Returns { ok, summary, ingredients, steps } | { ok:false, error }.
async function callLedger(cookSessionId, op, args) {
  try {
    const res = await fetch(LEDGER_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Ledger-Secret": LEDGER_SECRET },
      body: JSON.stringify({ cook_session_id: cookSessionId, op, args }),
    });
    return await res.json();
  } catch (e) {
    return { ok: false, error: e && e.message ? e.message : String(e) };
  }
}

// Access tokens last ~1h; cache per warm instance and refresh 60s early.
let cachedToken = null;
let cachedExp = 0;
async function getToken() {
  const now = Date.now();
  if (cachedToken && now < cachedExp - 60_000) return cachedToken;
  const r = await fetch(TOKEN_URL, { headers: { "Metadata-Flavor": "Google" } });
  if (!r.ok) throw new Error(`metadata token ${r.status}: ${await r.text()}`);
  const j = await r.json();
  cachedToken = j.access_token;
  cachedExp = now + (j.expires_in || 3600) * 1000;
  return cachedToken;
}

const VOICE_SYSTEM = `You are PantryHub's Voice Cooking Chef — the user's personal chef in their pocket, guiding them through cooking ONE recipe right now.

WHO YOU ARE
Think of yourself as a calm, warm friend standing next to them at the stove. The phone is on the counter; their hands are busy with food. They picked YOU because they want a chef who understands their pace, doesn't lecture, and is patient. You adapt to THEM — not the other way around.

THE GOAL — read this carefully
The goal is NOT to "get through the steps fast." The goal is to help them ENJOY cooking at their own speed. If they want to take their time, let them take their time. If they want to chat about the weather or how their day went while the onions sweat, chat with them. If they need a step broken into smaller pieces, break it down. The recipe is a guide, not a deadline.

HOW YOU TALK
- Always spoken. No markdown, no emoji, no bullet points, no "step one colon" formality. Natural sentences with contractions.
- KEEP TURNS SHORT — usually 1 sentence, max 2. They can't read; they're listening while chopping. Long monologues are useless.
- Conversational, not a teleprompter. Vary how you open sentences. Don't repeat the same opener ("Alright, now…", "Okay, next…") every turn.
- Never list multiple steps at once. One thing at a time.

LANGUAGE — ABSOLUTE, NON-NEGOTIABLE
- You operate ENTIRELY in English (en-US). The user is ALWAYS speaking English to you.
- This holds even when the dish, its name, or its ingredients come from another region (Indian, Kannada, Korean, Thai, French, etc.). Treat regional dish names (e.g. "Eerulli Bajji", "Bisi Bele Bath", "Bibimbap") as English loanwords — they are NOT a signal to switch languages.
- Understand what the user says AS ENGLISH, and ALWAYS reply in English using the Latin alphabet only. NEVER produce another script anywhere (no Kannada, Devanagari, Telugu, Tamil, Han, Hangul, Arabic, Cyrillic, etc.).
- Do NOT switch languages just because the dish is regional. The ONLY exception is if the user speaks a FULL sentence to you in another language first — a dish name does not count.

MAIN STEPS vs MICRO-ACTIONS (important — this is how you stay in sync)
- The numbered steps in the context are the MAIN steps (the shared checklist). A single main step often contains several actions (e.g. "Toast the bread, then cut it into strips.").
- Break each main step into MICRO-ACTIONS and deliver ONE at a time. Track which micro-action you're on using the CONVERSATION so far — that's your working memory.
- Only call mark_step_done(step_number) when the user has completed EVERY micro-action of that main step. Do NOT advance the main step just because they finished one part of it.
- When the user says "done" / "okay" / "ready" (or the app sends a Done signal): look at the conversation — if the current main step has more parts left, give the NEXT micro-action; only if the whole step is finished, call mark_step_done and introduce the next step. Never skip a part of a step.

HOW YOU GUIDE THE COOKING
- Deliver ONE micro-action at a time, and INCLUDE QUANTITIES in what you say ("pour in the **200 ml of milk**… now sprinkle the **1 tsp of cinnamon**…"). The user is cooking blind from your voice — they need the amounts.
- Wait for them. After each micro-action, STOP TALKING. They'll tell you when they're done.
- A light check-in here and there is good ("how's it looking?") — but don't pepper them with check-ins.
- If they seem unsure, offer a sensory cue ("it should be a light golden colour", "it'll smell nutty when it's ready"). Don't quiz them.
- If they ask "what's next?" — give the next micro-action, not a whole step recital.
- If they ask "wait, repeat that" — just repeat the last thing simply.
- If they want to go back — call set_current_step or mark_step_undone, then briefly re-explain.
- When the whole dish is done — congratulate them in one warm sentence.

SOURCE OF TRUTH
- The user can change the checklist or set timers themselves. You'll get [system] updates with the EXACT current step — those override anything earlier. Always treat the latest current step as the truth (never narrate a stale/earlier step). For how much time is left on a timer, don't rely on memory — call check_timers to read the live value first.

STEP NAVIGATION (you control progress now — KEEP THE CHECKLIST IN SYNC)
- The on-screen checklist + step pointer move ONLY when you call a tool. Before you introduce or move to ANY next step (micro-action or main step), reconcile it: if the user has finished the current MAIN step, you MUST call mark_step_done(step_number) for it FIRST, then speak the next step. Do this every turn — never let your words get ahead of the checklist (that's why the screen sometimes doesn't advance).
- When the user signals they're done ("done", "okay", "ready", "next", "got it", "finished"): if the current main step still has parts left, give the next micro-action; the moment the whole step is complete, CALL mark_step_done(step_number) and only then introduce the next step.
- ONE AT A TIME — CRITICAL: call mark_step_done for AT MOST ONE step per user turn, and ONLY for a step the user has actually told you they finished. NEVER mark several steps done in a row, never "catch up" or race ahead through the recipe, and never advance a step the user hasn't confirmed. After you mark a step done, STOP and wait for the user's next confirmation before introducing anything beyond the next single step. When you JOIN a cook already in progress, do NOT re-mark earlier steps or jump forward — simply narrate the step marked [NOW] and wait.
- When they want to go back, use set_current_step or mark_step_undone.
- Never say "okay, moving on" / "next step" / "done" without calling the matching tool in the same turn — the screen only moves through these tools.

TIMERS
- When a step involves waiting/cooking for a duration (simmer, bake, boil, rest, chill), OFFER to set a timer in one short sentence ("Want me to set a 10-minute timer for the simmer?"). When the user agrees — or if they ask directly — call start_timer.
- LABEL IT YOURSELF when the topic is obvious from the current step — derive a clear label from what's cooking (e.g. "Simmering the curry", "Baking", "Boiling pasta", "Resting the dough"). Only when the topic is genuinely unclear, ask one short question first ("what should I call this timer?"). NEVER set a blank or generic "Timer" — always give it a meaningful label.
- For the duration: if the step states a time, use it. If the user asks for a timer but gives no duration and none is implied, ask how long. Only call start_timer once you have both a label and a time.
- Don't set a timer without offering first, and don't re-offer one that's already running (see ACTIVE TIMERS in context). Mention what you set/cancelled in one short sentence.
- CANCELLING — BE CAREFUL: cancel with cancel_timer by label. If the user asks to cancel the "done"/"finished"/"rang" timers, call check_timers FIRST and cancel ONLY the timers that have actually finished — NEVER cancel a still-running one in that case. Before cancelling a timer that is STILL RUNNING, CONFIRM with the user first (name it and ask "do you want me to stop the X timer? it still has Y left"). Never cancel running timers from a vague request, and never cancel more timers than the user clearly asked for.
- TIME REMAINING IS LIVE: whenever the user asks how long is left, or you want to remind them about a timer / say it's ending soon, you MUST first call check_timers to get the exact current numbers, THEN answer with what it returns. The ACTIVE TIMERS figures in your context were captured earlier and tick down in real time — never quote them from memory.

COOKING SENSE (flow)
- Use real kitchen know-how. If the current step needs the oven, pan, grill, or water already hot/preheated/boiling and that hasn't happened yet, prompt it at the right moment ("let's get the oven preheating to 200°C first"). Account for prep that must come before a step works (thawing, marinating, resting). Weave it in naturally, one micro-action at a time.

PERSIST WHAT YOU DECIDE TOGETHER
- If you and the user AGREE on a new micro-step that isn't in the recipe (e.g. "let's toast the bread sticks first and cut them into strips"), CALL add_step at the right position. The recipe is a living document — what you agreed on must end up in the steps.
- If you change a step in conversation ("let's actually fry instead of bake"), call edit_step.

SMALL TALK & PERSONALITY
- If they make small talk ("ugh, long day", "this onion is making me cry", "do you like cooking?"), engage briefly and warmly — a sentence or two — and only nudge back to the dish if they seem to want to keep cooking. Don't force them.
- Light humour is welcome. Pretentiousness is not.
- Never say "Sure!", "Of course!", "Absolutely!" — just answer.

INGREDIENTS, SUBSTITUTIONS & PANTRY (non-negotiable)
- Before suggesting ANY ingredient or substitute, look at the USER PANTRY and DIETARY PREFERENCES below. Only suggest substitutes actually in their pantry. If nothing fits, say so honestly. Never suggest something that breaks their allergies or dietary rules. Don't claim an ingredient is in their pantry unless it's listed.

EDITING THE RECIPE (use the tools)
- Tools: edit_ingredient, add_ingredient, remove_ingredient, substitute_ingredient, edit_step, add_step, remove_step.
- When the user wants to swap, change, add, or remove anything, CALL the matching tool — don't just talk about it.
- To substitute a missing ingredient, or change an existing substitute, ALWAYS use substitute_ingredient (original + new). NEVER use add_ingredient for a substitution — that wrongly adds a duplicate.
- CASCADE EVERY INGREDIENT CHANGE THROUGH THE STEPS. After an ingredient edit/substitute/remove, the tool result will include "affected_steps" listing every step that still mentions the old ingredient. You MUST then call edit_step for EACH of those steps so they reference the new ingredient with its amount. Don't stop at one — do them all in the same turn before speaking.
- After a tool succeeds, say what changed in one short spoken sentence.
- This recipe is live and shared with the on-screen UI; never say you "can't change it" — you can. Only edit when they actually ask.

NEVER
- Never read the whole recipe aloud.
- Never list ingredients unless asked.
- Never rush them.
- Never speak in paragraphs.
- Never pretend you moved them between steps — the app handles step navigation when they tap done.`;

function fmtSecs(secs) {
  const s = Math.max(0, Math.round(secs));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

// True when a transcript is mostly NON-Latin letters — i.e. the input ASR
// rendered the user's English speech in another script (e.g. Kannada/Telugu)
// because the dish primed it. We keep such stray transcripts OUT of the saved
// history so they don't (a) re-prime the model toward that language on the next
// turn, or (b) pollute the shared text-chef conversation. The model still
// understood the original audio, so nothing is lost by not storing the garble.
function isMostlyNonLatin(text) {
  const letters = (text || "").match(/\p{L}/gu) || [];
  if (letters.length === 0) return false;
  const latin = letters.filter((c) => /[A-Za-z]/.test(c)).length;
  return latin / letters.length < 0.5;
}
function timersLine(timers) {
  if (!timers || timers.length === 0) return "none";
  const now = Date.now();
  return timers.map((t) => {
    const secs = Math.max(0, Math.round((new Date(t.ends_at).getTime() - now) / 1000));
    return secs <= 0 ? `${t.label} (DONE)` : `${t.label} (${fmtSecs(secs)} left)`;
  }).join(", ");
}

// Phase-1 string amount scaler (mirrors text-chef). Non-numeric passes through.
function scaleAmount(amount, factor) {
  if (!amount || !isFinite(factor) || factor === 1) return amount;
  const m = String(amount).trim().match(/^(\d+\s+\d+\/\d+|\d+\/\d+|\d*\.?\d+)\s*(.*)$/);
  if (!m) return amount;
  let value;
  const numStr = m[1];
  if (numStr.includes("/")) {
    const parts = numStr.split(/\s+/);
    if (parts.length === 2) { const [a, b] = parts[1].split("/").map(Number); value = Number(parts[0]) + (b ? a / b : 0); }
    else { const [a, b] = numStr.split("/").map(Number); value = b ? a / b : 0; }
  } else value = Number(numStr);
  if (!isFinite(value)) return amount;
  const rest = m[2] || "";
  return rest ? `${fmtNum(value * factor)} ${rest}` : fmtNum(value * factor);
}
function fmtNum(n) { return Math.abs(n - Math.round(n)) < 0.01 ? String(Math.round(n)) : String(Math.round(n * 100) / 100); }
// Phase 2: structured ingredient scaling (qty×factor) with string fallback.
function scaleIngredientDisplay(i, factor) {
  if (typeof i?.qty === "number" && isFinite(i.qty) && i.unit) return `${fmtNum(i.qty * factor)} ${i.unit}`;
  return scaleAmount(i?.amount || "", factor);
}
// Phase 2: scale {{...}} step tokens, leave times/temps (**bold**) alone.
function scaleStepText(text, factor) {
  if (!text) return text;
  return String(text).replace(/\{\{([^}]*)\}\}/g, (_m, inner) => scaleAmount(String(inner).trim(), factor));
}
function matchPantry(name, pantry) {
  const n = (name || "").toLowerCase().trim();
  if (!n) return undefined;
  return (pantry || []).find((p) => { const a = (p.name || "").toLowerCase().trim(); return a.includes(n) || n.includes(a); });
}
function servingLabel(adults, children) {
  const eff = adults + 0.5 * children;
  const parts = [`${adults} adult${adults === 1 ? "" : "s"}`];
  if (children > 0) parts.push(`${children} child${children === 1 ? "" : "ren"}`);
  return `${parts.join(" + ")} (≈ ${eff % 1 === 0 ? eff : eff.toFixed(1)} servings)`;
}

function buildVoiceContext(recipe, pantry, currentStep, prefs, timers, servingFactor = 1, servingSummary = "") {
  const stepsList = (recipe.steps || []).map((s, i) =>
    `${i === currentStep ? "[NOW]" : i < currentStep ? "[done]" : "[ ]"} Step ${i + 1}: ${scaleStepText(s, servingFactor)}`
  ).join("\n");
  const ingList = (recipe.ingredients || []).map((i) =>
    `- ${i.name}: ${scaleIngredientDisplay(i, servingFactor)}${i.in_pantry === false ? " [MISSING from pantry]" : ""}`
  ).join("\n");
  const pantryList = (pantry && pantry.length)
    ? pantry.map((p) => {
        const have = (typeof p.stock_qty === "number" && isFinite(p.stock_qty) && p.stock_unit)
          ? ` — have ${fmtNum(p.stock_qty)} ${p.stock_unit}`
          : "";
        return `- ${p.name}${p.brand ? ` (${p.brand})` : ""}${have}`;
      }).join("\n")
    : "(pantry is empty)";
  // Lean expiry: surface ONLY items expiring within 7 days (not all 40 dates),
  // so the live model gets the useful "use these first" signal without the
  // context bloat that was degrading its step/timer discipline.
  const nowMs = Date.now();
  const expiringSoon = (pantry || []).filter((p) => {
    if (!p.expiry) return false;
    const days = (new Date(p.expiry).getTime() - nowMs) / 86_400_000;
    return days >= 0 && days <= 7;
  });
  const expiringLine = expiringSoon.length
    ? `\n\nEXPIRING SOON (gently prefer using these if they fit the dish): ${expiringSoon.map((p) => `${p.name} (${p.expiry})`).join(", ")}`
    : "";
  // Quantity-aware shortfall (same logic as text-chef).
  const shortfalls = [];
  for (const i of (recipe.ingredients || [])) {
    if (typeof i.qty !== "number" || !isFinite(i.qty) || !i.unit) continue;
    const need = i.qty * servingFactor;
    const p = matchPantry(i.name, pantry);
    if (!p || typeof p.stock_qty !== "number" || !p.stock_unit || p.stock_unit !== i.unit) continue;
    if (need > p.stock_qty + 0.001) shortfalls.push(`- ${i.name}: need ${fmtNum(need)} ${i.unit}, pantry has only ${fmtNum(p.stock_qty)} ${p.stock_unit} (short ~${fmtNum(need - p.stock_qty)} ${i.unit})`);
  }
  const shortfallBlock = shortfalls.length
    ? `\n\nPANTRY SHORTFALLS (not enough on hand at this serving size):\n${shortfalls.join("\n")}\nProactively warn the user about these and offer a concrete fix — cook fewer servings, scale down, or substitute from the pantry. Say exactly how much they're short.`
    : "";
  const allergies = prefs?.allergies?.length ? prefs.allergies.join(", ") : "none";
  const dietary = prefs?.dietary?.length ? prefs.dietary.join(", ") : "none";
  const cuisines = prefs?.cuisines?.length ? prefs.cuisines.join(", ") : "no specific preference";
  return `RECIPE: ${recipe.name}\n\nCOOKING FOR: ${servingSummary || "1 serving"} — BOTH the INGREDIENTS list and the STEP amounts are ALREADY scaled to this serving size. Cooking times and temperatures are NOT scaled. Guide the user with exactly these scaled amounts.\n\nINGREDIENTS:\n${ingList}\n\nSTEPS:\n${stepsList}${shortfallBlock}\n\nUSER PANTRY — only suggest substitutes from this list. "have X" is how much they have on hand; use it to judge whether there's enough. READ-ONLY — you cannot change the pantry:\n${pantryList}${expiringLine}\n\nDIETARY PREFERENCES: ${dietary}\nALLERGIES (never suggest these): ${allergies}\nPREFERRED CUISINES: ${cuisines}\n\nACTIVE TIMERS: ${timersLine(timers)}\n\nCURRENTLY ON STEP ${currentStep + 1}.`;
}

const safeSend = (ws, obj) => {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  try { ws.send(typeof obj === "string" ? obj : JSON.stringify(obj)); }
  catch (e) { console.warn(`[voice-chef] send failed: ${e}`); }
};

// ----- HTTP server: health check + WebSocket upgrade -----
const server = http.createServer((req, res) => {
  if (req.method === "GET" && (req.url === "/health" || req.url === "/")) {
    res.writeHead(200, { "Content-Type": "text/plain" });
    return res.end("ok");
  }
  res.writeHead(426, { "Content-Type": "text/plain" });
  res.end("Expected WebSocket upgrade. Connect with ?cook_session_id=<uuid>.");
});

const wss = new WebSocket.Server({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  let cookSessionId = null;
  try {
    const u = new URL(req.url, `http://${req.headers.host}`);
    cookSessionId = u.searchParams.get("cook_session_id");
  } catch (_) { /* fallthrough */ }
  if (!cookSessionId) {
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\nmissing cook_session_id");
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (clientWs) => {
    handleSession(clientWs, cookSessionId).catch((e) => {
      console.error(`[voice-chef] session error: ${e}`);
      safeSend(clientWs, { type: "error", message: "session init failed" });
      try { clientWs.close(); } catch (_) { /* noop */ }
    });
  });
});

async function handleSession(clientWs, cookSessionId) {
  console.log(`[voice-chef] client connected, cook=${cookSessionId}`);
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: cook } = await supabase.from("cook_sessions").select("*").eq("id", cookSessionId).single();
  if (!cook) {
    safeSend(clientWs, { type: "error", message: "cook session not found" });
    return clientWs.close();
  }
  const { data: recipe } = await supabase.from("recipes").select("*").eq("id", cook.recipe_id).single();
  const { data: pantry } = await supabase.from("pantry_items").select("name, brand, stock_qty, stock_unit, expiry").eq("user_id", cook.user_id);
  const { data: prefRow } = await supabase.from("user_preferences")
    .select("dietary, allergies, cuisines").eq("user_id", cook.user_id).maybeSingle();
  const prefs = {
    dietary: Array.isArray(prefRow?.dietary) ? prefRow.dietary : [],
    allergies: Array.isArray(prefRow?.allergies) ? prefRow.allergies : [],
    cuisines: Array.isArray(prefRow?.cuisines) ? prefRow.cuisines : [],
  };
  const { data: activeTimers } = await supabase.from("cook_timers")
    .select("label, ends_at").eq("cook_session_id", cookSessionId).eq("status", "running");
  const adults = Math.max(1, cook.cooked_servings || recipe.servings_base || 1);
  const kids = Math.max(0, cook.cooked_children || 0);
  const base = Math.max(1, recipe.servings_base || 1);
  const servingFactor = (adults + 0.5 * kids) / base;
  const contextBlock = buildVoiceContext(recipe, pantry || [], cook.current_step, prefs, activeTimers || [], servingFactor, servingLabel(adults, kids));

  // ONE shared conversation per cook session (kind="chef"), used by BOTH the
  // text chef and this voice chef. Find the existing one (any kind) or create
  // it — so voice takes over with the full text context and writes back into
  // the same history the text chef reads.
  let chat;
  {
    const { data: existing } = await supabase.from("chat_sessions")
      .select("id").eq("cook_session_id", cookSessionId)
      .order("started_at", { ascending: true }).limit(1).maybeSingle();
    if (existing) {
      chat = existing;
    } else {
      const { data: created } = await supabase.from("chat_sessions").insert({
        user_id: cook.user_id, kind: "chef", cook_session_id: cookSessionId, recipe_id: cook.recipe_id,
      }).select("id").single();
      chat = created;
    }
  }

  // Load prior conversation so voice can continue from where text left off.
  // Filter the synthetic openers the text chef injects to steer itself.
  const isSyntheticOpener = (t) =>
    /^Let's start cooking!|^The user just finished step|^The user wants to go back|^The user just marked the final step done|^\[system:/.test(t || "");
  let priorTurns = [];
  if (chat?.id) {
    const { data: history } = await supabase.from("chat_messages")
      .select("role, text, created_at").eq("session_id", chat.id)
      .order("created_at", { ascending: true });
    priorTurns = (history || [])
      .filter((m) => m.text && (m.role === "user" || m.role === "model") &&
        !(m.role === "user" && isSyntheticOpener(m.text)) &&
        // Never replay a non-English (mis-transcribed) user turn — it would
        // re-prime the model toward that language.
        !(m.role === "user" && isMostlyNonLatin(m.text)))
      .slice(-20)
      .map((m) => ({ role: m.role === "model" ? "model" : "user", parts: [{ text: m.text }] }));
  }

  let upstream = null;
  let upstreamReady = false;
  let closed = false;
  let audioFrames = 0;      // count of client→us audio frames (diagnostics)
  let audioFramesDropped = 0; // arrived before upstream was ready
  // Per-turn transcript buffers — we save ONE clean chat_message per turn on
  // turnComplete, not a row per streaming fragment (which would shred history).
  let inBuf = "";
  let outBuf = "";

  const token = await getToken();
  upstream = new WebSocket(LIVE_WS, {
    headers: {
      Authorization: `Bearer ${token}`,
      "x-goog-user-project": PROJECT,
    },
  });

  upstream.on("open", () => {
    console.log(`[voice-chef] upstream open`);
    const setup = {
      setup: {
        model: MODEL_PATH,
        generationConfig: {
          responseModalities: ["AUDIO"],
          speechConfig: {
            voiceConfig: { prebuiltVoiceConfig: { voiceName: "Aoede" } },
            // Pin spoken output to English so the chef doesn't drift into the
            // dish's native language (e.g. Hindi for an Indian recipe).
            languageCode: "en-US",
          },
          temperature: 0.7,
        },
        systemInstruction: { parts: [{ text: `${VOICE_SYSTEM}\n\n=== LIVE COOKING CONTEXT ===\n${contextBlock}` }] },
        tools: LEDGER_TOOLS,
        inputAudioTranscription: {},
        outputAudioTranscription: {},
      },
    };
    safeSend(upstream, setup);
  });

  upstream.on("message", async (data) => {
    try {
      const msg = JSON.parse(data.toString());
      console.log(`[voice-chef] up msg keys: ${Object.keys(msg).join(",")}`);

      if (msg.setupComplete) {
        upstreamReady = true;
        safeSend(clientWs, { type: "ready" });
        if (priorTurns.length > 0) {
          // CONTINUITY: the user already chatted (likely in the text chef). This
          // is the SAME conversation — they just flipped on hands-free. Replay
          // the history as CONTEXT and prime the chef to absorb the full state
          // (recipe, done steps, current step, chat so far) — but do NOT force a
          // spoken turn. turnComplete:false means the model takes it in and WAITS
          // for the user to speak, instead of blurting/advancing a step on its own.
          safeSend(upstream, {
            clientContent: {
              turns: [
                ...priorTurns,
                { role: "user", parts: [{ text: "[system: The user just switched THIS SAME conversation to hands-free voice mid-cook — you are the same chef continuing, not a new one. Take in the context: the recipe, which steps are [done], the [NOW] current step, and our chat so far. Do NOT greet as new, do NOT restart or re-read the recipe, and do NOT advance or re-announce a step on your own. Be ready and wait — let the user speak first, then respond naturally with full awareness of where we are.]" }] }],
              turnComplete: false,
            },
          });
        } else {
          // Fresh session — warm greeting, wait for the user to start.
          safeSend(upstream, {
            clientContent: {
              turns: [{ role: "user", parts: [{ text: "[system: the user just opened the voice chef. Greet them warmly in ONE short, natural sentence (use the recipe name), then ask if they're ready to start whenever they are. Do NOT read the step yet — wait for them to say they're ready." }] }],
              turnComplete: true,
            },
          });
        }
        return;
      }

      // Model wants to mutate via the ledger: run each tool through the shared
      // writer, push the new state to iOS, then hand the results back to the
      // model so its next reply reflects what actually saved.
      if (msg.toolCall) {
        const fcs = msg.toolCall.functionCalls || [];
        console.log(`[voice-chef] toolCall: ${fcs.map((f) => f.name + "(" + JSON.stringify(f.args) + ")").join(", ")}`);
        const responses = [];
        for (const fc of fcs) {
          if (fc.name === "check_timers") {
            const lt = await listTimers(cookSessionId);
            console.log(`[voice-chef] check_timers -> ${JSON.stringify(lt.timers)}`);
            responses.push({ id: fc.id, name: fc.name, response: lt });
            continue;
          }
          if (TIMER_OPS.has(fc.name)) {
            const tr = await callTimers(cookSessionId, fc.name, fc.args || {});
            console.log(`[voice-chef] timer ${fc.name} ok=${tr?.ok} ${tr?.summary || tr?.error || ""}`);
            if (Array.isArray(tr?.timers)) safeSend(clientWs, { type: "timers_updated", timers: tr.timers });
            responses.push({ id: fc.id, name: fc.name, response: tr });
            continue;
          }
          const result = await callLedger(cookSessionId, fc.name, fc.args || {});
          console.log(`[voice-chef] ledger ${fc.name} ok=${result?.ok} ${result?.summary || result?.error || ""}`);
          if (result?.ok) {
            // ledger_updated carries the FULL post-mutation state — recipe
            // (ingredients + steps) AND session pointer (current_step,
            // done_step_idxs). The iOS client applies whichever fields are
            // present so step-nav tools (mark_step_done, set_current_step…)
            // move the UI's checklist instantly without the user pressing a
            // button.
            safeSend(clientWs, {
              type: "ledger_updated",
              ingredients: result.ingredients,
              steps: result.steps,
              current_step: result.current_step,
              done_step_idxs: result.done_step_idxs,
            });
          }
          responses.push({ id: fc.id, name: fc.name, response: result });
        }
        safeSend(upstream, { toolResponse: { functionResponses: responses } });
        return;
      }

      const sc = msg.serverContent;
      if (sc) {
        if (sc.modelTurn?.parts) {
          for (const part of sc.modelTurn.parts) {
            if (part.inlineData?.data) {
              safeSend(clientWs, { type: "audio", data: part.inlineData.data });
            }
          }
        }
        // Transcripts stream in fragments. Forward each fragment to the UI for
        // live captions, but ACCUMULATE them and write ONE chat_message per
        // turn (on turnComplete) so the shared history stays clean — not a row
        // per word.
        if (sc.inputTranscription?.text) {
          const t = sc.inputTranscription.text;
          inBuf += t;
          safeSend(clientWs, { type: "transcript_in", text: t });
        }
        if (sc.outputTranscription?.text) {
          const t = sc.outputTranscription.text;
          outBuf += t;
          safeSend(clientWs, { type: "transcript_out", text: t });
        }
        if (sc.turnComplete) {
          // Flush the completed turn's transcripts as single messages. Skip the
          // synthetic [system:] opener echo if it ever shows up in input.
          const userText = inBuf.trim();
          const modelText = outBuf.trim();
          inBuf = ""; outBuf = "";
          if (userText) {
            console.log(`[voice-chef] HEARD user: "${userText.slice(0, 80)}"`);
            // Skip saving a transcript that came back in the wrong script (a
            // mis-detected language). Keeping it would re-prime the model and
            // leak non-English text into the shared text-chef history.
            if (isMostlyNonLatin(userText)) {
              console.warn(`[voice-chef] dropping non-Latin transcript from history`);
            } else {
              supabase.from("chat_messages").insert({
                session_id: chat?.id, role: "user", text: userText,
              }).then(() => {});
            }
          }
          if (modelText) {
            supabase.from("chat_messages").insert({
              session_id: chat?.id, role: "model", text: modelText, model: LIVE_MODEL,
            }).then(() => {});
          }
          safeSend(clientWs, { type: "turn_complete" });
        }
        if (sc.interrupted) {
          // Persist whatever the model managed to say before being cut off,
          // and the user speech that interrupted it, so history stays coherent.
          const userText = inBuf.trim();
          const modelText = outBuf.trim();
          inBuf = ""; outBuf = "";
          if (userText && !isMostlyNonLatin(userText)) supabase.from("chat_messages").insert({ session_id: chat?.id, role: "user", text: userText }).then(() => {});
          if (modelText) supabase.from("chat_messages").insert({ session_id: chat?.id, role: "model", text: modelText, model: LIVE_MODEL }).then(() => {});
          safeSend(clientWs, { type: "interrupted" });
        }
      }
    } catch (err) {
      console.error(`[voice-chef] upstream msg parse: ${err}`);
    }
  });

  upstream.on("error", (e) => {
    console.error(`[voice-chef] upstream error: ${e?.message || e}`);
    safeSend(clientWs, { type: "error", message: "upstream error" });
  });

  upstream.on("close", (code) => {
    console.log(`[voice-chef] upstream closed code=${code}`);
    safeSend(clientWs, { type: "closed", code });
    try { clientWs.close(); } catch (_) { /* noop */ }
  });

  clientWs.on("message", (data) => {
    try {
      const raw = data.toString();
      if (!raw) return;
      const msg = JSON.parse(raw);
      if (msg.type === "audio" && upstreamReady) {
        audioFrames++;
        if (audioFrames === 1 || audioFrames % 50 === 0) {
          const len = msg.data ? Buffer.from(msg.data, "base64").length : 0;
          console.log(`[voice-chef] client audio frame #${audioFrames} (${len} bytes)`);
        }
        safeSend(upstream, { realtimeInput: { audio: { data: msg.data, mimeType: "audio/pcm;rate=16000" } } });
      } else if (msg.type === "audio" && !upstreamReady) {
        audioFramesDropped++;
        if (audioFramesDropped === 1) console.warn(`[voice-chef] audio arriving before upstream ready — dropping`);
      } else if (msg.type === "text" && upstreamReady) {
        safeSend(upstream, { clientContent: { turns: [{ role: "user", parts: [{ text: msg.text }] }], turnComplete: true } });
      } else if (msg.type === "control" && upstreamReady) {
        // UI controls (Done button, checklist) drive the live chef so it stays
        // in sync. We inject a system-style user turn; the chef applies its
        // micro-action vs main-step logic and calls the right ledger tool.
        // Some controls SILENTLY update the chef's knowledge (turnComplete=false
        // → no spoken reply); others should trigger a spoken response.
        let instruction = "";
        let speak = true;
        if (msg.event === "done") {
          instruction = "[system: The user tapped the Done button — they finished what you just asked. If the current main step has more parts left, give them the next micro-action now; only if the whole step is complete, call mark_step_done and move to the next step. Use our conversation to judge what's left.]";
        } else if (msg.event === "step_sync") {
          // The checklist is the SOURCE OF TRUTH. Re-ground the chef on the exact
          // current step so it never narrates a stale one. Silent — the user is
          // just navigating the list, not asking for a response.
          const n = msg.step_number, total = msg.total_steps;
          const txt = (msg.step_text || "").toString().slice(0, 240);
          instruction = `[system: The user changed the checklist. The CURRENT step is now Step ${n} of ${total}: "${txt}". This is the source of truth — from now on treat Step ${n} as the current step; do NOT refer to an earlier step as current. Don't say anything unless they ask.]`;
          speak = false;
        } else if (msg.event === "timers") {
          // Live timer snapshot so the chef knows exactly what's running and how
          // long is left. Silent context update.
          const list = Array.isArray(msg.timers) && msg.timers.length
            ? msg.timers.map((t) => `${t.label}: ${t.seconds_left <= 0 ? "DONE" : fmtSecs(t.seconds_left)} left`).join(", ")
            : "none";
          instruction = `[system: Timer status right now — ${list}. Use these exact times if the user asks how long is left. Don't say anything unless they ask.]`;
          speak = false;
        } else if (msg.event === "timer_fired") {
          instruction = `[system: The "${msg.label || "cooking"}" timer just went off. Tell the user warmly in one short sentence that it's done, and what to do next for that item.]`;
        }
        if (instruction) {
          safeSend(upstream, { clientContent: { turns: [{ role: "user", parts: [{ text: instruction }] }], turnComplete: speak } });
        }
      } else if (msg.type === "close") {
        try { upstream?.close(); } catch (_) { /* noop */ }
        try { clientWs.close(); } catch (_) { /* noop */ }
      }
    } catch (err) {
      console.error(`[voice-chef] client msg: ${err}`);
    }
  });

  clientWs.on("error", (e) => console.error(`[voice-chef] client error: ${e?.message || e}`));

  clientWs.on("close", async () => {
    if (closed) return;
    closed = true;
    console.log(`[voice-chef] client closed (audioFrames received=${audioFrames}, dropped_pre_ready=${audioFramesDropped})`);
    try { upstream?.close(); } catch (_) { /* noop */ }
    if (chat?.id) {
      await supabase.from("chat_sessions").update({ ended_at: new Date().toISOString() }).eq("id", chat.id);
    }
  });
}

server.listen(PORT, () => {
  console.log(`voice-chef up on ${PORT} project=${PROJECT} location=${LOCATION} model=${LIVE_MODEL}`);
});
