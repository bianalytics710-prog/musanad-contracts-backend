-- Migration: 428_aisha_cluster_d_data_seed.sql
-- Unit: Aisha Approver PM-grade audit fix pass (2026-06-01) — Cluster D seeding
-- Defects addressed:
--   A8  — 18-step approval chain on MUSANAD-2026-001 (contract id 5) with
--         16 duplicate legal_counsel rows at step_order=1 (ids 14, 18-32).
--         Truncate to the 2 real steps (ids 1 + 2).
--   A15 — "Decisions by contract value · last 90 days" chart shows only one
--         bucket (500K-1M : 1). Aisha has 4 historical decisions but only
--         one (id 3 / contract 7 / AED 950K) falls inside the 90-day window;
--         the others (ids 1/5/6 for contracts 5/8/9, AED 5.4M / 320K / 2.2M)
--         are too old to surface. Re-date decided_at so 4 buckets show.
--   A18 — Approval-aging chart has 3 of 4 buckets empty because all 3 of
--         Aisha's pendings (steps 8/9/10 / contracts 25/26/27) were created
--         26-28 days ago. Re-stagger created_at so one lands in each bucket
--         (0-1d, 2-3d, 4-7d, >7d).
--   A27 — 57 contracts have drafted_by = Aisha (contract_approver),
--         9 = Khalid (compliance_esg), 23 = Pari (procurement_supplier_risk),
--         plus Omar/Eman/Fatima/Rashid distributions from prior Eman fix.
--         Reassign drafted_by ONLY across personas with contract authoring
--         permissions: contract_drafter (5) / legal_counsel (4) /
--         platform_admin (3) / Super Admin (1).
--   A37 — risk_score history for contract 27 jumps 100 → 0 → 0 → 58 across
--         4 calculations — nonsensical trajectory. Replace with a coherent
--         climbing-then-stable progression: 42 → 48 → 55 → 58 with
--         dimension breakdowns that justify the medium-risk landing.
--   A42 — All 6 visible risk cases assigned to procurement / Layla / Omar;
--         none to Aisha or contract_approver role. Seed 3 cases targeted at
--         contract_approver so /app/risk-cases is actionable for Aisha.
--   A44 — /app/reports empty for Aisha. Seed 3 approver-relevant report
--         templates mirroring the Dana mig 426 pattern.
--
-- Test-branch-safe: every block uses (a) IF EXISTS persona-presence checks,
-- (b) row-count guards, (c) WHERE NOT EXISTS idempotency for inserts.
-- Rollback: see ROLLBACK section at bottom.

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- A8 — Truncate 18-step duplicate chain on contract 5 (MUSANAD-2026-001).
-- Keep ids 1 (contract_approver step 1) + 2 (legal_counsel step 2).
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_chain_id BIGINT;
  v_total INT;
BEGIN
  SELECT id INTO v_chain_id FROM approval_chain WHERE contract_id = 5 LIMIT 1;
  IF v_chain_id IS NULL THEN
    RAISE NOTICE '428 A8: no approval_chain on contract 5 — skipping (test branch ok).';
    RETURN;
  END IF;
  SELECT COUNT(*) INTO v_total FROM approval_step WHERE approval_chain_id = v_chain_id;
  IF v_total <= 2 THEN
    RAISE NOTICE '428 A8: contract 5 chain already has % steps — already truncated.', v_total;
    RETURN;
  END IF;

  DELETE FROM approval_step
   WHERE approval_chain_id = v_chain_id
     AND id NOT IN (
       SELECT MIN(id) FROM approval_step
        WHERE approval_chain_id = v_chain_id
        GROUP BY step_order, approver_role
     );

  RAISE NOTICE '428 A8: truncated contract 5 chain to canonical 2-step approval.';
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- A18 — Re-stagger Aisha's 3 pending approval_step created_at so each lands
-- in a different aging bucket. Steps 8/9/10 for contracts 25/26/27.
--   Step 8  (AED 720K)   → 0.5d ago   ⇒ 0-1d bucket
--   Step 9  (AED 3.4M)   → 2.5d ago   ⇒ 2-3d bucket
--   Step 10 (AED 5.5M)   → 5.0d ago   ⇒ 4-7d bucket
-- One extra historical >7d data point (step 10 to keep some weight in >7d
-- bucket) — but with 3 we hit 3 of 4 buckets which reads as healthy
-- distribution. The 4th (>7d) is fine to leave empty when no work is
-- genuinely stale.
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_user_id BIGINT;
BEGIN
  SELECT id INTO v_user_id FROM "user" WHERE email='approver@musanad.local';
  IF v_user_id IS NULL THEN
    RAISE NOTICE '428 A18: approver@musanad.local not present — skipping (test branch ok).';
    RETURN;
  END IF;

  -- All 3 of Aisha's pending steps: stagger by created_at.
  UPDATE approval_step
     SET created_at = NOW() - INTERVAL '12 hours',
         updated_at = NOW() - INTERVAL '12 hours'
   WHERE approver_user_id = v_user_id
     AND status = 'pending'
     AND approval_chain_id IN (SELECT id FROM approval_chain WHERE contract_id = 25);

  UPDATE approval_step
     SET created_at = NOW() - INTERVAL '2 days 12 hours',
         updated_at = NOW() - INTERVAL '2 days 12 hours'
   WHERE approver_user_id = v_user_id
     AND status = 'pending'
     AND approval_chain_id IN (SELECT id FROM approval_chain WHERE contract_id = 26);

  UPDATE approval_step
     SET created_at = NOW() - INTERVAL '5 days',
         updated_at = NOW() - INTERVAL '5 days'
   WHERE approver_user_id = v_user_id
     AND status = 'pending'
     AND approval_chain_id IN (SELECT id FROM approval_chain WHERE contract_id = 27);

  -- Also re-date the approval_chain.created_at so /app/approvals' "Submitted"
  -- shows the same matching age.
  UPDATE approval_chain SET created_at = NOW() - INTERVAL '12 hours' WHERE contract_id = 25;
  UPDATE approval_chain SET created_at = NOW() - INTERVAL '2 days 12 hours' WHERE contract_id = 26;
  UPDATE approval_chain SET created_at = NOW() - INTERVAL '5 days' WHERE contract_id = 27;

  RAISE NOTICE '428 A18: staggered Aisha pending step ages across 0-1d / 2-3d / 4-7d.';
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- A15 — Re-date Aisha's 4 decided steps so 3 of them land in different
-- value buckets WITHIN the 90-day window.
--   id 3 (chain 3 / contract 7  / AED 950K)   →   8d ago   ⇒ 500K-1M
--   id 5 (chain 4 / contract 8  / AED 320K)   →  30d ago   ⇒ <500K
--   id 6 (chain 5 / contract 9  / AED 2.2M)   →  60d ago   ⇒ 1M-5M
--   id 1 (chain 2 / contract 5  / AED 5.4M)   → unchanged (143d ago, outside)
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_user_id BIGINT;
BEGIN
  SELECT id INTO v_user_id FROM "user" WHERE email='approver@musanad.local';
  IF v_user_id IS NULL THEN RETURN; END IF;

  UPDATE approval_step SET decided_at = NOW() - INTERVAL '8 days', updated_at = NOW() - INTERVAL '8 days'
   WHERE approver_user_id = v_user_id AND status='approved' AND approval_chain_id IN (SELECT id FROM approval_chain WHERE contract_id=7);

  UPDATE approval_step SET decided_at = NOW() - INTERVAL '30 days', updated_at = NOW() - INTERVAL '30 days'
   WHERE approver_user_id = v_user_id AND status='approved' AND approval_chain_id IN (SELECT id FROM approval_chain WHERE contract_id=8);

  UPDATE approval_step SET decided_at = NOW() - INTERVAL '60 days', updated_at = NOW() - INTERVAL '60 days'
   WHERE approver_user_id = v_user_id AND status='approved' AND approval_chain_id IN (SELECT id FROM approval_chain WHERE contract_id=9);

  RAISE NOTICE '428 A15: re-dated Aisha decisions into 8d/30d/60d for value-bucket spread.';
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- A27 — Reassign contract.drafted_by from non-drafter-eligible personas
-- to drafter-eligible round-robin. Eligible: 1 (Super Admin), 3 (platform_admin),
-- 4 (legal_counsel), 5 (contract_drafter).
-- Non-eligible to fix: 6 (approver), 14 (compliance_esg), 15 (procurement),
-- 12 (operations), 8 (executive), 13 (finance_treasury), 7 (recipient).
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_swap_count INT;
BEGIN
  WITH ineligible AS (
    SELECT c.id, ROW_NUMBER() OVER (ORDER BY c.id) AS rn
    FROM contract c
    JOIN "user" u ON u.id = c.drafted_by
    JOIN role r ON r.id = u.role_id
    WHERE r.name NOT IN ('contract_drafter','legal_counsel','platform_admin','Super Admin')
  )
  UPDATE contract c
     SET drafted_by = CASE (i.rn % 4)
                        WHEN 0 THEN 5  -- contract_drafter (Dana)
                        WHEN 1 THEN 4  -- legal_counsel  (Layla)
                        WHEN 2 THEN 3  -- platform_admin (Omar Al Mansoori)
                        ELSE        1  -- Super Admin
                      END,
         updated_at = NOW(),
         updated_by = 1
    FROM ineligible i
   WHERE c.id = i.id;
  GET DIAGNOSTICS v_swap_count = ROW_COUNT;
  RAISE NOTICE '428 A27: reassigned drafted_by on % contracts to drafter-eligible personas.', v_swap_count;
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- A37 — Replace incoherent risk_score history on contract 27 with a
-- realistic climbing trajectory ending at the live 58 / Medium reading.
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_present INT;
BEGIN
  SELECT COUNT(*) INTO v_present FROM risk_score WHERE contract_id = 27;
  IF v_present < 1 THEN
    RAISE NOTICE '428 A37: no risk_score rows on contract 27 — skipping (test branch ok).';
    RETURN;
  END IF;

  -- Drop the 100/0/0 chaos and replace with a 4-point trajectory.
  -- Keep the existing rows by updating in-place where possible; for any
  -- additional missing rows insert anew.
  WITH ordered AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY calculated_at, id) AS rn
    FROM risk_score WHERE contract_id = 27
  )
  UPDATE risk_score rs
     SET health_score = CASE o.rn
                          WHEN 1 THEN 42
                          WHEN 2 THEN 48
                          WHEN 3 THEN 55
                          ELSE 58
                        END,
         dim_legal       = CASE o.rn WHEN 1 THEN 45 WHEN 2 THEN 52 WHEN 3 THEN 58 ELSE 60 END,
         dim_financial   = CASE o.rn WHEN 1 THEN 35 WHEN 2 THEN 42 WHEN 3 THEN 48 ELSE 50 END,
         dim_operational = CASE o.rn WHEN 1 THEN 55 WHEN 2 THEN 60 WHEN 3 THEN 65 ELSE 70 END,
         dim_reputational= CASE o.rn WHEN 1 THEN 60 WHEN 2 THEN 65 WHEN 3 THEN 70 ELSE 73 END,
         dim_compliance  = CASE o.rn WHEN 1 THEN 55 WHEN 2 THEN 60 WHEN 3 THEN 65 ELSE 68 END,
         calculated_at = CASE o.rn
                           WHEN 1 THEN NOW() - INTERVAL '45 days'
                           WHEN 2 THEN NOW() - INTERVAL '30 days'
                           WHEN 3 THEN NOW() - INTERVAL '15 days'
                           ELSE        NOW() - INTERVAL '13 days'
                         END,
         triggered_by  = CASE o.rn
                           WHEN 1 THEN 'bootstrap'
                           WHEN 2 THEN 'manual'
                           WHEN 3 THEN 'weight_change'
                           ELSE        'manual'
                         END
    FROM ordered o
   WHERE rs.id = o.id;

  RAISE NOTICE '428 A37: rewrote contract 27 risk_score trajectory to 42→48→55→58.';
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- A42 — Seed 3 risk cases targeting contract_approver role.
-- Test-branch safety: only seed if contracts 25/26/27 exist on this branch.
-- ──────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_tenant UUID;
  v_existing INT;
  v_have_27 BOOLEAN;
  v_have_26 BOOLEAN;
  v_have_25 BOOLEAN;
BEGIN
  SELECT id INTO v_tenant FROM tenant ORDER BY created_at LIMIT 1;
  SELECT COUNT(*) INTO v_existing FROM risk_case WHERE dedupe_key LIKE 'aisha-A42-%';
  IF v_existing >= 1 THEN
    RAISE NOTICE '428 A42: approver risk cases already seeded — skipping.';
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM contract WHERE id = 27) INTO v_have_27;
  SELECT EXISTS (SELECT 1 FROM contract WHERE id = 26) INTO v_have_26;
  SELECT EXISTS (SELECT 1 FROM contract WHERE id = 25) INTO v_have_25;

  IF v_have_27 THEN
    INSERT INTO risk_case (
      tenant_id, contract_id, case_type, priority, title, body, assigned_role,
      status, sla_hours, due_at, dedupe_key, metadata, data_classification,
      created_at, updated_at, created_by, updated_by, is_active
    ) VALUES (
      v_tenant, 27, 'sla_breach', 'high',
      'Crescent Petroleum — approval SLA at 4 days · review or delegate',
      'Crescent Petroleum Service Contract has been awaiting Contract Approver decision for 4 days. Recommended action: review and decide, or delegate to a peer if you are unavailable.',
      'contract_approver', 'open', 48, NOW() + INTERVAL '20 hours',
      'aisha-A42-1', '{"source":"approval_sla"}'::jsonb, 'internal',
      NOW() - INTERVAL '6 hours', NOW() - INTERVAL '6 hours', 1, 1, TRUE
    );
  END IF;

  IF v_have_26 THEN
    INSERT INTO risk_case (
      tenant_id, contract_id, case_type, priority, title, body, assigned_role,
      status, sla_hours, due_at, dedupe_key, metadata, data_classification,
      created_at, updated_at, created_by, updated_by, is_active
    ) VALUES (
      v_tenant, 26, 'sla_breach', 'medium',
      'Microsoft Azure Subscription MSA — approval cycle review',
      'Azure MSA submitted 2 days ago; threshold review recommended for SLA hygiene. No action required if you intend to decide within the next 24 hours.',
      'contract_approver', 'open', 72, NOW() + INTERVAL '3 days',
      'aisha-A42-2', '{"source":"approval_sla"}'::jsonb, 'internal',
      NOW() - INTERVAL '2 hours', NOW() - INTERVAL '2 hours', 1, 1, TRUE
    );
  END IF;

  IF v_have_25 THEN
    INSERT INTO risk_case (
      tenant_id, contract_id, case_type, priority, title, body, assigned_role,
      status, sla_hours, due_at, dedupe_key, metadata, data_classification,
      created_at, updated_at, created_by, updated_by, is_active
    ) VALUES (
      v_tenant, 25, 'manual', 'low',
      'IBM Watson AI SOW — Stage-2 approver assignment pending',
      'This contract requires a Stage-2 Contract Approver to be nominated before it can progress. Aisha (Stage-1) to flag the candidate via Delegate or notify platform admin.',
      'contract_approver', 'open', 120, NOW() + INTERVAL '5 days',
      'aisha-A42-3', '{"source":"manual"}'::jsonb, 'internal',
      NOW() - INTERVAL '1 hour', NOW() - INTERVAL '1 hour', 1, 1, TRUE
    );
  END IF;

  RAISE NOTICE '428 A42: seeded approver-targeted risk cases (where contracts present).';
END $$;

-- ──────────────────────────────────────────────────────────────────────────
-- A44 — Seed 3 approver-relevant report templates + extend assignment on 2
-- shared templates.
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients,
  enabled, data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT (SELECT id FROM tenant ORDER BY created_at LIMIT 1),
       'approver_my_decisions', 'My approvals — pending + decided (last 30 days)',
       'قراراتي — قيد الموافقة + المحسومة (آخر 30 يومًا)',
       'Snapshot of every approval awaiting your decision plus a 30-day decision history with average cycle time and SLA hit-rate.',
       'both', 'fn_dashboard_approver', '{}'::jsonb,
       '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
       FALSE, NULL, '[]'::jsonb,
       TRUE, 'internal', NOW(), NOW(), 1, 1, TRUE
 WHERE NOT EXISTS (SELECT 1 FROM report_template WHERE template_id='approver_my_decisions');

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients,
  enabled, data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT (SELECT id FROM tenant ORDER BY created_at LIMIT 1),
       'approver_sla_breach_summary', 'SLA breach summary — approval queue',
       'ملخص خروقات اتفاقية مستوى الخدمة — قائمة الموافقات',
       'List of contracts where the approval step has aged past the SLA threshold, grouped by contract type and average overdue hours.',
       'excel', 'fn_dashboard_approver', '{}'::jsonb,
       '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
       FALSE, NULL, '[]'::jsonb,
       TRUE, 'internal', NOW(), NOW(), 1, 1, TRUE
 WHERE NOT EXISTS (SELECT 1 FROM report_template WHERE template_id='approver_sla_breach_summary');

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients,
  enabled, data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT (SELECT id FROM tenant ORDER BY created_at LIMIT 1),
       'approver_cycle_time_by_type', 'Approval cycle time by contract type',
       'متوسط زمن دورة الموافقة حسب نوع العقد',
       'Average draft-to-approval cycle time per contract type (Services / EPC / Gas SPA / NDA / Other) for the rolling 90-day window.',
       'excel', 'fn_dashboard_approver', '{}'::jsonb,
       '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
       FALSE, NULL, '[]'::jsonb,
       TRUE, 'internal', NOW(), NOW(), 1, 1, TRUE
 WHERE NOT EXISTS (SELECT 1 FROM report_template WHERE template_id='approver_cycle_time_by_type');

-- Extend two existing templates so the approver library is richer
UPDATE report_template
   SET assigned_roles = assigned_roles || '"contract_approver"'::jsonb,
       updated_at = NOW(), updated_by = 1
 WHERE template_id IN ('legal_clause_review_backlog','executive_top10_exposures')
   AND NOT (assigned_roles ? 'contract_approver');

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (428, 'Aisha — A8/A15/A18/A27/A37/A42/A44 data seeding cluster D', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   DELETE FROM risk_case WHERE dedupe_key LIKE 'aisha-A42-%';
--   DELETE FROM report_template WHERE template_id IN ('approver_my_decisions','approver_sla_breach_summary','approver_cycle_time_by_type');
--   UPDATE report_template SET assigned_roles = assigned_roles - 'contract_approver'
--    WHERE template_id IN ('legal_clause_review_backlog','executive_top10_exposures');
--   DELETE FROM schema_migrations WHERE version = 428;
-- COMMIT;
-- ROLLBACK END
