-- Migration: 111_cra2_internal_signal_functions.sql
-- Module: M8 — Internal Signal Data Path (CR-A2)
-- Description: Create the 4 net-new fn_'s for the internal-signal data path:
--                (1) fn_internal_signal_ingest          DEFINER SYSTEM-ONLY (REVOKE-only)
--                (2) fn_internal_signal_resolve         INVOKER write (idempotent)
--                (3) fn_internal_signal_kind_list       INVOKER STABLE bare-array
--                (4) fn_internal_signal_list            INVOKER STABLE paginated
--              Every fn ends with the standard tail block: COMMENT + REVOKE FROM PUBLIC + GRANT
--              TO neondb_owner (B14 / S2-21 / S2-27). fn_internal_signal_ingest is REVOKE-only —
--              no role GRANT EXECUTE — mirroring M7 fn_osint_signal_upsert (AC-S7-05).
-- Rollback: see ROLLBACK section below.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- 1. fn_internal_signal_ingest — DEFINER SYSTEM-ONLY (REVOKE-only)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_internal_signal_ingest(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id          UUID;
  v_actor              BIGINT;
  v_kind_id            BIGINT;
  v_param_schema       JSONB;
  v_default_severity   TEXT;
  v_kind_display       VARCHAR(200);
  v_required_keys      JSONB;
  v_required_key       TEXT;
  v_signal_type        TEXT;
  v_observed_at        TEXT;
  v_severity           TEXT;
  v_dedup              TEXT;
  v_inner_payload      JSONB;
  v_inner_result       JSONB;
  v_title              TEXT;
  v_contract_id        BIGINT;
  v_vendor_id          BIGINT;
  v_data_class         TEXT;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate (defence in depth — route is JWT-gated by the same permission)
  IF NOT fn_current_user_has_permission('internal_signal.ingest') THEN
    RAISE EXCEPTION 'forbidden: internal_signal.ingest required' USING ERRCODE = '42501';
  END IF;

  -- 3. Required-field check (caller payload, NOT yet osint_signal payload)
  v_signal_type := p_payload->>'signalType';
  v_observed_at := p_payload->>'observedAt';
  IF v_signal_type IS NULL OR length(trim(v_signal_type)) = 0 THEN
    RAISE EXCEPTION 'signalType is required' USING ERRCODE = '22023';
  END IF;
  IF v_observed_at IS NULL OR length(trim(v_observed_at)) = 0 THEN
    RAISE EXCEPTION 'observedAt is required' USING ERRCODE = '22023';
  END IF;

  -- 4. Catalogue lookup
  SELECT id, parameter_schema, default_severity, display_name
    INTO v_kind_id, v_param_schema, v_default_severity, v_kind_display
  FROM internal_signal_kind
  WHERE tenant_id = v_tenant_id
    AND signal_type = v_signal_type
    AND is_active = TRUE;
  IF v_kind_id IS NULL THEN
    RAISE EXCEPTION 'Unknown internal signal type: %', v_signal_type
      USING ERRCODE = '22023';
  END IF;

  -- 5. parameter_schema.required[] enforcement
  v_required_keys := COALESCE(v_param_schema->'required', '[]'::jsonb);
  FOR v_required_key IN SELECT jsonb_array_elements_text(v_required_keys)
  LOOP
    IF NOT (p_payload ? v_required_key) THEN
      RAISE EXCEPTION 'Required field missing for signal_type=%: %', v_signal_type, v_required_key
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- 6. S2-23 FK pre-validation — contractId
  IF p_payload ? 'contractId' AND p_payload->>'contractId' IS NOT NULL THEN
    BEGIN
      v_contract_id := (p_payload->>'contractId')::BIGINT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'contractId must be a BIGINT' USING ERRCODE = '22023';
    END;
    PERFORM 1 FROM contract WHERE id = v_contract_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Contract not found' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 6b. S2-23 FK pre-validation — vendorId
  IF p_payload ? 'vendorId' AND p_payload->>'vendorId' IS NOT NULL THEN
    BEGIN
      v_vendor_id := (p_payload->>'vendorId')::BIGINT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'vendorId must be a BIGINT' USING ERRCODE = '22023';
    END;
    PERFORM 1 FROM party WHERE id = v_vendor_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Vendor not found' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 7. Compute dedup_hash (per AC-S7-01)
  v_dedup := encode(
    digest(
      'internal:harness' || '|' ||
      v_signal_type     || '|' ||
      COALESCE((p_payload->>'contractId'),
               (p_payload->>'vendorId'),
               '') || '|' ||
      (v_observed_at)::text,
      'sha256'),
    'hex');

  -- 8. Severity resolution
  v_severity := COALESCE(p_payload->>'severity', v_default_severity);
  IF v_severity NOT IN ('informational','low','medium','high','critical') THEN
    RAISE EXCEPTION 'severity must be one of informational/low/medium/high/critical'
      USING ERRCODE = '23514';
  END IF;

  -- 9. Synthesise the title — non-NULL per upsert §624
  v_title := v_kind_display || ' — ' ||
             COALESCE(
               p_payload->>'milestoneRef',
               p_payload->>'invoiceRef',
               CASE WHEN v_contract_id IS NOT NULL THEN 'contract #' || v_contract_id::text ELSE NULL END,
               CASE WHEN v_vendor_id   IS NOT NULL THEN 'vendor #'   || v_vendor_id::text   ELSE NULL END,
               'event');

  v_data_class := COALESCE(p_payload->>'dataClassification', 'demo');

  -- 10. Build the M7-contract payload (S2-19 LOCK — 9 required keys verbatim from 107 §624–651)
  v_inner_payload := jsonb_build_object(
    'sourceId',           'internal:harness',
    'sourceReliability',  1.00,
    'fetchedAt',          (now())::text,
    'kind',               'internal',
    'title',              v_title,
    'summary',            jsonb_pretty(p_payload),
    'severity',           v_severity,
    'confidence',         1.00,
    'rawPayload',         p_payload,
    'dedupHash',          v_dedup,
    'signalKindSubtype',  v_signal_type,
    'eventDate',          v_observed_at,
    'dataClassification', v_data_class
  );

  -- 11. Delegate to fn_osint_signal_upsert (DEFINER chain — runs as owner)
  v_inner_result := fn_osint_signal_upsert(v_inner_payload);

  -- 12. Return shape per design §5.1 step 11
  RETURN jsonb_build_object(
    'signalId',          v_inner_result->'id',
    'inserted',          v_inner_result->'inserted',
    'dedupHashHit',      NOT (v_inner_result->>'inserted')::boolean,
    'signalKindSubtype', v_signal_type
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Preserve original SQLSTATE so BE error translator sees the right code
    RAISE EXCEPTION 'fn_internal_signal_ingest: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_internal_signal_ingest(JSONB) IS
  'M8 — DEFINER, SYSTEM-ONLY. Translates an internal-signal payload into the M7 osint_signal contract and delegates to fn_osint_signal_upsert. Returns { signalId, inserted, dedupHashHit, signalKindSubtype }. Permission: internal_signal.ingest (defence-in-depth gate inside body).';
REVOKE EXECUTE ON FUNCTION fn_internal_signal_ingest(JSONB) FROM PUBLIC;
-- AC-S7-05 mirror: NO role grant. Only neondb_owner (OWNER) executes.


-- ============================================================
-- 2. fn_internal_signal_resolve — INVOKER write (idempotent)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_internal_signal_resolve(
  p_actor_id          BIGINT,
  p_signal_id         BIGINT,
  p_resolution_kind   TEXT,
  p_resolution_note   TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_kind           TEXT;
  v_subtype        TEXT;
  v_existing_meta  JSONB;
  v_existing_at    TIMESTAMPTZ;
  v_resolved_at    TIMESTAMPTZ;
  v_role_ok        BOOLEAN;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Validate resolution_kind
  IF p_resolution_kind NOT IN ('cleared','superseded','mitigated','false_positive') THEN
    RAISE EXCEPTION 'Invalid resolution kind' USING ERRCODE = '22023';
  END IF;

  -- 3. Fetch signal (RLS narrows by tenant; explicit predicate is defence in depth)
  SELECT kind, signal_kind_subtype, metadata
    INTO v_kind, v_subtype, v_existing_meta
  FROM osint_signal
  WHERE id = p_signal_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Signal not found' USING ERRCODE = 'P0002';
  END IF;

  -- 4. Validate kind = 'internal' (per AC-S5-04)
  IF v_kind != 'internal' THEN
    RAISE EXCEPTION 'Signal is not an internal signal' USING ERRCODE = '22023';
  END IF;

  -- 5. Q-DA3 hardcoded role mapping per signal_kind_subtype.
  --    Caller must hold internal_signal.resolve AND a role in the per-type allowlist.
  IF NOT fn_current_user_has_permission('internal_signal.resolve') THEN
    RAISE EXCEPTION 'forbidden: internal_signal.resolve required' USING ERRCODE = '42501';
  END IF;

  -- Allowlist per signal_kind_subtype (Q-DA3 lock)
  v_role_ok := EXISTS (
    SELECT 1
    FROM user_role ur
    JOIN role r ON r.id = ur.role_id
    WHERE ur.user_id = p_actor_id
      AND ur.is_active = TRUE
      AND r.is_active = TRUE
      AND r.name IN (
        'Super Admin',
        'platform_admin',
        CASE v_subtype
          WHEN 'milestone_slippage' THEN 'operations'
          WHEN 'sla_breach'         THEN 'operations'
          WHEN 'vendor_incident'    THEN 'operations'
          WHEN 'ics_incident'       THEN 'operations'
          WHEN 'payment_delay'      THEN 'finance_treasury'
          WHEN 'invoice_dispute'    THEN 'finance_treasury'
          WHEN 'icv_status_change'  THEN 'compliance_esg'
          WHEN 'certificate_expiry' THEN 'compliance_esg'
        END,
        -- secondary fallback per Q-DA3 (some subtypes have two non-admin roles)
        CASE v_subtype
          WHEN 'vendor_incident'    THEN 'procurement'
          WHEN 'ics_incident'       THEN 'procurement'
          WHEN 'icv_status_change'  THEN 'procurement'
          WHEN 'certificate_expiry' THEN 'legal_counsel'
        END
      )
  );

  IF NOT v_role_ok THEN
    RAISE EXCEPTION 'Permission denied for signal_type=%', v_subtype
      USING ERRCODE = '42501';
  END IF;

  -- 6. Idempotence — re-resolve returns current payload + skips pg_notify (AC-S5-03)
  IF v_existing_meta IS NOT NULL
     AND v_existing_meta ? 'resolvedAt'
     AND NULLIF(v_existing_meta->>'resolvedAt', '') IS NOT NULL THEN
    v_existing_at := (v_existing_meta->>'resolvedAt')::timestamptz;
    RETURN jsonb_build_object(
      'signalId',       p_signal_id,
      'resolvedAt',     v_existing_at,
      'resolvedBy',     NULLIF(v_existing_meta->>'resolvedBy','')::BIGINT,
      'resolutionKind', v_existing_meta->>'resolutionKind',
      'idempotent',     true
    );
  END IF;

  -- 7. S2-20 actor coercion (CC4 sentinel pattern)
  IF p_actor_id = 0 THEN p_actor_id := NULL; END IF;

  v_resolved_at := now();

  -- 8. UPDATE osint_signal.metadata via Q-DA6 Implementation A
  UPDATE osint_signal
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'resolvedAt',      v_resolved_at,
        'resolvedBy',      p_actor_id,
        'resolutionKind',  p_resolution_kind,
        'resolutionNote',  p_resolution_note
      )
  WHERE id = p_signal_id AND tenant_id = v_tenant_id;

  -- 9. pg_notify (only on first-resolve)
  PERFORM pg_notify(
    'internal_signal_resolved',
    jsonb_build_object(
      'signalId',          p_signal_id,
      'tenantId',          v_tenant_id,
      'signalKindSubtype', v_subtype,
      'resolutionKind',    p_resolution_kind,
      'resolvedBy',        p_actor_id,
      'resolvedAt',        v_resolved_at
    )::text
  );

  -- 10. Return
  RETURN jsonb_build_object(
    'signalId',       p_signal_id,
    'resolvedAt',     v_resolved_at,
    'resolvedBy',     p_actor_id,
    'resolutionKind', p_resolution_kind,
    'idempotent',     false
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_internal_signal_resolve: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT) IS
  'M8 — INVOKER. Resolves an internal signal by writing resolution metadata + pg_notify(internal_signal_resolved). Idempotent — re-resolve returns current payload, skips notify. Role gate per signal_type per Q-DA3 hardcoded mapping. Permission: internal_signal.resolve.';
REVOKE EXECUTE ON FUNCTION fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;


-- ============================================================
-- 3. fn_internal_signal_kind_list — INVOKER STABLE bare-array
-- ============================================================
CREATE OR REPLACE FUNCTION fn_internal_signal_kind_list(
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id  UUID;
  v_data       JSONB;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('internal_signal.read') THEN
    RAISE EXCEPTION 'forbidden: internal_signal.read required' USING ERRCODE = '42501';
  END IF;

  -- 3. Bare-array shape per fn_source_health_list precedent (107 line ~1020)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',              k.id,
      'signalType',      k.signal_type,
      'displayName',     k.display_name,
      'displayNameAr',   k.display_name_ar,
      'description',     k.description,
      'parameterSchema', k.parameter_schema,
      'defaultSeverity', k.default_severity,
      'isActive',        k.is_active,
      'createdAt',       k.created_at,
      'updatedAt',       k.updated_at
    ) ORDER BY k.signal_type ASC
  ), '[]'::jsonb) INTO v_data
  FROM internal_signal_kind k
  WHERE k.tenant_id = v_tenant_id
    AND k.is_active = TRUE;

  RETURN v_data;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_internal_signal_kind_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_internal_signal_kind_list(BIGINT) IS
  'M8 — bare-array catalogue list for the /app/admin/internal-signal-kinds viewer. Order: signal_type ASC. Permission: internal_signal.read.';
REVOKE EXECUTE ON FUNCTION fn_internal_signal_kind_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_internal_signal_kind_list(BIGINT) TO neondb_owner;


-- ============================================================
-- 4. fn_internal_signal_list — INVOKER STABLE paginated
-- ============================================================
CREATE OR REPLACE FUNCTION fn_internal_signal_list(
  p_actor_id BIGINT,
  p_filter   JSONB,
  p_page     INTEGER,
  p_limit    INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id    UUID;
  v_page         INTEGER;
  v_limit        INTEGER;
  v_offset       INTEGER;
  v_filter       JSONB;
  v_signal_type  TEXT;
  v_status       TEXT;
  v_contract_id  BIGINT;
  v_vendor_id    BIGINT;
  v_since        TIMESTAMPTZ;
  v_total        INTEGER;
  v_rows         JSONB;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('internal_signal.read') THEN
    RAISE EXCEPTION 'forbidden: internal_signal.read required' USING ERRCODE = '42501';
  END IF;

  -- 3. Pagination defaults
  v_filter := COALESCE(p_filter, '{}'::jsonb);
  v_page   := GREATEST(COALESCE(p_page, 1), 1);
  v_limit  := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
  v_offset := (v_page - 1) * v_limit;

  -- 4. Parse + validate filters
  v_signal_type := NULLIF(v_filter->>'signalType', '');
  IF v_signal_type IS NOT NULL
     AND v_signal_type NOT IN ('milestone_slippage','sla_breach','payment_delay','invoice_dispute',
                               'vendor_incident','ics_incident','icv_status_change','certificate_expiry') THEN
    RAISE EXCEPTION 'signalType must be one of milestone_slippage/sla_breach/payment_delay/invoice_dispute/vendor_incident/ics_incident/icv_status_change/certificate_expiry'
      USING ERRCODE = '22023';
  END IF;

  v_status := NULLIF(v_filter->>'status', '');
  IF v_status IS NOT NULL AND v_status NOT IN ('open','resolved') THEN
    RAISE EXCEPTION 'status must be one of open/resolved' USING ERRCODE = '22023';
  END IF;

  IF (v_filter ? 'contractId') AND NULLIF(v_filter->>'contractId','') IS NOT NULL THEN
    BEGIN
      v_contract_id := (v_filter->>'contractId')::BIGINT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'contractId must be a BIGINT' USING ERRCODE = '22023';
    END;
  END IF;

  IF (v_filter ? 'vendorId') AND NULLIF(v_filter->>'vendorId','') IS NOT NULL THEN
    BEGIN
      v_vendor_id := (v_filter->>'vendorId')::BIGINT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'vendorId must be a BIGINT' USING ERRCODE = '22023';
    END;
  END IF;

  IF (v_filter ? 'since') AND NULLIF(v_filter->>'since','') IS NOT NULL THEN
    BEGIN
      v_since := (v_filter->>'since')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'since must be an ISO timestamp' USING ERRCODE = '22023';
    END;
  END IF;

  -- 5. COUNT
  SELECT COUNT(*) INTO v_total
  FROM osint_signal s
  WHERE s.tenant_id = v_tenant_id
    AND s.kind = 'internal'
    AND s.is_active = TRUE
    AND (v_signal_type IS NULL OR s.signal_kind_subtype = v_signal_type)
    AND (v_contract_id IS NULL OR (s.raw_payload->>'contractId')::BIGINT IS NOT DISTINCT FROM v_contract_id)
    AND (v_vendor_id   IS NULL OR (s.raw_payload->>'vendorId')::BIGINT   IS NOT DISTINCT FROM v_vendor_id)
    AND (v_since       IS NULL OR s.fetched_at >= v_since)
    AND (v_status IS NULL
         OR (v_status = 'open'     AND (s.metadata IS NULL OR (s.metadata->>'resolvedAt') IS NULL))
         OR (v_status = 'resolved' AND (s.metadata->>'resolvedAt') IS NOT NULL));

  -- 6. Page rows
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                 s.id,
      'tenantId',           s.tenant_id,
      'signalType',         s.signal_kind_subtype,
      'kind',               s.kind,
      'title',              s.title,
      'summary',            s.summary,
      'severity',           s.severity_v2,
      'confidence',         s.confidence,
      'fetchedAt',          s.fetched_at,
      'eventDate',          s.event_date_v2,
      'sourceId',           s.source_id,
      'sourceReliability',  s.source_reliability,
      'rawPayload',         s.raw_payload,
      'metadata',           s.metadata,
      'resolvedAt',         NULLIF(s.metadata->>'resolvedAt','')::timestamptz,
      'resolvedBy',         NULLIF(s.metadata->>'resolvedBy','')::BIGINT,
      'resolutionKind',     s.metadata->>'resolutionKind',
      'createdAt',          s.created_at
    ) ORDER BY s.fetched_at DESC NULLS LAST, s.id DESC
  ), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT s.*
    FROM osint_signal s
    WHERE s.tenant_id = v_tenant_id
      AND s.kind = 'internal'
      AND s.is_active = TRUE
      AND (v_signal_type IS NULL OR s.signal_kind_subtype = v_signal_type)
      AND (v_contract_id IS NULL OR (s.raw_payload->>'contractId')::BIGINT IS NOT DISTINCT FROM v_contract_id)
      AND (v_vendor_id   IS NULL OR (s.raw_payload->>'vendorId')::BIGINT   IS NOT DISTINCT FROM v_vendor_id)
      AND (v_since       IS NULL OR s.fetched_at >= v_since)
      AND (v_status IS NULL
           OR (v_status = 'open'     AND (s.metadata IS NULL OR (s.metadata->>'resolvedAt') IS NULL))
           OR (v_status = 'resolved' AND (s.metadata->>'resolvedAt') IS NOT NULL))
    ORDER BY s.fetched_at DESC NULLS LAST, s.id DESC
    LIMIT v_limit OFFSET v_offset
  ) s;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::FLOAT / v_limit)::INTEGER END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_internal_signal_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_internal_signal_list(BIGINT, JSONB, INTEGER, INTEGER) IS
  'M8 — paginated list of osint_signal rows where kind=internal. Filters: signalType, contractId, vendorId, since, status. RLS auto-scopes tenant. Permission: internal_signal.read.';
REVOKE EXECUTE ON FUNCTION fn_internal_signal_list(BIGINT, JSONB, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_internal_signal_list(BIGINT, JSONB, INTEGER, INTEGER) TO neondb_owner;

-- ----------------------------------------------------------------
-- Record this migration
-- ----------------------------------------------------------------
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (111, 'cra2_internal_signal_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_internal_signal_list(BIGINT, JSONB, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_internal_signal_kind_list(BIGINT);
-- DROP FUNCTION IF EXISTS fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_internal_signal_ingest(JSONB);
-- DELETE FROM schema_migrations WHERE version = 111;
-- COMMIT;
-- ============================================================
