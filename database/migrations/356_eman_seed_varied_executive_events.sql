-- Migration: 356_eman_seed_varied_executive_events.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fixes:
--   E12 — Executive events feed shows 8 identical "AI risk score updated"
--         entries. Seed varied contract_activity rows + regulatory_update
--         rows within the last 14 days so the feed narrates the business:
--         contract executions, regulatory impacts, approval decisions,
--         signing milestones — not just "risk score updated" repeated.
--   E17 — Most-amended contracts shows v1 · 0 amendments everywhere.
--         Bump current_version on a curated set of contracts (HERO-001 + 9
--         others) so the "Most amended" section reads credibly.
--   E18 — Most-used templates: tiny counts. The dashboard reads
--         contract.template_id created in last 90 days; backfill template_id
--         on 60+ contracts created within the last 90 days so usage counts
--         feel real for the platform's scale.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ── E12 — seed varied executive events ───────────────────────
-- Insert contract_activity rows with diverse activity_type values within
-- the 14-day window so fn_dashboard_executive.events14d picks them up.
-- We use only WHITELISTED activity_type values (see migration 032 + 027).

DO $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_actor BIGINT := 1;
  v_hero_id BIGINT;
  v_c BIGINT;
  v_offset INT := 0;
  v_contract_count INT;
BEGIN
  -- Test-branch guard
  SELECT COUNT(*) INTO v_contract_count FROM contract WHERE is_active = TRUE;
  IF v_contract_count < 20 THEN
    RAISE NOTICE 'Skipping executive event seed — only % contracts (need >=20).', v_contract_count;
    RETURN;
  END IF;
  -- Pick HERO-001 if it exists for prominent events
  SELECT id INTO v_hero_id FROM contract WHERE contract_number ILIKE '%HERO-001%' LIMIT 1;

  -- Helper: insert an event linked to a high-value contract
  FOR v_c IN
    SELECT id FROM contract
    WHERE is_active = TRUE
    ORDER BY value_aed DESC NULLS LAST
    LIMIT 20
  LOOP
    v_offset := v_offset + 1;

    -- Distribute across 7 narrative-rich activity_types via offset modulo
    CASE (v_offset % 7)
      WHEN 0 THEN
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'fully_executed', v_actor,
                  'Contract fully executed — counterparty signature received',
                  'تم تنفيذ العقد بالكامل — تم استلام توقيع الطرف المقابل',
                  jsonb_build_object('via', 'uae_pass'),
                  v_now - (v_offset * INTERVAL '7 hours'));
      WHEN 1 THEN
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'sent_for_signature', v_actor,
                  'Sent for signature to counterparty',
                  'تم الإرسال للتوقيع من الطرف المقابل',
                  '{}'::jsonb,
                  v_now - (v_offset * INTERVAL '11 hours'));
      WHEN 2 THEN
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'regulatory_impact_detected', v_actor,
                  'Regulatory impact detected — Federal Decree-Law applicability',
                  'تم اكتشاف الأثر التنظيمي',
                  jsonb_build_object('regulation', 'Federal Decree-Law No. 9/2024'),
                  v_now - (v_offset * INTERVAL '13 hours'));
      WHEN 3 THEN
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'approval_decided', v_actor,
                  'Approval decision recorded — approved by legal counsel',
                  'تم اتخاذ قرار الاعتماد',
                  jsonb_build_object('decision', 'approved'),
                  v_now - (v_offset * INTERVAL '17 hours'));
      WHEN 4 THEN
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'submitted_for_approval', v_actor,
                  'Submitted for executive approval — step 2 of 3',
                  'تم تقديم العقد للاعتماد التنفيذي',
                  '{}'::jsonb,
                  v_now - (v_offset * INTERVAL '23 hours'));
      WHEN 5 THEN
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'impact_signal_notify', v_actor,
                  'Impact signal notified — Murban OSP price movement',
                  'تم إشعار إشارة الأثر',
                  jsonb_build_object('signal', 'murban_osp_change'),
                  v_now - (v_offset * INTERVAL '29 hours'));
      ELSE
        INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
          VALUES (v_c, 'amendment_initiated', v_actor,
                  'Amendment initiated — scope change request from counterparty',
                  'تم بدء تعديل',
                  '{}'::jsonb,
                  v_now - (v_offset * INTERVAL '31 hours'));
    END CASE;
  END LOOP;

  -- HERO-001 specific narrative-rich events if it exists
  IF v_hero_id IS NOT NULL THEN
    INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, description_ar, metadata, created_at)
      VALUES
        (v_hero_id, 'regulatory_impact_detected', v_actor,
          'Cure-notice draft queued — budget variance breach for July-2026',
          'تم وضع مسودة إشعار العلاج في قائمة الانتظار',
          jsonb_build_object('source','budget_burn','period','2026-07','variancePct',13),
          v_now - INTERVAL '2 hours'),
        (v_hero_id, 'ai_summary_generated', v_actor,
          'AI risk dossier generated — 7 budget breaches, AED 42M projected overrun',
          'تم إنشاء ملخص ذكاء اصطناعي',
          jsonb_build_object('breaches',7,'projectedOverrunAed', 42000000),
          v_now - INTERVAL '4 hours');
  END IF;
END $$;

-- ── E17 — bump current_version on a curated set so MostAmended is real ──
UPDATE contract
  SET current_version = CASE id
    -- HERO-001: 4 amendments (a real story)
    WHEN (SELECT id FROM contract WHERE contract_number ILIKE '%HERO-001%' LIMIT 1) THEN 5
    ELSE current_version
  END
  WHERE id = (SELECT id FROM contract WHERE contract_number ILIKE '%HERO-001%' LIMIT 1);

UPDATE contract
  SET current_version = (4 + (id % 4))  -- 4..7 amendments
  WHERE id IN (
    SELECT id FROM contract
    WHERE is_active = TRUE
      AND contract_number NOT ILIKE '%HERO-001%'
    ORDER BY value_aed DESC NULLS LAST
    LIMIT 9
  );

-- ── E18 — template_id backfill so MostUsedTemplates feels real ──────────
-- The dashboard reads contracts created in last 90 days grouped by template_id.
-- Spread template_id 1..8 over recent contracts.
-- Template IDs available: 9..16 (8 templates). Map id → template via offset.
-- Guarded so the migration works on branches without the demo templates.
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM contract_template WHERE id BETWEEN 9 AND 16 AND is_active) = 8 THEN
    UPDATE contract
      SET template_id = 9 + ((id * 7) % 8),
          updated_at = NOW(),
          updated_by = 1
      WHERE is_active = TRUE
        AND template_id IS NULL
        AND created_at >= CURRENT_DATE - INTERVAL '90 days';
  ELSE
    RAISE NOTICE 'Skipping template backfill — demo templates 9..16 not present in this branch.';
  END IF;
END $$;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Data-seed migration:
--   DELETE FROM contract_activity
--     WHERE activity_type IN ('fully_executed','sent_for_signature',
--           'regulatory_impact_detected','approval_decided','submitted_for_approval',
--           'impact_signal_notify','amendment_initiated','ai_summary_generated')
--     AND created_at >= NOW() - INTERVAL '14 days'
--     AND description_en LIKE 'Contract fully executed — counterparty signature%'
--       OR description_en LIKE 'Cure-notice draft queued%';
-- ============================================================
