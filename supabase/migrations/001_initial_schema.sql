-- PantryHub initial schema
-- Phase 1: pantry, recipes, daily feed. Single demo user (no auth yet).
-- Designed for cheap dedup of recipes across users (Recipe Vault pattern).

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =========================================================================
-- Enums
-- =========================================================================

CREATE TYPE pantry_category AS ENUM (
  'produce', 'meat', 'dairy', 'grains',
  'condiments', 'snacks', 'drinks', 'frozen'
);

CREATE TYPE item_image_kind AS ENUM ('generic', 'product');

CREATE TYPE meal_category AS ENUM ('breakfast', 'lunch', 'dinner', 'snacks');

CREATE TYPE recipe_difficulty AS ENUM ('easy', 'medium', 'elaborate');

-- =========================================================================
-- app_users — until Clerk is wired, every row points to a single demo user.
-- =========================================================================

CREATE TABLE app_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id   TEXT UNIQUE,                              -- Clerk user id (later)
  display_name  TEXT NOT NULL DEFAULT 'Alex',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE app_users IS
  'App users. Phase 1 = one hardcoded demo user. Future: link to Clerk via external_id.';

-- =========================================================================
-- Pantry Ledger — what the user has on hand.
-- Mirrors the SwiftUI PantryItem model so seeding from SampleData is 1:1.
-- =========================================================================

CREATE TABLE pantry_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  brand           TEXT NOT NULL DEFAULT '',
  image_name      TEXT NOT NULL DEFAULT '',
  image_kind      item_image_kind NOT NULL DEFAULT 'generic',
  category        pantry_category NOT NULL DEFAULT 'produce',
  quantity        TEXT NOT NULL DEFAULT '',
  fullness_levels NUMERIC[] NOT NULL DEFAULT ARRAY[1.0],
  fullness_unit   TEXT NOT NULL DEFAULT '%',
  expiry          DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE pantry_items IS
  'The Pantry Ledger — source of truth for what a user has. Curator and downstream nodes read from here.';

CREATE INDEX pantry_items_user_idx        ON pantry_items(user_id);
CREATE INDEX pantry_items_user_expiry_idx ON pantry_items(user_id, expiry);

-- =========================================================================
-- Recipe Vault — every recipe ever generated, deduplicated by content hash.
-- Two users with the same generated recipe share ONE row (and one image).
-- =========================================================================

CREATE TABLE recipes (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content_hash          TEXT UNIQUE NOT NULL,
  name                  TEXT NOT NULL,
  author                TEXT NOT NULL DEFAULT 'PantryHub Chef',
  category              meal_category NOT NULL,
  difficulty            recipe_difficulty NOT NULL,
  time_text             TEXT NOT NULL,                        -- e.g. "20–25 min"
  budget_text           TEXT NOT NULL DEFAULT '$5–$10',
  servings_base         INT  NOT NULL DEFAULT 1,
  calories_per_serving  INT  NOT NULL,
  ingredients           JSONB NOT NULL,                       -- [{name, amount, in_pantry, substitute?}]
  steps                 JSONB NOT NULL,                       -- ["step1", "step2", ...]
  image_url             TEXT,                                 -- set by Painter
  image_style           TEXT,                                 -- which of the 6 styles
  curator_model         TEXT,                                 -- 'gemini-3.1-flash-lite'
  curator_thinking      TEXT,                                 -- 'medium'
  painter_model         TEXT,                                 -- 'ZImageTurbo_INT8'
  prompt_version        TEXT NOT NULL DEFAULT 'v1',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE recipes IS
  'Recipe Vault. Global catalogue. content_hash is SHA-256 of normalized name+ingredients so identical recipes dedup across users.';

CREATE INDEX recipes_category_idx ON recipes(category);
CREATE INDEX recipes_created_idx  ON recipes(created_at DESC);

-- =========================================================================
-- Daily Feed — a user's 4 recipes for a day. Pure pointer rows into the Vault.
-- =========================================================================

CREATE TABLE daily_feed (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  feed_date    DATE NOT NULL,
  slot         meal_category NOT NULL,
  recipe_id    UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  match_score  INT  NOT NULL CHECK (match_score BETWEEN 0 AND 100),
  status       TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active', 'replaced', 'cooked')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, feed_date, slot)
);

COMMENT ON TABLE daily_feed IS
  'Per-user, per-day pointer rows into the Recipe Vault. Wipes nightly (later). Saved/cooked recipes live in separate ledgers.';

CREATE INDEX daily_feed_user_date_idx ON daily_feed(user_id, feed_date DESC);

-- =========================================================================
-- Auto-update updated_at on pantry_items
-- =========================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pantry_items_updated_at
  BEFORE UPDATE ON pantry_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================================
-- RLS — Phase 1 (no Clerk yet)
-- Edge functions use service_role and bypass RLS for writes.
-- Anon can SELECT (so iOS can fetch feed without auth during demo).
-- Will tighten to per-user policies once Clerk lands.
-- =========================================================================

ALTER TABLE app_users    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pantry_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE recipes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_feed   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon read app_users"    ON app_users    FOR SELECT TO anon USING (true);
CREATE POLICY "anon read pantry_items" ON pantry_items FOR SELECT TO anon USING (true);
CREATE POLICY "anon read recipes"      ON recipes      FOR SELECT TO anon USING (true);
CREATE POLICY "anon read daily_feed"   ON daily_feed   FOR SELECT TO anon USING (true);

CREATE POLICY "auth read app_users"    ON app_users    FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read pantry_items" ON pantry_items FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read recipes"      ON recipes      FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read daily_feed"   ON daily_feed   FOR SELECT TO authenticated USING (true);
