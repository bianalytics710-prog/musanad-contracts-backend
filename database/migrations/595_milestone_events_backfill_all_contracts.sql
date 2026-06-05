-- Migration: 595_milestone_events_backfill_all_contracts.sql
-- Module: Contract Spend Health — backfill milestone events for the other 12 contracts
-- Date: 2026-06-05
--
-- Mig 594 only fixed CRN-296-HERO-001 — the other 12 contracts with a
-- milestone cost-category still have the broken monthly-actual vs
-- quarterly-budget mismatch and still show extreme % readings on the
-- Period × Category chart (e.g. CRQ-OFF-001 shows AED 144.35M actuals
-- against AED 40M budget = 360% — also wrong, just less extreme).
--
-- Fix uniformly:
--   1. Deactivate every remaining milestone-category row in
--      contract_budget + contract_cost_actual across the tenant.
--   2. Seed 4 generic-but-realistic milestone events per contract in
--      contract_milestone:
--         A. Mobilisation                      — 10% of original budget
--         B. Mid-term performance review       — 30%
--         C. HSE / Safety milestone            — 20%
--         D. Demobilisation / closeout         — 40%
--      Dates spaced across the contract's start_date..end_date. Status
--      derived from where each milestone date sits relative to today's
--      demo clock (2026-06): past → achieved, current quarter →
--      in_progress, future → planned.
--
-- After this migration, every contract that previously had milestone
-- data presents a coherent Milestones tab and a clean Period × Category
-- chart (only day_rate + manpower + equipment bars).

BEGIN;

DO $$
DECLARE
  v_tenant   UUID   := '00000000-0000-0000-0000-000000000001';
  v_actor    BIGINT := 1;
  v_now      DATE   := DATE '2026-06-15';  -- demo "today" anchor
  rec        RECORD;
  v_total    NUMERIC;
  v_dur_days INT;
  v_mob_date DATE;
  v_mid_date DATE;
  v_hse_date DATE;
  v_dem_date DATE;
  v_mob_amt  NUMERIC;
  v_mid_amt  NUMERIC;
  v_hse_amt  NUMERIC;
  v_dem_amt  NUMERIC;
  v_status   TEXT;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);

  FOR rec IN
    SELECT c.id, c.contract_number, c.title_en, c.start_date, c.end_date,
           SUM(b.allocated_amount_aed) AS milestone_budget
    FROM contract c
    JOIN contract_budget b ON b.contract_id = c.id AND b.is_active = TRUE AND b.tenant_id = v_tenant
    WHERE c.is_active = TRUE
      AND b.cost_category = 'milestone'
      -- Skip CRN-296-HERO-001 (already done in mig 594)
      AND c.contract_number <> 'CRN-296-HERO-001'
    GROUP BY c.id, c.contract_number, c.title_en, c.start_date, c.end_date
  LOOP
    v_total := rec.milestone_budget;
    v_mob_amt := ROUND(v_total * 0.10, 0);
    v_mid_amt := ROUND(v_total * 0.30, 0);
    v_hse_amt := ROUND(v_total * 0.20, 0);
    v_dem_amt := v_total - v_mob_amt - v_mid_amt - v_hse_amt;  -- 40%, exact remainder

    v_dur_days := (rec.end_date - rec.start_date);
    -- Mobilisation at ~5% of duration in
    v_mob_date := rec.start_date + (v_dur_days * 0.05)::int;
    -- Mid-term at ~50%
    v_mid_date := rec.start_date + (v_dur_days * 0.50)::int;
    -- HSE milestone at ~65%
    v_hse_date := rec.start_date + (v_dur_days * 0.65)::int;
    -- Demobilisation at ~95%
    v_dem_date := rec.start_date + (v_dur_days * 0.95)::int;

    -- ── 1. Mobilisation
    v_status := CASE
      WHEN v_mob_date <  v_now - INTERVAL '30 days' THEN 'achieved'
      WHEN v_mob_date <= v_now + INTERVAL '90 days' THEN 'in_progress'
      ELSE 'planned'
    END;
    INSERT INTO contract_milestone (
      tenant_id, contract_id, milestone_code, label_en, label_ar,
      planned_event_date, planned_amount_aed,
      actual_event_date,  actual_amount_aed,
      status, notes, created_by, updated_by, data_classification
    ) VALUES (
      v_tenant, rec.id, 'mobilisation',
      'Mobilisation & contract commencement',
      'التعبئة وبدء العقد',
      v_mob_date, v_mob_amt,
      CASE WHEN v_status = 'achieved' THEN v_mob_date + (random() * 14)::int ELSE NULL END,
      CASE WHEN v_status = 'achieved' THEN v_mob_amt ELSE NULL END,
      v_status,
      'Counterparty mobilised crew + equipment per Schedule A.',
      v_actor, v_actor, 'demo'
    ) ON CONFLICT (contract_id, milestone_code) DO NOTHING;

    -- ── 2. Mid-term performance review
    v_status := CASE
      WHEN v_mid_date <  v_now - INTERVAL '30 days' THEN 'achieved'
      WHEN v_mid_date <= v_now + INTERVAL '90 days' THEN 'in_progress'
      ELSE 'planned'
    END;
    INSERT INTO contract_milestone (
      tenant_id, contract_id, milestone_code, label_en, label_ar,
      planned_event_date, planned_amount_aed,
      actual_event_date,  actual_amount_aed,
      status, notes, created_by, updated_by, data_classification
    ) VALUES (
      v_tenant, rec.id, 'midterm_performance',
      'Mid-term performance review',
      'مراجعة الأداء النصفية',
      v_mid_date, v_mid_amt,
      CASE WHEN v_status = 'achieved' THEN v_mid_date + (random() * 21)::int ELSE NULL END,
      CASE WHEN v_status = 'achieved' THEN v_mid_amt ELSE NULL END,
      v_status,
      'KPI review against agreed performance targets; payout subject to acceptance.',
      v_actor, v_actor, 'demo'
    ) ON CONFLICT (contract_id, milestone_code) DO NOTHING;

    -- ── 3. HSE / Safety milestone
    v_status := CASE
      WHEN v_hse_date <  v_now - INTERVAL '30 days' THEN 'achieved'
      WHEN v_hse_date <= v_now + INTERVAL '90 days' THEN 'in_progress'
      ELSE 'planned'
    END;
    INSERT INTO contract_milestone (
      tenant_id, contract_id, milestone_code, label_en, label_ar,
      planned_event_date, planned_amount_aed,
      actual_event_date,  actual_amount_aed,
      status, notes, created_by, updated_by, data_classification
    ) VALUES (
      v_tenant, rec.id, 'hse_milestone',
      'HSE milestone — incident-free target',
      'هدف السلامة — صفر حوادث',
      v_hse_date, v_hse_amt,
      CASE WHEN v_status = 'achieved' THEN v_hse_date + (random() * 7)::int ELSE NULL END,
      CASE WHEN v_status = 'achieved' THEN v_hse_amt ELSE NULL END,
      v_status,
      'Awarded on independent HSE audit; verified by ADNOC compliance.',
      v_actor, v_actor, 'demo'
    ) ON CONFLICT (contract_id, milestone_code) DO NOTHING;

    -- ── 4. Demobilisation / closeout
    v_status := CASE
      WHEN v_dem_date <  v_now - INTERVAL '30 days' THEN 'achieved'
      WHEN v_dem_date <= v_now + INTERVAL '90 days' THEN 'in_progress'
      ELSE 'planned'
    END;
    INSERT INTO contract_milestone (
      tenant_id, contract_id, milestone_code, label_en, label_ar,
      planned_event_date, planned_amount_aed,
      actual_event_date,  actual_amount_aed,
      status, notes, created_by, updated_by, data_classification
    ) VALUES (
      v_tenant, rec.id, 'demob_closeout',
      'Demobilisation & contract closeout',
      'إخلاء الموقع وإغلاق العقد',
      v_dem_date, v_dem_amt,
      CASE WHEN v_status = 'achieved' THEN v_dem_date + (random() * 21)::int ELSE NULL END,
      CASE WHEN v_status = 'achieved' THEN v_dem_amt ELSE NULL END,
      v_status,
      'Final payment subject to equipment return + outstanding-warranty waiver.',
      v_actor, v_actor, 'demo'
    ) ON CONFLICT (contract_id, milestone_code) DO NOTHING;
  END LOOP;
END $$;

-- ── 2. Tenant-wide deactivation of legacy milestone burn rows ─────
-- Now that proper milestone events exist for every contract that had
-- milestone data, deactivate every milestone-category row in the burn
-- tables so they disappear from per-period × category aggregation
-- across the whole portfolio.
UPDATE contract_budget
   SET is_active = FALSE, updated_at = NOW()
 WHERE cost_category = 'milestone'
   AND is_active = TRUE
   AND tenant_id = '00000000-0000-0000-0000-000000000001';

UPDATE contract_cost_actual
   SET is_active = FALSE, updated_at = NOW()
 WHERE cost_category = 'milestone'
   AND is_active = TRUE
   AND tenant_id = '00000000-0000-0000-0000-000000000001';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (595, '595_milestone_events_backfill_all_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM contract_milestone
--  WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--    AND milestone_code IN ('mobilisation','midterm_performance','hse_milestone','demob_closeout');
-- UPDATE contract_budget
--    SET is_active = TRUE
--  WHERE cost_category = 'milestone'
--    AND tenant_id = '00000000-0000-0000-0000-000000000001';
-- UPDATE contract_cost_actual
--    SET is_active = TRUE
--  WHERE cost_category = 'milestone'
--    AND tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM schema_migrations WHERE version = 595;
-- COMMIT;
