-- Migration: 416_omar_cluster_b_risk_cases_seed.sql
-- Unit: Omar Operations QA Phase 3 — Cluster B (risk cases + case detail enrichment)
-- Targets:
--   O23  Only 1 case (#12) assigned to Omar. Seed 5 additional operations-
--        scoped cases across Critical/High/Medium × Open/In review × SLA
--        breach/Correlation alert/Manual types so the demo breadth feels real.
--   O26  Case #12 body is one sentence; Timeline / Evidence tabs are sparse.
--        Enrich body with 3-paragraph narrative + seed 5 timeline events.

DO $$
DECLARE
  v_tenant   UUID := '00000000-0000-0000-0000-000000000001';
  v_omar     BIGINT := 12;
BEGIN
  ----------------------------------------------------------------------------
  -- O26 — enrich case #12 body + seed timeline events.
  -- Guard: test branch may not have case #12 — skip if absent.
  ----------------------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM risk_case WHERE id = 12) THEN
    RAISE NOTICE 'mig 416 O26: case #12 absent (test branch?), skipping enrichment.';
  ELSE
  UPDATE risk_case
     SET body = E'Construction milestone Q2 missed by 11 days on the ADNOC Onshore — EPC Crude Stabilization Unit — Ruwais contract (CRQ-ONS-023). The slip exposes the contract to liquidated-damages clause 23.4 (AED 730K/rig/day capped at AED 63.3M per contract year). Current penalty exposure: AED 1.4M.\n\nRoot cause per Field Engineering report 2026-05-27: subsea-tree FAT delay at vendor facility (Saudi Arabia → Ruwais). Vendor (Mubadala Petroleum Support Services) has been notified informally; formal cure-notice window opens 2026-06-04 if no remediation plan filed by 2026-06-03.\n\nNext steps: Operations to coordinate with Legal Counsel on cure-notice draft, Procurement to evaluate alternate vendor activation, Finance to size LD-exposure for Q3 board update. Closing this case requires either (a) remediation plan acceptance OR (b) cure-notice dispatch.',
         updated_at = NOW(),
         updated_by = 1
   WHERE id = 12;

  -- Seed 5 timeline events on case #12
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
  SELECT v_tenant, 12, e.event_type, e.actor_id, e.payload::jsonb, (NOW() - (e.delta_minutes || ' minutes')::interval)
    FROM (VALUES
      ('created',        1::bigint,  '{"source":"correlation_alert","sla_hours":72,"correlation_id":null,"trigger":"epc_milestone_slippage_signal_2026-05-27"}', 4320),
      ('assigned',       1::bigint,  '{"role":"operations","user_id":12,"reason":"EPC SLA → ops role per case-type routing matrix"}',                              4280),
      ('comment_added',  12::bigint, '{"comment":"Reviewed Field Engineering daily report — subsea-tree FAT delay vendor-side. Reaching out to Mubadala Petroleum Support Services for remediation timeline."}', 2880),
      ('comment_added',  12::bigint, '{"comment":"Vendor remediation plan due 2026-06-03. Cure-notice window opens 2026-06-04 if no plan."}',                       1440),
      ('status_changed', 12::bigint, '{"from":"open","to":"in_review","reason":"Vendor remediation plan under evaluation"}',                                       60)
    ) AS e(event_type, actor_id, payload, delta_minutes)
    WHERE NOT EXISTS (
      SELECT 1 FROM risk_case_event rce
       WHERE rce.risk_case_id = 12
         AND rce.event_type = e.event_type
         AND rce.payload::text = e.payload
    );
  END IF;

  ----------------------------------------------------------------------------
  -- O23 — seed 5 additional operations-scoped risk cases.
  -- Idempotent via dedupe_key. Spread priorities + statuses + types.
  ----------------------------------------------------------------------------
  INSERT INTO risk_case (
    tenant_id, correlation_id, contract_id, case_type, priority, title, body,
    assigned_role, assigned_user_id, status, sla_hours, due_at,
    dedupe_key, data_classification, created_at, updated_at, is_active,
    created_by, updated_by
  )
  SELECT
    v_tenant, NULL, t.contract_id, t.case_type, t.priority, t.title, t.body,
    'operations', v_omar, 'open', t.sla_hours, NOW() + (t.due_hours || ' hours')::interval,
    'omar-ops-' || t.dedupe_suffix, 'internal', NOW() - (t.created_hours_ago || ' hours')::interval, NOW(), TRUE, 1, 1
  FROM (VALUES
    (
      (SELECT id FROM contract WHERE contract_number = 'CRQ-GAS-009' LIMIT 1)::bigint,
      'sla_breach'::text,
      'high'::text,
      'North Star Shipping Services — vessel demurrage breach',
      E'Charter party demurrage clock breached on 3 consecutive shipments. Combined demurrage exposure AED 6.2M.\n\nVessel manifest shows port-rotation conflict at Jebel Ali. Charter party (North Star Shipping Services) confirms loading delays; ICV impact under review.',
      72::int, 60::int, 'high-sla-001'::text, 48::int
    ),
    (
      (SELECT id FROM contract WHERE contract_number = 'CRQ-GAS-014' LIMIT 1)::bigint,
      'correlation_alert'::text,
      'critical'::text,
      'Gulf Towage & Salvage — Hormuz routing FM event',
      E'Hormuz Strait routing disruption (ICS incident 2026-05-30) impacts vessel transit windows for Gulf Towage & Salvage tug fleet. Force-majeure clause 21.2 eligibility assessment underway.\n\nLegal Counsel review pending. Operations to coordinate alternate routing decision by 2026-06-04.',
      48::int, 36::int, 'crit-fm-001'::text, 28::int
    ),
    (
      (SELECT id FROM contract WHERE contract_number = 'CRQ-ONS-023' LIMIT 1)::bigint,
      'sla_breach'::text,
      'high'::text,
      'EPC Ruwais — rig-availability uptime miss',
      E'Rig 4 availability dropped to 87% in May (target ≥ 95%). LD-clause exposure projected at AED 2.1M if not remedied in Q3.\n\nVendor has submitted maintenance schedule; awaiting confirmation that Q3 target is restored.',
      72::int, 84::int, 'high-uptime-001'::text, 72::int
    ),
    (
      (SELECT id FROM contract WHERE contract_number = 'CRQ-GAS-001' LIMIT 1)::bigint,
      'sla_breach'::text,
      'medium'::text,
      'Oilfield Pipelines — vendor scorecard refresh stalled',
      E'Vendor performance scorecard last updated 2026-04-15. Required refresh frequency: monthly. Refresh stalled at vendor side; Procurement re-issued data request 2026-05-29.\n\nNo operational impact yet — flagging for visibility.',
      120::int, 120::int, 'med-scorecard-001'::text, 96::int
    ),
    (
      (SELECT id FROM contract WHERE contract_number = 'CRQ-GAS-027' LIMIT 1)::bigint,
      'manual'::text,
      'medium'::text,
      'Al Nokhada Shipping — voyage report compliance gap',
      E'Vendor voyage reports for May missed 2 of 4 weekly deadlines. Contract clause 14.3 requires weekly compliance. Operations sending formal reminder.\n\nNo penalty exposure yet; cumulative miss > 4 triggers warning letter.',
      120::int, 168::int, 'med-voyage-001'::text, 120::int
    )
  ) AS t(contract_id, case_type, priority, title, body, sla_hours, due_hours, dedupe_suffix, created_hours_ago)
  WHERE t.contract_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM risk_case rc WHERE rc.dedupe_key = 'omar-ops-' || t.dedupe_suffix
    );

  -- Mix in statuses: leave most Open, set 1 to in_review and 1 to snoozed.
  UPDATE risk_case
     SET status = 'in_review',
         updated_at = NOW(),
         updated_by = 1
   WHERE dedupe_key = 'omar-ops-crit-fm-001'
     AND status = 'open';

  UPDATE risk_case
     SET status = 'snoozed',
         snoozed_until = NOW() + INTERVAL '48 hours',
         updated_at = NOW(),
         updated_by = 1
   WHERE dedupe_key = 'omar-ops-med-scorecard-001'
     AND status = 'open';

  RAISE NOTICE 'mig 416: case #12 enriched + 5 new Omar cases seeded.';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (416, '416_omar_cluster_b_risk_cases_seed — O23/O26 risk-case breadth + #12 narrative', NOW())
ON CONFLICT (version) DO NOTHING;

-- ROLLBACK:
-- DELETE FROM risk_case_event WHERE risk_case_id = 12 AND occurred_at > NOW() - INTERVAL '4 days';
-- DELETE FROM risk_case WHERE dedupe_key LIKE 'omar-ops-%';
-- DELETE FROM schema_migrations WHERE version = 416;
