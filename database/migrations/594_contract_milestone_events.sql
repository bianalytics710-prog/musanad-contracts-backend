-- Migration: 594_contract_milestone_events.sql
-- Module: Contract Spend Health — Milestone events (separate from burn)
-- Date: 2026-06-05
--
-- Milestone payments are event-based lump sums (rig acceptance, first
-- well TD, demob complete, safety bonus) — NOT time-distributed costs
-- like day rate / equipment / manpower. The original seed dropped them
-- into contract_budget / contract_cost_actual with mismatched period
-- granularity (budget quarterly @ AED 8.25M, actuals monthly @
-- AED 2.75M), which produced nonsensical % consumed numbers in the
-- per-period × category chart.
--
-- Fix:
--   1. New contract_milestone table — event-shaped: code, label,
--      planned_event_date, planned_amount_aed, actual_event_date,
--      actual_amount_aed, status. No "period_label" — it's a list of
--      one-off events.
--   2. Seed 5 realistic events for CRN-296-HERO-001 totalling the
--      same AED 41.25M planned that was previously seeded. 3 are
--      "achieved", 1 is "in_progress", 1 is "planned".
--   3. Deactivate the existing milestone-category rows in
--      contract_budget and contract_cost_actual so they vanish from the
--      period × category aggregation (fn_burn already filters on
--      is_active). The remaining categories (day_rate / equipment /
--      manpower) stay intact and coherent.
--   4. fn_contract_milestone_list(p_contract_id) returns the events for
--      the contract detail page's new Milestones tab.

BEGIN;

-- ── 1. Schema ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS contract_milestone (
  id                      BIGSERIAL PRIMARY KEY,
  tenant_id               UUID NOT NULL,
  contract_id             BIGINT NOT NULL REFERENCES contract(id),
  milestone_code          TEXT NOT NULL,
  label_en                TEXT NOT NULL,
  label_ar                TEXT,
  planned_event_date      DATE NOT NULL,
  planned_amount_aed      NUMERIC(20,2) NOT NULL CHECK (planned_amount_aed >= 0),
  actual_event_date       DATE,
  actual_amount_aed       NUMERIC(20,2)            CHECK (actual_amount_aed IS NULL OR actual_amount_aed >= 0),
  status                  TEXT NOT NULL CHECK (status IN ('planned','in_progress','achieved','missed','forfeited')),
  notes                   TEXT,
  data_classification     TEXT NOT NULL DEFAULT 'demo',
  is_active               BOOLEAN NOT NULL DEFAULT TRUE,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by              BIGINT,
  updated_by              BIGINT,
  UNIQUE (contract_id, milestone_code)
);

COMMENT ON TABLE contract_milestone IS
  'Mig 594 — event-based milestone payments for services contracts. Distinct from contract_budget which is time-distributed costs. Each row is a single contractual event (e.g. "Rig Acceptance", "First Well TD") with planned + actual amount + status. The contract detail page renders these as a Milestones tab; they do NOT participate in the per-period burn aggregation.';

CREATE INDEX IF NOT EXISTS idx_contract_milestone_contract
  ON contract_milestone (contract_id, planned_event_date)
  WHERE is_active = TRUE;

ALTER TABLE contract_milestone ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_milestone FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contract_milestone_tenant_isolation ON contract_milestone;
CREATE POLICY contract_milestone_tenant_isolation ON contract_milestone
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid);

-- ── 2. Seed CRN-296-HERO-001 ────────────────────────────────────────
-- The old seed had 5 quarterly milestone rows totalling AED 41.25M
-- (5 × 8.25M). Reshape as 5 named events with realistic drilling-
-- contract semantics. 3 achieved, 1 in progress, 1 planned. Actuals
-- so far sum to AED 27.5M (matches what the original seed had on the
-- actuals side, just routed through proper event rows).
DO $$
DECLARE
  v_tenant   UUID   := '00000000-0000-0000-0000-000000000001';
  v_actor    BIGINT := 1;
  v_contract BIGINT;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::TEXT, true);
  SELECT id INTO v_contract FROM contract WHERE contract_number = 'CRN-296-HERO-001';
  IF v_contract IS NULL THEN
    RAISE NOTICE 'CRN-296-HERO-001 not found — skipping milestone seed';
    RETURN;
  END IF;

  INSERT INTO contract_milestone (
    tenant_id, contract_id, milestone_code, label_en, label_ar,
    planned_event_date, planned_amount_aed,
    actual_event_date,  actual_amount_aed,
    status, notes, created_by, updated_by, data_classification
  ) VALUES
    (v_tenant, v_contract, 'rig_acceptance',
      'Rig acceptance & commissioning (2 rigs)',
      'قبول الجهاز والتشغيل (جهازين)',
      '2025-09-30', 8250000,
      '2025-10-12', 8250000,
      'achieved',
      'Both jack-ups accepted on AGT inspection; commissioning sign-off filed 2025-10-12.',
      v_actor, v_actor, 'demo'),

    (v_tenant, v_contract, 'first_well_td',
      'First well drilled to total depth',
      'إنجاز أول بئر إلى العمق النهائي',
      '2026-02-28', 11000000,
      '2026-03-08', 11000000,
      'achieved',
      'Reached TD 8 days late; no LD triggered (within 14-day grace).',
      v_actor, v_actor, 'demo'),

    (v_tenant, v_contract, 'safety_milestone_100k',
      'Safety milestone — 100,000 hours LTI-free',
      'علامة السلامة — ١٠٠٬٠٠٠ ساعة دون إصابات',
      '2026-04-30', 8250000,
      '2026-04-30', 8250000,
      'achieved',
      'Awarded on schedule; certificate signed by ADNOC HSE.',
      v_actor, v_actor, 'demo'),

    (v_tenant, v_contract, 'midterm_performance',
      'Mid-term performance review (12-month)',
      'مراجعة الأداء النصفية',
      '2026-08-31', 8250000,
      NULL, NULL,
      'in_progress',
      'KPI dashboards open; payout depends on average NPT < 6%.',
      v_actor, v_actor, 'demo'),

    (v_tenant, v_contract, 'demob_complete',
      'Demobilisation completed (both rigs)',
      'استكمال إخلاء الموقع',
      '2027-12-15', 5500000,
      NULL, NULL,
      'planned',
      'Demob payment held until equipment returned in agreed condition.',
      v_actor, v_actor, 'demo')
  ON CONFLICT (contract_id, milestone_code) DO NOTHING;
END $$;

-- ── 3. Deactivate the broken milestone rows in burn tables ──────────
-- The per-period × category aggregation (mig 565 onward) filters on
-- is_active = TRUE, so deactivating these rows removes them from the
-- chart cleanly. The 3 other categories (day_rate / equipment /
-- manpower) stay intact.
UPDATE contract_budget
   SET is_active = FALSE, updated_at = NOW()
 WHERE contract_id IN (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001')
   AND cost_category = 'milestone'
   AND is_active = TRUE;

UPDATE contract_cost_actual
   SET is_active = FALSE, updated_at = NOW()
 WHERE contract_id IN (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001')
   AND cost_category = 'milestone'
   AND is_active = TRUE;

-- ── 4. Reader fn ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_contract_milestone_list(p_contract_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_data   JSONB;
  v_totals JSONB;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_context_missing' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                m.id,
    'milestoneCode',     m.milestone_code,
    'labelEn',           m.label_en,
    'labelAr',           m.label_ar,
    'plannedEventDate',  m.planned_event_date,
    'plannedAmountAed',  m.planned_amount_aed::text,
    'actualEventDate',   m.actual_event_date,
    'actualAmountAed',   CASE WHEN m.actual_amount_aed IS NULL THEN NULL ELSE m.actual_amount_aed::text END,
    'status',            m.status,
    'notes',             m.notes
  ) ORDER BY m.planned_event_date), '[]'::jsonb)
  INTO v_data
  FROM contract_milestone m
  WHERE m.contract_id = p_contract_id
    AND m.tenant_id   = v_tenant
    AND m.is_active   = TRUE;

  SELECT jsonb_build_object(
    'plannedTotalAed', COALESCE(SUM(m.planned_amount_aed), 0)::numeric(20,0)::text,
    'actualTotalAed',  COALESCE(SUM(m.actual_amount_aed),  0)::numeric(20,0)::text,
    'achievedCount',   COUNT(*) FILTER (WHERE m.status = 'achieved'),
    'inProgressCount', COUNT(*) FILTER (WHERE m.status = 'in_progress'),
    'plannedCount',    COUNT(*) FILTER (WHERE m.status = 'planned'),
    'missedCount',     COUNT(*) FILTER (WHERE m.status IN ('missed','forfeited'))
  ) INTO v_totals
  FROM contract_milestone m
  WHERE m.contract_id = p_contract_id
    AND m.tenant_id   = v_tenant
    AND m.is_active   = TRUE;

  RETURN jsonb_build_object('data', v_data, 'totals', v_totals);
END $$;

REVOKE ALL ON FUNCTION fn_contract_milestone_list(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_milestone_list(BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (594, '594_contract_milestone_events', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_contract_milestone_list(BIGINT);
-- UPDATE contract_budget
--    SET is_active = TRUE
--  WHERE contract_id = (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001')
--    AND cost_category = 'milestone'
--    AND is_active = FALSE;
-- UPDATE contract_cost_actual
--    SET is_active = TRUE
--  WHERE contract_id = (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001')
--    AND cost_category = 'milestone'
--    AND is_active = FALSE;
-- DROP TABLE IF EXISTS contract_milestone;
-- DELETE FROM schema_migrations WHERE version = 594;
-- COMMIT;
