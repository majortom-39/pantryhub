-- 009_recipe_source.sql
-- Distinguish how a recipe entered the system: the nightly curator vs. the
-- user's AI Chef author (suggestion they added to the feed). Drives a small
-- chef-hat badge on author recipes in the app.
alter table recipes add column if not exists source text not null default 'curator'; -- curator | author
update recipes set source = 'author' where curator_model like '%recipe-author%' and source <> 'author';
