-- ============================================================================
-- Migration 696 — Close the loop: contract bodies + obligations + breach link
-- ============================================================================
-- The two internal-risk contracts (77 EPC Crude Stabilization, 243 Gas SPA) had
-- no body and no obligations — so there was nothing in the contract defining the
-- milestone / SLA the operational signal was "breaching". This adds:
--   1. Bilingual contract BODY incl. the milestone/SLA clause + an LD clause
--      (so the Document tab shows the real document, not "no body text yet").
--   2. The structured contract_obligation (the "promise") for each.
--   3. A link from the risk case to the breached obligation + clause, so the
--      risk detail can show the gap: contract obligation (expected) vs the
--      source-system record (actual).
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001'::uuid;
  v_ob_77  BIGINT;
  v_ob_243 BIGINT;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id', '1', true);

  -- ── 1a. Contract 77 body (EPC Crude Stabilization) ─────────────────────
  UPDATE contract SET
    body_en = E'# EPC Crude Stabilization Unit — Ruwais\n\n'
            || E'## 1. Scope of Work\nThe Contractor shall engineer, procure and construct the Crude Stabilization Unit at the Ruwais Onshore complex, including all mechanical, electrical and instrumentation works required for Mechanical Completion and commissioning.\n\n'
            || E'## 2. Project Schedule and Milestones\nThe Contractor shall achieve Mechanical Completion of the Crude Stabilization Unit (critical-path activity A1340) no later than 30 April 2026. The baseline schedule is maintained in Oracle Primavera P6 and reviewed monthly. Any activity on the critical path is a key contractual milestone.\n\n'
            || E'## 3. Liquidated Damages\nIf the Contractor fails to achieve a critical-path milestone by its baseline date, the Contractor shall pay liquidated damages of 0.5% of the Contract Value per week of delay (or pro-rata part thereof), capped at 10% of the Contract Value. Liquidated damages are the Employer''s sole monetary remedy for delay.\n\n'
            || E'## 4. Governing Law\nThis Agreement is governed by the federal laws of the United Arab Emirates as applied in the Emirate of Abu Dhabi.',
    body_ar = E'# وحدة تثبيت الخام — الرويس\n\n'
            || E'## 1. نطاق العمل\nيتولى المقاول الهندسة والتوريد والإنشاء لوحدة تثبيت الخام في مجمع الرويس البري، بما في ذلك جميع الأعمال الميكانيكية والكهربائية وأعمال التحكم اللازمة للإنجاز الميكانيكي والتشغيل.\n\n'
            || E'## 2. الجدول الزمني والمعالم\nيلتزم المقاول بتحقيق الإنجاز الميكانيكي لوحدة تثبيت الخام (النشاط الحرج A1340) في موعد أقصاه 30 أبريل 2026. تُدار الخطة الأساسية في Oracle Primavera P6 وتُراجَع شهرياً.\n\n'
            || E'## 3. التعويضات المقطوعة\nفي حال إخفاق المقاول في تحقيق معلَم على المسار الحرج بحلول تاريخه الأساسي، يدفع المقاول تعويضات مقطوعة بنسبة 0.5% من قيمة العقد عن كل أسبوع تأخير، بحد أقصى 10% من قيمة العقد.\n\n'
            || E'## 4. القانون الحاكم\nيخضع هذا الاتفاق للقوانين الاتحادية لدولة الإمارات العربية المتحدة كما تُطبَّق في إمارة أبوظبي.',
    updated_at = now()
  WHERE id = 77;

  -- ── 1b. Contract 243 body (Gas SPA) ────────────────────────────────────
  UPDATE contract SET
    body_en = E'# 20-Year Gas Sales and Purchase Agreement — Ruwais Fertilizers (FERTIL)\n\n'
            || E'## 1. Scope of Supply\nThe Seller shall supply natural gas to the Buyer''s Ruwais fertilizer complex in accordance with the agreed delivery nominations and the operational interface managed through the gas dispatch scheduling service.\n\n'
            || E'## 2. Service Levels\nIncidents affecting the gas dispatch scheduling service are classified by priority. Priority-2 (P2) incidents shall be resolved within eight (8) hours of being logged. Incident records are maintained in ServiceNow ITSM and reviewed monthly with the Buyer.\n\n'
            || E'## 3. Service Credits\nWhere the Seller fails to meet a service-level target, the Buyer is entitled to service credits calculated on the duration of the breach, applied against the following invoice.\n\n'
            || E'## 4. Governing Law\nThis Agreement is governed by the federal laws of the United Arab Emirates as applied in the Emirate of Abu Dhabi.',
    body_ar = E'# اتفاقية بيع وشراء الغاز لمدة 20 عاماً — أسمدة الرويس (فيرتيل)\n\n'
            || E'## 1. نطاق التوريد\nيقوم البائع بتوريد الغاز الطبيعي إلى مجمع الأسمدة في الرويس وفقاً لإخطارات التسليم المتفق عليها والواجهة التشغيلية المُدارة عبر خدمة جدولة توزيع الغاز.\n\n'
            || E'## 2. مستويات الخدمة\nتُصنَّف الحوادث التي تؤثر على خدمة جدولة توزيع الغاز حسب الأولوية. يجب حل حوادث الأولوية الثانية (P2) خلال ثماني (8) ساعات من تسجيلها. تُحفظ سجلات الحوادث في ServiceNow وتُراجَع شهرياً مع المشتري.\n\n'
            || E'## 3. ائتمانات الخدمة\nعند إخفاق البائع في تحقيق مستوى الخدمة المستهدف، يحق للمشتري الحصول على ائتمانات خدمة تُحتسب على مدة الإخلال وتُطبَّق على الفاتورة التالية.\n\n'
            || E'## 4. القانون الحاكم\nيخضع هذا الاتفاق للقوانين الاتحادية لدولة الإمارات العربية المتحدة كما تُطبَّق في إمارة أبوظبي.',
    updated_at = now()
  WHERE id = 243;

  -- ── 2a. Milestone obligation for contract 77 (the "promise") ───────────
  IF NOT EXISTS (SELECT 1 FROM contract_obligation
                  WHERE contract_id = 77 AND title_en = 'Mechanical Completion — Crude Stabilization Unit') THEN
    INSERT INTO contract_obligation (
      contract_id, title_en, title_ar, description_en, description_ar,
      obligation_type, due_date, recurrence, responsible_party, status,
      is_seed, created_by, updated_by, is_active, data_classification
    ) VALUES (
      77, 'Mechanical Completion — Crude Stabilization Unit',
      'الإنجاز الميكانيكي — وحدة تثبيت الخام',
      'Critical-path activity A1340: Mechanical Completion due 30 April 2026. Delay attracts liquidated damages of 0.5% of Contract Value per week (cap 10%) per §3.',
      'النشاط الحرج A1340: الإنجاز الميكانيكي مستحق في 30 أبريل 2026. يترتب على التأخير تعويضات مقطوعة 0.5% من قيمة العقد أسبوعياً (بحد أقصى 10%).',
      'delivery', DATE '2026-04-30', 'once', 'counterparty', 'overdue',
      TRUE, 1, 1, TRUE, 'demo'
    ) RETURNING id INTO v_ob_77;
  ELSE
    SELECT id INTO v_ob_77 FROM contract_obligation
      WHERE contract_id = 77 AND title_en = 'Mechanical Completion — Crude Stabilization Unit' LIMIT 1;
  END IF;

  -- ── 2b. SLA obligation for contract 243 ─────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM contract_obligation
                  WHERE contract_id = 243 AND title_en = 'Incident Resolution SLA (P2 ≤ 8h)') THEN
    INSERT INTO contract_obligation (
      contract_id, title_en, title_ar, description_en, description_ar,
      obligation_type, recurrence, responsible_party, status,
      is_seed, created_by, updated_by, is_active, data_classification
    ) VALUES (
      243, 'Incident Resolution SLA (P2 ≤ 8h)',
      'اتفاقية مستوى خدمة حل الحوادث (P2 ≤ 8 ساعات)',
      'Priority-2 incidents on the gas dispatch scheduling service must be resolved within 8 hours (§2). Breaches accrue service credits per §3.',
      'يجب حل حوادث الأولوية الثانية على خدمة جدولة توزيع الغاز خلال 8 ساعات. يترتب على الإخلال ائتمانات خدمة.',
      'other', 'monthly', 'counterparty', 'open',
      TRUE, 1, 1, TRUE, 'demo'
    ) RETURNING id INTO v_ob_243;
  ELSE
    SELECT id INTO v_ob_243 FROM contract_obligation
      WHERE contract_id = 243 AND title_en = 'Incident Resolution SLA (P2 ≤ 8h)' LIMIT 1;
  END IF;

  -- ── 3. Link the risk cases (44 milestone, 45 SLA) to the breached promise
  UPDATE risk_case SET metadata = COALESCE(metadata,'{}'::jsonb) || jsonb_build_object(
      'breachedObligationId', v_ob_77,
      'breachedClauseHeading', '§2 Project Schedule and Milestones',
      'breachedClauseSnippet', 'Mechanical Completion of the Crude Stabilization Unit (critical-path activity A1340) shall be achieved no later than 30 April 2026; delay on a critical-path milestone attracts liquidated damages of 0.5% of Contract Value per week, capped at 10%.'
    ), updated_at = now()
   WHERE id = 44 AND tenant_id = v_tenant;

  UPDATE risk_case SET metadata = COALESCE(metadata,'{}'::jsonb) || jsonb_build_object(
      'breachedObligationId', v_ob_243,
      'breachedClauseHeading', '§2 Service Levels',
      'breachedClauseSnippet', 'Priority-2 incidents affecting the gas dispatch scheduling service shall be resolved within eight (8) hours of being logged; breaches accrue service credits.'
    ), updated_at = now()
   WHERE id = 45 AND tenant_id = v_tenant;
END $$;

-- ── 4. fn_risk_case_get_by_id — add breachedObligation block ────────────────
--    Verbatim from mig 694 + the 'breachedObligation' key (the contract "promise"
--    resolved from metadata.breachedObligationId, paired with the clause heading +
--    snippet). NULL when the case has no linked obligation.
CREATE OR REPLACE FUNCTION public.fn_risk_case_get_by_id(
  p_actor_id bigint,
  p_id       bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_case        RECORD;
  v_caller_role TEXT;
  v_vis_map     JSONB;
  v_full_access BOOLEAN := FALSE;
  v_visible     BOOLEAN := FALSE;
  v_risk_type   TEXT;
BEGIN
  SELECT * INTO v_case FROM risk_case WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;
  SELECT value INTO v_vis_map FROM system_setting WHERE key = 'risk_case_visibility_map';
  v_full_access := v_caller_role IN ('platform_admin','Super Admin','executive');

  v_visible := v_full_access
    OR v_case.assigned_role = v_caller_role
    OR v_case.assigned_user_id = p_actor_id
    OR (v_vis_map IS NOT NULL AND v_vis_map ? v_caller_role AND (
         (v_vis_map -> v_caller_role) ? '*'
         OR (v_vis_map -> v_caller_role) ? v_case.case_type
       ));
  IF NOT v_visible THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  v_risk_type := COALESCE(NULLIF(v_case.metadata->>'riskType',''),
                          fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                           v_case.title, v_case.assigned_role, v_case.case_type));

  RETURN jsonb_build_object(
    'riskCase', jsonb_build_object(
      'id', v_case.id,
      'tenantId', v_case.tenant_id,
      'correlationId', v_case.correlation_id,
      'contractId', v_case.contract_id,
      'caseType', v_case.case_type,
      'riskType', v_risk_type,
      'riskOrigin', fn_risk_origin(
                      (SELECT os.kind FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                        WHERE co.id = v_case.correlation_id),
                      v_risk_type, v_case.case_type
                    ),
      'isEscalated', COALESCE((v_case.metadata->>'escalated')::boolean, false),
      'priority', v_case.priority,
      'title', v_case.title,
      'body', v_case.body,
      'assignedRole', v_case.assigned_role,
      'assignedRoleDisplay', CASE v_case.assigned_role
                                WHEN 'compliance_esg'             THEN 'Compliance & ESG'
                                WHEN 'legal_counsel'              THEN 'Legal Counsel'
                                WHEN 'finance_treasury'           THEN 'Finance & Treasury'
                                WHEN 'procurement_supplier_risk'  THEN 'Procurement & Supplier Risk'
                                WHEN 'operations'                 THEN 'Operations'
                                WHEN 'platform_admin'             THEN 'Platform Admin'
                                WHEN 'contract_drafter'           THEN 'Contract Drafter'
                                WHEN 'contract_approver'          THEN 'Contract Approver'
                                WHEN 'contract_approver_2'        THEN 'Contract Approver (Stage 2)'
                                WHEN 'contract_recipient'         THEN 'Contract Recipient'
                                WHEN 'executive'                  THEN 'Executive'
                                WHEN 'Super Admin'                THEN 'Super Admin'
                                ELSE                                  COALESCE(v_case.assigned_role, '—')
                              END,
      'assignedUserId', v_case.assigned_user_id,
      'assignedUserName', (
        SELECT (u.first_name || ' ' || u.last_name)
          FROM "user" u WHERE u.id = v_case.assigned_user_id
      ),
      'status', v_case.status,
      'slaHours', v_case.sla_hours,
      'dueAt', v_case.due_at,
      'snoozedUntil', v_case.snoozed_until,
      'closedAt', v_case.closed_at,
      'closedBy', v_case.closed_by,
      'closureOutcome', v_case.closure_outcome,
      'dedupeKey', v_case.dedupe_key,
      'metadata', v_case.metadata,
      'dataClassification', v_case.data_classification,
      'createdAt', v_case.created_at,
      'updatedAt', v_case.updated_at,
      'createdBy', v_case.created_by,
      'updatedBy', v_case.updated_by,
      'isActive', v_case.is_active
    ),
    'timeline', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', e.id,
               'eventType', e.event_type,
               'actorId', e.actor_id,
               'actorName', NULLIF(TRIM(COALESCE(au.first_name,'') || ' ' || COALESCE(au.last_name,'')), ''),
               'payload', e.payload,
               'occurredAt', e.occurred_at
             ) ORDER BY e.occurred_at ASC)
        FROM risk_case_event e
        LEFT JOIN "user" au ON au.id = e.actor_id
        WHERE e.risk_case_id = v_case.id
    ), '[]'::jsonb),
    'attachments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'fileName', a.file_name,
               'fileMime', a.file_mime,
               'fileBytes', a.file_bytes,
               'uploadedBy', a.uploaded_by,
               'uploadedByName', NULLIF(TRIM(COALESCE(uu.first_name,'') || ' ' || COALESCE(uu.last_name,'')), ''),
               'uploadedAt', a.uploaded_at
             ) ORDER BY a.uploaded_at DESC)
        FROM risk_case_attachment a
        LEFT JOIN "user" uu ON uu.id = a.uploaded_by
        WHERE a.risk_case_id = v_case.id AND a.is_active = TRUE
    ), '[]'::jsonb),
    'linkedCorrelation', (
      SELECT jsonb_build_object('id', c.id, 'ruleId', c.rule_id, 'confidence', c.confidence,
                                'matchReason', c.match_reason, 'status', c.status)
        FROM correlation c WHERE c.id = v_case.correlation_id
    ),
    'linkedContract', (
      SELECT jsonb_build_object(
               'id', c.id,
               'titleEn', c.title_en,
               'titleAr', c.title_ar,
               'title', c.title_en,
               'status', c.status,
               'contractNumber', c.contract_number
             )
        FROM contract c WHERE c.id = v_case.contract_id
    ),
    'counterparty', (
      SELECT jsonb_build_object(
               'id',                    p.id,
               'nameEn',                p.name_en,
               'nameAr',                p.name_ar,
               'partyType',             p.party_type,
               'country',               p.country,
               'emirate',               p.emirate,
               'isVerified',            p.is_verified,
               'sanctionsStatus',       p.sanctions_status,
               'sanctionsLastChecked',  p.sanctions_last_checked,
               'sanctionsMatchSignalId',p.sanctions_match_signal_id,
               'icvStatus',             p.icv_status,
               'icvPct',                p.icv_pct,
               'esgScore',              p.esg_score,
               'parentId',              p.parent_id,
               'parentName',            pp.name_en,
               'aliases',               COALESCE(p.aliases, '[]'::jsonb)
             )
        FROM contract c
        JOIN party p   ON p.id  = c.counterparty_id
        LEFT JOIN party pp ON pp.id = p.parent_id
       WHERE c.id = v_case.contract_id
    ),
    'sourceSystemRecord', (
      SELECT jsonb_build_object(
               'systemCode',     iss.system_code,
               'systemName',     iss.display_name,
               'systemKind',     iss.kind,
               'recordRef',      os.source_record_ref,
               'recordUrl',      os.url,
               'capturedAt',     os.fetched_at,
               'signalSubtype',  os.signal_kind_subtype,
               'snapshot',       os.source_record_snapshot
             )
        FROM correlation co
        JOIN osint_signal os ON os.id = co.signal_id AND os.kind = 'internal'
        LEFT JOIN internal_system_source iss ON iss.id = os.internal_system_id
       WHERE co.id = v_case.correlation_id
    ),
    -- 696 — the breached contract obligation (the "promise") paired with the
    -- clause it derives from, so the detail can show expected vs actual.
    'breachedObligation', (
      CASE WHEN v_case.metadata ? 'breachedObligationId' THEN (
        SELECT jsonb_build_object(
                 'id',               o.id,
                 'titleEn',          o.title_en,
                 'titleAr',          o.title_ar,
                 'descriptionEn',    o.description_en,
                 'descriptionAr',    o.description_ar,
                 'obligationType',   o.obligation_type,
                 'dueDate',          o.due_date,
                 'status',           o.status,
                 'responsibleParty', o.responsible_party,
                 'clauseHeading',    v_case.metadata->>'breachedClauseHeading',
                 'clauseSnippet',    v_case.metadata->>'breachedClauseSnippet'
               )
          FROM contract_obligation o
         WHERE o.id = NULLIF(v_case.metadata->>'breachedObligationId','')::bigint
           AND o.is_active = TRUE
      ) ELSE NULL END
    ),
    'linkedAdvisoryDrafts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', d.id, 'approvalStatus', d.approval_status,
                                          'templateId', d.template_id, 'createdAt', d.created_at))
        FROM advisory_draft d
       WHERE d.correlation_id = v_case.correlation_id
         AND v_case.correlation_id IS NOT NULL
         AND d.is_active = TRUE
    ), '[]'::jsonb),
    'slaCountdownSeconds',
      CASE WHEN v_case.due_at IS NOT NULL
           AND v_case.status NOT IN ('closed','approved','rejected','accept_risk')
           THEN EXTRACT(EPOCH FROM (v_case.due_at - fn_demo_now()))::INTEGER
           ELSE NULL END
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (696, 'contract bodies + obligations for 77/243 + risk breachedObligation link', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
