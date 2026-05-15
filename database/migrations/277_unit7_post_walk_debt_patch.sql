-- Migration: 277_unit7_post_walk_debt_patch.sql
-- Module: M19+M20 — Unit 7 post-walk debt patch
-- Date: 2026-05-15
-- Description: Reserved for QA Stage 4 / post-MCP-walk patches (mirrors mig 223
--              DEBT-CRH-1/2 pattern). Do NOT use unless prompted by post-impl agent.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (277, '277_unit7_post_walk_debt_patch', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 277;
-- ============================================================
