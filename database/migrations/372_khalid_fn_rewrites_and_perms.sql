-- Migration: 372_khalid_fn_rewrites_and_perms.sql
-- Unit: Khalid Compliance QA Phase 3.6 (2026-05-31)
-- Fixes K20 / K31 / K34 / K35 / K36
--
-- K20  — Cascade detail H1 stays English ("Federal Decree-Law No. 9 of 2024")
--        in AR mode. Backfill regulatory_cascade_run.regulation_ref_ar so
--        the FE can render the Arabic title when actor language is AR.
--        ALSO add the column if it doesn't exist.
-- K31  — Khalid (compliance_esg role) gets 403 on /api/v1/regulatory-updates
--        because the route auth gate is `regulations.read` which was not
--        granted to compliance_esg. Grant regulations.read to compliance_esg.
-- K34  — fn_risk_case_get_by_id returns `assignedRole` as raw enum slug
--        (compliance_esg). Add `assignedRoleDisplay` field humanized at the
--        BE layer so the FE doesn't need to humanize on every render.
--        (Defensive: the FE will also wrap in humanizeLabel — this is
--        belt-and-suspenders so logs/API consumers see the human form.)
-- K35  — fn_risk_case_get_by_id doesn't return assignedUserName (only
--        the by-id form lacks it; the list form already has it). Rewrite
--        the fn body to add `assignedUserName` = first_name || ' ' || last_name.
-- K36  — fn_risk_case_get_by_id returns linkedContract.titleEn / titleAr
--        but the FE accesses linkedContract.title — so the cell renders
--        empty. Add a `title` field that prefers titleEn (FE can still
--        choose isAr ? titleAr : titleEn for full bilingual support).
--
-- K5 (partial date filter) is a known design limitation logged as 🟠 in the
-- audit but not changing fn behavior here (would require windowing all KPIs
-- which is a bigger architectural change). FE will surface a caption
-- noting which KPI honors the window — handled in the FE cluster.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── K31 — Grant regulations.read to compliance_esg ──────────────────────────
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'compliance_esg'
   AND p.code = 'regulations.read'
   AND r.is_active = TRUE
   AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ── K20 — Add regulation_ref_ar column to regulatory_cascade_run + backfill ──
ALTER TABLE regulatory_cascade_run
  ADD COLUMN IF NOT EXISTS regulation_ref_ar TEXT;

COMMENT ON COLUMN regulatory_cascade_run.regulation_ref_ar IS
  'Arabic translation of regulation_ref for cascade detail H1 in AR mode (K20).';

UPDATE regulatory_cascade_run
   SET regulation_ref_ar = CASE
         WHEN regulation_ref ILIKE '%Decree-Law%9%2024%'              THEN 'المرسوم بقانون اتحادي رقم 9 لسنة 2024'
         WHEN regulation_ref ILIKE '%FDL%9%2024%'                     THEN 'المرسوم بقانون اتحادي رقم 9 لسنة 2024'
         WHEN regulation_ref ILIKE '%Cabinet Resolution 14/2024%'     THEN 'قرار مجلس الوزراء رقم 14 لسنة 2024 — تقارير ضغط المياه (ESG)'
         WHEN regulation_ref ILIKE '%Emiratisation%'                  THEN 'قرار التوطين'
         ELSE                                                              regulation_ref
       END,
       updated_at = NOW(),
       updated_by = 1
 WHERE regulation_ref_ar IS NULL OR regulation_ref_ar = '';

-- ── K34 / K35 / K36 — rewrite fn_risk_case_get_by_id RETURN block ───────────
-- Read the prior fn body (mig 259) and re-emit it with 3 new fields:
--   • riskCase.assignedRoleDisplay  (humanised)
--   • riskCase.assignedUserName     (first + last name from "user")
--   • linkedContract.title          (= titleEn, defensive shim for FE that
--                                     reads .title not .titleEn)
-- Body verbatim from 259 except RETURN block.
CREATE OR REPLACE FUNCTION fn_risk_case_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case          risk_case%ROWTYPE;
  v_caller_role   TEXT;
  v_vis_map       JSONB;
  v_visible       BOOLEAN := FALSE;
BEGIN
  IF NOT fn_current_user_has_permission('risk.case.read') THEN
    RAISE EXCEPTION 'permission_denied: risk.case.read required' USING ERRCODE = '42501';
  END IF;

  IF p_actor_id IS NULL OR p_id IS NULL THEN
    RAISE EXCEPTION 'invalid_input' USING ERRCODE = '22023';
  END IF;

  SELECT rc.* INTO v_case
    FROM risk_case rc
   WHERE rc.id = p_id
     AND rc.is_active = TRUE
     AND rc.tenant_id = current_setting('app.current_tenant_id', true)::uuid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;

  SELECT setting_value INTO v_vis_map
    FROM system_setting WHERE setting_key = 'risk_case.visibility_by_role' AND is_active = TRUE;

  v_visible := (v_caller_role IN ('Super Admin','platform_admin')
       OR v_case.assigned_role = v_caller_role
       OR v_case.assigned_user_id = p_actor_id
       OR v_case.created_by = p_actor_id
       OR (v_vis_map IS NOT NULL AND v_vis_map ? v_caller_role AND
           (v_vis_map -> v_caller_role) IS NOT NULL AND
           jsonb_typeof(v_vis_map -> v_caller_role) = 'array' AND
           v_case.case_type IS NOT NULL AND
           (v_vis_map -> v_caller_role) ? v_case.case_type
       ));
  IF NOT v_visible THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'riskCase', jsonb_build_object(
      'id', v_case.id,
      'tenantId', v_case.tenant_id,
      'correlationId', v_case.correlation_id,
      'contractId', v_case.contract_id,
      'caseType', v_case.case_type,
      'priority', v_case.priority,
      'title', v_case.title,
      'body', v_case.body,
      'assignedRole', v_case.assigned_role,
      -- K34: humanised role label so the FE doesn't show the raw enum.
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
      -- K35: assigned user's display name, derived from "user" table.
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
               'payload', e.payload,
               'occurredAt', e.occurred_at
             ) ORDER BY e.occurred_at ASC)
        FROM risk_case_event e WHERE e.risk_case_id = v_case.id
    ), '[]'::jsonb),
    'attachments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'fileName', a.file_name,
               'fileMime', a.file_mime,
               'fileBytes', a.file_bytes,
               'uploadedBy', a.uploaded_by,
               'uploadedAt', a.uploaded_at
             ) ORDER BY a.uploaded_at DESC)
        FROM risk_case_attachment a WHERE a.risk_case_id = v_case.id AND a.is_active = TRUE
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
               -- K36: FE reads linkedContract.title — provide it
               -- (= titleEn for default render).
               'title', c.title_en,
               'status', c.status,
               'contractNumber', c.contract_number
             )
        FROM contract c WHERE c.id = v_case.contract_id
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
      CASE WHEN v_case.due_at IS NOT NULL AND v_case.status NOT IN ('closed','approved','rejected','accept_risk')
           THEN EXTRACT(EPOCH FROM (v_case.due_at - fn_demo_now()))::INTEGER
           ELSE NULL END
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) IS
  'Full risk case detail (K34/K35/K36 patch: adds assignedRoleDisplay + assignedUserName + linkedContract.title shim). Returns timeline / attachments / linkedCorrelation / linkedContract / linkedAdvisoryDrafts / slaCountdownSeconds.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) TO neondb_owner;

COMMIT;

-- ============================================================
-- Record migration version
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (372, '372_khalid_fn_rewrites_and_perms', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission
--   WHERE role_id = (SELECT id FROM role WHERE name='compliance_esg')
--     AND permission_id = (SELECT id FROM permission WHERE code='regulations.read');
-- ALTER TABLE regulatory_cascade_run DROP COLUMN IF EXISTS regulation_ref_ar;
-- (Re-apply migration 259 body for fn_risk_case_get_by_id to roll back.)
-- DELETE FROM schema_migrations WHERE version = 372;
