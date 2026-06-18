-- ============================================================================
-- Migration 701 — Backfill contract_activity.actor_id to real personas
-- ============================================================================
-- The contract "Activity" tab should attribute each event to a real persona,
-- not "System" (actor NULL), "System Admin" (admin@musanad.local), "Platform
-- Admin" (platform@musanad.local), or "Smoke Test". Those are seed/loader
-- accounts that ran the demo data import; they are not who really "did" the
-- contract work.
--
-- Fix: for activity rows currently attributed to one of those sentinel
-- accounts (or to nobody), re-derive the actor from the contract's own people
-- by event family:
--   * approval actions          → approved_by → reviewed_by → drafted_by → created_by
--   * status / submit / sign     → reviewed_by → approved_by → drafted_by → created_by
--   * everything else (drafting) → drafted_by → created_by → reviewed_by
--
-- Safety guard: we ONLY write a genuine persona. If the derived actor is null
-- or itself a sentinel account, the row is left exactly as-is (we never make
-- attribution worse). AI housekeeping events are skipped (they are hidden by
-- migration 700 anyway).
--
-- Note: this overwrites the prior (null/sentinel) actor_id — the original
-- carried no real signal, and audit_log retains the raw row-level trail. Not
-- cleanly reversible; rollback is a no-op.
-- ============================================================================

BEGIN;

WITH sentinel AS (
  SELECT id
    FROM "user"
   WHERE email IN ('admin@musanad.local', 'platform@musanad.local')
      OR (first_name = 'Smoke' AND last_name = 'Test')
),
reattr AS (
  SELECT ca.id AS activity_id,
         CASE
           WHEN ca.activity_type IN (
                  'approval_decided', 'approval_escalated',
                  'approval_reassigned', 'approval_delegated')
             THEN COALESCE(c.approved_by, c.reviewed_by, c.drafted_by, c.created_by)
           WHEN ca.activity_type IN (
                  'status_changed', 'submitted_for_approval', 'fully_executed',
                  'sent_for_signature', 'signer_signed', 'signer_viewed',
                  'signer_declined', 'signature_invalidated')
             THEN COALESCE(c.reviewed_by, c.approved_by, c.drafted_by, c.created_by)
           ELSE COALESCE(c.drafted_by, c.created_by, c.reviewed_by)
         END AS derived_actor
    FROM contract_activity ca
    JOIN contract c ON c.id = ca.contract_id
   WHERE ca.is_active = TRUE
     AND ca.activity_type NOT IN (
           'ai_summary_generated', 'ai_risk_score_updated', 'ai_diff_summary_generated')
     AND (ca.actor_id IS NULL OR ca.actor_id IN (SELECT id FROM sentinel))
)
UPDATE contract_activity ca
   SET actor_id = r.derived_actor
  FROM reattr r
 WHERE ca.id = r.activity_id
   AND r.derived_actor IS NOT NULL
   AND r.derived_actor NOT IN (SELECT id FROM "user"
                                WHERE email IN ('admin@musanad.local', 'platform@musanad.local')
                                   OR (first_name = 'Smoke' AND last_name = 'Test'));

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (701, 'backfill_activity_actor_personas', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Not reversible — prior actor_id values (null / sentinel) are not retained.
-- DELETE FROM schema_migrations WHERE version = 701;
-- ROLLBACK END
