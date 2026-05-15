-- Migration: 276_unit7_in_flight_defect_placeholder_3.sql
-- Module: M19+M20 — Unit 7 in-flight defect placeholder #3
-- Date: 2026-05-15
-- Description: Third reserve slot.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (276, '276_unit7_in_flight_defect_placeholder_3', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 276;
-- ============================================================
