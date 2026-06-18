-- ============================================================================
-- Migration 706 — Internal-system connector "Sync now" (pull → land → triage)
-- ============================================================================
-- The Internal Systems admin page (mig 577/578) already registers connectors
-- (SAP S/4HANA Finance, ServiceNow ITSM, Oracle Primavera P6, …) and can probe
-- their health (test-connection). What it could NOT do is actually PULL records
-- and turn them into platform risk. This migration adds that final hop.
--
-- A connector "Sync now" runs a per-vendor adapter in the BE (see
-- internal-system-connectors.service.ts) which fetches + normalises records
-- (sample/sandbox data for the demo; the vendor's real API in production) and
-- hands them to fn_internal_system_sync_run as a JSONB array. The fn lands each
-- record exactly the way mig 690 seeded the 3 demo triage cases:
--     osint_signal (kind='internal' + provenance + source_record_snapshot)
--       → correlation (links the signal to the contract)
--         → risk_case (shows up in Risk Triage + the contract Risk tab)
-- and records the run in internal_system_sync_run + refreshes the connector's
-- last_pull_at / last_status.
--
-- Idempotent: each record carries a stable dedupe_key + the signal dedup_hash
-- folds in the record ref, so re-clicking Sync produces { deduped } rather than
-- duplicate cases.
--
-- NOTE on the landing path: the HTTP front door for EXTERNAL push (iPaaS /
-- service-to-service) remains POST /api/v1/admin/internal-signals →
-- fn_internal_signal_ingest. Connectors run server-side and land directly via
-- this fn (the 'internal:harness' osint_source is intentionally inactive, which
-- fn_internal_signal_ingest's active-source check would reject), mirroring the
-- proven seed insert. Both paths converge on the same osint_signal model.
-- ============================================================================

BEGIN;

-- ── 1. Sync-run history ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS internal_system_sync_run (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL REFERENCES tenant(id),
  internal_system_id BIGINT NOT NULL REFERENCES internal_system_source(id) ON DELETE CASCADE,
  started_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at        TIMESTAMPTZ,
  status             TEXT NOT NULL DEFAULT 'success'
                       CHECK (status IN ('success', 'partial', 'failed')),
  records_pulled     INTEGER NOT NULL DEFAULT 0,
  signals_created    INTEGER NOT NULL DEFAULT 0,
  signals_deduped    INTEGER NOT NULL DEFAULT 0,
  risk_cases_created INTEGER NOT NULL DEFAULT 0,
  summary            JSONB NOT NULL DEFAULT '[]'::jsonb,
  error              TEXT,
  data_classification VARCHAR(20) NOT NULL DEFAULT 'demo',
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by         BIGINT,
  updated_by         BIGINT
);

CREATE INDEX IF NOT EXISTS idx_internal_system_sync_run_system
  ON internal_system_sync_run (internal_system_id, started_at DESC);

COMMENT ON TABLE internal_system_sync_run IS
  '706: one row per connector "Sync now" run. Counts records pulled / signals created / deduped / risk cases created + a per-record summary. Drives the connector last-run display + an audit trail of internal-system pulls.';

-- ── 2. fn_internal_system_sync_run — land adapter records into the risk chain ─
CREATE OR REPLACE FUNCTION fn_internal_system_sync_run(
  p_actor_id  BIGINT,
  p_system_id BIGINT,
  p_records   JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id        UUID;
  v_system           RECORD;
  v_osint_source_id  BIGINT;
  v_corr_status      TEXT;
  v_corr_dc          TEXT;
  v_rec              JSONB;
  v_signal_type      TEXT;
  v_contract_id      BIGINT;
  v_record_ref       TEXT;
  v_observed_at      TEXT;
  v_severity         TEXT;
  v_dedupe_key       TEXT;
  v_category         TEXT;
  v_dedup_hash       TEXT;
  v_sig              BIGINT;
  v_corr             BIGINT;
  v_sla_hours        INTEGER;
  v_pulled           INTEGER := 0;
  v_created          INTEGER := 0;
  v_deduped          INTEGER := 0;
  v_cases            INTEGER := 0;
  v_outcomes         JSONB := '[]'::jsonb;
  v_outcome          TEXT;
  v_run_id           BIGINT;
BEGIN
  -- Tenant + permission (defence in depth — route is JWT-gated by the same).
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('platform.integrations.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.integrations.manage required' USING ERRCODE = '42501';
  END IF;

  -- Connector must exist + be active for this tenant.
  SELECT id, system_code, display_name, kind, base_url
    INTO v_system
  FROM internal_system_source
  WHERE id = p_system_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF v_system.id IS NULL THEN
    RAISE EXCEPTION 'Internal system not found' USING ERRCODE = '22023';
  END IF;

  IF p_records IS NULL OR jsonb_typeof(p_records) <> 'array' THEN
    RAISE EXCEPTION 'records must be a JSON array' USING ERRCODE = '22023';
  END IF;

  -- Resolve the internal harness source WITHOUT the is_active filter (it is
  -- intentionally inactive — see header). Mirrors the mig 690 seed (id 15).
  SELECT id INTO v_osint_source_id
  FROM osint_source WHERE source_id = 'internal:harness'
  ORDER BY id LIMIT 1;
  IF v_osint_source_id IS NULL THEN
    RAISE EXCEPTION 'internal:harness osint_source missing' USING ERRCODE = '22023';
  END IF;

  -- Reuse an existing correlation's enum values to stay schema-safe (per seed).
  SELECT status, data_classification INTO v_corr_status, v_corr_dc
    FROM correlation WHERE is_active = TRUE LIMIT 1;
  v_corr_status := COALESCE(v_corr_status, 'active');
  v_corr_dc     := COALESCE(v_corr_dc, 'demo');

  FOR v_rec IN SELECT * FROM jsonb_array_elements(p_records)
  LOOP
    v_pulled      := v_pulled + 1;
    v_signal_type := v_rec->>'signalType';
    v_contract_id := NULLIF(v_rec->>'contractId', '')::BIGINT;
    v_record_ref  := NULLIF(v_rec->>'recordRef', '');
    v_observed_at := COALESCE(NULLIF(v_rec->>'observedAt', ''), now()::text);
    v_severity    := COALESCE(NULLIF(v_rec->>'severity', ''), 'medium');
    v_dedupe_key  := v_rec->>'dedupeKey';
    v_sla_hours   := COALESCE(NULLIF(v_rec->>'slaHours', '')::INTEGER, 48);

    -- Skip silently if this record already produced a case (idempotent re-sync).
    IF v_dedupe_key IS NOT NULL
       AND EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = v_dedupe_key) THEN
      v_deduped := v_deduped + 1;
      v_outcome := 'deduped';
      v_outcomes := v_outcomes || jsonb_build_object(
        'recordRef', v_record_ref, 'signalType', v_signal_type, 'outcome', v_outcome);
      CONTINUE;
    END IF;

    -- Target contract must exist + be active; otherwise record + skip.
    IF v_contract_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM contract WHERE id = v_contract_id AND is_active = TRUE) THEN
      v_outcomes := v_outcomes || jsonb_build_object(
        'recordRef', v_record_ref, 'signalType', v_signal_type, 'outcome', 'skipped_no_contract');
      CONTINUE;
    END IF;

    -- Back-compat category (osint_signal.category) — proven-safe values per seed.
    v_category := CASE v_signal_type
      WHEN 'payment_delay'      THEN 'market_financial'
      WHEN 'invoice_dispute'    THEN 'market_financial'
      WHEN 'milestone_slippage' THEN 'supply_chain'
      WHEN 'sla_breach'         THEN 'supply_chain'
      ELSE 'supply_chain'
    END;

    -- Dedup hash — same recipe as fn_internal_signal_ingest so the two landing
    -- paths agree on identity (folds the record ref in).
    v_dedup_hash := encode(digest(
      'internal:harness' || '|' || v_signal_type || '|' ||
      COALESCE(v_contract_id::text, '') || '|' ||
      COALESCE(v_record_ref, '') || '|' || v_observed_at, 'sha256'), 'hex');

    INSERT INTO osint_signal (
      tenant_id, osint_source_id, source_id, source_reliability, fetched_at, event_date_v2,
      kind, signal_kind_subtype, title, summary, geographies, affected_entities,
      severity_v2, confidence, url, raw_payload, dedup_hash, data_classification,
      internal_system_id, source_record_ref, source_record_snapshot, metadata,
      created_by, updated_by, ext_id, category, source, severity, title_en, published_date
    ) VALUES (
      v_tenant_id, v_osint_source_id, 'internal:harness', 1.00, now(),
      v_observed_at::timestamptz,
      'internal', v_signal_type,
      v_rec->>'title',
      v_rec->>'summary',
      '[]'::jsonb, '[]'::jsonb,
      v_severity, COALESCE(NULLIF(v_rec->>'confidence','')::numeric, 1.00),
      v_rec->>'recordUrl',
      COALESCE(v_rec->'rawPayload', v_rec),
      v_dedup_hash, COALESCE(v_rec->>'dataClassification', 'demo'),
      v_system.id, v_record_ref,
      COALESCE(v_rec->'snapshot', '{}'::jsonb), '{}'::jsonb,
      p_actor_id, p_actor_id,
      'internal:sync-' || left(v_dedup_hash, 24),
      v_category, 'internal:harness', v_severity,
      v_rec->>'title', v_observed_at::date
    )
    ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
    RETURNING id INTO v_sig;

    -- Signal already existed (rare partial-state) — reuse it, still ensure a case.
    IF v_sig IS NULL THEN
      SELECT id INTO v_sig FROM osint_signal
      WHERE tenant_id = v_tenant_id AND dedup_hash = v_dedup_hash;
      v_deduped := v_deduped + 1;
      v_outcome := 'deduped';
    ELSE
      v_created := v_created + 1;
      v_outcome := 'created';
    END IF;

    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence,
      match_reason, match_evidence, match_geographies, match_entities, status,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_sig, v_contract_id,
      COALESCE(v_rec->>'ruleId', 'rule.internal.' || v_signal_type), 'v1-internal-sync',
      COALESCE(NULLIF(v_rec->>'confidence','')::numeric, 0.90),
      v_rec->>'matchReason',
      '{}'::jsonb, '[]'::jsonb, '[]'::jsonb, v_corr_status,
      v_corr_dc, p_actor_id, p_actor_id
    ) RETURNING id INTO v_corr;

    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      assigned_role, assigned_user_id, status, sla_hours, due_at, dedupe_key,
      metadata, data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_corr, v_contract_id,
      COALESCE(v_rec->>'caseType', 'correlation_alert'),
      COALESCE(NULLIF(v_rec->>'casePriority',''), v_severity),
      v_rec->>'caseTitle', v_rec->>'caseBody',
      COALESCE(NULLIF(v_rec->>'assignedRole',''), 'operations'), NULL,
      'open', v_sla_hours, now() + make_interval(hours => v_sla_hours),
      v_dedupe_key,
      jsonb_build_object(
        'confidence',      COALESCE(NULLIF(v_rec->>'confidence','')::numeric, 0.90),
        'materialityAed',  NULLIF(v_rec->>'materialityAed','')::numeric,
        'tier',            COALESCE(NULLIF(v_rec->>'tier','')::int, 2),
        'suppressedReason', v_rec->>'suppressedReason',
        'syncedFrom',      v_system.system_code
      ),
      'internal', p_actor_id, p_actor_id
    );

    v_cases := v_cases + 1;
    v_outcomes := v_outcomes || jsonb_build_object(
      'recordRef', v_record_ref, 'signalType', v_signal_type,
      'contractId', v_contract_id, 'signalId', v_sig, 'outcome', v_outcome);
  END LOOP;

  -- Refresh the connector's health/last-pull (a successful pull = healthy).
  UPDATE internal_system_source
     SET last_pull_at = now(), last_status = 'healthy', last_status_at = now(),
         last_error = NULL, updated_by = p_actor_id, updated_at = now()
   WHERE id = v_system.id;

  INSERT INTO internal_system_sync_run (
    tenant_id, internal_system_id, finished_at, status,
    records_pulled, signals_created, signals_deduped, risk_cases_created,
    summary, created_by, updated_by
  ) VALUES (
    v_tenant_id, v_system.id, now(), 'success',
    v_pulled, v_created, v_deduped, v_cases,
    v_outcomes, p_actor_id, p_actor_id
  ) RETURNING id INTO v_run_id;

  RETURN jsonb_build_object(
    'runId',          v_run_id,
    'systemId',       v_system.id,
    'systemCode',     v_system.system_code,
    'systemName',     v_system.display_name,
    'recordsPulled',  v_pulled,
    'signalsCreated', v_created,
    'signalsDeduped', v_deduped,
    'riskCasesCreated', v_cases,
    'records',        v_outcomes,
    'lastPullAt',     now()
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_internal_system_sync_run: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_internal_system_sync_run(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_system_sync_run(BIGINT, BIGINT, JSONB) TO neondb_owner;
COMMENT ON FUNCTION fn_internal_system_sync_run(BIGINT, BIGINT, JSONB) IS
  '706: connector "Sync now" landing. Takes adapter-normalised records (JSONB array) and lands each as osint_signal(kind=internal)+correlation+risk_case (mirrors mig 690 seed), idempotent via dedupe_key + dedup_hash. Refreshes internal_system_source.last_pull_at/last_status + writes internal_system_sync_run. DEFINER + platform.integrations.manage gate.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (706, 'internal_system_sync', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DROP FUNCTION IF EXISTS fn_internal_system_sync_run(BIGINT, BIGINT, JSONB);
-- DROP TABLE IF EXISTS internal_system_sync_run;
-- DELETE FROM schema_migrations WHERE version = 706;
-- ROLLBACK END
-- ============================================================================
