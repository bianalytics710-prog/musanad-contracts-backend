-- ============================================================================
-- 033_m3_extend_fn_contract_status_update_internal_for_signatures.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   026_m2_split_fn_contract_status_update.sql (canonical body).
-- ----------------------------------------------------------------------------
-- CC-1 / DN-5 — extend the allowed-transitions guard in the canonical M2
-- fn_contract_status_update_internal to permit the 9 signature-driven
-- transitions documented in collision-report.extend.fn_contract_status_update_internal.
--
-- Signature preserved (S2-19):
--   (BIGINT, TEXT, BIGINT, TEXT DEFAULT NULL) RETURNS jsonb
--
-- Body byte-for-byte identical to canonical 026 lines 185-234 EXCEPT the
-- IF NOT (...) condition is extended from one transition family
--   in_approval -> {approved,rejected,draft}
-- to five transition families:
--   in_approval                      -> {approved,rejected,draft}
--   approved                         -> awaiting_signature_employer
--   awaiting_signature_employer      -> {awaiting_signature_counterparty, fully_signed,
--                                        rejected, expired, approved}
--   awaiting_signature_counterparty  -> {fully_signed, rejected, expired, approved}
--
-- (The "approved" target on awaiting_signature_* is the cancel-rollback path
-- from fn_signature_invitation_cancel when the last active step is cancelled.)
--
-- M2 026 FOR UPDATE on contract row, P0002 NOT FOUND code, P0001 transition
-- violation message format, UPDATE statement, and RETURN jsonb_build_object
-- preserved verbatim (S2-17 lock preservation).
--
-- REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner preserved.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_status_update_internal(
  p_contract_id BIGINT,
  p_new_status  TEXT,
  p_actor_id    BIGINT,
  p_reason      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_status TEXT;
BEGIN
  SELECT status INTO v_existing_status
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_status_update_internal: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- M3 (033): allowed-transitions extension. Signature transitions added.
  IF NOT (
    (v_existing_status = 'in_approval' AND p_new_status IN ('approved','rejected','draft'))
    OR
    (v_existing_status = 'approved' AND p_new_status = 'awaiting_signature_employer')
    OR
    (v_existing_status = 'awaiting_signature_employer'
       AND p_new_status IN ('awaiting_signature_counterparty','fully_signed','rejected','expired','approved'))
    OR
    (v_existing_status = 'awaiting_signature_counterparty'
       AND p_new_status IN ('fully_signed','rejected','expired','approved'))
  ) THEN
    RAISE EXCEPTION 'fn_contract_status_update_internal: %',
      format('newStatus:Internal-only transition violation (from %s to %s)', v_existing_status, p_new_status)
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE contract
    SET status     = p_new_status,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_contract_id;

  -- The trg_contract_activity_emit_iu trigger emits 'status_changed' on this UPDATE.
  -- We do NOT call fn_contract_activity_create here (the rich approval_decided
  -- activity is emitted by fn_approval_decide). One status_changed (lifecycle)
  -- + one approval_decided (operational) per terminal decision — AC-S12-08 / AC-S2-09.
  -- M3 callers (fn_signature_*) emit their own signature_* activity rows.

  RETURN jsonb_build_object(
    'id',         p_contract_id,
    'fromStatus', v_existing_status,
    'toStatus',   p_new_status,
    'changedAt',  CURRENT_TIMESTAMP
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_status_update_internal(BIGINT, TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_status_update_internal(BIGINT, TEXT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_status_update_internal(BIGINT, TEXT, BIGINT, TEXT) IS
  'M3 (033) — SECURITY DEFINER, system-only. Allowed-transitions extended for signature lifecycle: approved -> awaiting_signature_employer; awaiting_signature_* -> {awaiting_signature_counterparty, fully_signed, rejected, expired, approved (cancel-rollback)}. M2 (026) in_approval -> {approved,rejected,draft} preserved. REVOKE FROM PUBLIC; GRANT EXECUTE TO neondb_owner.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (33, 'm3_extend_fn_contract_status_update_internal_for_signatures', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;

-- Restore canonical M2 026 body verbatim.
CREATE OR REPLACE FUNCTION fn_contract_status_update_internal(
  p_contract_id BIGINT,
  p_new_status  TEXT,
  p_actor_id    BIGINT,
  p_reason      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_status TEXT;
BEGIN
  SELECT status INTO v_existing_status
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_status_update_internal: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    v_existing_status = 'in_approval'
    AND p_new_status IN ('approved','rejected','draft')
  ) THEN
    RAISE EXCEPTION 'fn_contract_status_update_internal: %',
      format('newStatus:Internal-only transition violation (from %s to %s)', v_existing_status, p_new_status)
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE contract
    SET status     = p_new_status,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_contract_id;

  RETURN jsonb_build_object(
    'id',         p_contract_id,
    'fromStatus', v_existing_status,
    'toStatus',   p_new_status,
    'changedAt',  CURRENT_TIMESTAMP
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_status_update_internal(BIGINT, TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_status_update_internal(BIGINT, TEXT, BIGINT, TEXT) TO neondb_owner;

DELETE FROM schema_migrations WHERE version = 33;
COMMIT;
-- ROLLBACK END
