-- ============================================================================
-- 017_m1c_import_functions.sql — M1c fn_ functions + fn_contract_list rewrite
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import)
-- Owner:     DB Implementation Agent (Agent 6) — applies Agent 4 design verbatim
-- Depends:   016_m1c_import_batch.sql (import_batch table); M0 fn_user_get_by_id,
--            fn_current_user_has_permission; M1a fn_contract_list (15-param
--            signature about to be replaced).
-- ----------------------------------------------------------------------------
-- This migration deploys:
--   1. DROP fn_contract_list (15-param signature, fully qualified) IF EXISTS.
--      Postgres CREATE OR REPLACE FUNCTION cannot change a function's parameter
--      list — so the param-list extension requires DROP + CREATE. Idempotent.
--   2. CREATE fn_contract_list (18-param signature) — adds 3 new optional
--      params (p_import_batch_id, p_import_confidence_min,
--      p_import_confidence_max) and 3 new ContractListItem fields
--      (importBatchId, importConfidence, importWarnings). All M1a behaviour
--      preserved verbatim when new params are NULL.
--   3. CREATE OR REPLACE fn_import_batch_create / fn_import_batch_update
--      / fn_import_batch_list / fn_import_batch_get_by_id.
-- ----------------------------------------------------------------------------
-- Conventions:
--   - All fn_'s use SET search_path = public, pg_temp (M0 hardening pattern).
--   - SECURITY INVOKER for all 5 (no privilege escalation needed; RLS enforces
--     row visibility).
--   - STABLE marker on read fn_'s.
--   - Field-prefixed exception messages: 'fn_<name>: <field>:<message>'.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. DROP fn_contract_list (15-param) — fully qualified to target M1a only
-- ============================================================================

DROP FUNCTION IF EXISTS public.fn_contract_list(
  integer, integer, text, text, bigint, bigint, bigint,
  date, date, date, date, text[], text, bigint, text
);

-- ============================================================================
-- 2. CREATE fn_contract_list (18-param) — M1c additive extension (AE-1)
-- ============================================================================

CREATE FUNCTION fn_contract_list(
  p_page                    INTEGER       DEFAULT 1,
  p_limit                   INTEGER       DEFAULT 20,
  p_status                  TEXT          DEFAULT NULL,
  p_contract_type           TEXT          DEFAULT NULL,
  p_counterparty_id         BIGINT        DEFAULT NULL,
  p_drafted_by              BIGINT        DEFAULT NULL,
  p_approved_by             BIGINT        DEFAULT NULL,
  p_start_date_from         DATE          DEFAULT NULL,
  p_start_date_to           DATE          DEFAULT NULL,
  p_end_date_from           DATE          DEFAULT NULL,
  p_end_date_to             DATE          DEFAULT NULL,
  p_tags                    TEXT[]        DEFAULT NULL,
  p_search                  TEXT          DEFAULT NULL,
  p_actor_id                BIGINT        DEFAULT NULL,
  p_actor_role              TEXT          DEFAULT NULL,
  p_import_batch_id         BIGINT        DEFAULT NULL,
  p_import_confidence_min   INTEGER       DEFAULT NULL,
  p_import_confidence_max   INTEGER       DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
  v_role_can_see_all BOOLEAN;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive');

  SELECT COUNT(*) INTO v_total
    FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status IS NULL          OR c.status = p_status)
      AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
      AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
      AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR (
            lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
      -- M1c additive filters (additive-only — NULL preserves M1a semantics)
      AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
      AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
      AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id));

  SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data
    FROM (
      SELECT jsonb_build_object(
        'id', c.id,
        'contractNumber', c.contract_number,
        'titleEn', c.title_en,
        'titleAr', c.title_ar,
        'contractType', c.contract_type,
        'status', c.status,
        'valueAed', c.value_aed,
        'currency', c.currency,
        'startDate', c.start_date,
        'endDate', c.end_date,
        'counterpartyId', c.counterparty_id,
        'ourPartyId', c.our_party_id,
        'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag)
                           FROM contract_tag ct
                           WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
        'currentVersion', c.current_version,
        'createdAt', c.created_at,
        'updatedAt', c.updated_at,
        -- M1c additive fields (always present; null when no import_batch attached)
        'importBatchId',    c.import_batch_id,
        'importConfidence', c.import_confidence,
        'importWarnings',   c.import_warnings
      ) AS row_to_payload
        FROM contract c
        WHERE c.is_active = TRUE
          AND (p_status IS NULL          OR c.status = p_status)
          AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
          AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
          AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
          AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
          AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
          AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
          AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
          AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
          AND (p_search IS NULL OR (
                lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (
                    SELECT 1 FROM contract_tag ct
                      WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                  )) = array_length(p_tags, 1)))
          AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
          AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
          AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id
             OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id
             OR c.created_by  = p_actor_id))
        ORDER BY c.created_at DESC, c.end_date ASC NULLS LAST
        LIMIT p_limit OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page', p_page,
      'limit', p_limit,
      'totalPages', CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_list IS
  'M1a list extended by M1c (AE-1). 18-param signature; 19-field ContractListItem. '
  'M1c added 3 optional params (p_import_batch_id, p_import_confidence_min, '
  'p_import_confidence_max) and 3 row fields (importBatchId, importConfidence, '
  'importWarnings). M1a behaviour preserved verbatim when new params are NULL. '
  'Replaces former 15-param signature via DROP + CREATE (Postgres CREATE OR '
  'REPLACE cannot change parameter list).';

-- ============================================================================
-- 3. fn_import_batch_create
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_import_batch_create(
  p_data     JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id            BIGINT;
  v_total_files   INTEGER;
  v_status_mode   TEXT;
  v_contract_type TEXT;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('import.run') THEN
    RAISE EXCEPTION 'fn_import_batch_create: %', 'permission:Forbidden';
  END IF;

  -- 2. totalFiles >= 1
  v_total_files := NULLIF(p_data->>'totalFiles','')::INTEGER;
  IF v_total_files IS NULL OR v_total_files < 1 THEN
    RAISE EXCEPTION 'fn_import_batch_create: %', 'totalFiles:totalFiles must be at least 1';
  END IF;

  -- 3. config.statusMode (when present) IN ('active','draft','auto')
  IF p_data ? 'config' AND (p_data->'config') ? 'statusMode' THEN
    v_status_mode := p_data->'config'->>'statusMode';
    IF v_status_mode NOT IN ('active','draft','auto') THEN
      RAISE EXCEPTION 'fn_import_batch_create: %', 'config.statusMode:Invalid statusMode';
    END IF;
  END IF;

  -- 4. config.contractType (when present) IN M1a contract_type enum
  --    Hardcoded list cross-references M1a migration 003.
  IF p_data ? 'config' AND (p_data->'config') ? 'contractType' THEN
    v_contract_type := p_data->'config'->>'contractType';
    IF v_contract_type NOT IN (
      'service','employment','vendor','partnership',
      'lease','license','nda','other'
    ) THEN
      RAISE EXCEPTION 'fn_import_batch_create: %', 'config.contractType:Invalid contractType';
    END IF;
  END IF;

  -- 5. INSERT
  INSERT INTO import_batch (
    initiated_by, config, total_files, status, started_at,
    created_by, updated_by
  ) VALUES (
    p_actor_id,
    COALESCE(p_data->'config', '{}'::jsonb),
    v_total_files,
    'in_progress',
    CURRENT_TIMESTAMP,
    p_actor_id,
    p_actor_id
  ) RETURNING id INTO v_id;

  RETURN fn_import_batch_get_by_id(v_id, p_actor_id);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_import_batch_create: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_import_batch_create: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_import_batch_create(JSONB, BIGINT) IS
  'M1c S1 entry point. SECURITY INVOKER. Validates totalFiles >= 1 + config.statusMode + '
  'config.contractType. INSERTs row at status=in_progress; returns full shape via '
  'fn_import_batch_get_by_id. Field-prefixed exception messages map to BE { field, message }.';

-- ============================================================================
-- 4. fn_import_batch_update — Codex BE-001 SELECT FOR UPDATE pattern
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_import_batch_update(
  p_id                          BIGINT,
  p_actor_id                    BIGINT,
  p_status                      TEXT     DEFAULT NULL,
  p_auto_saved_delta            INTEGER  DEFAULT 0,
  p_review_queue_delta          INTEGER  DEFAULT 0,
  p_manual_entry_delta          INTEGER  DEFAULT 0,
  p_duplicates_skipped_delta    INTEGER  DEFAULT 0,
  p_errored_delta               INTEGER  DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row           import_batch%ROWTYPE;
  v_new_auto      INTEGER;
  v_new_review    INTEGER;
  v_new_manual    INTEGER;
  v_new_dup       INTEGER;
  v_new_err       INTEGER;
  v_new_status    TEXT;
  v_completed_at  TIMESTAMPTZ;
BEGIN
  -- 1. Lock the row (Codex BE-001) — serialises concurrent counter updates
  SELECT * INTO v_row
    FROM import_batch
    WHERE id = p_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', '404:Import batch not found';
  END IF;

  -- 2. Permission gate (defense in depth — RLS also enforces)
  IF NOT fn_current_user_has_permission('import.run')
     AND v_row.initiated_by IS DISTINCT FROM p_actor_id THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'permission:Forbidden';
  END IF;

  -- 3. Compute new counter values
  v_new_auto    := v_row.auto_saved          + COALESCE(p_auto_saved_delta, 0);
  v_new_review  := v_row.review_queue        + COALESCE(p_review_queue_delta, 0);
  v_new_manual  := v_row.manual_entry        + COALESCE(p_manual_entry_delta, 0);
  v_new_dup     := v_row.duplicates_skipped  + COALESCE(p_duplicates_skipped_delta, 0);
  v_new_err     := v_row.errored             + COALESCE(p_errored_delta, 0);

  -- 4. Underflow guards (AC-S2-04). Field name maps to the failing counter.
  IF v_new_auto   < 0 THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'autoSaved:Counter underflow';
  END IF;
  IF v_new_review < 0 THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'reviewQueue:Counter underflow';
  END IF;
  IF v_new_manual < 0 THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'manualEntry:Counter underflow';
  END IF;
  IF v_new_dup    < 0 THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'duplicatesSkipped:Counter underflow';
  END IF;
  IF v_new_err    < 0 THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'errored:Counter underflow';
  END IF;

  -- 5. Overflow guard (AC-S2-05)
  IF v_new_auto + v_new_review + v_new_manual + v_new_dup + v_new_err > v_row.total_files THEN
    RAISE EXCEPTION 'fn_import_batch_update: %', 'counters:Counter overflow vs totalFiles';
  END IF;

  -- 6. Status transition validation (AC-S2-02 / AC-S2-08)
  v_new_status := COALESCE(p_status, v_row.status);
  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_row.status THEN
    IF v_row.status = 'in_progress' AND p_status NOT IN ('paused','completed','cancelled') THEN
      RAISE EXCEPTION 'fn_import_batch_update: %', 'status:Invalid status transition';
    ELSIF v_row.status = 'paused' AND p_status NOT IN ('in_progress','completed','cancelled') THEN
      RAISE EXCEPTION 'fn_import_batch_update: %', 'status:Invalid status transition';
    ELSIF v_row.status IN ('completed','cancelled') THEN
      -- Terminal states cannot transition (AC-S2-08 reopen-from-terminal -> 409)
      RAISE EXCEPTION 'fn_import_batch_update: %', 'status:Invalid status transition';
    END IF;
  END IF;

  -- 7. completed_at: set when transitioning INTO terminal; preserve otherwise.
  v_completed_at := CASE
    WHEN p_status IN ('completed','cancelled')
         AND v_row.status NOT IN ('completed','cancelled')
      THEN CURRENT_TIMESTAMP
    ELSE v_row.completed_at
  END;

  -- 8. UPDATE
  UPDATE import_batch SET
    auto_saved         = v_new_auto,
    review_queue       = v_new_review,
    manual_entry       = v_new_manual,
    duplicates_skipped = v_new_dup,
    errored            = v_new_err,
    status             = v_new_status,
    completed_at       = v_completed_at,
    updated_by         = p_actor_id,
    updated_at         = CURRENT_TIMESTAMP
  WHERE id = p_id;

  RETURN fn_import_batch_get_by_id(p_id, p_actor_id);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_import_batch_update: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_import_batch_update: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_import_batch_update(BIGINT, BIGINT, TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) IS
  'M1c S2 counter + status transition. SECURITY INVOKER. Codex BE-001 SELECT FOR UPDATE on '
  'the batch row serialises concurrent counter writes. Validates underflow / overflow / '
  'allowed transitions (in_progress<->paused, in_progress|paused -> completed|cancelled). '
  'Terminal states (completed, cancelled) cannot transition out (AC-S2-08). completed_at '
  'set on terminal transition. Field-prefixed exception messages.';

-- ============================================================================
-- 5. fn_import_batch_list — paginated + role-aware
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_import_batch_list(
  p_page             INTEGER   DEFAULT 1,
  p_limit            INTEGER   DEFAULT 20,
  p_status           TEXT      DEFAULT NULL,
  p_initiated_by     BIGINT    DEFAULT NULL,
  p_actor_id         BIGINT    DEFAULT NULL,
  p_actor_role       TEXT      DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset            INTEGER;
  v_total             BIGINT;
  v_data              JSONB;
  v_role_can_see_all  BOOLEAN;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_import_batch_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_import_batch_list: %', 'limit:Limit must be between 1 and 100';
  END IF;

  v_offset := (p_page - 1) * p_limit;
  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive', 'Super Admin');

  SELECT COUNT(*) INTO v_total
    FROM import_batch b
    WHERE b.is_active = TRUE
      AND (p_status IS NULL          OR b.status = p_status)
      AND (p_initiated_by IS NULL    OR b.initiated_by = p_initiated_by)
      AND (v_role_can_see_all OR b.initiated_by = p_actor_id);

  SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data
    FROM (
      SELECT jsonb_build_object(
        'id',                 b.id,
        'initiatedBy',        b.initiated_by,
        'totalFiles',         b.total_files,
        'autoSaved',          b.auto_saved,
        'reviewQueue',        b.review_queue,
        'manualEntry',        b.manual_entry,
        'duplicatesSkipped',  b.duplicates_skipped,
        'errored',            b.errored,
        'status',             b.status,
        'config',             b.config,
        'startedAt',          b.started_at,
        'completedAt',        b.completed_at
      ) AS row_to_payload
        FROM import_batch b
        WHERE b.is_active = TRUE
          AND (p_status IS NULL          OR b.status = p_status)
          AND (p_initiated_by IS NULL    OR b.initiated_by = p_initiated_by)
          AND (v_role_can_see_all OR b.initiated_by = p_actor_id)
        ORDER BY b.started_at DESC, b.id DESC
        LIMIT p_limit OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       p_page,
      'limit',      p_limit,
      'totalPages', CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_import_batch_list: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_import_batch_list: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_import_batch_list(INTEGER, INTEGER, TEXT, BIGINT, BIGINT, TEXT) IS
  'M1c S3 admin list. SECURITY INVOKER STABLE. Pagination 1..100 enforced. ORDER BY '
  'started_at DESC, id DESC. Role narrowing: platform_admin / legal_counsel / executive / '
  'Super Admin see all; everyone else (e.g. contract_drafter) sees only their own batches '
  'via initiated_by = p_actor_id (defense-in-depth: also enforced by RLS '
  'import_batch_select_role_aware). totalPages = 0 when total = 0 (M1a 007 patch precedent).';

-- ============================================================================
-- 6. fn_import_batch_get_by_id — UserRef hydration on initiatedBy
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_import_batch_get_by_id(
  p_id           BIGINT,
  p_actor_id     BIGINT     DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row        import_batch%ROWTYPE;
  v_initiator  JSONB;
BEGIN
  SELECT * INTO v_row
    FROM import_batch
    WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN NULL;  -- BE controller maps NULL -> 404
  END IF;

  -- UserRef hydration via M0 helper (M1a precedent)
  v_initiator := fn_user_get_by_id(v_row.initiated_by);

  RETURN jsonb_build_object(
    'id',                 v_row.id,
    'initiatedBy',        CASE
      WHEN v_initiator IS NULL THEN to_jsonb(v_row.initiated_by)  -- fall back to bigint
      ELSE jsonb_build_object(
        'id',        (v_initiator->>'id')::BIGINT,
        'firstName', v_initiator->>'firstName',
        'lastName',  v_initiator->>'lastName'
      )
    END,
    'config',             v_row.config,
    'totalFiles',         v_row.total_files,
    'autoSaved',          v_row.auto_saved,
    'reviewQueue',        v_row.review_queue,
    'manualEntry',        v_row.manual_entry,
    'duplicatesSkipped',  v_row.duplicates_skipped,
    'errored',            v_row.errored,
    'status',             v_row.status,
    'startedAt',          v_row.started_at,
    'completedAt',        v_row.completed_at,
    'createdAt',          v_row.created_at,
    'updatedAt',          v_row.updated_at
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_import_batch_get_by_id: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_import_batch_get_by_id: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_import_batch_get_by_id(BIGINT, BIGINT) IS
  'M1c S4 admin drill-down. SECURITY INVOKER STABLE. Returns full batch shape with '
  'initiatedBy hydrated as UserRef { id, firstName, lastName } via M0 fn_user_get_by_id. '
  'Returns NULL when row not found OR is_active=FALSE OR not visible to caller (RLS-filtered). '
  'BE controller maps NULL -> HTTP 404.';

-- ============================================================================
-- 7. Record migration
-- ============================================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (17, 'm1c_import_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 017_m1c_import_functions.sql
-- ============================================================================
-- Restores M1a 15-param fn_contract_list signature (canonical body from
-- migration 007 + Codex BE-002 changes are in 008 — the 15-param body was
-- last touched at 007 / 008; here we restore the 007 body since 008 only
-- changed fn_contract_create + fn_contract_update + fn_contract_set_tags,
-- not fn_contract_list). Drops all four M1c fn_'s.
-- ROLLBACK BEGIN
BEGIN;

  DROP FUNCTION IF EXISTS fn_import_batch_get_by_id(BIGINT, BIGINT);
  DROP FUNCTION IF EXISTS fn_import_batch_list(INTEGER, INTEGER, TEXT, BIGINT, BIGINT, TEXT);
  DROP FUNCTION IF EXISTS fn_import_batch_update(BIGINT, BIGINT, TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER);
  DROP FUNCTION IF EXISTS fn_import_batch_create(JSONB, BIGINT);

  -- Drop M1c 18-param fn_contract_list and restore M1a 15-param canonical body
  DROP FUNCTION IF EXISTS public.fn_contract_list(
    integer, integer, text, text, bigint, bigint, bigint,
    date, date, date, date, text[], text, bigint, text,
    bigint, integer, integer
  );

  CREATE OR REPLACE FUNCTION fn_contract_list(
    p_page              INTEGER       DEFAULT 1,
    p_limit             INTEGER       DEFAULT 20,
    p_status            TEXT          DEFAULT NULL,
    p_contract_type     TEXT          DEFAULT NULL,
    p_counterparty_id   BIGINT        DEFAULT NULL,
    p_drafted_by        BIGINT        DEFAULT NULL,
    p_approved_by       BIGINT        DEFAULT NULL,
    p_start_date_from   DATE          DEFAULT NULL,
    p_start_date_to     DATE          DEFAULT NULL,
    p_end_date_from     DATE          DEFAULT NULL,
    p_end_date_to       DATE          DEFAULT NULL,
    p_tags              TEXT[]        DEFAULT NULL,
    p_search            TEXT          DEFAULT NULL,
    p_actor_id          BIGINT        DEFAULT NULL,
    p_actor_role        TEXT          DEFAULT NULL
  ) RETURNS JSONB
  LANGUAGE plpgsql
  SECURITY INVOKER
  STABLE
  SET search_path = public, pg_temp
  AS $body$
  DECLARE
    v_offset    INTEGER;
    v_total     BIGINT;
    v_data      JSONB;
    v_role_can_see_all BOOLEAN;
  BEGIN
    IF p_page < 1 THEN
      RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
    END IF;
    IF p_limit NOT BETWEEN 1 AND 100 THEN
      RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
    END IF;

    v_offset := (p_page - 1) * p_limit;
    v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive');

    SELECT COUNT(*) INTO v_total
      FROM contract c
      WHERE c.is_active = TRUE
        AND (p_status IS NULL          OR c.status = p_status)
        AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
        AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
        AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
        AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
        AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
        AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
        AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
        AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
        AND (p_search IS NULL OR (
              lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
           OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
           OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
        AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
              (SELECT COUNT(*) FROM unnest(p_tags) tg
                WHERE EXISTS (
                  SELECT 1 FROM contract_tag ct
                    WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                )) = array_length(p_tags, 1)))
        AND (v_role_can_see_all OR (
              c.drafted_by  = p_actor_id
           OR c.reviewed_by = p_actor_id
           OR c.approved_by = p_actor_id
           OR c.created_by  = p_actor_id));

    SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data
      FROM (
        SELECT jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'contractType', c.contract_type,
          'status', c.status,
          'valueAed', c.value_aed,
          'currency', c.currency,
          'startDate', c.start_date,
          'endDate', c.end_date,
          'counterpartyId', c.counterparty_id,
          'ourPartyId', c.our_party_id,
          'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag)
                             FROM contract_tag ct
                             WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
          'currentVersion', c.current_version,
          'createdAt', c.created_at,
          'updatedAt', c.updated_at
        ) AS row_to_payload
          FROM contract c
          WHERE c.is_active = TRUE
            AND (p_status IS NULL          OR c.status = p_status)
            AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
            AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
            AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
            AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
            AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
            AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
            AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
            AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
            AND (p_search IS NULL OR (
                  lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
               OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
               OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
            AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                  (SELECT COUNT(*) FROM unnest(p_tags) tg
                    WHERE EXISTS (
                      SELECT 1 FROM contract_tag ct
                        WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                    )) = array_length(p_tags, 1)))
            AND (v_role_can_see_all OR (
                  c.drafted_by  = p_actor_id
               OR c.reviewed_by = p_actor_id
               OR c.approved_by = p_actor_id
               OR c.created_by  = p_actor_id))
          ORDER BY c.created_at DESC, c.end_date ASC NULLS LAST
          LIMIT p_limit OFFSET v_offset
      ) sub;

    RETURN jsonb_build_object(
      'data', v_data,
      'pagination', jsonb_build_object(
        'total', v_total,
        'page', p_page,
        'limit', p_limit,
        'totalPages', CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
      )
    );
  END;
  $body$;

  DELETE FROM schema_migrations WHERE version = 17;
COMMIT;
-- ROLLBACK END
