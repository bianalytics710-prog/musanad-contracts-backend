-- Migration: 191_unit3_seed_persona_users_ops_ft_ces.sql
-- Unit: Unit-3 (R-OPS + R-FT + R-CES batch — 3-Persona Closure)
-- Description: Seed demo persona users for the 3 net-new roles introduced in M15/CR-G.
--              Migration 181 created the role rows but no user rows. Without these the
--              login page persona tiles + /change-request audit walks can't sign in.
--              Password hash = bcrypt('ChangeMe@123', 12) — same as Drafter/Approver/etc.
--              Reference: GAP-REPORT-OPERATIONS.md C1, GAP-REPORT-FINANCE-TREASURY.md C1,
--              GAP-REPORT-COMPLIANCE-ESG.md C1.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
SELECT  'operations@musanad.local',
        '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
        'Omar', 'Operations',
        r.id, TRUE, 1, 1
  FROM role r WHERE r.name = 'operations'
ON CONFLICT (email) DO NOTHING;

INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
SELECT  'finance@musanad.local',
        '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
        'Fatima', 'Finance',
        r.id, TRUE, 1, 1
  FROM role r WHERE r.name = 'finance_treasury'
ON CONFLICT (email) DO NOTHING;

INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, is_active, created_by, updated_by)
SELECT  'compliance@musanad.local',
        '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
        'Khalid', 'Compliance',
        r.id, TRUE, 1, 1
  FROM role r WHERE r.name = 'compliance_esg'
ON CONFLICT (email) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (191, 'Unit-3: seed 3 persona users (operations, finance, compliance) for R-OPS+R-FT+R-CES audit + demo', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM "user" WHERE email IN ('operations@musanad.local','finance@musanad.local','compliance@musanad.local');
-- DELETE FROM schema_migrations WHERE version = 191;
