-- Migration: 175_crf_permissions_grants_and_bootstrap.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: (1) INSERT 3 new permission rows + 9 role_permission grants (idempotent ON CONFLICT DO NOTHING).
--   (2) One-shot DO block iterating all is_active=TRUE contracts and calling
--   fn_risk_score_compute(c.id, 'bootstrap', 0) for each.
--   Bootstrap is gated WHERE NOT EXISTS guard for idempotency.
--   S2-20: app.current_actor_id GUC set to '0' so sentinel coercion produces created_by=NULL.
--
--   DEFECT-2 fix: permission table has no 'display_name' column — INSERT uses
--   (code, module, action, description) per live schema. See db-impl-defect-report.md DEFECT-2.
--
--   Bootstrap notes:
--   - 52 active contracts on test/m0-foundation branches as of 2026-05-13
--   - Per-contract BEGIN/EXCEPTION/END isolation — one failure doesn't kill the whole job
--   - app.current_tenant_id set to the (sole) tenant via SELECT id FROM tenant LIMIT 1
--   - Score functions + scoring config rows + role_permission grants must be applied BEFORE this migration
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Part 1a: 3 net-new permission rows
-- DEFECT-2 fix: permission table schema is (code, module, action, description) — no display_name column
INSERT INTO permission (code, module, action, description)
VALUES
  ('score.read',           'score', 'read',            'Read risk_score snapshots, AVaR aggregations, history, explanations.'),
  ('score.weights.manage', 'score', 'weights.manage',  'View and edit scoring.weights + recompute-all admin actions.'),
  ('risk.acknowledge',     'risk',  'acknowledge',     'Acknowledge or accept MaR contributions on risk cases. Placeholder in CR-F; full role grants in CR-G.')
ON CONFLICT (code) DO NOTHING;

-- Part 1b: 9 role_permission grants
-- score.read — 6 grants: Super Admin, platform_admin, legal_counsel, executive, contract_drafter, contract_approver
-- score.weights.manage — 2 grants: Super Admin, platform_admin
-- risk.acknowledge — 1 grant: Super Admin only (pre-emptive; CR-G adds operations/finance_treasury/compliance_esg/legal_counsel)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM   role r
CROSS JOIN permission p
WHERE  (r.name, p.code) IN (
  -- score.read grants
  ('Super Admin',        'score.read'),
  ('platform_admin',     'score.read'),
  ('legal_counsel',      'score.read'),
  ('executive',          'score.read'),
  ('contract_drafter',   'score.read'),
  ('contract_approver',  'score.read'),

  -- score.weights.manage grants
  ('Super Admin',        'score.weights.manage'),
  ('platform_admin',     'score.weights.manage'),

  -- risk.acknowledge grant
  ('Super Admin',        'risk.acknowledge')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record Part 1 in schema_migrations (permissions seed done)
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (175, '175_crf_permissions_grants_and_bootstrap', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- Part 2: Bootstrap initial risk_score rows for every active contract
-- Runs OUTSIDE the main BEGIN/COMMIT because fn_risk_score_compute calls REFRESH MATERIALIZED VIEW
-- which cannot run inside a regular transaction block.
-- ============================================================

DO $$
DECLARE
  v_contract_id BIGINT;
  v_count       INTEGER := 0;
  v_tenant_id   TEXT;
BEGIN
  -- Verify scoring config exists before bootstrapping
  IF NOT EXISTS (SELECT 1 FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE) THEN
    RAISE NOTICE '175: scoring.weights config missing — bootstrap skipped. Apply migration 168 first.';
    RETURN;
  END IF;

  -- Verify fn_risk_score_compute exists before bootstrapping
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_risk_score_compute') THEN
    RAISE NOTICE '175: fn_risk_score_compute not found — bootstrap skipped. Apply migration 171 first.';
    RETURN;
  END IF;

  -- Verify latest_risk_score MV exists before bootstrapping
  IF NOT EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'latest_risk_score') THEN
    RAISE NOTICE '175: latest_risk_score MV not found — bootstrap skipped. Apply migration 170 first.';
    RETURN;
  END IF;

  -- Set system-actor sentinel GUC for the bootstrap pass (S2-20: actor=0 → created_by=NULL)
  PERFORM set_config('app.current_actor_id', '0', true);

  -- Set tenant GUC to the (sole) tenant — ADNOC v1 sole-tenant assumption
  -- For pilot multi-tenant: rewrite to iterate per tenant + set GUC per pass
  SELECT id::text INTO v_tenant_id FROM tenant LIMIT 1;
  IF v_tenant_id IS NULL THEN
    RAISE NOTICE '175: no tenant found — bootstrap skipped.';
    RETURN;
  END IF;
  PERFORM set_config('app.current_tenant_id', v_tenant_id, true);

  -- Note: contract table has no tenant_id column (M0 design — tenant resolved from GUC).
  -- NOT EXISTS guard uses contract_id only; tenant_id on risk_score populated from GUC.
  FOR v_contract_id IN
    SELECT c.id
    FROM   contract c
    WHERE  c.is_active = TRUE
      AND  NOT EXISTS (
        SELECT 1 FROM risk_score rs
        WHERE  rs.contract_id = c.id
      )
    ORDER BY c.id
  LOOP
    BEGIN
      -- Per-contract isolation: one failure doesn't abort the whole bootstrap (AC-S16-01)
      PERFORM fn_risk_score_compute(v_contract_id, 'bootstrap', 0);
      v_count := v_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE '175: bootstrap skipped for contract %: %', v_contract_id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE '175: bootstrap complete — % contracts scored', v_count;
END $$;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 175;
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('score.read','score.weights.manage','risk.acknowledge'));
-- DELETE FROM permission WHERE code IN ('score.read','score.weights.manage','risk.acknowledge');
-- COMMIT;
-- DELETE FROM risk_score WHERE triggered_by = 'bootstrap';  -- (no tenant_id filter needed — contract table has no tenant_id col)
-- REFRESH MATERIALIZED VIEW latest_risk_score;
-- ============================================================
