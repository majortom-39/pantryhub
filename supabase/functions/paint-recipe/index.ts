// paint-recipe — generates a food-photography image for a recipe.
//
// Flow:
//   1. Receive { recipe_id }
//   2. Load recipe from DB
//   3. Pick a random style from a 6-pool (variety, no boring repetition)
//   4. Submit job to deAPI (ZImageTurbo_INT8)
//   5. Poll until done, download bytes
//   6. Upload to Supabase Storage (public bucket recipe-images)
//   7. Update recipes.image_url + image_style + painter_model
//
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// --- Config ---
// deAPI key is read from a Supabase function secret (DEAPI_API_KEY) — never
// hardcoded. Set it with: supabase secrets set DEAPI_API_KEY=... (or via the
// dashboard → Edge Functions → Secrets).
const DEAPI_API_KEY = Deno.env.get("DEAPI_API_KEY") || "";
const DEAPI_BASE = "https://api.deapi.ai/api/v2";
const PAINTER_MODEL = "ZImageTurbo_INT8";
const IMG_WIDTH = 1024;
const IMG_HEIGHT = 768; // 4:3 — flatters the RecipeCard crop
const IMG_STEPS = 8;     // model default
const POLL_INTERVAL_MS = 2_000;
const POLL_MAX_ATTEMPTS = 60; // 2 minutes ceiling

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// Vertex proxy (keyless Cloud Run) — used to GROUND what the dish looks like so
// the image model isn't guessing at obscure dishes (e.g. onion pakora).
const VERTEX_PROXY_URL = Deno.env.get("VERTEX_PROXY_URL") || "";
const VERTEX_PROXY_SECRET = Deno.env.get("VERTEX_PROXY_SECRET") || "";
const DESCRIBE_MODEL = "gemini-3.1-flash-lite";

// --- Style pool: 6 distinct professional food-photo styles ---
type Style = { id: string; prompt: string };
// Styles describe LIGHTING / SURFACE / ANGLE only — never "props" or
// "scattered ingredients", which is what made the model litter the plate with
// raw onions, flour piles and peanuts that aren't part of the finished dish.
const STYLES: Style[] = [
  {
    id: "overhead-flatlay",
    prompt: "overhead flat-lay top-down view on a clean ceramic plate, soft natural side lighting",
  },
  {
    id: "editorial-moody",
    prompt: "editorial moody dark background, single dramatic spotlight, fine-dining magazine aesthetic, deep shadows, rich contrast",
  },
  {
    id: "bright-airy",
    prompt: "bright airy modern Scandinavian, white marble surface, bright daylight, minimalist composition, clean negative space",
  },
  {
    id: "rustic-farmhouse",
    prompt: "rustic farmhouse table setting, weathered wood, linen napkin, warm golden-hour light",
  },
  {
    id: "bistro-plating",
    prompt: "fine bistro plating on a white porcelain plate, crisp white tablecloth, restaurant presentation",
  },
  {
    id: "cookbook-hero",
    prompt: "cookbook hero shot, three-quarter angle, perfectly composed, clean neutral background, razor-sharp focus",
  },
];

const COMMON_SUFFIX =
  "the finished, fully-cooked dish plated and ready to eat, professional food photography, highly appetizing, magazine quality, vibrant natural colors, sharp focus, 4k, no text, no watermark, no people, no hands";

// Forbid the model from inventing extra foods / scattering raw ingredients —
// the recurring complaint was garnishes and raw ingredient piles that aren't in
// the recipe.
const NEGATIVE_PROMPT =
  "raw ingredients scattered around the plate, separate piles of spices or flour, uncooked ingredients, deconstructed ingredients, extra garnishes not part of the dish, foods not in the recipe, text, letters, watermark, logo, people, hands, fingers, blurry, low quality, cartoon, illustration, deformed, ugly, overexposed";

// --- Helpers ---

function pickStyle(seed: string): Style {
  // Deterministic pick from a string seed — same recipe always gets same style,
  // BUT different recipes get visually different styles across the feed.
  let hash = 0;
  for (let i = 0; i < seed.length; i++) {
    hash = (hash * 31 + seed.charCodeAt(i)) | 0;
  }
  const idx = Math.abs(hash) % STYLES.length;
  return STYLES[idx];
}

// Ask Gemini (with Google Search grounding) what the FINISHED dish actually
// looks like, so the image model isn't guessing at dishes it doesn't know.
// Returns a short visual description, or "" on any failure (caller falls back).
async function describeDish(name: string, ingredients: string[]): Promise<string> {
  if (!VERTEX_PROXY_URL || !VERTEX_PROXY_SECRET) return "";
  const sys = `You describe finished dishes for a food photographer. In 2-3 vivid sentences, describe exactly what a finished, plated portion of the dish looks like — its colour, shape, texture, and how it is served on the plate. Describe ONLY the cooked dish as it sits ready to eat. Do NOT mention raw or uncooked ingredients, separate piles of spices/flour, props, or any ingredient not in the dish. If you are unsure what the dish looks like, search for it. Output plain prose only.`;
  const user = `Dish: "${name}". Made from: ${ingredients.join(", ")}.`;
  try {
    const res = await fetch(VERTEX_PROXY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Proxy-Secret": VERTEX_PROXY_SECRET },
      body: JSON.stringify({
        model: DESCRIBE_MODEL,
        systemInstruction: { parts: [{ text: sys }] },
        contents: [{ role: "user", parts: [{ text: user }] }],
        tools: [{ googleSearch: {} }],
        generationConfig: { thinkingConfig: { thinkingLevel: "minimal" }, temperature: 0.4 },
      }),
    });
    if (!res.ok) return "";
    const json = await res.json();
    // deno-lint-ignore no-explicit-any
    const parts = json?.candidates?.[0]?.content?.parts ?? [];
    // deno-lint-ignore no-explicit-any
    const text = parts.map((p: any) => p.text || "").join("").trim();
    return text.slice(0, 600);
  } catch {
    return "";
  }
}

function buildPrompt(recipeName: string, brief: string, topIngredients: string[], style: Style): string {
  // Prefer the grounded visual brief; fall back to name + ingredients.
  const subject = brief && brief.length > 20
    ? `${recipeName}: ${brief}`
    : `A plate of ${recipeName} made with ${topIngredients.slice(0, 5).join(", ")}`;
  return `${subject} ${style.prompt}, ${COMMON_SUFFIX}`;
}

async function submitJob(prompt: string): Promise<string> {
  const seed = Math.floor(Math.random() * 2_147_483_647);
  const res = await fetch(`${DEAPI_BASE}/images/generations`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${DEAPI_API_KEY}`,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify({
      model: PAINTER_MODEL,
      prompt,
      negative_prompt: NEGATIVE_PROMPT,
      width: IMG_WIDTH,
      height: IMG_HEIGHT,
      steps: IMG_STEPS,
      seed,
    }),
  });
  if (!res.ok) {
    throw new Error(`deAPI submit failed: ${res.status} ${await res.text()}`);
  }
  const body = await res.json();
  const requestId = body?.data?.request_id;
  if (!requestId) throw new Error(`deAPI submit returned no request_id: ${JSON.stringify(body)}`);
  return requestId;
}

async function pollJob(requestId: string): Promise<string> {
  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    const res = await fetch(`${DEAPI_BASE}/jobs/${requestId}`, {
      headers: {
        "Authorization": `Bearer ${DEAPI_API_KEY}`,
        "Accept": "application/json",
      },
    });
    if (!res.ok) {
      throw new Error(`deAPI poll failed: ${res.status} ${await res.text()}`);
    }
    const body = await res.json();
    const status = body?.data?.status;
    const resultUrl = body?.data?.result_url;
    if (status === "done" && resultUrl) return resultUrl;
    if (status === "failed" || status === "error") {
      throw new Error(`deAPI job failed: ${JSON.stringify(body)}`);
    }
  }
  throw new Error(`deAPI job did not complete within ${POLL_MAX_ATTEMPTS * POLL_INTERVAL_MS}ms`);
}

async function downloadImage(url: string): Promise<{ bytes: Uint8Array; contentType: string }> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Download failed: ${res.status}`);
  const contentType = res.headers.get("content-type") || "image/png";
  const bytes = new Uint8Array(await res.arrayBuffer());
  return { bytes, contentType };
}

function extFromContentType(ct: string): string {
  if (ct.includes("jpeg")) return "jpg";
  if (ct.includes("webp")) return "webp";
  return "png";
}

// --- Main handler ---

Deno.serve(async (req) => {
  // Tiny CORS preflight for safety
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
        "Access-Control-Allow-Headers": "authorization,content-type",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    const { recipe_id } = await req.json();
    if (!recipe_id) {
      return Response.json({ error: "recipe_id is required" }, { status: 400 });
    }

    // 1) Load recipe
    const { data: recipe, error: recipeErr } = await supabase
      .from("recipes")
      .select("id, user_id, name, ingredients, image_url, image_brief")
      .eq("id", recipe_id)
      .single();
    if (recipeErr || !recipe) {
      return Response.json({ error: `recipe not found: ${recipeErr?.message}` }, { status: 404 });
    }

    // Skip if already painted (idempotent)
    if (recipe.image_url) {
      return Response.json({
        recipe_id,
        image_url: recipe.image_url,
        skipped: true,
        reason: "already painted",
      });
    }

    // 2) Get a GROUNDED visual description of the dish (cached on the row), so
    // the image model paints the real dish — not a guess with invented props.
    const ingredientNames = (recipe.ingredients as Array<{ name: string }>).map((i) => i.name);
    let brief: string = (recipe.image_brief as string) || "";
    if (!brief) {
      brief = await describeDish(recipe.name, ingredientNames);
      if (brief) {
        await supabase.from("recipes").update({ image_brief: brief }).eq("id", recipe.id);
      }
    }

    const style = pickStyle(recipe.id);
    const prompt = buildPrompt(recipe.name, brief, ingredientNames, style);
    console.log(`[paint-recipe] ${recipe.name} → style=${style.id} brief=${brief ? "yes" : "no"}`);

    // 3) Submit + poll
    const requestId = await submitJob(prompt);
    console.log(`[paint-recipe] submitted ${requestId}`);
    const resultUrl = await pollJob(requestId);
    console.log(`[paint-recipe] result_url received`);

    // 4) Download
    const { bytes, contentType } = await downloadImage(resultUrl);
    const ext = extFromContentType(contentType);
    // Per-user path: each user's recipe images live under their own folder, so
    // images are never shared across users and a user's images can be wiped in
    // one sweep. recipe.id is already unique, so collisions are impossible.
    const storagePath = `${recipe.user_id}/${recipe.id}.${ext}`;

    // 5) Upload to Storage
    const { error: uploadErr } = await supabase.storage
      .from("recipe-images")
      .upload(storagePath, bytes, { contentType, upsert: true });
    if (uploadErr) throw new Error(`storage upload failed: ${uploadErr.message}`);

    // 6) Get public URL
    const { data: pub } = supabase.storage.from("recipe-images").getPublicUrl(storagePath);
    const publicUrl = pub.publicUrl;

    // 7) Update recipe row
    const { error: updateErr } = await supabase
      .from("recipes")
      .update({
        image_url: publicUrl,
        image_style: style.id,
        painter_model: PAINTER_MODEL,
      })
      .eq("id", recipe.id);
    if (updateErr) throw new Error(`recipe update failed: ${updateErr.message}`);

    return Response.json({
      recipe_id: recipe.id,
      image_url: publicUrl,
      style: style.id,
      skipped: false,
    });
  } catch (err) {
    console.error(`[paint-recipe] error: ${err instanceof Error ? err.message : String(err)}`);
    return Response.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 500 },
    );
  }
});
