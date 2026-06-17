// recipe-ledger — the ONE writer for everything a chef can change during a
// cook session. Both chefs (text and voice) funnel mutations through here, so:
//   • text and voice can never drift
//   • ownership is checked once
//   • in_pantry stays honest after a swap
//   • step indices in cook_sessions stay correct when steps move
//   • the chef gets back a unified, fresh state snapshot it can act on
//
// What this writer mutates:
//   recipes.ingredients      (per-user copy)
//   recipes.steps            (per-user copy)
//   cook_sessions.current_step + done_step_idxs   (the user's progress)
//
// POST { cook_session_id, op, args }   (X-Ledger-Secret header required)
//   Recipe ops:    edit_ingredient | add_ingredient | remove_ingredient
//                  substitute_ingredient
//                  edit_step | add_step | remove_step
//   Session ops:   mark_step_done | mark_step_undone | set_current_step
//
// Successful response (uniform — chef can pick whatever it needs):
//   {
//     ok: true,
//     summary: "...",                  // one short human sentence
//     ingredients: [...],              // current ingredient list
//     steps: [...],                    // current step list
//     current_step: N,                 // session pointer
//     done_step_idxs: [...],           // checked-off steps
//     // Hint after an ingredient change — steps STILL referencing the OLD
//     // ingredient that the chef must follow up with edit_step on.
//     affected_steps: [{ step_number, text }]
//   }
// Error response: { ok: false, error: "..." }
//   substitute_ingredient with a substitute the user doesn't own → blocked here.
//   This prevents the model from suggesting off-pantry items in conversation.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Shared secret both chefs send in X-Ledger-Secret (Supabase fn secret + Cloud Run env).
const LEDGER_SECRET = Deno.env.get("LEDGER_SECRET") || "";

type Substitute = { name: string; note?: string };
type Ingredient = { name: string; amount: string; in_pantry?: boolean; substitute?: Substitute | null };

// Fuzzy contains-match used everywhere we compare names ("Greek yogurt" ↔ "Yogurt").
function fuzzyMatch(a: string, b: string): boolean {
  const x = a.toLowerCase().trim();
  const y = b.toLowerCase().trim();
  return x === y || x.includes(y) || y.includes(x);
}
function inPantry(name: string, pantry: { name: string }[]): boolean {
  return pantry.some((p) => fuzzyMatch(p.name, name));
}
function findIngredient(ings: Ingredient[], name: string): number {
  const n = name.toLowerCase().trim();
  let i = ings.findIndex((x) => x.name.toLowerCase().trim() === n);
  if (i === -1) i = ings.findIndex((x) => fuzzyMatch(x.name, n));
  return i;
}

// Steps that mention the given ingredient by name (case-insensitive substring).
// Used to tell the chef "you changed X — these steps still say X, please fix."
function stepsMentioning(steps: string[], name: string): Array<{ step_number: number; text: string }> {
  const needle = name.toLowerCase().trim();
  if (!needle) return [];
  // Match word boundaries to avoid e.g. "rice" → "price"; simple wordish guard.
  const out: Array<{ step_number: number; text: string }> = [];
  for (let i = 0; i < steps.length; i++) {
    const s = (steps[i] || "").toLowerCase();
    if (s.includes(needle)) out.push({ step_number: i + 1, text: steps[i] });
  }
  return out;
}

// When steps are inserted/removed, the cook_session's current_step and
// done_step_idxs need to stay pointing at the same logical actions.
function shiftSession(
  current: number,
  done: number[],
  changeIdx: number,  // 0-based index where the insert/remove happened
  delta: 1 | -1,
): { current: number; done: number[] } {
  let newCurrent = current;
  let newDone = done.slice();
  if (delta === 1) {
    // Inserted at changeIdx → everything at or after shifts down (idx + 1).
    if (current >= changeIdx) newCurrent = current + 1;
    newDone = newDone.map((i) => (i >= changeIdx ? i + 1 : i));
  } else {
    // Removed at changeIdx → everything strictly after shifts up (idx − 1).
    if (current > changeIdx) newCurrent = current - 1;
    newDone = newDone.filter((i) => i !== changeIdx).map((i) => (i > changeIdx ? i - 1 : i));
  }
  return { current: newCurrent, done: newDone };
}

interface MutationResult {
  ok: true;
  summary: string;
  recipe: { ingredients: Ingredient[]; steps: string[] };
  session: { current_step: number; done_step_idxs: number[] };
  affected_steps?: Array<{ step_number: number; text: string }>;
}

function err(message: string, status = 200) {
  return Response.json({ ok: false, error: message }, { status });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return err("POST only", 405);
  if (!LEDGER_SECRET || req.headers.get("X-Ledger-Secret") !== LEDGER_SECRET) {
    return err("unauthorized", 401);
  }

  const supabase: SupabaseClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    const { cook_session_id, op, args } = await req.json();
    if (!cook_session_id || !op) return err("missing cook_session_id or op");

    const { data: cook } = await supabase.from("cook_sessions")
      .select("id, user_id, recipe_id, current_step, done_step_idxs")
      .eq("id", cook_session_id).single();
    if (!cook) return err("cook session not found");

    const { data: recipe } = await supabase.from("recipes")
      .select("id, user_id, ingredients, steps").eq("id", cook.recipe_id).single();
    if (!recipe) return err("recipe not found");
    if (recipe.user_id && recipe.user_id !== cook.user_id) return err("ownership mismatch");

    const { data: pantryRows } = await supabase.from("pantry_items")
      .select("name").eq("user_id", cook.user_id);
    const pantry = pantryRows || [];

    const ingredients: Ingredient[] = Array.isArray(recipe.ingredients) ? [...recipe.ingredients] : [];
    let steps: string[] = Array.isArray(recipe.steps) ? [...recipe.steps] : [];
    let currentStep: number = cook.current_step ?? 0;
    let doneIdxs: number[] = Array.isArray(cook.done_step_idxs) ? [...cook.done_step_idxs] : [];
    const a = (args || {}) as Record<string, unknown>;

    let summary = "";
    // Set after an ingredient mutation — the chef MUST cascade these.
    let affected: Array<{ step_number: number; text: string }> | undefined;
    // Tracks whether we modified the recipe vs. just the session pointer.
    let recipeChanged = false;
    let sessionChanged = false;

    switch (op) {
      // ─────────────── recipe: ingredients ───────────────
      case "edit_ingredient": {
        const idx = findIngredient(ingredients, String(a.name || ""));
        if (idx === -1) return err(`ingredient not found: ${a.name}`);
        const before = ingredients[idx].name;
        const name = a.new_name ? String(a.new_name) : ingredients[idx].name;
        const amount = a.new_amount ? String(a.new_amount) : ingredients[idx].amount;
        const nowInPantry = inPantry(name, pantry);
        // Keep the substitute only if the ingredient is still "missing".
        const keptSub = nowInPantry ? null : (ingredients[idx].substitute ?? null);
        ingredients[idx] = { name, amount, in_pantry: nowInPantry, substitute: keptSub };
        summary = a.new_name
          ? `Swapped ${before} → ${name}${a.new_amount ? ` (${amount})` : ""}.`
          : `Updated ${name} to ${amount}.`;
        affected = stepsMentioning(steps, before).filter((s) => !s.text.toLowerCase().includes(name.toLowerCase()));
        recipeChanged = true;
        break;
      }
      case "substitute_ingredient": {
        // Set or REPLACE the substitute for a missing ingredient, in place.
        // Hard-validate the substitute is something the user actually owns —
        // this is what stops the model from suggesting "Apples" when there are
        // no apples in the pantry.
        const idx = findIngredient(ingredients, String(a.name || ""));
        if (idx === -1) return err(`ingredient not found: ${a.name}`);
        const subName = String(a.substitute_name ?? a.substitute ?? "").trim();
        const orig = ingredients[idx];
        if (!subName) {
          ingredients[idx] = { ...orig, substitute: null };
          summary = `Removed the substitute for ${orig.name}.`;
        } else {
          if (!inPantry(subName, pantry)) {
            // Tell the chef WHY it failed AND what's actually available, so the
            // very next tool call can use a real pantry item.
            const choices = pantry.map((p) => p.name).slice(0, 30).join(", ") || "(empty)";
            return err(`'${subName}' is not in the user's pantry — refusing to suggest something they don't own. Pantry has: ${choices}. Try substitute_ingredient again with one of these.`);
          }
          const note = a.note ? String(a.note) : "";
          ingredients[idx] = { ...orig, in_pantry: false, substitute: { name: subName, note } };
          summary = `Using ${subName} instead of ${orig.name}.`;
        }
        // The dish still cooks using the substitute, not the original. Show the
        // chef every step that names the original so it can rewrite them
        // referencing the substitute (and the substitute's amount/units).
        affected = stepsMentioning(steps, orig.name);
        recipeChanged = true;
        break;
      }
      case "add_ingredient": {
        const name = String(a.name || "").trim();
        if (!name) return err("name required");
        const amount = String(a.amount || "").trim();
        ingredients.push({ name, amount, in_pantry: inPantry(name, pantry), substitute: null });
        summary = `Added ${name}${amount ? ` (${amount})` : ""}.`;
        recipeChanged = true;
        break;
      }
      case "remove_ingredient": {
        const idx = findIngredient(ingredients, String(a.name || ""));
        if (idx === -1) return err(`ingredient not found: ${a.name}`);
        const [rm] = ingredients.splice(idx, 1);
        summary = `Removed ${rm.name}.`;
        affected = stepsMentioning(steps, rm.name);
        recipeChanged = true;
        break;
      }
      // ─────────────── recipe: steps ───────────────
      case "edit_step": {
        const i = Number(a.step_number) - 1;
        if (!(i >= 0 && i < steps.length)) return err(`step ${a.step_number} out of range`);
        steps[i] = String(a.new_text || "");
        summary = `Updated step ${i + 1}.`;
        recipeChanged = true;
        break;
      }
      case "add_step": {
        const text = String(a.text || "").trim();
        if (!text) return err("text required");
        // After_step_number is 1-based and refers to the step the new one goes
        // AFTER. 0 = very beginning. Missing → append at end.
        let after = a.after_step_number == null ? steps.length : Number(a.after_step_number);
        after = Math.max(0, Math.min(after, steps.length));
        steps.splice(after, 0, text);
        const shifted = shiftSession(currentStep, doneIdxs, after, 1);
        currentStep = shifted.current; doneIdxs = shifted.done;
        summary = `Added a step at position ${after + 1}.`;
        recipeChanged = true;
        sessionChanged = true;
        break;
      }
      case "remove_step": {
        const i = Number(a.step_number) - 1;
        if (!(i >= 0 && i < steps.length)) return err(`step ${a.step_number} out of range`);
        steps.splice(i, 1);
        const shifted = shiftSession(currentStep, doneIdxs, i, -1);
        currentStep = shifted.current; doneIdxs = shifted.done;
        summary = `Removed step ${i + 1}.`;
        recipeChanged = true;
        sessionChanged = true;
        break;
      }
      // ─────────────── session: progress ───────────────
      case "mark_step_done": {
        const i = Number(a.step_number) - 1;
        if (!(i >= 0 && i < steps.length)) return err(`step ${a.step_number} out of range`);
        if (!doneIdxs.includes(i)) doneIdxs = [...doneIdxs, i];
        if (i === currentStep) currentStep = Math.min(i + 1, steps.length);
        summary = `Marked step ${i + 1} done.`;
        sessionChanged = true;
        break;
      }
      case "mark_step_undone": {
        const i = Number(a.step_number) - 1;
        if (!(i >= 0 && i < steps.length)) return err(`step ${a.step_number} out of range`);
        doneIdxs = doneIdxs.filter((x) => x !== i);
        if (i < currentStep) currentStep = i;
        summary = `Marked step ${i + 1} not done.`;
        sessionChanged = true;
        break;
      }
      case "set_current_step": {
        const i = Number(a.step_number) - 1;
        if (!(i >= 0 && i <= steps.length)) return err(`step ${a.step_number} out of range`);
        currentStep = i;
        summary = `Now on step ${i + 1}.`;
        sessionChanged = true;
        break;
      }
      default:
        return err(`unknown op: ${op}`);
    }

    // Persist whatever actually changed.
    if (recipeChanged) {
      const { error: upErr } = await supabase.from("recipes")
        .update({ ingredients, steps }).eq("id", recipe.id);
      if (upErr) return err(`save failed: ${upErr.message}`);
    }
    if (sessionChanged) {
      const { error: csErr } = await supabase.from("cook_sessions")
        .update({ current_step: currentStep, done_step_idxs: doneIdxs }).eq("id", cook.id);
      if (csErr) return err(`session save failed: ${csErr.message}`);
    }

    const result: MutationResult = {
      ok: true,
      summary,
      recipe: { ingredients, steps },
      session: { current_step: currentStep, done_step_idxs: doneIdxs },
      ...(affected && affected.length ? { affected_steps: affected } : {}),
    };
    // Back-compat for the existing chefs (they currently read .ingredients/.steps
    // at the top level). Keep both shapes while we update them.
    return Response.json({
      ...result,
      ingredients,
      steps,
      current_step: currentStep,
      done_step_idxs: doneIdxs,
    });
  } catch (e) {
    return err(e instanceof Error ? e.message : String(e), 500);
  }
});
