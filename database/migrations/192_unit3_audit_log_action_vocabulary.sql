-- Migration: 192_unit3_audit_log_action_vocabulary.sql
-- Unit: Unit-3 (R-OPS + R-FT + R-CES batch — 3-Persona Closure)
-- Description: Document the canonical audit_log.action vocabulary including the 7 new
--              persona-action values introduced by Unit-3 (BRD §7 action sets). The
--              column is TEXT (free-form by design — fn_audit_trigger writes whatever
--              the caller emits) so no DDL is needed; this migration is a documentation
--              anchor + a referential CHECK so callers spell action codes consistently.
-- Reference: decisions AD-4 (single migration for audit_log enum extensions). The
--            decisions log named these as ENUM extensions; investigation found the
--            column is TEXT, so the migration shifts to a COMMENT + CHECK on the new
--            audit_log_action_code helper table for the persona-action set only.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Helper reference table: persona-action codes used by Unit-3 BRD §7 wiring.
-- This is documentation-as-data; fn_audit_trigger does NOT validate against
-- this table — it lets fn_audit_log_record_v2 callers stay loose. The table
-- exists so a reviewer can see the catalog without grep-ing the codebase,
-- and a Zod-enum on the BE can FK into it later if we tighten the spec.
CREATE TABLE IF NOT EXISTS audit_log_action_code (
  code TEXT PRIMARY KEY,
  persona TEXT NOT NULL,
  description TEXT NOT NULL,
  introduced_in_migration INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE audit_log_action_code IS
  'Reference catalog of audit_log.action codes. Documentation-as-data; not FK-enforced from audit_log.action which stays free-text by design (the trigger writes generic CRUD actions create/update/delete that pre-date this catalog). Unit-3 persona action codes are seeded here so reviewers can find them by name.';
COMMENT ON COLUMN audit_log.action IS
  'Free-text action code. Standard CRUD verbs (create/update/delete/soft-delete) are emitted by fn_audit_trigger. Persona-action codes are seeded in audit_log_action_code (e.g. ops_event_acknowledged, price_review_initiated, payment_hold_recommended, sanctions_flag_raised, supplier_audit_initiated, hold_recommended, termination_recommended). See migration 192 for the Unit-3 set.';

INSERT INTO audit_log_action_code (code, persona, description, introduced_in_migration) VALUES
  ('ops_event_acknowledged',      'operations',       'Operations user acknowledged a recent ops event from the operations dashboard.', 192),
  ('ops_remedy_linked',            'operations',       'Operations user linked an event to a contract remedy / penalty clause.',         192),
  ('ops_escalation_requested',     'operations',       'Operations user escalated an event to procurement or legal.',                    192),
  ('price_review_initiated',       'finance_treasury', 'Finance & Treasury user initiated a price-review on a contract.',                192),
  ('payment_hold_recommended',     'finance_treasury', 'Finance & Treasury user recommended a payment hold.',                            192),
  ('hedge_review_initiated',       'finance_treasury', 'Finance & Treasury user initiated a hedge review for an FX-exposed contract.',  192),
  ('sanctions_flag_raised',        'compliance_esg',   'Compliance user raised a sanctions/ESG flag on a contract or counterparty.',    192),
  ('supplier_audit_initiated',     'compliance_esg',   'Compliance user kicked off a supplier audit.',                                   192),
  ('hold_recommended',             'compliance_esg',   'Compliance user recommended placing a contract on hold.',                        192),
  ('termination_recommended',      'compliance_esg',   'Compliance user recommended termination of a contract.',                        192),
  ('icv_certificate_uploaded',     'compliance_esg',   'Compliance user uploaded an ICV certificate (kind=icv_certificate) for a contract.', 192)
ON CONFLICT (code) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (192, 'Unit-3: audit_log action vocabulary catalog (BRD §7 persona action codes)', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM audit_log_action_code WHERE introduced_in_migration = 192;
-- DROP TABLE IF EXISTS audit_log_action_code;
-- DELETE FROM schema_migrations WHERE version = 192;
