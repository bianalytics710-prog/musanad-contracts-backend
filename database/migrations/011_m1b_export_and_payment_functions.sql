-- ============================================================================
-- 011_m1b_export_and_payment_functions.sql — M1b 5 fn_'s in dependency order
-- ============================================================================
-- Module:    M1b
-- Depends:   009 (payment_schedule), 010 (CMW-1 extended enum), M1a fn_contract_activity_create
-- ----------------------------------------------------------------------------
-- 1. fn_audit_log_record           — SECURITY DEFINER helper (XLSX list export audit)
-- 2. fn_payment_schedule_list      — SECURITY INVOKER STABLE
-- 3. fn_payment_schedule_create_bulk — SECURITY INVOKER (parent FOR UPDATE)
-- 4. fn_contract_export_pdf        — SECURITY INVOKER (NOT STABLE — emits activity)
-- 5. fn_contract_export_xlsx       — SECURITY INVOKER STABLE (no activity emit)
-- ----------------------------------------------------------------------------

BEGIN;

-- 1. fn_audit_log_record (SECURITY DEFINER helper)
CREATE OR REPLACE FUNCTION fn_audit_log_record(
  p_table_name TEXT,
  p_record_id  BIGINT,
  p_action     TEXT,
  p_new_values JSONB,
  p_actor_id   BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id    BIGINT;
  v_actor BIGINT;
BEGIN
  IF p_action NOT IN ('INSERT','UPDATE','DELETE') THEN
    RAISE EXCEPTION 'fn_audit_log_record: %', 'action:Invalid action value';
  END IF;
  v_actor := COALESCE(p_actor_id, NULLIF(current_setting('app.current_user_id', true), '')::BIGINT);
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (p_table_name, p_record_id, p_action, NULL, p_new_values, v_actor, CURRENT_TIMESTAMP)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id);
END;
$$;
REVOKE ALL ON FUNCTION fn_audit_log_record(TEXT,BIGINT,TEXT,JSONB,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_log_record(TEXT,BIGINT,TEXT,JSONB,BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_audit_log_record(TEXT,BIGINT,TEXT,JSONB,BIGINT) IS
  'M1b internal helper. SECURITY DEFINER. Bypasses audit_log RLS deny-direct-INSERT for cross-cutting events without a source-table trigger (e.g., XLSX list export). p_action stays in the M0 audit_log.action CHECK enum (INSERT/UPDATE/DELETE) — list-export uses INSERT with new_values discriminator (event=EXPORT) per W4.';

-- 2. fn_payment_schedule_list (SECURITY INVOKER STABLE)
CREATE OR REPLACE FUNCTION fn_payment_schedule_list(
  p_contract_id BIGINT,
  p_actor_id    BIGINT,
  p_actor_role  TEXT DEFAULT NULL,
  p_status      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_parent contract%ROWTYPE;
  v_data   JSONB;
BEGIN
  SELECT * INTO v_parent FROM contract WHERE id = p_contract_id;
  IF NOT FOUND OR v_parent.is_active = FALSE THEN
    RETURN NULL;
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('pending','due','paid','overdue','waived','cancelled') THEN
    RAISE EXCEPTION 'fn_payment_schedule_list: %', 'status:Invalid status value';
  END IF;
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', ps.id, 'contractId', ps.contract_id,
      'milestoneLabelEn', ps.milestone_label_en, 'milestoneLabelAr', ps.milestone_label_ar,
      'milestoneNameEn', ps.milestone_name_en,   'milestoneNameAr', ps.milestone_name_ar,
      'amountAed', ps.amount_aed, 'dueDate', ps.due_date, 'paidAt', ps.paid_at,
      'status', ps.status, 'recurrence', ps.recurrence, 'invoiceRef', ps.invoice_ref,
      'createdAt', ps.created_at, 'updatedAt', ps.updated_at
    ) ORDER BY ps.due_date ASC NULLS LAST, ps.id ASC
  ), '[]'::JSONB) INTO v_data
    FROM payment_schedule ps
    WHERE ps.contract_id = p_contract_id
      AND ps.is_active = TRUE
      AND (p_status IS NULL OR ps.status = p_status);
  RETURN jsonb_build_object('data', v_data);
END;
$$;
COMMENT ON FUNCTION fn_payment_schedule_list IS 'M1b read. Returns active milestone list ordered by due_date ASC NULLS LAST, then id ASC. NULL when parent contract not visible (controller → 404).';

-- 3. fn_payment_schedule_create_bulk (SECURITY INVOKER, parent FOR UPDATE)
CREATE OR REPLACE FUNCTION fn_payment_schedule_create_bulk(
  p_contract_id      BIGINT,
  p_rows             JSONB,
  p_replace_existing BOOLEAN DEFAULT FALSE,
  p_actor_id         BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_parent       contract%ROWTYPE;
  v_row          JSONB;
  v_idx          INTEGER := 0;
  v_inserted     INTEGER := 0;
  v_soft_deleted INTEGER := 0;
  v_status       TEXT;
  v_recurrence   TEXT;
  v_label_en     TEXT;
  v_amount       NUMERIC(15,2);
  v_inserted_ids BIGINT[] := ARRAY[]::BIGINT[];
  v_new_id       BIGINT;
  v_rows_out     JSONB;
BEGIN
  -- 1. Input validation
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %', 'rows:rows must be a non-empty array';
  END IF;
  IF jsonb_array_length(p_rows) > 100 THEN
    RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %', 'rows:Maximum 100 milestones per batch';
  END IF;

  -- 2. TOCTOU defense — SELECT FOR UPDATE on parent contract head row
  --    (Codex BE-001 lesson + AC-S3-11)
  SELECT * INTO v_parent FROM contract WHERE id = p_contract_id FOR UPDATE;
  IF NOT FOUND OR v_parent.is_active = FALSE THEN
    RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %', 'id:Contract not found';
  END IF;

  -- 3. Per-row validation
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_label_en := trim(BOTH FROM COALESCE(v_row->>'milestoneLabelEn', ''));
    IF v_label_en = '' OR char_length(v_label_en) > 255 THEN
      RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %',
        format('rows[%s].milestoneLabelEn:Milestone label is required', v_idx);
    END IF;
    BEGIN
      v_amount := (v_row->>'amountAed')::NUMERIC(15,2);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %',
        format('rows[%s].amountAed:Amount must be greater than or equal to zero', v_idx);
    END;
    IF v_amount IS NULL OR v_amount < 0 THEN
      RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %',
        format('rows[%s].amountAed:Amount must be greater than or equal to zero', v_idx);
    END IF;
    IF v_row ? 'status' AND v_row->>'status' IS NOT NULL THEN
      v_status := v_row->>'status';
      IF v_status NOT IN ('pending','due','paid','overdue','waived','cancelled') THEN
        RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %',
          format('rows[%s].status:Invalid status value', v_idx);
      END IF;
    END IF;
    IF v_row ? 'recurrence' AND v_row->>'recurrence' IS NOT NULL THEN
      v_recurrence := v_row->>'recurrence';
      IF v_recurrence NOT IN ('once','monthly','quarterly','annually') THEN
        RAISE EXCEPTION 'fn_payment_schedule_create_bulk: %',
          format('rows[%s].recurrence:Invalid recurrence value', v_idx);
      END IF;
    END IF;
    v_idx := v_idx + 1;
  END LOOP;

  -- 4. Replace path
  IF p_replace_existing = TRUE THEN
    WITH soft_deleted AS (
      UPDATE payment_schedule
        SET is_active = FALSE, updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
        WHERE contract_id = p_contract_id AND is_active = TRUE
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_soft_deleted FROM soft_deleted;
  END IF;

  -- 5. Insert loop
  v_idx := 0;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    INSERT INTO payment_schedule (
      contract_id, milestone_label_en, milestone_label_ar,
      milestone_name_en, milestone_name_ar,
      amount_aed, due_date, paid_at, status, recurrence, invoice_ref,
      created_by, updated_by
    ) VALUES (
      p_contract_id,
      trim(BOTH FROM v_row->>'milestoneLabelEn'),
      NULLIF(trim(BOTH FROM COALESCE(v_row->>'milestoneLabelAr','')), ''),
      NULLIF(trim(BOTH FROM COALESCE(v_row->>'milestoneNameEn','')),  ''),
      NULLIF(trim(BOTH FROM COALESCE(v_row->>'milestoneNameAr','')),  ''),
      (v_row->>'amountAed')::NUMERIC(15,2),
      NULLIF(v_row->>'dueDate','')::DATE,
      NULLIF(v_row->>'paidAt','')::TIMESTAMPTZ,
      COALESCE(v_row->>'status','pending'),
      NULLIF(v_row->>'recurrence',''),
      NULLIF(v_row->>'invoiceRef',''),
      p_actor_id, p_actor_id
    )
    RETURNING id INTO v_new_id;
    v_inserted_ids := array_append(v_inserted_ids, v_new_id);
    v_idx := v_idx + 1;
  END LOOP;
  v_inserted := v_idx;

  -- 6. Activity emission on replace path only (AC-S3-10)
  IF p_replace_existing = TRUE THEN
    PERFORM fn_contract_activity_create(
      p_contract_id    => p_contract_id,
      p_activity_type  => 'payment_schedule_replaced',
      p_actor_id       => p_actor_id,
      p_description_en => format('Replaced payment schedule (%s inserted, %s soft-deleted)', v_inserted, v_soft_deleted),
      p_description_ar => NULL,
      p_metadata       => jsonb_build_object('insertedCount', v_inserted, 'softDeletedCount', v_soft_deleted)
    );
  END IF;

  -- 7. Build return rows
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', ps.id, 'contractId', ps.contract_id,
      'milestoneLabelEn', ps.milestone_label_en, 'milestoneLabelAr', ps.milestone_label_ar,
      'milestoneNameEn', ps.milestone_name_en,   'milestoneNameAr', ps.milestone_name_ar,
      'amountAed', ps.amount_aed, 'dueDate', ps.due_date, 'paidAt', ps.paid_at,
      'status', ps.status, 'recurrence', ps.recurrence, 'invoiceRef', ps.invoice_ref,
      'createdAt', ps.created_at, 'updatedAt', ps.updated_at
    ) ORDER BY ps.id ASC
  ), '[]'::JSONB) INTO v_rows_out
    FROM payment_schedule ps WHERE ps.id = ANY(v_inserted_ids);

  RETURN jsonb_build_object(
    'contractId',  p_contract_id,
    'inserted',    v_inserted,
    'softDeleted', v_soft_deleted,
    'rows',        v_rows_out
  );
END;
$$;
COMMENT ON FUNCTION fn_payment_schedule_create_bulk IS
  'M1b write. SECURITY INVOKER. Atomic bulk insert (or replace-existing) of payment_schedule rows for a contract. Codex BE-001 hardening: parent contract head row is locked via SELECT FOR UPDATE before any read or write so concurrent fn_contract_delete and concurrent bulk-replace serialise per contract id (AC-S3-11). Replace path emits a single ''payment_schedule_replaced'' contract_activity row via fn_contract_activity_create. Append path emits no activity. Max batch 100 rows.';

-- 4. fn_contract_export_pdf (SECURITY INVOKER — NOT STABLE due to activity emit)
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

  -- Activity emission (per Q4 PDF path) — emitted via M1a SECURITY DEFINER helper
  PERFORM fn_contract_activity_create(
    p_contract_id    => p_contract_id,
    p_activity_type  => 'exported',
    p_actor_id       => p_actor_id,
    p_description_en => format('Exported contract to PDF (language=%s)', p_language),
    p_description_ar => NULL,
    p_metadata       => jsonb_build_object('format','pdf','language',p_language,'includeAttachments',p_include_attachments)
  );

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
  'M1b read + activity-emit. SECURITY INVOKER. Returns denormalised JSONB shape for the BE Puppeteer renderer. Reads body from contract head pointer (current_version) only — NOT a specific historical version (Q5). Emits a per-contract ''exported'' contract_activity row on every successful return (Q4 PDF path). NULL when contract not found / soft-deleted / not visible (controller → 404). NOT marked STABLE because of the activity-emit side effect.';

-- 5. fn_contract_export_xlsx (SECURITY INVOKER STABLE — no activity emit)
CREATE OR REPLACE FUNCTION fn_contract_export_xlsx(
  p_actor_id         BIGINT,
  p_actor_role       TEXT    DEFAULT NULL,
  p_status           TEXT    DEFAULT NULL,
  p_contract_type    TEXT    DEFAULT NULL,
  p_counterparty_id  BIGINT  DEFAULT NULL,
  p_drafted_by       BIGINT  DEFAULT NULL,
  p_approved_by      BIGINT  DEFAULT NULL,
  p_start_date_from  DATE    DEFAULT NULL,
  p_start_date_to    DATE    DEFAULT NULL,
  p_end_date_from    DATE    DEFAULT NULL,
  p_end_date_to      DATE    DEFAULT NULL,
  p_tags             TEXT[]  DEFAULT NULL,
  p_search           TEXT    DEFAULT NULL,
  p_max_rows         INTEGER DEFAULT 10000
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_max_rows  INTEGER;
  v_total     BIGINT;
  v_rows      JSONB;
  v_truncated BOOLEAN := FALSE;
BEGIN
  IF p_max_rows IS NULL OR p_max_rows < 1 OR p_max_rows > 50000 THEN
    RAISE EXCEPTION 'fn_contract_export_xlsx: %', 'maxRows:maxRows must be between 1 and 50000';
  END IF;
  v_max_rows := LEAST(GREATEST(p_max_rows, 1), 50000);

  -- Count for truncation flag (cheap because of M1a indexes; reuses same WHERE)
  WITH filtered AS (
    SELECT c.id FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status         IS NULL OR c.status = p_status)
      AND (p_contract_type  IS NULL OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by     IS NULL OR c.drafted_by = p_drafted_by)
      AND (p_approved_by    IS NULL OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to   IS NULL OR c.start_date <= p_start_date_to)
      AND (p_end_date_from   IS NULL OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to     IS NULL OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR lower(coalesce(c.contract_number,'') || ' ' || coalesce(c.title_en,'') || ' ' || coalesce(c.title_ar,''))
                                 LIKE '%' || lower(p_search) || '%')
      AND (p_tags IS NULL OR p_tags <@ (
        SELECT COALESCE(array_agg(t.tag), ARRAY[]::TEXT[])
          FROM contract_tag t WHERE t.contract_id = c.id AND t.is_active = TRUE
      ))
  )
  SELECT COUNT(*)::BIGINT INTO v_total FROM filtered;

  IF v_total > v_max_rows THEN v_truncated := TRUE; END IF;

  -- Aggregate the row payload (capped by v_max_rows)
  WITH filtered AS (
    SELECT c.* FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status         IS NULL OR c.status = p_status)
      AND (p_contract_type  IS NULL OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by     IS NULL OR c.drafted_by = p_drafted_by)
      AND (p_approved_by    IS NULL OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to   IS NULL OR c.start_date <= p_start_date_to)
      AND (p_end_date_from   IS NULL OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to     IS NULL OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR lower(coalesce(c.contract_number,'') || ' ' || coalesce(c.title_en,'') || ' ' || coalesce(c.title_ar,''))
                                 LIKE '%' || lower(p_search) || '%')
      AND (p_tags IS NULL OR p_tags <@ (
        SELECT COALESCE(array_agg(t.tag), ARRAY[]::TEXT[])
          FROM contract_tag t WHERE t.contract_id = c.id AND t.is_active = TRUE
      ))
    ORDER BY c.created_at DESC, c.id DESC
    LIMIT v_max_rows
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', f.id, 'contractNumber', f.contract_number,
      'titleEn', f.title_en, 'titleAr', f.title_ar,
      'contractType', f.contract_type, 'status', f.status,
      'valueAed', f.value_aed, 'currency', f.currency,
      'startDate', f.start_date, 'endDate', f.end_date,
      'counterpartyId', f.counterparty_id, 'ourPartyId', f.our_party_id,
      'tagsCsv', (SELECT string_agg(t.tag, ', ' ORDER BY t.tag) FROM contract_tag t
                    WHERE t.contract_id = f.id AND t.is_active = TRUE),
      'currentVersion', f.current_version,
      'createdAt', f.created_at, 'updatedAt', f.updated_at
    ) ORDER BY f.created_at DESC, f.id DESC
  ), '[]'::JSONB) INTO v_rows
    FROM filtered f;

  RETURN jsonb_build_object(
    'rows',          v_rows,
    'totalRows',     LEAST(v_total, v_max_rows),
    'truncated',     v_truncated,
    'filterApplied', jsonb_build_object(
      'status', p_status, 'contractType', p_contract_type,
      'counterpartyId', p_counterparty_id, 'draftedBy', p_drafted_by, 'approvedBy', p_approved_by,
      'startDateFrom', p_start_date_from, 'startDateTo', p_start_date_to,
      'endDateFrom',   p_end_date_from,   'endDateTo',   p_end_date_to,
      'tags', to_jsonb(p_tags), 'search', p_search, 'maxRows', v_max_rows
    ),
    'generatedAt',   CURRENT_TIMESTAMP
  );
END;
$$;
COMMENT ON FUNCTION fn_contract_export_xlsx IS
  'M1b read. SECURITY INVOKER STABLE. Returns flat list payload for BE exceljs streaming. Filter semantics IDENTICAL to M1a fn_contract_list (M1b duplicates the WHERE rather than refactoring; if a third copy emerges, refactor then). Hard cap p_max_rows ∈ [1,50000]; sets truncated=true when filter yields more rows. NO activity emission — list-level audit is the BE controller''s responsibility via fn_audit_log_record.';

-- Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (11, 'm1b_export_and_payment_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 011_m1b_export_and_payment_functions.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  DROP FUNCTION IF EXISTS fn_contract_export_xlsx(BIGINT,TEXT,TEXT,TEXT,BIGINT,BIGINT,BIGINT,DATE,DATE,DATE,DATE,TEXT[],TEXT,INTEGER);
  DROP FUNCTION IF EXISTS fn_contract_export_pdf(BIGINT,BIGINT,TEXT,TEXT,BOOLEAN);
  DROP FUNCTION IF EXISTS fn_payment_schedule_create_bulk(BIGINT,JSONB,BOOLEAN,BIGINT);
  DROP FUNCTION IF EXISTS fn_payment_schedule_list(BIGINT,BIGINT,TEXT,TEXT);
  REVOKE ALL ON FUNCTION fn_audit_log_record(TEXT,BIGINT,TEXT,JSONB,BIGINT) FROM neondb_owner;
  DROP FUNCTION IF EXISTS fn_audit_log_record(TEXT,BIGINT,TEXT,JSONB,BIGINT);
  DELETE FROM schema_migrations WHERE version = 11;
COMMIT;
-- ROLLBACK END
