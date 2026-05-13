-- Migration: 179_crg_extend_ai_request_log.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: ALTER TABLE ai_request_log ADD COLUMN scope_hash TEXT + acl_filtered_count INTEGER
--              Both nullable, backward-compatible (fn_ai_request_log_create M4 unaffected)
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

ALTER TABLE ai_request_log
  ADD COLUMN IF NOT EXISTS scope_hash         TEXT    NULL,
  ADD COLUMN IF NOT EXISTS acl_filtered_count INTEGER NULL;

COMMENT ON COLUMN ai_request_log.scope_hash
  IS 'CR-G AI Risk Assistant: SHA-256 hash of caller scope (sorted contract_id list) used as ai_insight entity_id derivation input. NULL for non-risk-assistant rows.';

COMMENT ON COLUMN ai_request_log.acl_filtered_count
  IS 'CR-G AI Risk Assistant: count of contract candidates excluded from LLM prompt context due to caller ACL (caller could not read them). 0 = no contracts filtered. NULL for non-risk-assistant rows. Audit-only — never user-visible.';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (179, '179_crg_extend_ai_request_log', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 179;
-- ALTER TABLE ai_request_log
--   DROP COLUMN IF EXISTS acl_filtered_count,
--   DROP COLUMN IF EXISTS scope_hash;
-- ============================================================
