-- 003: Cooking sessions, chat ledgers, deduction log, kitchen log, prefs.
-- Phase-2 backend for Text Chef, Recipe Author, Save/Cook flows.

-- =========================================================================
-- user_preferences (1 row per user)
-- =========================================================================

CREATE TABLE user_preferences (
  user_id       UUID PRIMARY KEY REFERENCES app_users(id) ON DELETE CASCADE,
  cuisines      TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  dietary       TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  allergies     TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  unit_default  TEXT   NOT NULL DEFAULT 'metric'
                  CHECK (unit_default IN ('metric', 'imperial')),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE user_preferences IS
  'Per-user cuisine/dietary/allergy tags + default unit system. Read by Curator and Recipe Author when generating recipes.';

CREATE TRIGGER user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO user_preferences (user_id) VALUES ('00000000-0000-0000-0000-000000000001');

-- =========================================================================
-- cook_sessions — one row per "I'm cooking this recipe right now"
-- =========================================================================

CREATE TYPE cook_status AS ENUM ('active', 'finished', 'abandoned');

CREATE TABLE cook_sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  recipe_id       UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  current_step    INT  NOT NULL DEFAULT 0,
  status          cook_status NOT NULL DEFAULT 'active',
  -- Chef may modify steps mid-cook (e.g. "skip step 3"). Source of truth.
  modified_steps  JSONB,                                    -- nil = use recipe.steps as-is
  done_step_idxs  INT[] NOT NULL DEFAULT ARRAY[]::INT[],    -- which step indexes are marked done
  started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at     TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE cook_sessions IS
  'Active cooking state. One per started recipe. current_step = index user is on. modified_steps overrides recipe.steps when chef edits them.';

CREATE INDEX cook_sessions_user_status_idx ON cook_sessions(user_id, status);
CREATE INDEX cook_sessions_recipe_idx       ON cook_sessions(recipe_id);

CREATE TRIGGER cook_sessions_updated_at
  BEFORE UPDATE ON cook_sessions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================================
-- chat_sessions — text-chef chats, recipe-author chats, voice-chef transcripts
-- =========================================================================

CREATE TYPE chat_kind AS ENUM ('text_chef', 'voice_chef', 'recipe_author');

CREATE TABLE chat_sessions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  kind             chat_kind NOT NULL,
  cook_session_id  UUID REFERENCES cook_sessions(id) ON DELETE CASCADE,
                                -- text_chef/voice_chef are bound to a cook_session
                                -- recipe_author is null
  recipe_id        UUID REFERENCES recipes(id) ON DELETE SET NULL,
                                -- recipe_author may target a specific recipe
  started_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at         TIMESTAMPTZ
);

CREATE INDEX chat_sessions_user_kind_idx ON chat_sessions(user_id, kind, started_at DESC);
CREATE INDEX chat_sessions_cook_idx      ON chat_sessions(cook_session_id);

-- =========================================================================
-- chat_messages — every turn of every chat
-- =========================================================================

CREATE TYPE chat_role AS ENUM ('user', 'model', 'tool');

CREATE TABLE chat_messages (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   UUID NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  role         chat_role NOT NULL,
  text         TEXT,                       -- simple text turns (most common)
  parts        JSONB,                      -- richer: function calls, tool responses
  model        TEXT,                       -- which Gemini model produced this (for model turns)
  thinking_tokens INT,                     -- bookkeeping
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX chat_messages_session_idx ON chat_messages(session_id, created_at);

COMMENT ON TABLE chat_messages IS
  'Every chat turn for text/voice chef and recipe-author. parts holds functionCall/functionResponse JSON when present.';

-- =========================================================================
-- pantry_deduction_log — audit trail of every pantry mutation by the chef
-- =========================================================================

CREATE TABLE pantry_deduction_log (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  cook_session_id   UUID REFERENCES cook_sessions(id) ON DELETE SET NULL,
  pantry_item_id    UUID REFERENCES pantry_items(id) ON DELETE SET NULL,
  pantry_item_name  TEXT NOT NULL,                          -- snapshot for audit even after delete
  recipe_ingredient TEXT NOT NULL,                          -- as written in the recipe
  ingredient_amount TEXT NOT NULL,                          -- as written in the recipe
  fullness_before   NUMERIC[],                              -- snapshot of fullness_levels
  fullness_after    NUMERIC[],
  reduced_by        NUMERIC,                                -- approx % reduced from total
  notes             TEXT,                                   -- e.g. 'recipe asked for tahini but pantry has none'
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX pantry_deduction_log_user_idx ON pantry_deduction_log(user_id, created_at DESC);

COMMENT ON TABLE pantry_deduction_log IS
  'Every pantry write triggered by a finish-cook. Lets us audit, debug, and undo.';

-- =========================================================================
-- saved_recipes + cooked_recipes (Kitchen Log)
-- =========================================================================

CREATE TABLE saved_recipes (
  user_id    UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  recipe_id  UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  saved_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, recipe_id)
);

CREATE TABLE cooked_recipes (
  user_id          UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  recipe_id        UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  cooked_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cook_session_id  UUID REFERENCES cook_sessions(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, recipe_id)
);

CREATE INDEX saved_recipes_user_idx  ON saved_recipes(user_id, saved_at DESC);
CREATE INDEX cooked_recipes_user_idx ON cooked_recipes(user_id, cooked_at DESC);

COMMENT ON TABLE saved_recipes  IS 'My Kitchen → Saved tab. Pointer rows into Recipe Vault.';
COMMENT ON TABLE cooked_recipes IS 'My Kitchen → Cooked tab. Pointer rows into Recipe Vault. Deduplicated by primary key so re-cooking does not re-add.';

-- =========================================================================
-- RLS — same permissive pattern as Phase 1
-- =========================================================================

ALTER TABLE user_preferences     ENABLE ROW LEVEL SECURITY;
ALTER TABLE cook_sessions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_sessions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_messages        ENABLE ROW LEVEL SECURITY;
ALTER TABLE pantry_deduction_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_recipes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE cooked_recipes       ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon read user_preferences"     ON user_preferences     FOR SELECT TO anon USING (true);
CREATE POLICY "anon read cook_sessions"        ON cook_sessions        FOR SELECT TO anon USING (true);
CREATE POLICY "anon read chat_sessions"        ON chat_sessions        FOR SELECT TO anon USING (true);
CREATE POLICY "anon read chat_messages"        ON chat_messages        FOR SELECT TO anon USING (true);
CREATE POLICY "anon read pantry_deduction_log" ON pantry_deduction_log FOR SELECT TO anon USING (true);
CREATE POLICY "anon read saved_recipes"        ON saved_recipes        FOR SELECT TO anon USING (true);
CREATE POLICY "anon read cooked_recipes"       ON cooked_recipes       FOR SELECT TO anon USING (true);

CREATE POLICY "auth read user_preferences"     ON user_preferences     FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read cook_sessions"        ON cook_sessions        FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read chat_sessions"        ON chat_sessions        FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read chat_messages"        ON chat_messages        FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read pantry_deduction_log" ON pantry_deduction_log FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read saved_recipes"        ON saved_recipes        FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth read cooked_recipes"       ON cooked_recipes       FOR SELECT TO authenticated USING (true);
