-- 006_recipes_per_user.sql
-- Make recipes per-user: each recipe belongs to exactly one user, no cross-user sharing.
-- Replaces the old global content_hash dedup (which forced identical dishes to be
-- shared across users) with a PER-USER uniqueness rule.

-- 1) Add owner column (nullable first so we can backfill existing rows).
ALTER TABLE public.recipes
  ADD COLUMN user_id uuid REFERENCES public.app_users(id) ON DELETE CASCADE;

-- 2) Backfill all existing recipes to the demo user (only user that exists today).
UPDATE public.recipes
  SET user_id = '00000000-0000-0000-0000-000000000001'
  WHERE user_id IS NULL;

-- 3) Now require an owner on every recipe going forward.
ALTER TABLE public.recipes
  ALTER COLUMN user_id SET NOT NULL;

-- 4) Remove the global dedup rule that forced recipes to be shared across users.
ALTER TABLE public.recipes
  DROP CONSTRAINT IF EXISTS recipes_content_hash_key;

-- 5) Replace it with a PER-USER uniqueness rule: the same user won't get the
--    same recipe twice, but different users can each have their own copy.
ALTER TABLE public.recipes
  ADD CONSTRAINT recipes_user_content_hash_key UNIQUE (user_id, content_hash);

-- 6) Index for fast per-user recipe lookups.
CREATE INDEX IF NOT EXISTS idx_recipes_user_id ON public.recipes(user_id);

COMMENT ON COLUMN public.recipes.user_id IS 'Owner of this recipe. Recipes are per-user; no cross-user sharing.';
COMMENT ON TABLE public.recipes IS 'Per-user recipe store. Each row belongs to one user (user_id). content_hash is unique only WITHIN a user, so two users can hold identical dishes as separate private rows.';
