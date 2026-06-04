-- MIGRATION: 531_correlation_rule_id_remap_and_chain_cleanup.sql
-- Date: 2026-06-03
-- Description:
--   Two cleanups surfaced when the Risk-tab What-If panel started showing
--   ruleName entries like "2", "2", "5":
--
--   1. Some legacy seed correlations were inserted with the rule's integer
--      primary key in the rule_id column (e.g. rule_id='2') instead of the
--      correlation_rule.rule_id text key ('rule.hormuz.supply_disruption').
--      Risk explain joins correlation_rule on rule_id text, so the join
--      fails and FE falls back to the raw rule_id ("2"). Remap them.
--
--   2. Existing in-flight approval_chain rows generated against the OLD
--      matrix still carry platform_admin pending steps. mig 527 cleaned
--      the matrix; this finishes the cleanup by marking those leftover
--      pending steps as skipped so the chain advances naturally.
--
--   3. Bulk-recompute affected contracts so risk scores reflect the now-
--      named rules + cleaner UI.

BEGIN;

-- ============================================================
-- 1. Remap correlation.rule_id from integer-PK form to text rule_id form.
--    Match by rule_id::text = correlation_rule.id::text (i.e. the legacy
--    seed stuffed the integer PK into the text column).
-- ============================================================
WITH remap AS (
  SELECT c.id AS correlation_id, cr.rule_id AS correct_rule_id
    FROM correlation c
    JOIN correlation_rule cr ON cr.id::text = c.rule_id
   WHERE c.rule_id ~ '^[0-9]+$'
     AND c.is_active = TRUE
)
UPDATE correlation c
   SET rule_id   = r.correct_rule_id,
       updated_at = CURRENT_TIMESTAMP
  FROM remap r
 WHERE c.id = r.correlation_id;

-- ============================================================
-- 2. Skip existing pending platform_admin approval_step rows.
-- ============================================================
UPDATE approval_step
   SET status     = 'skipped',
       decided_at = CURRENT_TIMESTAMP,
       updated_at = CURRENT_TIMESTAMP
 WHERE approver_role = 'platform_admin'
   AND status        = 'pending'
   AND is_active     = TRUE;

-- Also clear platform_admin from escalation_role on any in-flight steps so
-- the FE never renders "escalates to Platform Admin after Xh" on a step
-- that came from the old matrix snapshot.
UPDATE approval_step
   SET escalation_role        = NULL,
       escalation_after_hours = NULL,
       updated_at             = CURRENT_TIMESTAMP
 WHERE escalation_role = 'platform_admin'
   AND is_active       = TRUE;

-- ============================================================
-- 3. Bulk recompute affected contracts so the rename propagates to the
--    next fn_risk_score_explain call.
-- ============================================================
DO $$
DECLARE
  v_cid BIGINT;
BEGIN
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false);
  FOR v_cid IN
    SELECT DISTINCT contract_id
      FROM correlation
     WHERE status = 'active'
       AND is_active = TRUE
  LOOP
    BEGIN
      PERFORM fn_risk_score_compute(v_cid, 'config_change', 1);
    EXCEPTION WHEN OTHERS THEN
      -- swallow per-contract errors; one bad row shouldn't abort
    END;
  END LOOP;
  REFRESH MATERIALIZED VIEW latest_risk_score;
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (531, 'correlation_rule_id_remap_and_chain_cleanup', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
