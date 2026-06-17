-- 007_unified_chat_kind.sql
-- The text chef and the voice chef now SHARE one chat_session per cook session
-- (so switching modes carries the full conversation context). They converge on
-- a single kind = 'chef'. Older rows may still be 'text_chef'/'voice_chef';
-- both chefs look up by cook_session_id regardless of kind.
ALTER TYPE chat_kind ADD VALUE IF NOT EXISTS 'chef';
