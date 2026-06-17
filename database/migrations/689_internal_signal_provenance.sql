-- ============================================================================
-- Migration 689 — Internal signal provenance ("marry" to a source system + record)
-- ============================================================================
-- WHY: External (OSINT) signals are tied to a real source — osint_signal.source_id
-- points at an osint_source row (rss_gulf_business, ncm_uae, …) so an executive can
-- see where a signal came from. Internal signals had NO such tie: every one was
-- stamped source_id='internal:harness' with no link to which internal system
-- (SAP S/4, ServiceNow, Primavera, …) or which record (invoice #, ticket #) it came
-- from. That made them un-auditable — an executive can't trust or act on a signal
-- with no provenance.
--
-- The internal_system_source registry (mig 577) already lists the tenant's internal
-- systems. This migration MARRIES each internal signal to a row there + a record
-- reference, mirroring how external signals carry their source.
--
-- WHAT (all additive — external signals are untouched, new columns stay NULL):
--   1. osint_signal gains internal_system_id (FK → internal_system_source) +
--      source_record_ref. The existing `url` column carries the record deep-link.
--   2. fn_internal_signal_ingest now captures provenance. Callers MAY pass
--      sourceSystemCode / sourceRecordRef / sourceRecordUrl explicitly; when omitted
--      the fn AUTO-DERIVES — system from the signal_type, record ref from the
--      existing payload fields (invoiceRef / milestoneRef / ticketRef / …), and a
--      deep-link from the system's base_url. So every internal signal — including
--      those from existing demo scenarios — gets authentic provenance with zero
--      caller changes. source_id stays 'internal:harness' (it must remain a
--      registered osint_source per the upsert FK check); the REAL provenance is the
--      new internal_system_id + source_record_ref + url.
--   3. fn_osint_signal_upsert writes the two new columns from the payload.
--   4. fn_risk_score_explain enriches each contributing correlation's `signal` with
--      sourceSystemName / sourceRecordRef / sourceRecordUrl at READ time (no score
--      recompute) so the contract Risk tab shows provenance immediately.
--   5. Backfill — the existing internal signals get provenance by the same
--      auto-derivation so the demo shows married signals on day one.
--
-- system-by-type default mapping (matches the internal_system_source seed notes):
--   milestone_slippage → primavera_p6     sla_breach        → servicenow_itsm
--   payment_delay      → sap_s4_finance   invoice_dispute   → sap_s4_finance
--   vendor_incident    → sap_ariba_procurement   ics_incident → microsoft_sentinel_siem
--   icv_status_change  → sap_ariba_procurement   certificate_expiry → sap_ariba_procurement
--
-- S2-21: fn_osint_signal_upsert + fn_internal_signal_ingest keep their (p_payload JSONB)
-- signatures (CREATE OR REPLACE), so the existing REVOKE-only grant posture is
-- preserved; we re-issue REVOKE for safety. fn_risk_score_explain keeps its
-- (bigint, bigint) signature; REVOKE/GRANT re-issued verbatim.
-- ============================================================================

BEGIN;

-- ── 1. Provenance columns on osint_signal ───────────────────────────────────
ALTER TABLE osint_signal
  ADD COLUMN IF NOT EXISTS internal_system_id BIGINT
    REFERENCES internal_system_source(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_record_ref TEXT;

COMMENT ON COLUMN osint_signal.internal_system_id IS
  'M8+ (689) — for kind=internal signals, the internal_system_source row this signal originated from (SAP S/4, ServiceNow, …). NULL for external/OSINT signals (those use osint_source_id instead). The internal mirror of osint_source_id.';
COMMENT ON COLUMN osint_signal.source_record_ref IS
  'M8+ (689) — the originating record identifier in the source system (invoice #, ticket #, milestone ref, PO #). The "which record" half of internal-signal provenance; the deep-link lives in the existing url column.';

CREATE INDEX IF NOT EXISTS idx_osint_signal_internal_system
  ON osint_signal (internal_system_id) WHERE internal_system_id IS NOT NULL;

-- ── 2. fn_internal_signal_ingest — capture provenance (auto-derive when omitted)
--    Verbatim from mig 111 + the provenance block (steps 6c, 9b, payload keys).
DROP FUNCTION IF EXISTS fn_internal_signal_ingest(JSONB);
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
  -- 689 provenance locals
  v_system_code        TEXT;
  v_internal_system_id BIGINT;
  v_base_url           TEXT;
  v_record_ref         TEXT;
  v_record_url         TEXT;
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

  -- 6c. 689 — PROVENANCE resolution (the "marry to source system + record").
  --     System: explicit sourceSystemCode wins, else auto-derive from signal_type.
  v_system_code := COALESCE(
    NULLIF(p_payload->>'sourceSystemCode', ''),
    CASE v_signal_type
      WHEN 'milestone_slippage' THEN 'primavera_p6'
      WHEN 'sla_breach'         THEN 'servicenow_itsm'
      WHEN 'payment_delay'      THEN 'sap_s4_finance'
      WHEN 'invoice_dispute'    THEN 'sap_s4_finance'
      WHEN 'vendor_incident'    THEN 'sap_ariba_procurement'
      WHEN 'ics_incident'       THEN 'microsoft_sentinel_siem'
      WHEN 'icv_status_change'  THEN 'sap_ariba_procurement'
      WHEN 'certificate_expiry' THEN 'sap_ariba_procurement'
    END
  );
  IF v_system_code IS NOT NULL THEN
    SELECT id, base_url
      INTO v_internal_system_id, v_base_url
    FROM internal_system_source
    WHERE tenant_id = v_tenant_id
      AND system_code = v_system_code
      AND is_active = TRUE;
    -- An explicitly-supplied system that doesn't exist is a hard error; a derived
    -- default that happens to be absent degrades gracefully (system_id stays NULL).
    IF v_internal_system_id IS NULL AND (p_payload ? 'sourceSystemCode') THEN
      RAISE EXCEPTION 'Unknown internal system: %', v_system_code USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Record ref: explicit sourceRecordRef wins, else derive from the kind's natural
  -- record field already present in the payload.
  v_record_ref := COALESCE(
    NULLIF(p_payload->>'sourceRecordRef', ''),
    NULLIF(p_payload->>'invoiceRef', ''),
    NULLIF(p_payload->>'milestoneRef', ''),
    NULLIF(p_payload->>'ticketRef', ''),
    NULLIF(p_payload->>'incidentRef', ''),
    NULLIF(p_payload->>'certificateType', ''),
    NULLIF(p_payload->>'metricRef', '')
  );

  -- Deep-link: explicit sourceRecordUrl wins, else synth from the system base_url.
  v_record_url := COALESCE(
    NULLIF(p_payload->>'sourceRecordUrl', ''),
    CASE WHEN v_base_url IS NOT NULL AND v_record_ref IS NOT NULL
         THEN rtrim(v_base_url, '/') || '/record/' || v_record_ref END
  );

  -- 7. Compute dedup_hash (per AC-S7-01) — 689 folds the record ref in so two
  --    distinct records of the same type/contract don't collapse onto one signal.
  v_dedup := encode(
    digest(
      'internal:harness' || '|' ||
      v_signal_type     || '|' ||
      COALESCE((p_payload->>'contractId'),
               (p_payload->>'vendorId'),
               '') || '|' ||
      COALESCE(v_record_ref, '') || '|' ||
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
               v_record_ref,
               p_payload->>'milestoneRef',
               p_payload->>'invoiceRef',
               CASE WHEN v_contract_id IS NOT NULL THEN 'contract #' || v_contract_id::text ELSE NULL END,
               CASE WHEN v_vendor_id   IS NOT NULL THEN 'vendor #'   || v_vendor_id::text   ELSE NULL END,
               'event');

  v_data_class := COALESCE(p_payload->>'dataClassification', 'demo');

  -- 10. Build the M7-contract payload (S2-19 LOCK — base 9 keys + 689 provenance keys)
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
    'dataClassification', v_data_class,
    -- 689 provenance — fn_osint_signal_upsert writes these to the new columns + url.
    'internalSystemId',   v_internal_system_id,
    'sourceRecordRef',    v_record_ref,
    'url',                v_record_url
  );

  -- 11. Delegate to fn_osint_signal_upsert (DEFINER chain — runs as owner)
  v_inner_result := fn_osint_signal_upsert(v_inner_payload);

  -- 12. Return shape per design §5.1 step 11 + 689 provenance echo
  RETURN jsonb_build_object(
    'signalId',          v_inner_result->'id',
    'inserted',          v_inner_result->'inserted',
    'dedupHashHit',      NOT (v_inner_result->>'inserted')::boolean,
    'signalKindSubtype', v_signal_type,
    'internalSystemId',  v_internal_system_id,
    'sourceSystemCode',  v_system_code,
    'sourceRecordRef',   v_record_ref,
    'sourceRecordUrl',   v_record_url
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Preserve original SQLSTATE so BE error translator sees the right code
    RAISE EXCEPTION 'fn_internal_signal_ingest: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_internal_signal_ingest(JSONB) IS
  'M8 (689) — DEFINER, SYSTEM-ONLY. Translates an internal-signal payload into the M7 osint_signal contract and delegates to fn_osint_signal_upsert. Captures provenance: sourceSystemCode (→ internal_system_id, auto-derived from signal_type when omitted), sourceRecordRef (auto-derived from invoiceRef/milestoneRef/… when omitted), sourceRecordUrl (synth from system base_url when omitted). Permission: internal_signal.ingest.';
REVOKE EXECUTE ON FUNCTION fn_internal_signal_ingest(JSONB) FROM PUBLIC;
-- AC-S7-05 mirror: NO role grant. Only neondb_owner (OWNER) executes.


-- ── 3. fn_osint_signal_upsert — write the two new columns (additive) ─────────
--    Verbatim from mig 107 + internal_system_id + source_record_ref in the INSERT.
CREATE OR REPLACE FUNCTION fn_osint_signal_upsert(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id        UUID;
  v_osint_source_id  BIGINT;
  v_actor            BIGINT;
  v_id               BIGINT;
  v_inserted         BOOLEAN;
  v_kind             TEXT;
  v_severity         TEXT;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Required-field check
  IF p_payload->>'sourceId' IS NULL THEN
    RAISE EXCEPTION 'sourceId is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'sourceReliability' IS NULL THEN
    RAISE EXCEPTION 'sourceReliability is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'fetchedAt' IS NULL THEN
    RAISE EXCEPTION 'fetchedAt is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'kind' IS NULL THEN
    RAISE EXCEPTION 'kind is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'title' IS NULL OR length(trim(p_payload->>'title')) = 0 THEN
    RAISE EXCEPTION 'title is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'severity' IS NULL THEN
    RAISE EXCEPTION 'severity is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'confidence' IS NULL THEN
    RAISE EXCEPTION 'confidence is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->'rawPayload' IS NULL THEN
    RAISE EXCEPTION 'rawPayload is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'dedupHash' IS NULL THEN
    RAISE EXCEPTION 'dedupHash is required' USING ERRCODE = '22023';
  END IF;

  -- 3. Enum validation
  v_kind     := p_payload->>'kind';
  v_severity := p_payload->>'severity';
  IF v_kind NOT IN ('geopolitical','sanctions','weather','commodity','fx','logistics','esg','regulatory','news','internal') THEN
    RAISE EXCEPTION 'kind must be one of geopolitical/sanctions/weather/commodity/fx/logistics/esg/regulatory/news/internal'
      USING ERRCODE = '22023';
  END IF;
  IF v_severity NOT IN ('informational','low','medium','high','critical') THEN
    RAISE EXCEPTION 'severity must be one of informational/low/medium/high/critical'
      USING ERRCODE = '23514';
  END IF;

  -- 4. S2-23 FK pre-validation — resolve osint_source_id
  SELECT id INTO v_osint_source_id
  FROM osint_source
  WHERE tenant_id = v_tenant_id
    AND source_id = p_payload->>'sourceId'
    AND is_active = TRUE;
  IF v_osint_source_id IS NULL THEN
    RAISE EXCEPTION 'Source not registered: %', p_payload->>'sourceId' USING ERRCODE = '22023';
  END IF;

  -- 5. S2-20 actor sentinel
  BEGIN
    v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN
    v_actor := NULL;
  END;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  -- 6. Idempotent INSERT (UNIQUE on (tenant_id, dedup_hash))
  INSERT INTO osint_signal (
    tenant_id, osint_source_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities,
    severity_v2, confidence, url, raw_payload, dedup_hash,
    data_classification, created_by, updated_by,
    -- 689 internal-signal provenance (NULL for external signals):
    internal_system_id, source_record_ref,
    -- R-LC back-compat NOT-NULL columns must be synthesised:
    ext_id, category, source, severity, title_en, published_date
  )
  VALUES (
    v_tenant_id, v_osint_source_id, p_payload->>'sourceId',
    (p_payload->>'sourceReliability')::numeric,
    (p_payload->>'fetchedAt')::timestamptz,
    NULLIF(p_payload->>'eventDate','')::timestamptz,
    v_kind,
    p_payload->>'signalKindSubtype',
    p_payload->>'title',
    p_payload->>'summary',
    COALESCE(p_payload->'geographies',      '[]'::jsonb),
    COALESCE(p_payload->'affectedEntities', '[]'::jsonb),
    v_severity,
    (p_payload->>'confidence')::numeric,
    p_payload->>'url',
    p_payload->'rawPayload',
    p_payload->>'dedupHash',
    COALESCE(p_payload->>'dataClassification', 'demo'),
    v_actor, v_actor,
    -- 689 provenance
    NULLIF(p_payload->>'internalSystemId','')::BIGINT,
    NULLIF(p_payload->>'sourceRecordRef',''),
    -- R-LC compat (synthesised)
    'osint:' || left(p_payload->>'dedupHash', 24),
    CASE v_kind
      WHEN 'regulatory'    THEN 'regulatory'
      WHEN 'commodity'     THEN 'commodity_prices'
      WHEN 'logistics'     THEN 'supply_chain'
      WHEN 'fx'            THEN 'market_financial'
      WHEN 'geopolitical'  THEN 'geopolitical'
      ELSE 'geopolitical'
    END,
    left(p_payload->>'sourceId', 120),
    v_severity,
    p_payload->>'title',
    COALESCE(NULLIF(p_payload->>'eventDate','')::date,
             NULLIF(p_payload->>'fetchedAt','')::date,
             CURRENT_DATE)
  )
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
  RETURNING id INTO v_id;

  v_inserted := (v_id IS NOT NULL);

  IF NOT v_inserted THEN
    SELECT id INTO v_id
    FROM osint_signal
    WHERE tenant_id = v_tenant_id
      AND dedup_hash = p_payload->>'dedupHash';
  ELSE
    -- Emit pg_notify only on insert path (AC-S7-04)
    PERFORM pg_notify(
      'osint_signal_inserted',
      jsonb_build_object(
        'id',        v_id,
        'tenantId',  v_tenant_id,
        'sourceId',  p_payload->>'sourceId',
        'severity',  v_severity,
        'kind',      v_kind
      )::text
    );
  END IF;

  RETURN jsonb_build_object(
    'id',         v_id,
    'inserted',   v_inserted,
    'dedupHash',  p_payload->>'dedupHash'
  );

EXCEPTION
  WHEN check_violation THEN
    RAISE EXCEPTION 'CHECK constraint violation: %', SQLERRM USING ERRCODE = '23514';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_signal_upsert: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_signal_upsert(JSONB) IS
  'M7 (689) — DEFINER, SYSTEM-ONLY. Idempotent upsert via UNIQUE(tenant_id, dedup_hash). Writes internal_system_id + source_record_ref when present (internal-signal provenance; NULL for external). Emits pg_notify(osint_signal_inserted) only on insert path. NO role grant; only neondb_owner connection invokes.';
REVOKE EXECUTE ON FUNCTION fn_osint_signal_upsert(JSONB) FROM PUBLIC;


-- ── 4. fn_risk_score_explain — read-time provenance enrichment ───────────────
--    Verbatim from mig 529 + a single enrichment pass over v_contributing that
--    LEFT JOINs each correlation's signal to osint_signal + internal_system_source.
--    Additive: external signals / correlations without an internal system are
--    returned unchanged. No score recompute.
CREATE OR REPLACE FUNCTION public.fn_risk_score_explain(p_contract_id bigint, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $fn$
DECLARE
  v_tenant_id   UUID;
  v_latest      RECORD;
  v_explanation JSONB;
  v_addends     JSONB;
  v_bands       JSONB;
  v_band_label  TEXT;
  v_narrative   TEXT;
  v_contributing JSONB;
  v_dominant    JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT id, tenant_id, contract_id, health_score,
         dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
         mar_value, mar_currency, contributing_correlations, explanation,
         weights_version, calculated_at, triggered_by
    INTO v_latest
    FROM latest_risk_score
   WHERE contract_id = p_contract_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'risk_score for contract % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  v_explanation := COALESCE(v_latest.explanation, '{}'::jsonb);
  v_addends     := COALESCE(v_explanation->'addends', '[]'::jsonb);
  v_bands       := COALESCE(v_explanation->'bands',
                            (SELECT value FROM system_setting WHERE key='scoring.v2.bands' AND is_active LIMIT 1),
                            '{"lowMax":29,"mediumMax":59}'::jsonb);

  v_band_label := CASE
    WHEN v_latest.health_score <= (v_bands->>'lowMax')::integer    THEN 'Low'
    WHEN v_latest.health_score <= (v_bands->>'mediumMax')::integer THEN 'Medium'
    ELSE 'High'
  END;

  -- Hydrated contributing — mig 528 logic, kept here so downstream can rely on it.
  v_contributing := COALESCE(v_latest.contributing_correlations, '[]'::jsonb);

  -- 689 — enrich each contributing correlation with internal-system provenance at
  -- read time. Each correlation object carries correlationId (the correlation row
  -- id); we LEFT JOIN correlation → osint_signal (kind=internal) → the originating
  -- internal_system_source and graft the source system + record ref + deep-link
  -- onto the correlation. Correlations backed by external/OSINT signals (no
  -- internal system) pass through unchanged. No score recompute.
  SELECT COALESCE(jsonb_agg(
           CASE
             WHEN iss.id IS NOT NULL THEN
               elem || jsonb_build_object(
                 'sourceSystemCode', iss.system_code,
                 'sourceSystemName', iss.display_name,
                 'sourceRecordRef',  os.source_record_ref,
                 'sourceRecordUrl',  os.url
               )
             ELSE elem
           END
           ORDER BY ord
         ), '[]'::jsonb)
    INTO v_contributing
    FROM jsonb_array_elements(v_contributing) WITH ORDINALITY AS t(elem, ord)
    LEFT JOIN correlation co
      ON co.id = NULLIF(elem->>'correlationId','')::bigint
    LEFT JOIN osint_signal os
      ON os.id = co.signal_id
     AND os.tenant_id = v_tenant_id
     AND os.kind = 'internal'
    LEFT JOIN internal_system_source iss
      ON iss.id = os.internal_system_id;

  -- Pick the highest-impact addend as the narrative driver.
  SELECT a INTO v_dominant
    FROM jsonb_array_elements(v_addends) a
   ORDER BY (a->>'points')::numeric DESC NULLS LAST
   LIMIT 1;

  IF v_dominant IS NOT NULL AND (v_dominant->>'points')::integer > 0 THEN
    v_narrative := 'Score ' || v_latest.health_score || '/100 (' || v_band_label || ') — top driver: '
                || (v_dominant->>'label') || ' (+' || (v_dominant->>'points') || ' pts). '
                || jsonb_array_length(v_addends) || ' factor(s) considered.';
  ELSE
    v_narrative := 'Score ' || v_latest.health_score || '/100 (' || v_band_label
                || ') — no notable risk factors detected.';
  END IF;

  RETURN jsonb_build_object(
    'riskScoreId',              v_latest.id::text,
    'contractId',               v_latest.contract_id::text,
    'healthScore',              v_latest.health_score,
    'band',                     v_band_label,
    'bands',                    v_bands,
    'narrative',                v_narrative,
    'formulaVersion',           COALESCE(v_explanation->>'formulaVersion', 'v1'),
    'addends',                  v_addends,
    'bucketSubtotals',          COALESCE(v_explanation->'bucketSubtotals', '{}'::jsonb),
    'dimensions',               jsonb_build_object(
      'legal',        jsonb_build_object('score', COALESCE(v_latest.dim_legal, 0),        'reasons', '[]'::jsonb),
      'financial',    jsonb_build_object('score', COALESCE(v_latest.dim_financial, 0),    'reasons', '[]'::jsonb),
      'operational',  jsonb_build_object('score', COALESCE(v_latest.dim_operational, 0),  'reasons', '[]'::jsonb),
      'reputational', jsonb_build_object('score', COALESCE(v_latest.dim_reputational, 0), 'reasons', '[]'::jsonb),
      'compliance',   jsonb_build_object('score', COALESCE(v_latest.dim_compliance, 0),   'reasons', '[]'::jsonb)
    ),
    'marFormula',               COALESCE(v_explanation->'marFormula', '{}'::jsonb),
    'marValue',                 v_latest.mar_value::text,
    'marCurrency',              v_latest.mar_currency,
    'weightsVersion',           v_latest.weights_version,
    'weightsAtCalculation',     '{}'::jsonb,
    'contributingCorrelations', v_contributing,
    'calculatedAt',             v_latest.calculated_at,
    'triggeredBy',              v_latest.triggered_by
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_explain: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_explain(bigint, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_explain(bigint, bigint) TO neondb_owner;


-- ── 5. Backfill existing internal signals ───────────────────────────────────
--    Same auto-derivation as the ingest fn, applied to the rows already present so
--    the demo shows married signals immediately. Runs under the bootstrap admin
--    (Super Admin → holds internal_signal.resolve) so the osint_signal RESTRICTIVE
--    deny-direct-update carve-out (mig 109) permits the write.
DO $$
DECLARE
  v_tenant_id UUID := '00000000-0000-0000-0000-000000000001'::uuid;
  v_admin_id  BIGINT;
BEGIN
  SELECT id INTO v_admin_id FROM "user" WHERE email = 'admin@musanad.local' LIMIT 1;
  IF v_admin_id IS NULL THEN
    RAISE NOTICE '689 backfill skipped — bootstrap admin not found';
    RETURN;
  END IF;
  PERFORM set_config('app.current_tenant_id', v_tenant_id::text, true);
  PERFORM set_config('app.current_user_id',   v_admin_id::text, true);

  UPDATE osint_signal s SET
    internal_system_id = iss.id,
    source_record_ref  = COALESCE(
      NULLIF(s.raw_payload->>'sourceRecordRef',''),
      NULLIF(s.raw_payload->>'invoiceRef',''),
      NULLIF(s.raw_payload->>'milestoneRef',''),
      NULLIF(s.raw_payload->>'ticketRef',''),
      NULLIF(s.raw_payload->>'incidentRef',''),
      NULLIF(s.raw_payload->>'certificateType',''),
      'REC-' || s.id),
    url = COALESCE(
      s.url,
      rtrim(iss.base_url, '/') || '/record/' || COALESCE(
        NULLIF(s.raw_payload->>'sourceRecordRef',''),
        NULLIF(s.raw_payload->>'invoiceRef',''),
        NULLIF(s.raw_payload->>'milestoneRef',''),
        NULLIF(s.raw_payload->>'ticketRef',''),
        NULLIF(s.raw_payload->>'incidentRef',''),
        'REC-' || s.id))
  FROM internal_system_source iss
  WHERE s.kind = 'internal'
    AND s.tenant_id = v_tenant_id
    AND s.internal_system_id IS NULL
    AND iss.tenant_id = v_tenant_id
    AND iss.is_active = TRUE
    AND iss.system_code = CASE s.signal_kind_subtype
      WHEN 'milestone_slippage' THEN 'primavera_p6'
      WHEN 'sla_breach'         THEN 'servicenow_itsm'
      WHEN 'payment_delay'      THEN 'sap_s4_finance'
      WHEN 'invoice_dispute'    THEN 'sap_s4_finance'
      WHEN 'vendor_incident'    THEN 'sap_ariba_procurement'
      WHEN 'ics_incident'       THEN 'microsoft_sentinel_siem'
      WHEN 'icv_status_change'  THEN 'sap_ariba_procurement'
      WHEN 'certificate_expiry' THEN 'sap_ariba_procurement'
    END;

  RAISE NOTICE '689 backfill complete';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (689, 'internal_signal provenance — internal_system_id + source_record_ref + url; ingest/upsert/explain wired + backfill', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK (manual)
-- ============================================================================
-- BEGIN;
-- -- restore fn bodies from migrations 111 (ingest), 107 (upsert), 529 (explain)
-- DROP INDEX IF EXISTS idx_osint_signal_internal_system;
-- ALTER TABLE osint_signal DROP COLUMN IF EXISTS source_record_ref;
-- ALTER TABLE osint_signal DROP COLUMN IF EXISTS internal_system_id;
-- DELETE FROM schema_migrations WHERE version = 689;
-- COMMIT;
-- ============================================================================
