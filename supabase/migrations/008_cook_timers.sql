-- 008_cook_timers.sql
-- In-app cooking timers, owned by a cook session and shared by both chefs and
-- the manual UI. Countdown is computed client-side from ends_at; this table is
-- the source of truth for which timers exist. Dies with the cook session.
create table if not exists cook_timers (
  id uuid primary key default gen_random_uuid(),
  cook_session_id uuid not null references cook_sessions(id) on delete cascade,
  user_id uuid not null,
  label text not null,
  duration_seconds integer not null,
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  status text not null default 'running',   -- running | cancelled
  created_by text not null default 'user',  -- user | text_chef | voice_chef
  created_at timestamptz not null default now()
);
create index if not exists cook_timers_session_idx on cook_timers(cook_session_id) where status = 'running';
