-- ============================================================================
-- 026_m2_split_fn_contract_status_update.sql — AE-2 M1a placeholder split
-- ============================================================================
-- Module:    M2 (Approval Workflows)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   005_m1a_contract_functions.sql (M1a placeholder),
--            023_m2_extend_contract_status_check.sql (16-value enum)
-- ----------------------------------------------------------------------------
-- AE-2 — DROP the M1a placeholder fn_contract_status_update(BIGINT,TEXT,BIGINT,TEXT)
-- and CREATE two replacements:
--   (a) fn_contract_status_update_user      — INVOKER, drafter narrow transitions
--                                              FOR UPDATE on contract row (UPGRADE
--                                              over M1a placeholder which had no lock)
--   (b) fn_contract_status_update_internal  — SECURITY DEFINER, system-only,
--                                              REVOKE FROM PUBLIC; GRANT EXECUTE TO
--                                              neondb_owner. Called only by
--                                              fn_approval_decide.
--
-- S2-17: M1a placeholder body preserved for forensic reference. The activity
-- emit pattern (fn_contract_activity_create with status_changed metadata
-- duplicate-guard via fn_trg_contract_activity_emit) is preserved.
-- ----------------------------------------------------------------------------

BEGIN;

-- DROP M1a placeholder
DROP FUNCTION IF EXISTS fn_contract_status_update(BIGINT, TEXT, BIGINT, TEXT);

-- ============================================================
-- fn_contract_status_update_user (INVOKER, drafter-facing wrapper)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_status_update_user(
  p_contract_id BIGINT,
  p_new_status  TEXT,
  p_actor_id    BIGINT,
  p_reason      TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_status TEXT;
  v_existing_owner  BIGINT;
  v_route_init_result JSONB;
  v_is_owner        BOOLEAN := FALSE;
BEGIN
  IF p_new_status IS NULL OR p_new_status = '' THEN
    RAISE EXCEPTION 'fn_contract_status_update_user: %', 'newStatus:newStatus is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_new_status NOT IN (
    'draft','in_review','approved',
    'awaiting_signature_employer','awaiting_signature_counterparty','fully_signed',
    'active','expiring_soon','expired',
    'amended','renewed','terminated',
    'rejected','resubmission_requested',
    'in_approval','cancelled'
  ) THEN
    RAISE EXCEPTION 'fn_contract_status_update_user: %', 'newStatus:Invalid status'
      USING ERRCODE = '23514';
  END IF;

  -- Lock contract row (UPGRADE — M1a placeholder had no lock)
  SELECT status, created_by INTO v_existing_status, v_existing_owner
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_status_update_user: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_existing_status = p_new_status THEN
    RAISE EXCEPTION 'fn_contract_status_update_user: %',
      'newStatus:Status is already ' || p_new_status
      USING ERRCODE = 'P0001';
  END IF;

  v_is_owner := (v_existing_owner IS NOT DISTINCT FROM p_actor_id);

  -- Reject in_approval terminal direct overrides (M2-NEW-1 / AC-S12-02)
  IF v_existing_status = 'in_approval' AND p_new_status IN ('approved','rejected','resubmission_requested') THEN
    RAISE EXCEPTION 'fn_contract_status_update_user: %',
      'newStatus:Use fn_approval_decide for in_approval transitions'
      USING ERRCODE = 'P0001';
  END IF;

  -- Whitelist + per-transition permission gate
  IF v_existing_status = 'draft' AND p_new_status = 'in_review' THEN
    IF NOT fn_current_user_has_permission('approval.submit_for_review') THEN
      RAISE EXCEPTION 'fn_contract_status_update_user: %', 'permission:approval.submit_for_review required'
        USING ERRCODE = '42501';
    END IF;
  ELSIF v_existing_status = 'in_review' AND p_new_status = 'draft' THEN
    IF NOT (
      (fn_current_user_has_permission('approval.submit_for_review') AND v_is_owner)
      OR fn_current_user_has_permission('contract.delete')
    ) THEN
      RAISE EXCEPTION 'fn_contract_status_update_user: %', 'permission:approval.submit_for_review (own contract) or contract.delete required'
        USING ERRCODE = '42501';
    END IF;
  ELSIF v_existing_status = 'in_review' AND p_new_status = 'in_approval' THEN
    IF NOT fn_current_user_has_permission('approval.submit_for_review') THEN
      RAISE EXCEPTION 'fn_contract_status_update_user: %', 'permission:approval.submit_for_review required'
        USING ERRCODE = '42501';
    END IF;
    -- Delegate to fn_approval_route_init within the same transaction
    SELECT fn_approval_route_init(p_contract_id, p_actor_id) INTO v_route_init_result;
    RETURN jsonb_build_object(
      'id',         p_contract_id,
      'fromStatus', v_existing_status,
      'toStatus',   'in_approval',
      'changedAt',  CURRENT_TIMESTAMP,
      'routeInit',  v_route_init_result
    );
  ELSIF v_existing_status = 'approved' AND p_new_status = 'active' THEN
    IF NOT fn_current_user_has_permission('contract.edit') THEN
      RAISE EXCEPTION 'fn_contract_status_update_user: %', 'permission:contract.edit required'
        USING ERRCODE = '42501';
    END IF;
  ELSIF p_new_status = 'cancelled' AND v_existing_status NOT IN ('approved','active','expired','terminated','cancelled','rejected','fully_signed','expiring_soon','amended','renewed') THEN
    -- non-terminal -> cancelled (drafter ownership OR contract.delete)
    IF NOT (
      fn_current_user_has_permission('contract.delete')
      OR (fn_current_user_has_permission('contract.draft') AND v_is_owner)
    ) THEN
      RAISE EXCEPTION 'fn_contract_status_update_user: %', 'permission:contract.delete or (contract.draft + ownership) required'
        USING ERRCODE = '42501';
    END IF;
  ELSIF p_new_status = 'cancelled' AND v_existing_status IN ('approved','active','fully_signed','expiring_soon') THEN
    -- Admin-only override path
    IF NOT fn_current_user_has_permission('contract.delete') THEN
      RAISE EXCEPTION 'fn_contract_status_update_user: %', 'permission:contract.delete required (admin override)'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'fn_contract_status_update_user: %',
      format('newStatus:Invalid transition from %s to %s', v_existing_status, p_new_status)
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE contract
    SET status     = p_new_status,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_contract_id;

  -- Preserve M1a duplicate-guard pattern: emit explicit activity row with reason metadata.
  -- The fn_trg_contract_activity_emit AFTER UPDATE trigger detects within-1-second matching
  -- payload and skips re-emission, so this is exactly one row per transition.
  PERFORM fn_contract_activity_create(
    p_contract_id,
    'status_changed',
    p_actor_id,
    NULL, NULL,
    jsonb_build_object('fromStatus', v_existing_status, 'toStatus', p_new_status, 'reason', p_reason)
  );

  RETURN jsonb_build_object(
    'id',         p_contract_id,
    'fromStatus', v_existing_status,
    'toStatus',   p_new_status,
    'changedAt',  CURRENT_TIMESTAMP
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_status_update_user: %'
       OR SQLERRM LIKE 'fn_approval_route_init: %'
       OR SQLERRM LIKE 'fn_contract_activity_create: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_status_update_user: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_status_update_user(BIGINT, TEXT, BIGINT, TEXT) IS
  'M2 AE-2 — INVOKER. Drafter-facing status writer. Owns non-chain transitions: draft<->in_review, in_review->in_approval (via fn_approval_route_init), approved->active, any non-terminal -> cancelled. FOR UPDATE on contract row (UPGRADE over M1a placeholder). Rejects in_approval direct overrides with 409 (M2-NEW-1).';

-- ============================================================
-- fn_contract_status_update_internal (DEFINER, system-only)
-- ============================================================
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

  -- The trg_contract_activity_emit_iu trigger emits 'status_changed' on this UPDATE.
  -- We do NOT call fn_contract_activity_create here (the rich approval_decided
  -- activity is emitted by fn_approval_decide). One status_changed (lifecycle)
  -- + one approval_decided (operational) per terminal decision — AC-S12-08 / AC-S2-09.

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
  'M2 AE-2 — SECURITY DEFINER, system-only. Approval engine terminal-state writer for in_approval -> {approved,rejected,draft}. REVOKE FROM PUBLIC; GRANT EXECUTE TO neondb_owner. Called by fn_approval_decide.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (26, 'm2_split_fn_contract_status_update', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP FUNCTION IF EXISTS fn_contract_status_update_user(BIGINT, TEXT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_contract_status_update_internal(BIGINT, TEXT, BIGINT, TEXT);
-- Restore M1a 005 placeholder body verbatim
CREATE OR REPLACE FUNCTION fn_contract_status_update(
  p_id         BIGINT,
  p_new_status TEXT,
  p_actor_id   BIGINT,
  p_reason     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_status TEXT;
BEGIN
  SELECT status INTO v_existing_status
    FROM contract
    WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_status_update: %', 'id:Contract not found';
  END IF;

  IF p_new_status NOT IN ('draft','in_review','approved','awaiting_signature_employer','awaiting_signature_counterparty','fully_signed','active','expiring_soon','expired','amended','renewed','terminated','rejected','resubmission_requested') THEN
    RAISE EXCEPTION 'fn_contract_status_update: %', 'newStatus:Invalid status';
  END IF;

  IF v_existing_status = p_new_status THEN
    RAISE EXCEPTION 'fn_contract_status_update: %', 'newStatus:Status is already ' || p_new_status;
  END IF;

  UPDATE contract
    SET status = p_new_status,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_id;

  PERFORM fn_contract_activity_create(
    p_id,
    'status_changed',
    p_actor_id,
    NULL,
    NULL,
    jsonb_build_object('fromStatus', v_existing_status, 'toStatus', p_new_status, 'reason', p_reason)
  );

  RETURN jsonb_build_object(
    'id', p_id,
    'fromStatus', v_existing_status,
    'toStatus', p_new_status,
    'changedAt', CURRENT_TIMESTAMP
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_status_update: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_status_update: %', SQLERRM;
    END IF;
END;
$$;
DELETE FROM schema_migrations WHERE version = 26;
COMMIT;
-- ROLLBACK END
