-- Migration: 347_seed_procurement_persona.sql
-- Unit: QA Phase 3 Pre-QA Gate (autonomous run 2026-05-30)
-- Description: Seed demo persona user for the procurement_supplier_risk role.
--              Migration 292 (CR-M) created the role row but no user row. Without this,
--              the QA Phase 3 Part J walk + ADNOC demo procurement view cannot be done
--              under the native role; Bootstrap Admin would have to proxy.
--              Password hash = bcrypt('ChangeMe@123', 12) — same as all other demo personas.
--              Reference: QA_Execution_Script_v1.md v1.1 Pre-QA Gate item 1.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
SELECT  'procurement@musanad.local',
        '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
        'Pari', 'Procurement',
        r.id, TRUE, 1, 1
  FROM role r WHERE r.name = 'procurement_supplier_risk'
ON CONFLICT (email) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (347, 'Seed procurement_supplier_risk demo persona for QA Phase 3 Part J walk', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM "user" WHERE email = 'procurement@musanad.local';
-- DELETE FROM schema_migrations WHERE version = 347;
