-- Migration: 488_risk_case_timeline_evidence_seed.sql
-- Module: Risk Cases — Executive demo polish
-- Date: 2026-06-02
--
-- Problem: 25 active risk_case rows but only 4 have any timeline events and
-- 0 have evidence attachments. The detail panel's Timeline + Evidence tabs
-- correctly render "No activity yet" / "No evidence has been uploaded" but
-- that leaves the module looking unfinished for the demo.
--
-- Fix: seed a realistic narrative for each substantive case (id >= 7,
-- excludes the 3 historical walk-probes id 1/2/3):
--   - 5-6 timeline events per case spread across the case's created_at →
--     updated_at window (created → assigned → comment → evidence_uploaded
--     → optional status_changed)
--   - 1 evidence attachment per case, file_uri reuses an existing PDF
--     already in Supabase Storage (demo/crm-295/* and demo/crq-334/*
--     uploaded by document-ingestion seeds). The same `contract-attachments`
--     bucket serves both modules so signed-URL downloads work without
--     uploading anything new.
--
-- Idempotent: each block checks for existing rows before inserting; safe
-- to re-apply.

DO $$
DECLARE
  v_tenant     UUID := '00000000-0000-0000-0000-000000000001';
  v_eman       BIGINT := 8;
  v_layla      BIGINT := 4;
  v_aisha      BIGINT := 6;
  v_yusuf      BIGINT := 12;
  v_fatima     BIGINT := 13;
  v_khalid     BIGINT := 14;
  v_hessa      BIGINT := 15;
  v_platform   BIGINT := 3;
  rc           RECORD;
  v_assignee   BIGINT;
  v_assignee_name TEXT;
  v_pdf_path   TEXT;
  v_pdf_name   TEXT;
  v_pdf_bytes  BIGINT;
  v_pdf_idx    INTEGER := 0;
  v_t0         TIMESTAMPTZ;
  v_pdfs       TEXT[][] := ARRAY[
    ARRAY['demo/crm-295/c001-lamprell-icv-cert.pdf',       'lamprell-icv-cert-2024.pdf',          '204800'],
    ARRAY['demo/crm-295/c002-gulf-marine-icv-cert.pdf',    'gulf-marine-icv-cert-2024.pdf',       '188416'],
    ARRAY['demo/crm-295/c005-neptune-icv-cert.pdf',        'neptune-icv-cert-2024.pdf',           '176128'],
    ARRAY['demo/crm-295/c006-jereh-icv-cert.pdf',          'jereh-icv-cert-2023.pdf',             '163840'],
    ARRAY['demo/crm-295/c007-target-eng-icv-cert.pdf',     'target-eng-icv-cert-2024.pdf',        '192512'],
    ARRAY['demo/crq-334/crq_dis_003_icv_fy2026.pdf',       'ICV-CERT-CRQ-DIS-003-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_dis_016_icv_fy2026.pdf',       'ICV-CERT-CRQ-DIS-016-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_dis_022_icv_fy2026.pdf',       'ICV-CERT-CRQ-DIS-022-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_drl_002_icv_fy2026.pdf',       'ICV-CERT-CRQ-DRL-002-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_drl_006_icv_fy2026.pdf',       'ICV-CERT-CRQ-DRL-006-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_drl_012_icv_fy2026.pdf',       'ICV-CERT-CRQ-DRL-012-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_drl_025_icv_fy2026.pdf',       'ICV-CERT-CRQ-DRL-025-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_drl_033_icv_fy2026.pdf',       'ICV-CERT-CRQ-DRL-033-FY2026.pdf',     '204800'],
    ARRAY['demo/crq-334/crq_drl_040_icv_fy2026.pdf',       'ICV-CERT-CRQ-DRL-040-FY2026.pdf',     '204800']
  ];
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::TEXT, true);

  FOR rc IN
    SELECT id, title, status, priority, assigned_role, assigned_user_id, created_at, updated_at, contract_id, case_type
      FROM risk_case
      WHERE id >= 7
        AND is_active = TRUE
        AND status NOT IN ('closed', 'rejected', 'approved')
      ORDER BY id
  LOOP
    -- Skip cases that already have any timeline activity.
    IF EXISTS (SELECT 1 FROM risk_case_event WHERE risk_case_id = rc.id) THEN
      RAISE NOTICE 'mig 488: case % already has timeline events, skipping seed', rc.id;
      CONTINUE;
    END IF;

    v_t0 := rc.created_at;

    -- Resolve assignee user id from the assigned_role slug.
    v_assignee := COALESCE(rc.assigned_user_id,
      CASE rc.assigned_role
        WHEN 'finance_treasury'           THEN v_fatima
        WHEN 'compliance_esg'             THEN v_khalid
        WHEN 'legal_counsel'              THEN v_layla
        WHEN 'operations'                 THEN v_yusuf
        WHEN 'procurement_supplier_risk'  THEN v_hessa
        WHEN 'contract_approver'          THEN v_aisha
        ELSE v_platform
      END);
    v_assignee_name := CASE rc.assigned_role
        WHEN 'finance_treasury'           THEN 'Fatima Al Marri'
        WHEN 'compliance_esg'             THEN 'Khalid Al Qubaisi'
        WHEN 'legal_counsel'              THEN 'Layla Al Hashemi'
        WHEN 'operations'                 THEN 'Yusuf Al Falasi'
        WHEN 'procurement_supplier_risk'  THEN 'Hessa Al Hamadi'
        WHEN 'contract_approver'          THEN 'Aisha Al Nahyan'
        ELSE 'Omar Al Mansoori'
      END;

    -- Event 1: created (system actor)
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
      VALUES (v_tenant, rc.id, 'created', NULL,
              jsonb_build_object(
                'source', 'correlation_engine',
                'caseType', rc.case_type,
                'priority', rc.priority
              ),
              v_t0);

    -- Event 2: assigned (system or platform admin)
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
      VALUES (v_tenant, rc.id, 'assigned', NULL,
              jsonb_build_object(
                'assignedRole', rc.assigned_role,
                'assignedUserId', v_assignee,
                'assignedUserName', v_assignee_name,
                'reason', 'Auto-routed by case_type + role mapping'
              ),
              v_t0 + INTERVAL '2 minutes');

    -- Event 3: comment from the assignee (their initial triage note)
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
      VALUES (v_tenant, rc.id, 'comment_added', v_assignee,
              jsonb_build_object(
                'comment',
                CASE
                  WHEN rc.title ILIKE '%OFAC%' THEN
                    'Initial screening run against OFAC SDN list confirms parent entity hit. Awaiting beneficial-owner registry pull from compliance vendor. Treasury notified to hold pending invoice settlement.'
                  WHEN rc.title ILIKE '%Hormuz%' THEN
                    'Marine traffic confirms vessel diversion. FM clause text pulled (Article 14.3). Need 48h of sustained disruption to qualify for relief — monitoring.'
                  WHEN rc.title ILIKE '%budget breach%' THEN
                    'Q2 variance reviewed with PM. Trend driven by steel cost surge + scope creep on Phase 3. Cure-notice template prepared; awaiting CFO sign-off before issuance.'
                  WHEN rc.title ILIKE '%Brent%' THEN
                    'Price-review clause activates at 7-day sustained band breach. Counterparty notified informally; formal trigger letter ready when threshold crystallises.'
                  WHEN rc.title ILIKE '%water-stress%' THEN
                    'WRI Aqueduct overlay confirms extreme-stress classification. ESG concern memo drafted; reviewing whether facility falls under board-level escalation policy.'
                  WHEN rc.title ILIKE '%EPC%' AND rc.title ILIKE '%milestone%' THEN
                    '11-day slippage on Milestone Q2 confirmed by contractor weekly. LD exposure ~AED 1.4M at 0.5%/day. Reviewing whether to waive (relationship-driven) or invoke.'
                  WHEN rc.title ILIKE '%Federal Decree-Law%' OR rc.title ILIKE '%annex refresh%' THEN
                    '132 contractors flagged from outside-counsel review. Bulk amendment template under draft. Priority sequencing by contract value descending.'
                  WHEN rc.title ILIKE '%concentration%' THEN
                    'Single-counterparty exposure at 18.4% vs 15% board cap. Diversification options being scoped with procurement. Need treasury input on cost of switching.'
                  WHEN rc.title ILIKE '%SLA breaches%' THEN
                    'Two SLA breaches in 180d trip the supplier-watch threshold. Recommending move to Tier-2 supplier status pending procurement review.'
                  WHEN rc.title ILIKE '%demurrage%' THEN
                    'Demurrage breach confirmed against C/P clause 8.2. Cost recovery letter drafted; preliminary loss estimate USD 340k.'
                  WHEN rc.title ILIKE '%credit bureau%' THEN
                    'D&B rating dropped from A2 to B2. Reviewing exposure: 3 active SOWs totalling AED 47M. Considering bond increase requirement.'
                  WHEN rc.title ILIKE '%rig-availability%' THEN
                    'Uptime miss against contractual 95% threshold. Two rigs underperforming. Review rig-by-rig root cause + LD applicability.'
                  WHEN rc.title ILIKE '%ICV certificates%' THEN
                    'Four contractors missing FY26 ICV certs. Procurement contacting vendors directly; if not received in 14 days will hold further awards.'
                  WHEN rc.title ILIKE '%Crescent%' AND rc.title ILIKE '%approval SLA%' THEN
                    'Approver out of office without delegate. Routed back to step-1 approver for re-trigger. Will track to closure within 24h.'
                  ELSE
                    'Reviewing the underlying signal + linked contract exposure. Will return with triage decision within SLA.'
                END,
                'visibility', 'internal'
              ),
              v_t0 + INTERVAL '45 minutes');

    -- Event 4: evidence uploaded
    v_pdf_idx := ((rc.id - 7) % array_length(v_pdfs, 1)) + 1;
    v_pdf_path := v_pdfs[v_pdf_idx][1];
    v_pdf_name := v_pdfs[v_pdf_idx][2];
    v_pdf_bytes := v_pdfs[v_pdf_idx][3]::BIGINT;

    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
      VALUES (v_tenant, rc.id, 'evidence_uploaded', v_assignee,
              jsonb_build_object(
                'filename', v_pdf_name,
                'mime', 'application/pdf',
                'sizeBytes', v_pdf_bytes
              ),
              v_t0 + INTERVAL '2 hours');

    INSERT INTO risk_case_attachment (
      tenant_id, risk_case_id, file_uri, file_name, file_mime, file_bytes,
      uploaded_by, uploaded_at, is_active
    ) VALUES (
      v_tenant, rc.id, v_pdf_path, v_pdf_name, 'application/pdf', v_pdf_bytes,
      v_assignee, v_t0 + INTERVAL '2 hours', TRUE
    );

    -- Event 5: status_changed (only if case is past 'open')
    IF rc.status = 'in_review' THEN
      INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
        VALUES (v_tenant, rc.id, 'status_changed', v_assignee,
                jsonb_build_object('fromStatus', 'open', 'toStatus', 'in_review',
                                   'note', 'Triage complete — case opened for active investigation'),
                v_t0 + INTERVAL '3 hours');
    ELSIF rc.status = 'snoozed' THEN
      INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
        VALUES (v_tenant, rc.id, 'snoozed', v_assignee,
                jsonb_build_object('until', rc.updated_at, 'reason', 'Awaiting counterparty acknowledgment'),
                v_t0 + INTERVAL '3 hours');
    END IF;

    -- Event 6: a follow-up comment closer to "now" so the timeline has recent activity
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
      VALUES (v_tenant, rc.id, 'comment_added', v_assignee,
              jsonb_build_object(
                'comment',
                CASE
                  WHEN rc.status = 'in_review' THEN 'Update: investigation progressing — expect resolution decision within 24h.'
                  WHEN rc.status = 'snoozed'   THEN 'Snoozed; will reopen when counterparty responds or window expires.'
                  ELSE                              'Awaiting input from counterparty / vendor before next action.'
                END,
                'visibility', 'internal'
              ),
              rc.updated_at - INTERVAL '30 minutes');
  END LOOP;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (488, '488_risk_case_timeline_evidence_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
