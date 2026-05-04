-- ============================================================================
-- 022_m1c_extend_fn_contract_get_by_id_projection.sql
--   M1c Codex BE round-1 follow-up: extend fn_contract_get_by_id JSONB
--   projection with the 4 import-trace fields so single-get and list endpoints
--   are symmetric.
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import) — Codex BE round-1 patch (Finding H1)
-- Owner:     DB Implementation Agent (Agent 6, bug-fix mode — cycle 3)
-- Depends:   001..021. Targets fn_contract_get_by_id last redefined in 005
--            (M1a). M1c migration 020 extended fn_contract_create to persist
--            the 4 fields; 017 extended fn_contract_list to project them.
--            This migration closes the symmetry gap on the single-get path.
-- ----------------------------------------------------------------------------
-- Why this migration exists (Codex BE round-1, finding H1 — HIGH):
--
-- M1c migrations 019 + 020 extended fn_contract_create to persist:
--    • importBatchId    → contract.import_batch_id
--    • importFilename   → contract.import_filename
--    • importConfidence → contract.import_confidence
--    • importWarnings   → contract.import_warnings
--
-- M1c migration 017 extended fn_contract_list to surface 3 of these
-- (importBatchId, importConfidence, importWarnings) in each ContractListItem.
--
-- But fn_contract_get_by_id (M1a migration 005) was never extended. The
-- single-get endpoint GET /api/v1/contracts/:id therefore returns a contract
-- payload that does NOT include import metadata, while GET /api/v1/contracts
-- (list) does. AC-S5-08 round-trip is asymmetric: a contract created with
-- import fields can be listed with them but cannot be re-fetched with them
-- by id.
--
-- This migration extends fn_contract_get_by_id (signature unchanged) to
-- project the same 4 import fields in camelCase, matching the convention used
-- by fn_contract_list. The list shape includes 3 fields (no importFilename —
-- list rows are deliberately lightweight); the single-get includes all 4.
--
-- Defaults: when the underlying column is NULL, the JSONB key value is null
-- (not omitted). Consumers expect the 4 keys to always be present per the
-- backward-compat additive pattern.
-- ----------------------------------------------------------------------------
-- Method: CREATE OR REPLACE FUNCTION (signature unchanged — atomic, no DROP).
-- ============================================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_get_by_id — extend JSONB projection with 4 import fields
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_get_by_id(
  p_id          BIGINT,
  p_actor_id    BIGINT,
  p_actor_role  TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row              contract%ROWTYPE;
  v_drafter          JSONB;
  v_reviewer         JSONB;
  v_approver         JSONB;
  v_tags             JSONB;
  v_attachment_count INTEGER := 0;
  v_comment_count    INTEGER := 0;
BEGIN
  SELECT * INTO v_row FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_drafter
    FROM "user" u WHERE u.id = v_row.drafted_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_reviewer
    FROM "user" u WHERE u.id = v_row.reviewed_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_approver
    FROM "user" u WHERE u.id = v_row.approved_by;

  SELECT COALESCE(jsonb_agg(tag ORDER BY tag), '[]'::JSONB) INTO v_tags
    FROM contract_tag
    WHERE contract_id = p_id AND is_active = TRUE;

  IF to_regclass('public.contract_attachment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_attachment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_attachment_count
      USING p_id;
  END IF;
  IF to_regclass('public.contract_comment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_comment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_comment_count
      USING p_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'contractNumber', v_row.contract_number,
    'titleEn', v_row.title_en,
    'titleAr', v_row.title_ar,
    'contractType', v_row.contract_type,
    'templateId', v_row.template_id,
    'status', v_row.status,
    'language', v_row.language,
    'ourPartyId', v_row.our_party_id,
    'counterpartyId', v_row.counterparty_id,
    'valueAed', v_row.value_aed,
    'currency', v_row.currency,
    'startDate', v_row.start_date,
    'endDate', v_row.end_date,
    'signedAt', v_row.signed_at,
    'expiryNoticeDays', v_row.expiry_notice_days,
    'emirate', v_row.emirate,
    'governingLaw', v_row.governing_law,
    'jurisdictionCourt', v_row.jurisdiction_court,
    'parentContractId', v_row.parent_contract_id,
    'relationshipType', v_row.relationship_type,
    'bodyEn', v_row.body_en,
    'bodyAr', v_row.body_ar,
    'currentVersion', v_row.current_version,
    'draftedBy', v_drafter,
    'reviewedBy', v_reviewer,
    'approvedBy', v_approver,
    'tags', v_tags,
    'attachmentCount', v_attachment_count,
    'commentCount', v_comment_count,
    -- M1c extension (Codex BE round-1, finding H1) — symmetry with
    -- fn_contract_list import-trace fields. Keys always present; values are
    -- null when the underlying column is null (non-imported contracts).
    'importBatchId',    v_row.import_batch_id,
    'importFilename',   v_row.import_filename,
    'importConfidence', v_row.import_confidence,
    'importWarnings',   v_row.import_warnings,
    'createdAt', v_row.created_at,
    'updatedAt', v_row.updated_at
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_get_by_id(BIGINT, BIGINT, TEXT) IS
  'M1a single get; M1c-extended (migration 022, Codex BE round-1 finding H1) '
  'to project 4 import-trace fields (importBatchId, importFilename, '
  'importConfidence, importWarnings) in camelCase. SECURITY INVOKER. Returns '
  'NULL when row missing or is_active=false (controller maps to 404). Actor '
  'enrichment via inline JOIN to "user". attachmentCount/commentCount '
  'tolerate the contract_attachment/contract_comment tables not yet existing '
  '(to_regclass guard). Round-trip symmetry with fn_contract_list and '
  'fn_contract_create.';

-- ============================================================
-- 2. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (22, 'm1c_extend_fn_contract_get_by_id_projection', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 022_m1c_extend_fn_contract_get_by_id_projection.sql
-- ============================================================================
-- Restores the M1a-005 fn_contract_get_by_id projection (without the 4
-- import-trace fields). Run this manually if 022 must be reversed; the AC-
-- S5-08 round-trip asymmetry returns afterwards.
-- ROLLBACK BEGIN
BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_get_by_id(
  p_id          BIGINT,
  p_actor_id    BIGINT,
  p_actor_role  TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row              contract%ROWTYPE;
  v_drafter          JSONB;
  v_reviewer         JSONB;
  v_approver         JSONB;
  v_tags             JSONB;
  v_attachment_count INTEGER := 0;
  v_comment_count    INTEGER := 0;
BEGIN
  SELECT * INTO v_row FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_drafter
    FROM "user" u WHERE u.id = v_row.drafted_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_reviewer
    FROM "user" u WHERE u.id = v_row.reviewed_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_approver
    FROM "user" u WHERE u.id = v_row.approved_by;

  SELECT COALESCE(jsonb_agg(tag ORDER BY tag), '[]'::JSONB) INTO v_tags
    FROM contract_tag
    WHERE contract_id = p_id AND is_active = TRUE;

  IF to_regclass('public.contract_attachment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_attachment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_attachment_count
      USING p_id;
  END IF;
  IF to_regclass('public.contract_comment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_comment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_comment_count
      USING p_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'contractNumber', v_row.contract_number,
    'titleEn', v_row.title_en,
    'titleAr', v_row.title_ar,
    'contractType', v_row.contract_type,
    'templateId', v_row.template_id,
    'status', v_row.status,
    'language', v_row.language,
    'ourPartyId', v_row.our_party_id,
    'counterpartyId', v_row.counterparty_id,
    'valueAed', v_row.value_aed,
    'currency', v_row.currency,
    'startDate', v_row.start_date,
    'endDate', v_row.end_date,
    'signedAt', v_row.signed_at,
    'expiryNoticeDays', v_row.expiry_notice_days,
    'emirate', v_row.emirate,
    'governingLaw', v_row.governing_law,
    'jurisdictionCourt', v_row.jurisdiction_court,
    'parentContractId', v_row.parent_contract_id,
    'relationshipType', v_row.relationship_type,
    'bodyEn', v_row.body_en,
    'bodyAr', v_row.body_ar,
    'currentVersion', v_row.current_version,
    'draftedBy', v_drafter,
    'reviewedBy', v_reviewer,
    'approvedBy', v_approver,
    'tags', v_tags,
    'attachmentCount', v_attachment_count,
    'commentCount', v_comment_count,
    'createdAt', v_row.created_at,
    'updatedAt', v_row.updated_at
  );
END;
$$;

DELETE FROM schema_migrations WHERE version = 22;
COMMIT;
-- ROLLBACK END
