-- ============================================================
-- Migration 127 — CRC data_classification_rollout
-- ============================================================
-- Module:      M10 — CR-C
-- Description: Single-TX rollout of `data_classification TEXT NOT NULL DEFAULT 'demo'
--              CHECK (data_classification IN ('demo','pilot','production'))` across
--              34 content tables (per OPEN-DECISION-C tier list in db-design.md §1.4).
--
-- Tier 1 (Contracts/Parties M1a..M_parity, 12)  : contract, contract_attachment, contract_clause, contract_obligation,
--                                                  contract_template, contract_comment, contract_watch, contract_activity,
--                                                  contract_tag, contract_version, party, payment_schedule
-- Tier 2 (Signature M3, 6)                       : signature_party, signature_party_side, signature_event,
--                                                  signature_invitation, signature_method, signer_qa_session
-- Tier 3 (Approvals M2, 4)                       : approval_chain, approval_step, approval_decision, approval_matrix
-- Tier 4 (Regulatory M5, 5)                      : regulation, regulator, regulatory_update, regulatory_impact, impact_category
-- Tier 5 (Impact Signals R-LC9, 1)               : impact_signal_contract  (impact_signal is a VIEW — SKIPPED)
-- Tier 6 (AI M4, 3)                              : ai_insight, ai_prompt, ai_request_log
-- Tier 7 (Imports M1c, 1)                        : import_batch
-- Tier 8 (CRIP M7..M9, 6)                        : osint_source, osint_signal, source_credential, source_health,
--                                                  internal_signal_kind, party_relationship
-- Tier 9 (CR-C own, 1 already-at-create)         : notification_template (column added at CREATE in 125 — included
--                                                  defensively here via IF NOT EXISTS so re-applies are no-ops)
--
-- Excluded (per AC-S5-03): user, role, permission, role_permission, audit_log, schema_migrations,
--                          token_blacklist, tenant, system_setting.
-- Idempotent:  ADD COLUMN IF NOT EXISTS — safe to re-run.
-- ============================================================

BEGIN;

-- Tier 1 — Contracts/Parties (12)
ALTER TABLE contract             ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract.data_classification IS 'CR-C: demo / pilot / production. Existing rows default to demo. Demo rows purged by fn_demo_data_purge.';
ALTER TABLE contract_attachment  ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_attachment.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_clause      ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_clause.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_obligation  ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_obligation.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_template    ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_template.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_comment     ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_comment.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_watch       ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_watch.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_activity    ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_activity.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_tag         ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_tag.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE contract_version     ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN contract_version.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE party                ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN party.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE payment_schedule     ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN payment_schedule.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 2 — Signature M3 (6)
ALTER TABLE signature_party       ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN signature_party.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE signature_party_side  ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN signature_party_side.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE signature_event       ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN signature_event.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE signature_invitation  ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN signature_invitation.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE signature_method      ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN signature_method.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE signer_qa_session     ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN signer_qa_session.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 3 — Approvals M2 (4)
ALTER TABLE approval_chain    ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN approval_chain.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE approval_step     ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN approval_step.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE approval_decision ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN approval_decision.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE approval_matrix   ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN approval_matrix.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 4 — Regulatory M5 (5)
ALTER TABLE regulation        ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN regulation.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE regulator         ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN regulator.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE regulatory_update ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN regulatory_update.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE regulatory_impact ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN regulatory_impact.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE impact_category   ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN impact_category.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 5 — Impact Signals R-LC9 (1; impact_signal is a VIEW, skipped)
ALTER TABLE impact_signal_contract ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN impact_signal_contract.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 6 — AI M4 (3)
ALTER TABLE ai_insight        ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN ai_insight.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE ai_prompt         ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN ai_prompt.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE ai_request_log    ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN ai_request_log.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 7 — Imports M1c (1)
ALTER TABLE import_batch      ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN import_batch.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 8 — CRIP M7..M9 (6)
ALTER TABLE osint_source         ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN osint_source.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE osint_signal         ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN osint_signal.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE source_credential    ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN source_credential.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE source_health        ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN source_health.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE internal_signal_kind ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN internal_signal_kind.data_classification IS 'CR-C: demo / pilot / production.';
ALTER TABLE party_relationship   ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN party_relationship.data_classification IS 'CR-C: demo / pilot / production.';

-- Tier 9 — defensive (notification_template column was added at CREATE-time in 125)
ALTER TABLE notification_template ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'));

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (127, 'crc_data_classification_rollout', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- ALTER TABLE party_relationship    DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE internal_signal_kind  DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE source_health         DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE source_credential     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE osint_signal          DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE osint_source          DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE import_batch          DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE ai_request_log        DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE ai_prompt             DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE ai_insight            DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE impact_signal_contract DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE impact_category       DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE regulatory_impact     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE regulatory_update     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE regulator             DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE regulation            DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE approval_matrix       DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE approval_decision     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE approval_step         DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE approval_chain        DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE signer_qa_session     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE signature_method      DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE signature_invitation  DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE signature_event       DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE signature_party_side  DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE signature_party       DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE payment_schedule      DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE party                 DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_version      DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_tag          DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_activity     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_watch        DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_comment      DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_template     DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_obligation   DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_clause       DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract_attachment   DROP COLUMN IF EXISTS data_classification;
-- ALTER TABLE contract              DROP COLUMN IF EXISTS data_classification;
-- DELETE FROM schema_migrations WHERE version = 127;
-- COMMIT;
-- ROLLBACK END
