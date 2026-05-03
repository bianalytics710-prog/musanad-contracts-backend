-- ============================================================================
-- 015_m1b_export_pdf_strip_activity_emit.sql — Codex BE-M1b-004
-- ============================================================================
-- Module:    M1b (post-Codex round-1 fix)
-- Depends:   011 (fn_contract_export_pdf), 013 (extended whitelist), 014
-- ----------------------------------------------------------------------------
-- Codex flagged that fn_contract_export_pdf (v from 011) emits its
-- contract_activity('exported') row INSIDE the function — i.e. BEFORE
-- the BE Puppeteer renderer succeeds. If the render throws, the activity
-- row commits while no file is delivered.
--
-- Fix: turn fn_contract_export_pdf into a thin data-shape function with
-- NO side effect (matches fn_contract_export_xlsx pattern). The controller
-- now emits the activity AFTER renderContractPdf resolves successfully via
-- fn_contract_activity_create.
--
-- The function body below is identical to 011 except the
--   PERFORM fn_contract_activity_create(...)
-- block has been removed and the COMMENT updated.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_export_pdf(
  p_contract_id         BIGINT,
  p_actor_id            BIGINT,
  p_actor_role          TEXT    DEFAULT NULL,
  p_language            TEXT    DEFAULT 'bilingual',
  p_include_attachments BOOLEAN DEFAULT FALSE
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
  v_payment_schedule JSONB;
  v_contract_json    JSONB;
BEGIN
  IF p_language NOT IN ('en','ar','bilingual') THEN
    RAISE EXCEPTION 'fn_contract_export_pdf: %', 'language:Invalid language value';
  END IF;
  SELECT * INTO v_row FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_drafter  FROM "user" u WHERE u.id = v_row.drafted_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_reviewer FROM "user" u WHERE u.id = v_row.reviewed_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_approver FROM "user" u WHERE u.id = v_row.approved_by;

  SELECT COALESCE(jsonb_agg(tag ORDER BY tag), '[]'::JSONB) INTO v_tags
    FROM contract_tag WHERE contract_id = p_contract_id AND is_active = TRUE;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', ps.id, 'contractId', ps.contract_id,
      'milestoneLabelEn', ps.milestone_label_en, 'milestoneLabelAr', ps.milestone_label_ar,
      'milestoneNameEn', ps.milestone_name_en,   'milestoneNameAr', ps.milestone_name_ar,
      'amountAed', ps.amount_aed, 'dueDate', ps.due_date, 'paidAt', ps.paid_at,
      'status', ps.status, 'recurrence', ps.recurrence, 'invoiceRef', ps.invoice_ref
    ) ORDER BY ps.due_date ASC NULLS LAST, ps.id ASC
  ), '[]'::JSONB) INTO v_payment_schedule
    FROM payment_schedule ps WHERE ps.contract_id = p_contract_id AND ps.is_active = TRUE;

  v_contract_json := jsonb_build_object(
    'id', v_row.id, 'contractNumber', v_row.contract_number,
    'titleEn', v_row.title_en, 'titleAr', v_row.title_ar,
    'contractType', v_row.contract_type, 'language', v_row.language,
    'valueAed', v_row.value_aed, 'currency', v_row.currency,
    'startDate', v_row.start_date, 'endDate', v_row.end_date,
    'signedAt', v_row.signed_at, 'emirate', v_row.emirate,
    'governingLaw', v_row.governing_law, 'jurisdictionCourt', v_row.jurisdiction_court,
    'status', v_row.status, 'currentVersion', v_row.current_version,
    'draftedBy', v_drafter, 'reviewedBy', v_reviewer, 'approvedBy', v_approver,
    'bodyEn', v_row.body_en, 'bodyAr', v_row.body_ar,
    'createdAt', v_row.created_at
  );

  -- Codex BE-M1b-004 fix: NO activity emission here. Controller emits
  -- via fn_contract_activity_create AFTER the Puppeteer render resolves.
  -- This prevents activity rows for un-delivered exports.
  RETURN jsonb_build_object(
    'contract',        v_contract_json,
    'tags',            v_tags,
    'paymentSchedule', v_payment_schedule,
    'ourParty',        NULL,    -- TODO[parties-module]
    'counterparty',    NULL,    -- TODO[parties-module]
    'attachments',     NULL,    -- TODO[attachments-module]
    'exportLanguage',  p_language,
    'generatedAt',     CURRENT_TIMESTAMP
  );
END;
$$;
COMMENT ON FUNCTION fn_contract_export_pdf IS
  'M1b read. SECURITY INVOKER STABLE. Returns denormalised JSONB shape for the BE Puppeteer renderer. Reads body from contract head pointer (current_version) only — NOT a specific historical version (Q5). Codex BE-M1b-004 fix: NO activity emission inside the function — controller emits via fn_contract_activity_create AFTER successful render so undelivered exports never produce activity rows. NULL when contract not found / soft-deleted / not visible (controller → 404).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (15, 'm1b_export_pdf_strip_activity_emit', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 015_m1b_export_pdf_strip_activity_emit.sql
-- ============================================================================
-- Restoring the activity-emitting variant from migration 011. NB: rolling
-- back this fn change without reverting the controller change creates a
-- duplicate-emit (function emits + controller emits) — coordinate.
-- ROLLBACK BEGIN
BEGIN;
  CREATE OR REPLACE FUNCTION fn_contract_export_pdf(
    p_contract_id         BIGINT,
    p_actor_id            BIGINT,
    p_actor_role          TEXT    DEFAULT NULL,
    p_language            TEXT    DEFAULT 'bilingual',
    p_include_attachments BOOLEAN DEFAULT FALSE
  ) RETURNS JSONB
  LANGUAGE plpgsql
  SECURITY INVOKER
  SET search_path = public, pg_temp
  AS $body$
  DECLARE
    v_row              contract%ROWTYPE;
    v_drafter          JSONB;
    v_reviewer         JSONB;
    v_approver         JSONB;
    v_tags             JSONB;
    v_payment_schedule JSONB;
    v_contract_json    JSONB;
  BEGIN
    IF p_language NOT IN ('en','ar','bilingual') THEN
      RAISE EXCEPTION 'fn_contract_export_pdf: %', 'language:Invalid language value';
    END IF;
    SELECT * INTO v_row FROM contract WHERE id = p_contract_id AND is_active = TRUE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
      INTO v_drafter  FROM "user" u WHERE u.id = v_row.drafted_by;
    SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
      INTO v_reviewer FROM "user" u WHERE u.id = v_row.reviewed_by;
    SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
      INTO v_approver FROM "user" u WHERE u.id = v_row.approved_by;
    SELECT COALESCE(jsonb_agg(tag ORDER BY tag), '[]'::JSONB) INTO v_tags
      FROM contract_tag WHERE contract_id = p_contract_id AND is_active = TRUE;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', ps.id, 'contractId', ps.contract_id,
      'milestoneLabelEn', ps.milestone_label_en, 'milestoneLabelAr', ps.milestone_label_ar,
      'milestoneNameEn', ps.milestone_name_en,   'milestoneNameAr', ps.milestone_name_ar,
      'amountAed', ps.amount_aed, 'dueDate', ps.due_date, 'paidAt', ps.paid_at,
      'status', ps.status, 'recurrence', ps.recurrence, 'invoiceRef', ps.invoice_ref
    ) ORDER BY ps.due_date ASC NULLS LAST, ps.id ASC), '[]'::JSONB) INTO v_payment_schedule
      FROM payment_schedule ps WHERE ps.contract_id = p_contract_id AND ps.is_active = TRUE;
    v_contract_json := jsonb_build_object(
      'id', v_row.id, 'contractNumber', v_row.contract_number,
      'titleEn', v_row.title_en, 'titleAr', v_row.title_ar,
      'contractType', v_row.contract_type, 'language', v_row.language,
      'valueAed', v_row.value_aed, 'currency', v_row.currency,
      'startDate', v_row.start_date, 'endDate', v_row.end_date,
      'signedAt', v_row.signed_at, 'emirate', v_row.emirate,
      'governingLaw', v_row.governing_law, 'jurisdictionCourt', v_row.jurisdiction_court,
      'status', v_row.status, 'currentVersion', v_row.current_version,
      'draftedBy', v_drafter, 'reviewedBy', v_reviewer, 'approvedBy', v_approver,
      'bodyEn', v_row.body_en, 'bodyAr', v_row.body_ar,
      'createdAt', v_row.created_at
    );
    PERFORM fn_contract_activity_create(
      p_contract_id    => p_contract_id,
      p_activity_type  => 'exported',
      p_actor_id       => p_actor_id,
      p_description_en => format('Exported contract to PDF (language=%s)', p_language),
      p_description_ar => NULL,
      p_metadata       => jsonb_build_object('format','pdf','language',p_language,'includeAttachments',p_include_attachments)
    );
    RETURN jsonb_build_object(
      'contract', v_contract_json, 'tags', v_tags, 'paymentSchedule', v_payment_schedule,
      'ourParty', NULL, 'counterparty', NULL, 'attachments', NULL,
      'exportLanguage', p_language, 'generatedAt', CURRENT_TIMESTAMP
    );
  END;
  $body$;
  DELETE FROM schema_migrations WHERE version = 15;
COMMIT;
-- ROLLBACK END
