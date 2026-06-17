// pantry — the user's pantry sync endpoint (Phase 2).
//
// The cloud is the source of truth for the pantry. The app loads from here and
// writes every change back, so the Pantry page, the chefs, and the curator all
// read ONE list.
//
//   GET                                   → list the user's pantry items
//   POST { action: "add",    items: [...] }→ insert scanned items (returns rows)
//   POST { action: "update", item: {...} } → update one item by id (returns row)
//   POST { action: "delete", id }          → delete one item by id
//   POST { action: "backfill" }            → recompute stock_qty/stock_unit for
//                                            any rows missing it (one-shot)
//
// Each item carries a canonical stock figure (stock_qty + stock_unit) so the
// app/chefs can do fast shortfall arithmetic. We derive it here from the
// human "quantity" text × how full the containers are.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const DEMO_USER_ID = "00000000-0000-0000-0000-000000000001";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  "Access-Control-Allow-Headers": "authorization,content-type",
};

// Columns the app needs back (everything that round-trips a pantry item).
const FIELDS = "id, name, brand, image_name, image_kind, category, quantity, fullness_levels, fullness_unit, expiry, stock_qty, stock_unit";

// ── stock normalisation ──────────────────────────────────────────────────────
// Parse a human package size ("500 g box", "1 L carton", "12", "1 kg bag") into
// a canonical { amount, unit } in g | ml | piece. Returns null if unparseable.
function parsePackage(quantity: string): { amount: number; unit: "g" | "ml" | "piece" } | null {
  const q = (quantity || "").toLowerCase().trim();
  if (!q) return null;
  // leading number: integer, decimal, or simple fraction
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
  const rest = q.slice(m.index! + numStr.length);
  // unit detection (order matters: check kg/ml before g/l)
  if (/\bkg\b|kilogram/.test(rest)) return { amount: value * 1000, unit: "g" };
  if (/\bmg\b|milligram/.test(rest)) return { amount: value / 1000, unit: "g" };
  if (/\bg\b|gram/.test(rest)) return { amount: value, unit: "g" };
  if (/\boz\b|ounce/.test(rest)) return { amount: value * 28.35, unit: "g" };
  if (/\blb\b|pound/.test(rest)) return { amount: value * 453.6, unit: "g" };
  if (/\bml\b|millilit/.test(rest)) return { amount: value, unit: "ml" };
  if (/\b(l|litre|liter)\b/.test(rest)) return { amount: value * 1000, unit: "ml" };
  if (/\bdozen\b/.test(rest)) return { amount: value * 12, unit: "piece" };
  // bare number, or counted nouns (eggs, cans, slices…) → pieces
  return { amount: value, unit: "piece" };
}

// Total amount on hand now = package size × sum of each container's fullness.
// e.g. a 500 g box at [0.4, 0.15] = 0.55 boxes = 275 g.
function normalizeStock(quantity: string, fullnessLevels: unknown): { stock_qty: number; stock_unit: string } | null {
  const pkg = parsePackage(quantity);
  if (!pkg) return null;
  const lv = Array.isArray(fullnessLevels) && fullnessLevels.length
    ? (fullnessLevels as number[]).map(Number).filter((n) => isFinite(n))
    : [1];
  const fillSum = lv.reduce((a, b) => a + b, 0) || 1;
  let stock = pkg.amount * fillSum;
  stock = pkg.unit === "piece" ? Math.round(stock) : Math.round(stock * 10) / 10;
  return { stock_qty: stock, stock_unit: pkg.unit };
}

const ALLOWED_CATEGORY = new Set(["produce", "meat", "dairy", "grains", "condiments", "snacks", "drinks", "frozen"]);
const ALLOWED_KIND = new Set(["generic", "product"]);

// deno-lint-ignore no-explicit-any
function cleanItem(raw: any) {
  const quantity = String(raw?.quantity ?? "");
  const fullness = Array.isArray(raw?.fullness_levels) && raw.fullness_levels.length
    ? raw.fullness_levels.map((n: unknown) => Math.max(0, Math.min(1, Number(n) || 0)))
    : [1];
  const stock = normalizeStock(quantity, fullness);
  return {
    name: String(raw?.name ?? "").slice(0, 120),
    brand: String(raw?.brand ?? ""),
    image_name: String(raw?.image_name ?? ""),
    image_kind: ALLOWED_KIND.has(raw?.image_kind) ? raw.image_kind : "generic",
    category: ALLOWED_CATEGORY.has(raw?.category) ? raw.category : "produce",
    quantity,
    fullness_levels: fullness,
    fullness_unit: String(raw?.fullness_unit ?? "%"),
    expiry: raw?.expiry ? String(raw.expiry).slice(0, 10) : null,
    stock_qty: stock?.stock_qty ?? null,
    stock_unit: stock?.stock_unit ?? null,
  };
}

async function handleList(supabase: SupabaseClient, userId: string) {
  const { data, error } = await supabase.from("pantry_items")
    .select(FIELDS).eq("user_id", userId).order("created_at", { ascending: false });
  if (error) throw new Error(`pantry list failed: ${error.message}`);
  return { items: data || [] };
}

// deno-lint-ignore no-explicit-any
async function handleAdd(supabase: SupabaseClient, userId: string, items: any[]) {
  if (!Array.isArray(items) || items.length === 0) return { items: [] };
  const rows = items.map((i) => ({ user_id: userId, ...cleanItem(i) }));
  const { data, error } = await supabase.from("pantry_items").insert(rows).select(FIELDS);
  if (error) throw new Error(`pantry add failed: ${error.message}`);
  return { items: data || [] };
}

// deno-lint-ignore no-explicit-any
async function handleUpdate(supabase: SupabaseClient, userId: string, item: any) {
  const id = String(item?.id || "");
  if (!id) throw new Error("update needs an item id");
  const { data, error } = await supabase.from("pantry_items")
    .update(cleanItem(item)).eq("id", id).eq("user_id", userId).select(FIELDS).maybeSingle();
  if (error) throw new Error(`pantry update failed: ${error.message}`);
  return { item: data };
}

async function handleDelete(supabase: SupabaseClient, userId: string, id: string) {
  if (!id) throw new Error("delete needs an id");
  const { error } = await supabase.from("pantry_items").delete().eq("id", id).eq("user_id", userId);
  if (error) throw new Error(`pantry delete failed: ${error.message}`);
  return { ok: true };
}

// Recompute stock for rows that don't have it yet (one-shot backfill).
async function handleBackfill(supabase: SupabaseClient, userId: string) {
  const { data, error } = await supabase.from("pantry_items")
    .select("id, quantity, fullness_levels, stock_qty").eq("user_id", userId);
  if (error) throw new Error(`backfill read failed: ${error.message}`);
  let updated = 0, skipped = 0;
  for (const row of (data || [])) {
    if (row.stock_qty !== null && row.stock_qty !== undefined) { skipped++; continue; }
    const stock = normalizeStock(row.quantity || "", row.fullness_levels);
    if (!stock) { skipped++; continue; }
    const { error: uErr } = await supabase.from("pantry_items")
      .update({ stock_qty: stock.stock_qty, stock_unit: stock.stock_unit }).eq("id", row.id);
    if (!uErr) updated++;
  }
  return { updated, skipped };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    if (req.method === "GET") {
      return Response.json(await handleList(supabase, DEMO_USER_ID), { headers: CORS });
    }
    if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: CORS });

    const body = await req.json();
    const userId = body.user_id || DEMO_USER_ID;
    let result: unknown;
    switch (body.action) {
      case "add":      result = await handleAdd(supabase, userId, body.items); break;
      case "update":   result = await handleUpdate(supabase, userId, body.item); break;
      case "delete":   result = await handleDelete(supabase, userId, String(body.id || "")); break;
      case "backfill": result = await handleBackfill(supabase, userId); break;
      case "list":     result = await handleList(supabase, userId); break;
      default: throw new Error(`unknown action: ${body.action}`);
    }
    return Response.json(result, { headers: CORS });
  } catch (err) {
    console.error(`[pantry] ${err instanceof Error ? err.message : String(err)}`);
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500, headers: CORS });
  }
});
