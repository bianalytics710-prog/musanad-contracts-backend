-- Migration: 399_layla_hero_budget_cure_full_bind.sql
-- Unit: Layla Counsel QA Phase 3.7 follow-up — L23 finish (HERO-001 cure notice)
--
-- Bind the remaining Mustache parameters (breach_period / cost_category /
-- budgeted_amount_aed / actual_amount_aed / overrun_pct / ld_clause_ref) on
-- the HERO-001 budget_cure_notice draft so the body renders without any
-- unfilled placeholders. Re-render generated_text_en/ar using the existing
-- fn_mustache_render helper.

DO $$
DECLARE
  v_draft RECORD;
  v_ctx JSONB;
  v_tpl_en TEXT;
  v_tpl_ar TEXT;
BEGIN
  SELECT d.id, d.template_context, t.body_template_en, t.body_template_ar
    INTO v_draft
    FROM advisory_draft d
    JOIN advisory_template t ON t.id = d.template_id
   WHERE d.contract_id = 52 AND d.draft_type = 'cure_notice'
     AND t.template_id = 'budget_cure_notice_v1'
   ORDER BY d.id DESC LIMIT 1;

  IF v_draft.id IS NULL THEN
    RAISE NOTICE 'Mig 399: HERO-001 budget_cure_notice draft not present — skipping';
    RETURN;
  END IF;

  v_ctx := COALESCE(v_draft.template_context, '{}'::jsonb)
        || jsonb_build_object(
             'breach_period',        '2026-07',
             'cost_category',        'jack-up day-rate billing',
             'budgeted_amount_aed',  '845,000,000',
             'actual_amount_aed',    '955,000,000',
             'overrun_pct',          '13',
             'ld_clause_ref',
               'Section 23.4 — Liquidated Damages: AED 730,000 per rig per day; aggregate cap AED 63.3M per contract year'
           );

  UPDATE advisory_draft
     SET template_context = v_ctx,
         generated_text_en = fn_mustache_render(v_draft.body_template_en, v_ctx),
         generated_text_ar = fn_mustache_render(v_draft.body_template_ar, v_ctx),
         updated_at = NOW()
   WHERE id = v_draft.id;
END $$;
