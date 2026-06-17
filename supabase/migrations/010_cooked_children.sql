-- 010_cooked_children.sql
-- Serving size now has two parts: adults (full portions) and children (each a
-- half portion). Effective servings = cooked_servings + 0.5 * cooked_children.
alter table cook_sessions add column if not exists cooked_children integer not null default 0;
