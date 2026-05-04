-- ============================================================================
-- 031_m2_fix_actor_check_and_cron_actor.sql — M2 bug-fix cycle 1
-- ============================================================================
-- Module:    M2 (Approval Workflows) — Phase 2 fix loop, cycle 1
-- Owner:     Agent 6 — DB Implementation (BUG-FIX MODE)
-- Depends:   025_m2_approval_functions.sql (broken fn_approval_decide body),
--            027_m2_extend_fn_contract_activity_create_whitelist.sql (broken
--            fn_contract_activity_create body w/r/t system-actor=0 fallback).
-- ----------------------------------------------------------------------------
-- Two HIGH-severity bugs, fixed via two CREATE OR REPLACE FUNCTION statements.
-- Per the report-don't-fix protocol: this is an additive forward-fix migration;
-- migrations 023..030 are immutable history.
--
-- BUG 1 — fn_approval_decide actor check is NULL-OR-fragile (AC-S2-04 db + be).
--   The OR-chain `approver_user_id = p_actor_id OR delegated_to = p_actor_id
--   OR reassigned_to = p_actor_id` evaluates to NULL under SQL three-valued
--   logic when delegated_to and reassigned_to are NULL. plpgsql `IF NULL`
--   is treated as FALSE, so the actor RAISE is BYPASSED and any user with
--   approval.act permission can decide on any pending step. Privilege
--   escalation. Fix: NULL-safe equality via `IS NOT DISTINCT FROM` — the same
--   pattern fn_approval_delegate already uses (migration 025 line 1030).
--
-- BUG 2 — fn_approval_escalate FK-violates contract_activity.actor_id when
--   called by the BE cron driver (AC-S9-01, AC-S9-04, AC-S9-08).
--   fn_approval_escalate calls fn_contract_activity_create with p_actor_id=NULL.
--   fn_contract_activity_create then falls back to GUC app.current_user_id.
--   The cron driver (src/services/approval-escalation.cron.service.ts) sets
--   app.current_user_id='0' (SYSTEM_ACTOR_ID), which is INSERTed into
--   contract_activity.actor_id — but no user.id=0 row exists, so the FK
--   contract_activity_actor_id_fkey rejects with SQLSTATE 23503. The cron
--   wraps the call in try/catch + logs as "non-fatal" → SILENTLY BROKEN in
--   prod. Fix: in fn_contract_activity_create, after resolving v_actor, treat
--   `v_actor IS NULL OR v_actor = 0` as a system event and INSERT actor_id=NULL.
--   contract_activity.actor_id is already nullable (M1a 003 line 18:
--   `actor_id BIGINT REFERENCES "user"(id) ON DELETE SET NULL`) — no ALTER
--   TABLE needed.
--
-- S2-17 fidelity: both fn_'s are re-issued as CREATE OR REPLACE with the
-- bug-fix only — every other byte preserved verbatim against the canonical
-- migration 025 / 027 bodies.
--
--   fn_approval_decide   — preserved: signature, LANGUAGE, SECURITY INVOKER,
--                          search_path, all DECLARE, all branching logic,
--                          all PERFORM/UPDATE/INSERT, all RETURN keys,
--                          parallel-group resolution, reject/resub paths,
--                          terminal-approve fn_contract_status_update_internal
--                          call, audit-after-render. ONLY changed: the 4-line
--                          actor IF-NOT block now uses IS NOT DISTINCT FROM.
--   fn_contract_activity_create — preserved: signature, LANGUAGE, SECURITY
--                          DEFINER, search_path, REVOKE/GRANT, 14-value
--                          whitelist (per M2 027), GUC fallback, INSERT.
--                          ONLY changed: a single 3-line block coerces
--                          v_actor=0 → NULL just before the INSERT.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. fn_approval_decide — BUG 1 fix
--    Replace the actor IF-NOT block with NULL-safe IS NOT DISTINCT FROM.
--    Everything else is byte-for-byte identical to migration 025 lines 774-986.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_decide(
  p_step_id       BIGINT,
  p_actor_id      BIGINT,
  p_decision      TEXT,
  p_decision_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step                  RECORD;
  v_chain                 RECORD;
  v_contract_id           BIGINT;
  v_remaining_required    INTEGER;
  v_any_optional_peer     BOOLEAN;
  v_advance               BOOLEAN := FALSE;
  v_next_step_order       INTEGER;
  v_new_step_status       TEXT;
  v_new_chain_status      TEXT;
  v_new_contract_status   TEXT;
  v_advanced_to_step_order INTEGER;
  v_decision_id           BIGINT;
BEGIN
  IF p_decision NOT IN ('approve','reject','request_resubmission') THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'decision:Invalid decision'
      USING ERRCODE = '22023';
  END IF;

  SELECT s.*
    INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- BUG 1 FIX (031): NULL-safe actor check via IS NOT DISTINCT FROM.
  -- Original (broken) used `=` which yields NULL when delegated_to / reassigned_to
  -- are NULL — plpgsql treats `IF NULL` as FALSE so the RAISE was BYPASSED.
  -- IS NOT DISTINCT FROM is NULL-safe equality (NULL <> p_actor_id reliably FALSE).
  IF NOT (
    v_step.approver_user_id IS NOT DISTINCT FROM p_actor_id
    OR v_step.delegated_to  IS NOT DISTINCT FROM p_actor_id
    OR v_step.reassigned_to IS NOT DISTINCT FROM p_actor_id
  ) THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'actor:Not the assigned approver'
      USING ERRCODE = '42501';
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'status:Step already decided'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_decision IN ('reject','request_resubmission')
     AND (p_decision_note IS NULL OR length(trim(p_decision_note)) = 0) THEN
    RAISE EXCEPTION 'fn_approval_decide: %',
      format('decisionNote:decisionNote is required for %s', p_decision)
      USING ERRCODE = '22023';
  END IF;

  SELECT ch.*
    INTO v_chain
    FROM approval_chain ch
    WHERE ch.id = v_step.approval_chain_id
    FOR UPDATE;
  IF v_chain.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Chain not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_contract_id := v_chain.contract_id;
  PERFORM 1 FROM contract WHERE id = v_contract_id FOR UPDATE;

  -- Compute new step status
  v_new_step_status := CASE p_decision
    WHEN 'approve' THEN 'approved'
    WHEN 'reject' THEN 'rejected'
    WHEN 'request_resubmission' THEN 'resubmission_requested'
  END;

  UPDATE approval_step
    SET status     = v_new_step_status,
        decided_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_step_id;

  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    decided_at, created_by, is_active
  ) VALUES (
    p_step_id, p_decision, p_actor_id, p_decision_note,
    CURRENT_TIMESTAMP, p_actor_id, TRUE
  ) RETURNING id INTO v_decision_id;

  -- Reject (required) or request_resubmission -> chain halts
  IF p_decision = 'reject' AND v_step.is_required THEN
    UPDATE approval_chain
      SET status = 'rejected',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'rejected';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'rejected', p_actor_id, p_decision_note);
    v_new_contract_status := 'rejected';
  ELSIF p_decision = 'request_resubmission' THEN
    UPDATE approval_chain
      SET status = 'resubmission_requested',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'resubmission_requested';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'draft', p_actor_id, p_decision_note);
    v_new_contract_status := 'draft';
  ELSIF p_decision = 'approve' THEN
    -- Parallel-group resolution
    SELECT EXISTS (
      SELECT 1 FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_active = TRUE
          AND is_required = FALSE
    ) INTO v_any_optional_peer;

    IF v_any_optional_peer AND v_step.is_required THEN
      -- ANY-OF rule (mixed required + optional peers): approving the required short-circuits the rest
      UPDATE approval_step
        SET status     = 'skipped',
            decided_at = CURRENT_TIMESTAMP,
            updated_by = p_actor_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := TRUE;
    ELSE
      -- ALL-OF rule: advance only when no required peer remains pending
      SELECT COUNT(*)
        INTO v_remaining_required
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_required = TRUE
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := (v_remaining_required = 0);
    END IF;

    IF v_advance THEN
      SELECT MIN(step_order) INTO v_next_step_order
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND status = 'pending'
          AND step_order > v_step.step_order
          AND is_active = TRUE;
      IF v_next_step_order IS NULL THEN
        UPDATE approval_chain
          SET status = 'approved',
              current_step_order = v_step.step_order,
              completed_at = CURRENT_TIMESTAMP,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'approved';
        PERFORM fn_contract_status_update_internal(v_contract_id, 'approved', p_actor_id, p_decision_note);
        v_new_contract_status := 'approved';
      ELSE
        UPDATE approval_chain
          SET current_step_order = v_next_step_order,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'in_progress';
        v_new_contract_status := 'in_approval';
        v_advanced_to_step_order := v_next_step_order;
      END IF;
    ELSE
      v_new_chain_status := 'in_progress';
      v_new_contract_status := 'in_approval';
    END IF;
  END IF;

  -- AUDIT-AFTER-RENDER (BE-M1b-004)
  PERFORM fn_contract_activity_create(
    v_contract_id, 'approval_decided', p_actor_id, NULL, NULL,
    jsonb_build_object(
      'chainId',         v_chain.id,
      'stepId',          p_step_id,
      'decision',        p_decision,
      'newStepStatus',   v_new_step_status,
      'newChainStatus',  v_new_chain_status,
      'newContractStatus', v_new_contract_status
    )
  );

  RETURN jsonb_build_object(
    'stepId',                p_step_id,
    'chainId',               v_chain.id,
    'contractId',            v_contract_id,
    'decisionId',            v_decision_id,
    'newStepStatus',         v_new_step_status,
    'newChainStatus',        v_new_chain_status,
    'newContractStatus',     v_new_contract_status,
    'advancedToStepOrder',   v_advanced_to_step_order,
    'allChainStepsResolved', (v_new_chain_status <> 'in_progress')
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_decide(BIGINT, BIGINT, TEXT, TEXT) IS
  'M2 S2 — write, INVOKER. Approver acts on a step. Parallel-aware. Atomically inserts decision row, updates step+chain+contract status. Calls fn_contract_status_update_internal for terminal contract transitions. M2-031: actor check made NULL-safe via IS NOT DISTINCT FROM (was bypassed by 3VL when delegated_to/reassigned_to were NULL).';

-- ============================================================
-- 2. fn_contract_activity_create — BUG 2 fix
--    Coerce v_actor=0 (SYSTEM_ACTOR_ID sentinel) to NULL so the cron driver's
--    SET app.current_user_id='0' produces a system-event row (actor_id=NULL)
--    rather than FK-violating against user(id). Everything else is byte-for-byte
--    identical to migration 027 lines 43-87.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_activity_create(
  p_contract_id    BIGINT,
  p_activity_type  TEXT,
  p_actor_id       BIGINT       DEFAULT NULL,
  p_description_en TEXT         DEFAULT NULL,
  p_description_ar TEXT         DEFAULT NULL,
  p_metadata       JSONB        DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id      BIGINT;
  v_actor   BIGINT;
BEGIN
  -- Whitelist extended in M2 (027) to include 5 approval-namespace activity types.
  -- (CMW M2 027 also extended the table CHECK constraint above.)
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type'
      USING ERRCODE = '23514';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
  END IF;

  -- BUG 2 FIX (031): system-event coercion. The cron driver
  -- (src/services/approval-escalation.cron.service.ts) sets
  -- app.current_user_id='0' as a SYSTEM_ACTOR_ID sentinel before invoking
  -- fn_approval_escalate (which calls this fn with p_actor_id=NULL). user.id=0
  -- does NOT exist, so the previous code FK-violated on contract_activity.actor_id.
  -- Treat v_actor IN (NULL, 0) as a system event → INSERT actor_id=NULL.
  -- contract_activity.actor_id is nullable (M1a 003: REFERENCES "user"(id) ON DELETE SET NULL).
  IF v_actor IS NULL OR v_actor = 0 THEN
    v_actor := NULL;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) IS
  'INTERNAL helper. SECURITY DEFINER. Invoked by triggers + fn_contract_status_update_user/_internal + fn_approval_* directly when richer metadata than the trigger has access to is needed. EXECUTE granted only to neondb_owner — bypasses contract_activity RLS deny-direct-INSERT. M2 (027): whitelist extended to 14 values incl. submitted_for_approval, approval_decided, approval_reassigned, approval_escalated, approval_delegated. M2 (031): v_actor=0 (SYSTEM_ACTOR_ID sentinel from BE cron driver) coerced to NULL to avoid FK violation on contract_activity.actor_id.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (31, 'm2_fix_actor_check_and_cron_actor', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Re-creates the BROKEN bodies of fn_approval_decide and fn_contract_activity_create
-- exactly as they existed before 031 (i.e. matching migrations 025 / 027 verbatim).
-- After rollback the two HIGH-severity bugs RETURN. Do not deploy a rolled-back
-- system to production.
BEGIN;

CREATE OR REPLACE FUNCTION fn_approval_decide(
  p_step_id       BIGINT,
  p_actor_id      BIGINT,
  p_decision      TEXT,
  p_decision_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step                  RECORD;
  v_chain                 RECORD;
  v_contract_id           BIGINT;
  v_remaining_required    INTEGER;
  v_any_optional_peer     BOOLEAN;
  v_advance               BOOLEAN := FALSE;
  v_next_step_order       INTEGER;
  v_new_step_status       TEXT;
  v_new_chain_status      TEXT;
  v_new_contract_status   TEXT;
  v_advanced_to_step_order INTEGER;
  v_decision_id           BIGINT;
BEGIN
  IF p_decision NOT IN ('approve','reject','request_resubmission') THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'decision:Invalid decision'
      USING ERRCODE = '22023';
  END IF;

  SELECT s.*
    INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    v_step.approver_user_id = p_actor_id
    OR v_step.delegated_to  = p_actor_id
    OR v_step.reassigned_to = p_actor_id
  ) THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'actor:Not the assigned approver'
      USING ERRCODE = '42501';
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'status:Step already decided'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_decision IN ('reject','request_resubmission')
     AND (p_decision_note IS NULL OR length(trim(p_decision_note)) = 0) THEN
    RAISE EXCEPTION 'fn_approval_decide: %',
      format('decisionNote:decisionNote is required for %s', p_decision)
      USING ERRCODE = '22023';
  END IF;

  SELECT ch.*
    INTO v_chain
    FROM approval_chain ch
    WHERE ch.id = v_step.approval_chain_id
    FOR UPDATE;
  IF v_chain.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Chain not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_contract_id := v_chain.contract_id;
  PERFORM 1 FROM contract WHERE id = v_contract_id FOR UPDATE;

  v_new_step_status := CASE p_decision
    WHEN 'approve' THEN 'approved'
    WHEN 'reject' THEN 'rejected'
    WHEN 'request_resubmission' THEN 'resubmission_requested'
  END;

  UPDATE approval_step
    SET status     = v_new_step_status,
        decided_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_step_id;

  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    decided_at, created_by, is_active
  ) VALUES (
    p_step_id, p_decision, p_actor_id, p_decision_note,
    CURRENT_TIMESTAMP, p_actor_id, TRUE
  ) RETURNING id INTO v_decision_id;

  IF p_decision = 'reject' AND v_step.is_required THEN
    UPDATE approval_chain
      SET status = 'rejected',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'rejected';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'rejected', p_actor_id, p_decision_note);
    v_new_contract_status := 'rejected';
  ELSIF p_decision = 'request_resubmission' THEN
    UPDATE approval_chain
      SET status = 'resubmission_requested',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'resubmission_requested';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'draft', p_actor_id, p_decision_note);
    v_new_contract_status := 'draft';
  ELSIF p_decision = 'approve' THEN
    SELECT EXISTS (
      SELECT 1 FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_active = TRUE
          AND is_required = FALSE
    ) INTO v_any_optional_peer;

    IF v_any_optional_peer AND v_step.is_required THEN
      UPDATE approval_step
        SET status     = 'skipped',
            decided_at = CURRENT_TIMESTAMP,
            updated_by = p_actor_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := TRUE;
    ELSE
      SELECT COUNT(*)
        INTO v_remaining_required
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_required = TRUE
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := (v_remaining_required = 0);
    END IF;

    IF v_advance THEN
      SELECT MIN(step_order) INTO v_next_step_order
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND status = 'pending'
          AND step_order > v_step.step_order
          AND is_active = TRUE;
      IF v_next_step_order IS NULL THEN
        UPDATE approval_chain
          SET status = 'approved',
              current_step_order = v_step.step_order,
              completed_at = CURRENT_TIMESTAMP,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'approved';
        PERFORM fn_contract_status_update_internal(v_contract_id, 'approved', p_actor_id, p_decision_note);
        v_new_contract_status := 'approved';
      ELSE
        UPDATE approval_chain
          SET current_step_order = v_next_step_order,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'in_progress';
        v_new_contract_status := 'in_approval';
        v_advanced_to_step_order := v_next_step_order;
      END IF;
    ELSE
      v_new_chain_status := 'in_progress';
      v_new_contract_status := 'in_approval';
    END IF;
  END IF;

  PERFORM fn_contract_activity_create(
    v_contract_id, 'approval_decided', p_actor_id, NULL, NULL,
    jsonb_build_object(
      'chainId',         v_chain.id,
      'stepId',          p_step_id,
      'decision',        p_decision,
      'newStepStatus',   v_new_step_status,
      'newChainStatus',  v_new_chain_status,
      'newContractStatus', v_new_contract_status
    )
  );

  RETURN jsonb_build_object(
    'stepId',                p_step_id,
    'chainId',               v_chain.id,
    'contractId',            v_contract_id,
    'decisionId',            v_decision_id,
    'newStepStatus',         v_new_step_status,
    'newChainStatus',        v_new_chain_status,
    'newContractStatus',     v_new_contract_status,
    'advancedToStepOrder',   v_advanced_to_step_order,
    'allChainStepsResolved', (v_new_chain_status <> 'in_progress')
  );
END;
$$;

CREATE OR REPLACE FUNCTION fn_contract_activity_create(
  p_contract_id    BIGINT,
  p_activity_type  TEXT,
  p_actor_id       BIGINT       DEFAULT NULL,
  p_description_en TEXT         DEFAULT NULL,
  p_description_ar TEXT         DEFAULT NULL,
  p_metadata       JSONB        DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id      BIGINT;
  v_actor   BIGINT;
BEGIN
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type'
      USING ERRCODE = '23514';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

DELETE FROM schema_migrations WHERE version = 31;
COMMIT;
-- ROLLBACK END
