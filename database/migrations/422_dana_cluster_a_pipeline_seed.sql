-- Migration: 422_dana_cluster_a_pipeline_seed.sql
-- Unit: Dana Drafter PM-grade audit fix pass (2026-06-01) — Cluster A seeding
-- Defects addressed:
--   D1 — Drafter dashboard pipeline strip 0/0/0/0/0 (Dana has 119 contracts
--        but all in active/expired/fully_signed/in_approval/terminated states;
--        nothing in 'draft' or 'resubmission_requested' → KPIs are all 0).
--   D4 — Date filter no-op (myRecentlyApprovedCount enum-mismatch was filtering
--        on a state that does not exist in the contract.status enum).
-- Approach:
--   1. Re-assign 10 of Dana's 72 active contracts to in-flight states by
--      deterministic ROW_NUMBER slice so KPI buckets populate without
--      polluting other personas.
--   2. Patch fn_dashboard_drafter so readyToSendCount and myRecentlyApprovedCount
--      reference enum values that actually exist in the contract.status enum.
-- Test-branch-safe: every DO $$ block is guarded by a persona-presence check
-- (`IF EXISTS (... WHERE email='drafter@musanad.local')`). On the test branch
-- the seed contracts may have different counts; we slice by the available pool
-- so the migration never fails on a branch with a smaller dataset.
-- Rollback: see ROLLBACK section at bottom.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Seed Dana's in-flight pipeline by re-assigning slices of her own
--    active contracts to draft / resubmission_requested / in_approval /
--    awaiting_signature_counterparty.
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_dana_id BIGINT;
  v_pool_count INTEGER;
BEGIN
  SELECT id INTO v_dana_id FROM "user" WHERE email='drafter@musanad.local';
  IF v_dana_id IS NULL THEN
    RAISE NOTICE '422: drafter@musanad.local not present — skipping seed (test branch ok).';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_pool_count
  FROM contract WHERE drafted_by = v_dana_id AND status = 'active' AND is_active = TRUE;

  IF v_pool_count < 10 THEN
    RAISE NOTICE '422: Dana pool size % < 10 — skipping seed (test branch ok).', v_pool_count;
    RETURN;
  END IF;

  -- Idempotency: if Dana already has 4+ drafts, assume the seed has run.
  IF (SELECT COUNT(*) FROM contract WHERE drafted_by = v_dana_id AND status = 'draft' AND is_active = TRUE) >= 4 THEN
    RAISE NOTICE '422: Dana already has drafts — skipping seed.';
    RETURN;
  END IF;

  -- Reassign 10 specific contracts (ranked by lowest value_aed, ascending) to
  -- in-flight states. Picking the smallest-value active contracts means we
  -- keep the high-value HERO contracts on Active for demo storytelling.
  WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY COALESCE(value_aed, 0) ASC, id ASC) AS rn
    FROM contract
    WHERE drafted_by = v_dana_id AND status = 'active' AND is_active = TRUE
  )
  UPDATE contract c
     SET status = CASE
                    WHEN r.rn BETWEEN 1  AND 4  THEN 'draft'
                    WHEN r.rn BETWEEN 5  AND 5  THEN 'resubmission_requested'
                    WHEN r.rn BETWEEN 6  AND 7  THEN 'in_approval'
                    WHEN r.rn BETWEEN 8  AND 10 THEN 'awaiting_signature_counterparty'
                    ELSE c.status
                  END,
         -- updated_at staggered so "Last updated" + Recently approved windows
         -- spread across the last 7 days.
         updated_at = NOW() - ((r.rn * 14) || ' hours')::INTERVAL,
         updated_by = v_dana_id
    FROM ranked r
   WHERE c.id = r.id AND r.rn <= 10;

  RAISE NOTICE '422: re-assigned 10 of Dana''s contracts into draft/in_approval/resubmission_requested/awaiting_signature_counterparty.';
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Patch fn_dashboard_drafter so readyToSendCount + myRecentlyApprovedCount
--    reference enum values that actually appear in contract.status.
--    Original (mig 056 + 244) used 'approved' which is not a valid enum.
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_dashboard_drafter(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_drafter', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: forbidden — drafter dashboard restricted to contract_drafter, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myDraftsCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE),
    -- D1 fix: separate "awaiting MY action" from "all draft-like states" —
    -- only resubmission_requested means the drafter is the actor.
    'awaitingMyActionCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status = 'resubmission_requested'
          AND is_active = TRUE),
    -- D4 fix: 'approved' is not a valid contract.status enum value, so the
    -- count was always 0. Map to the real "awaiting signature" states which
    -- accurately reflect "approved internally + queued to dispatch."
    'readyToSendCount',
      (SELECT COUNT(*) FROM contract c
        WHERE c.drafted_by = v_user_id
          AND c.status IN ('awaiting_signature_employer','awaiting_signature_counterparty')
          AND c.is_active = TRUE),
    -- D4 fix: 'approved' is not valid; the drafter-relevant "recently approved"
    -- meaning is "moved to fully_signed within window". Active is the
    -- downstream state after dispatch, also counted within window.
    'myRecentlyApprovedCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('fully_signed','active')
          AND updated_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'myDrafts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'valueAed', c.value_aed,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb),
    'awaitingMyAction5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','resubmission_requested')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_drafter(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_drafter(integer) TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_drafter(integer) IS
  'D1+D4: pipeline KPI fn for contract_drafter / platform_admin / Super Admin. readyToSendCount + myRecentlyApprovedCount use real enum values (mig 422 fixes mig 244 enum drift). awaitingMyActionCount restricted to resubmission_requested for true drafter-actor scope.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (422, 'D1+D4 Dana drafter pipeline seed + fn_dashboard_drafter enum fix', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   -- Restore fn_dashboard_drafter from mig 244 body (re-run that file).
--   -- Note: seeded status changes (10 contracts) are intentionally NOT
--   -- rolled back here because the values are now demo-significant for
--   -- the drafter dashboard story. To revert: set status='active' on
--   -- all rows updated by mig 422 via a manual SELECT/UPDATE.
--   DELETE FROM schema_migrations WHERE version = 422;
-- COMMIT;
-- ROLLBACK END
