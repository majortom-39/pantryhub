-- 011_pantry_stock.sql — Phase 2 quantity-aware pantry.
--
-- Adds a canonical numeric stock figure to each pantry item so the app and the
-- chefs can do fast arithmetic shortfall checks (need = recipe_qty × servings
-- vs. stock_qty) without calling the LLM at view time.
--
--   stock_qty  — total amount available NOW (package size × current fullness),
--                in the canonical unit. NULL = unknown (graceful fallback:
--                behaves like today, no shortfall computed).
--   stock_unit — canonical unit: 'g' (mass) | 'ml' (volume) | 'piece' (count).
--
-- Recipe ingredients gain matching qty(number)+unit(g|ml|piece) inside the
-- existing `recipes.ingredients` jsonb — no DDL needed there.

alter table pantry_items add column if not exists stock_qty  numeric;
alter table pantry_items add column if not exists stock_unit text;
