-- Migration: 434_rashid_cluster_s_signing_history_fn.sql
-- Unit: Rashid Recipient PM-grade audit fix pass (2026-06-01) — Cluster S
-- Defect addressed:
--   R28 (continued) — Backing data fn for the recipient_signing_history
--                     report_template seeded in mig 433. STABLE INVOKER.
--                     Returns the caller's own signing footprint —
--                     contracts where signature_party.signer_email == caller.email
--                     within the supplied window.
-- Test-branch-safe: CREATE OR REPLACE.

BEGIN;

CREATE OR REPLACE FUNCTION fn_report_data_recipient_signing_history(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant       UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now          TIMESTAMPTZ := fn_demo_now();
  v_window_days  INTEGER := COALESCE((p_parameters->>'windowDays')::INTEGER, 365);
  v_window_start TIMESTAMPTZ;
  v_email        TEXT;
  v_rows         JSONB;
  v_trace        JSONB;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF v_window_days < 1 OR v_window_days > 365 THEN
    RAISE EXCEPTION 'windowDays must be 1..365' USING ERRCODE = '22023';
  END IF;
  v_window_start := v_now - (v_window_days || ' days')::INTERVAL;

  SELECT email INTO v_email FROM "user" WHERE id = p_actor_id;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'actor not found' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId', c.id,
    'contractNumber', c.contract_number,
    'titleEn', c.title_en,
    'titleAr', c.title_ar,
    'status', c.status,
    'valueAed', c.total_value,
    'lastUpdated', c.updated_at,
    'startDate', c.start_date,
    'endDate', c.end_date,
    'signerEmail', sp.signer_email,
    'signedAt', se.created_at
  ) ORDER BY c.updated_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM contract c
  JOIN signature_party sp
    ON sp.contract_id = c.id
   AND sp.is_active = TRUE
   AND lower(sp.signer_email) = lower(v_email)
  LEFT JOIN signature_event se
    ON se.contract_id = c.id
   AND se.actor_user_id = p_actor_id
   AND se.event_type = 'signed'
   AND se.is_active = TRUE
  WHERE c.is_active = TRUE
    AND c.updated_at >= v_window_start;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','contract','count', COALESCE(jsonb_array_length(v_rows), 0)),
    jsonb_build_object('tableName','signature_party','filter','signer_email = caller.email'),
    jsonb_build_object('tableName','signature_event','filter','actor_user_id = caller AND event_type = signed')
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object(
      'rows', v_rows,
      'windowStart', v_window_start,
      'windowEnd', v_now,
      'signerEmail', v_email
    ),
    'meta', jsonb_build_object(
      'tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', v_trace, 'parameters', p_parameters
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_data_recipient_signing_history: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_data_recipient_signing_history(BIGINT, JSONB)
  IS 'R28 — Recipient signing-history report: contracts where caller is a signer + status + value + signed timestamp.';
REVOKE EXECUTE ON FUNCTION fn_report_data_recipient_signing_history(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_recipient_signing_history(BIGINT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (434, 'R28 — fn_report_data_recipient_signing_history backing data fn', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   DROP FUNCTION IF EXISTS fn_report_data_recipient_signing_history(BIGINT, JSONB);
--   DELETE FROM schema_migrations WHERE version=434;
-- COMMIT;
-- ROLLBACK END
