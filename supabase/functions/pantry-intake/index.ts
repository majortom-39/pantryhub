// pantry-intake — ONE entry point for every way a user adds pantry items.
//
// Four front doors in the app (photo, gallery, barcode, voice) funnel into the
// SAME structured item shape here, so the app shows ONE review-and-confirm list
// no matter how the items were captured. This function only READS/derives — it
// returns structured items; the existing `pantry` function persists them after
// the user confirms.
//
//   POST { action: "scan_images",  images: ["<base64 jpeg>", ...] }
//   POST { action: "lookup_barcode", barcodes: ["0123456789012", ...] }
//   POST { action: "parse_voice",   transcript: "two onions, a litre of milk…" }
//
// Every action returns:  { items: IntakeItem[] }
// IntakeItem = {
//   name, brand, category(slug), quantity, image_kind,
//   expiry (YYYY-MM-DD|null), expiry_estimated (bool),
//   identified (bool),        // false = AI/lookup couldn't be sure; user types it in
//   barcode (string|null),    // echoed back for barcode misses
//   note (string)             // short human reason, e.g. "Couldn't read this label"
// }
//
// Defaults that match the product decisions:
//  • quantity defaults to full container (the app seeds fullness_levels:[1]).
//  • expiry is only set when printed/known; otherwise a rough estimate flagged
//    expiry_estimated:true so the app can nudge the user to confirm it.

const VERTEX_PROXY_URL = Deno.env.get("VERTEX_PROXY_URL")!;
const VERTEX_PROXY_SECRET = Deno.env.get("VERTEX_PROXY_SECRET")!;
const GEMINI_MODEL = "gemini-3.1-flash-lite";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
  "Access-Control-Allow-Headers": "authorization,content-type",
};

const CATEGORIES = ["produce", "meat", "dairy", "grains", "condiments", "snacks", "drinks", "frozen"];

// ---------------------------------------------------------------------------
// Shared Gemini caller (same proxy contract every other function uses).
// ---------------------------------------------------------------------------
// deno-lint-ignore no-explicit-any
async function geminiGenerate(body: object): Promise<any[]> {
  const maxRetries = 3;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const res = await fetch(VERTEX_PROXY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Proxy-Secret": VERTEX_PROXY_SECRET },
      body: JSON.stringify({ model: GEMINI_MODEL, ...body }),
    });
    if (res.ok) {
      const json = await res.json();
      return json?.candidates?.[0]?.content?.parts ?? [];
    }
    if ((res.status === 429 || res.status >= 500) && attempt < maxRetries) {
      const delay = Math.min(1000 * Math.pow(2, attempt), 12_000) + Math.random() * 400;
      await new Promise((r) => setTimeout(r, delay));
      continue;
    }
    throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 400)}`);
  }
  throw new Error("Gemini retries exhausted");
}

// Pull the text out of the model's parts and parse the JSON object inside it,
// tolerating ```json fences or stray prose around it.
// deno-lint-ignore no-explicit-any
function parseJSONFromParts(parts: any[]): any {
  const text = parts.map((p) => p?.text ?? "").join("").trim();
  if (!text) return null;
  // Prefer a fenced block, else the outermost {...}.
  let body = text;
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) body = fence[1].trim();
  else {
    const first = body.indexOf("{");
    const last = body.lastIndexOf("}");
    if (first >= 0 && last > first) body = body.slice(first, last + 1);
  }
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
}

// Coerce whatever the model/lookup gives into a clean, safe IntakeItem.
// deno-lint-ignore no-explicit-any
function normalizeItem(raw: any): IntakeItem | null {
  const name = String(raw?.name ?? "").trim().slice(0, 120);
  // An item with no name at all is useless — drop it (unless it's a flagged miss).
  const identified = raw?.identified !== false;
  if (!name && identified) return null;

  let category = String(raw?.category ?? "").toLowerCase().trim();
  if (!CATEGORIES.includes(category)) category = guessCategory(name, String(raw?.note ?? ""));

  const expiryRaw = raw?.expiry ? String(raw.expiry).slice(0, 10) : null;
  const expiry = /^\d{4}-\d{2}-\d{2}$/.test(expiryRaw || "") ? expiryRaw : null;

  const kind = String(raw?.image_kind ?? "").toLowerCase();
  return {
    name: name || "Unknown item",
    brand: String(raw?.brand ?? "").trim().slice(0, 80),
    category,
    quantity: String(raw?.quantity ?? "").trim().slice(0, 80),
    image_kind: kind === "product" ? "product" : "generic",
    expiry,
    expiry_estimated: expiry ? raw?.expiry_estimated === true : false,
    identified,
    barcode: raw?.barcode ? String(raw.barcode).slice(0, 32) : null,
    note: String(raw?.note ?? "").trim().slice(0, 160),
  };
}

interface IntakeItem {
  name: string;
  brand: string;
  category: string;
  quantity: string;
  image_kind: "generic" | "product";
  expiry: string | null;
  expiry_estimated: boolean;
  identified: boolean;
  barcode: string | null;
  note: string;
}

// Lightweight keyword → category fallback for when nothing better is known.
function guessCategory(name: string, extra = ""): string {
  const s = `${name} ${extra}`.toLowerCase();
  const has = (...ws: string[]) => ws.some((w) => s.includes(w));
  if (has("milk", "cheese", "yogurt", "yoghurt", "butter", "cream", "egg", "paneer")) return "dairy";
  if (has("chicken", "beef", "pork", "lamb", "fish", "salmon", "tuna", "shrimp", "prawn", "bacon", "ham", "mutton", "meat", "seafood")) return "meat";
  if (has("rice", "bread", "flour", "pasta", "noodle", "oat", "cereal", "wheat", "loaf", "tortilla", "grain")) return "grains";
  if (has("soda", "juice", "water", "coffee", "tea", "cola", "beer", "wine", "drink", "beverage", "lassi")) return "drinks";
  if (has("frozen", "canned", "can ", "tinned")) return "frozen";
  if (has("chip", "cookie", "candy", "chocolate", "snack", "sweet", "biscuit", "cracker")) return "snacks";
  if (has("oil", "sauce", "spice", "salt", "sugar", "pepper", "masala", "pickle", "vinegar", "ketchup", "mustard", "honey", "jam", "paste", "powder", "condiment", "seasoning")) return "condiments";
  if (has("apple", "banana", "tomato", "onion", "garlic", "potato", "carrot", "lettuce", "spinach", "pepper", "fruit", "veg", "lemon", "lime", "mango", "berr")) return "produce";
  return "condiments"; // safest catch-all for packaged goods
}

// ===========================================================================
// Action 1: scan_images — vision extraction from photos / receipts.
// ===========================================================================
async function handleScanImages(images: unknown): Promise<{ items: IntakeItem[] }> {
  const list = Array.isArray(images) ? images.filter((x) => typeof x === "string" && x.length > 0) : [];
  if (list.length === 0) return { items: [] };
  // Hard cap to keep payload/cost sane (the app batches photos in one go).
  const capped = (list as string[]).slice(0, 8);

  const today = new Date().toISOString().slice(0, 10);
  const sys = `You are PantryHub's vision intake assistant. You are given one or more photos. They may show:
 • a grocery receipt (a list of purchased products), OR
 • a pantry/fridge shelf with several products, OR
 • a single product (front or back of a package).

Extract EVERY distinct food or grocery product you can see across ALL the images. Combine the images — if the same product appears twice, list it once.

For each product return:
 - name: the product / food name in clean Title Case, correctly spelled (e.g. "Mango Pickle", "Blended Sesame Oil", "Eggs").
 - brand: the brand if visible, else "".
 - category: EXACTLY one of: produce, meat, dairy, grains, condiments, snacks, drinks, frozen.
 - quantity: the package size. Use what's PRINTED on the package when visible (e.g. "500 g", "1 L", "12 ct"). If the size isn't legible/printed, fill in the TYPICAL retail package size for that exact brand + product from your knowledge (e.g. "Café Du Monde Coffee and Chicory" → "15 oz", "Friendly Farms Whole Milk" → "1/2 gal") rather than leaving it blank — the user can correct it. Only use "" if you truly have no idea what size it comes in.
 - image_kind: "product" for a branded/packaged good, "generic" for a loose whole food (an onion, an egg).
 - expiry: a date YYYY-MM-DD ONLY if a best-before / use-by / expiry date is clearly printed. If none is printed you MAY estimate a typical one for that food relative to today (${today}); if you estimate, set expiry_estimated:true. If you truly can't reason about it, use null.
 - identified: true normally. Set FALSE when you can SEE a product but cannot confidently name it (blurry, cut off, label turned away, foreign/unfamiliar, no readable text). Still include it; put your best guess (or "") in name.
 - note: THIS IS IMPORTANT. When identified is FALSE, write a SHORT VISUAL DESCRIPTION that lets the user instantly spot WHICH item you mean and type it in — include container type, colour, rough size, where it sits in the photo, and ANY partial text you can read. Good: "Small glass jar, green screw lid, Italian label, far-right of the fridge shelf — maybe a pesto or sauce." Bad: "Couldn't read this clearly." When identified is TRUE but you couldn't read one specific detail (brand, size, or date), say so briefly, e.g. "Size not legible." Otherwise leave note as "".

Return ONLY JSON: {"items":[ ... ]}. No prose.`;

  // deno-lint-ignore no-explicit-any
  const parts: any[] = (capped as string[]).map((b64) => ({
    inlineData: { mimeType: "image/jpeg", data: b64 },
  }));
  parts.push({ text: "Extract all pantry products from these images as JSON." });

  const out = await geminiGenerate({
    systemInstruction: { parts: [{ text: sys }] },
    contents: [{ role: "user", parts }],
    generationConfig: { temperature: 0.1, responseMimeType: "application/json" },
  });
  const parsed = parseJSONFromParts(out);
  const rawItems = Array.isArray(parsed?.items) ? parsed.items : Array.isArray(parsed) ? parsed : [];
  const items = rawItems.map(normalizeItem).filter((x): x is IntakeItem => x !== null);
  return { items };
}

// ===========================================================================
// Action 2: lookup_barcode — Open Food Facts (free, keyless).
// ===========================================================================
function offCategory(tagsOrText: string): string {
  return guessCategory("", tagsOrText);
}

async function lookupOne(barcode: string): Promise<IntakeItem> {
  const code = barcode.replace(/[^0-9]/g, "");
  const miss: IntakeItem = {
    name: "", brand: "", category: "condiments", quantity: "",
    image_kind: "product", expiry: null, expiry_estimated: false,
    identified: false, barcode: code,
    note: "We couldn't find this barcode — type the item in or try another method.",
  };
  if (!code) return miss;
  try {
    const url = `https://world.openfoodfacts.org/api/v2/product/${code}.json?fields=product_name,brands,quantity,categories,categories_tags`;
    const res = await fetch(url, {
      headers: { "User-Agent": "PantryHub/1.0 (pantryhub app barcode lookup)" },
    });
    if (!res.ok) return miss;
    const j = await res.json();
    if (j?.status !== 1 || !j?.product) return miss;
    const p = j.product;
    const name = String(p.product_name ?? "").trim();
    if (!name) return { ...miss, note: "Found the barcode but it has no name — type the item in." };
    const catText = `${p.categories ?? ""} ${(p.categories_tags ?? []).join(" ")}`;
    return {
      name: name.slice(0, 120),
      brand: String(p.brands ?? "").split(",")[0].trim().slice(0, 80),
      category: offCategory(`${name} ${catText}`),
      quantity: String(p.quantity ?? "").trim().slice(0, 80),
      image_kind: "product",
      expiry: null,
      expiry_estimated: false,
      identified: true,
      barcode: code,
      note: "",
    };
  } catch {
    return miss;
  }
}

async function handleLookupBarcode(barcodes: unknown): Promise<{ items: IntakeItem[] }> {
  const list = Array.isArray(barcodes)
    ? barcodes.filter((x) => typeof x === "string" && x.length > 0)
    : typeof barcodes === "string" ? [barcodes] : [];
  if (list.length === 0) return { items: [] };
  const capped = (list as string[]).slice(0, 20);
  const items = await Promise.all(capped.map(lookupOne));
  return { items };
}

// ===========================================================================
// Action 3: parse_voice — structure a spoken list into clean items.
// ===========================================================================
async function handleParseVoice(transcript: unknown): Promise<{ items: IntakeItem[] }> {
  const text = String(transcript ?? "").trim().slice(0, 2000);
  if (!text) return { items: [] };

  const today = new Date().toISOString().slice(0, 10);
  const sys = `You are PantryHub's voice intake assistant. The user spoke aloud the groceries they want to add to their pantry. Turn their words into a clean, correctly-spelled list of distinct products.

Rules:
 - Split everything they mention into separate items.
 - name: clean Title Case, correct spelling, singular product name (e.g. user says "tomatoes" → "Tomato", "a dozen eggs" → "Eggs").
 - brand: only if they clearly named one, else "".
 - category: EXACTLY one of: produce, meat, dairy, grains, condiments, snacks, drinks, frozen.
 - quantity: if they said an amount or count, normalise it (e.g. "two onions" → "2", "a litre of milk" → "1 L", "half a kg of rice" → "0.5 kg"); else "".
 - image_kind: "product" for branded/packaged goods, "generic" for loose whole foods.
 - expiry: estimate a typical best-before date for that food relative to today (${today}) and set expiry_estimated:true; use null only if you really can't.
 - identified: always true (the user told us what it is).

Return ONLY JSON: {"items":[ ... ]}. No prose.`;

  const out = await geminiGenerate({
    systemInstruction: { parts: [{ text: sys }] },
    contents: [{ role: "user", parts: [{ text }] }],
    generationConfig: { temperature: 0.2, responseMimeType: "application/json" },
  });
  const parsed = parseJSONFromParts(out);
  const rawItems = Array.isArray(parsed?.items) ? parsed.items : Array.isArray(parsed) ? parsed : [];
  const items = rawItems.map(normalizeItem).filter((x): x is IntakeItem => x !== null);
  return { items };
}

// ===========================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: CORS });
  try {
    const body = await req.json();
    let result: { items: IntakeItem[] };
    switch (body.action) {
      case "scan_images":   result = await handleScanImages(body.images); break;
      case "lookup_barcode": result = await handleLookupBarcode(body.barcodes ?? body.barcode); break;
      case "parse_voice":   result = await handleParseVoice(body.transcript); break;
      default: throw new Error(`unknown action: ${body.action}`);
    }
    return Response.json(result, { headers: CORS });
  } catch (err) {
    console.error(`[pantry-intake] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500, headers: CORS });
  }
});
