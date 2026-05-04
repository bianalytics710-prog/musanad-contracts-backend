-- ============================================================================
-- 036_m3_signature_functions.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   035_m3_signature_tables.sql (tables, RLS, triggers, ref seeds);
--            033 (extended fn_contract_status_update_internal);
--            032 (extended fn_contract_activity_create whitelist).
-- ----------------------------------------------------------------------------
-- 11 new fn_ + GRANT EXECUTE matrix:
--   PUBLIC (5):   fn_signature_get_by_invitation_token,
--                 fn_signature_sign,
--                 fn_signature_decline,
--                 fn_signer_qa_session_start,
--                 fn_signer_qa_session_record_message
--   neondb_owner: fn_signature_party_create_bulk (INVOKER),
--                 fn_signature_send_for_signature (INVOKER),
--                 fn_signature_invitation_resend (INVOKER),
--                 fn_signature_invitation_cancel (INVOKER),
--                 fn_signature_list_for_contract (INVOKER),
--                 fn_signature_invitation_expire_due (DEFINER, system-cron)
--
-- IMPL NOTE: The design's prose called fn_current_user_has_permission with a
-- 2-arg form (actor + code). The canonical signature is single-arg (p_code TEXT)
-- and reads actor via GUC app.current_user_id. We call the 1-arg form. (S2-19
-- fn-to-fn signature verification — reported and correctly used.)
--
-- ALL fn_ JSONB keys are camelCase. SENSITIVE (signer_email, signer_phone,
-- signature_data, signature_image_url, *_token_hash) NEVER appear in
-- RAISE EXCEPTION messages. Plaintext tokens returned ONCE at creation only.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. fn_signature_party_create_bulk (INVOKER)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_party_create_bulk(
  p_contract_id BIGINT,
  p_signers     JSONB,
  p_actor_id    BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract             RECORD;
  v_approval_chain_count INTEGER;
  v_signer               JSONB;
  v_signer_idx           INTEGER := 0;
  v_signers_len          INTEGER;
  v_has_employer         BOOLEAN := FALSE;
  v_created_count        INTEGER := 0;
  v_skipped_count        INTEGER := 0;
  v_inserted_id          BIGINT;
  v_party_summary        JSONB;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('signature.send') THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %', 'permission:signature.send required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Lock contract row + validate
  SELECT id, status, is_active INTO v_contract
    FROM contract
    WHERE id = p_contract_id
    FOR UPDATE;
  IF NOT FOUND OR v_contract.is_active IS NOT TRUE THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- 3. status MUST be 'approved'
  IF v_contract.status IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %',
      format('precondition_failed:contract_status_not_approved (current=%s)', v_contract.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- 4. At least one approval_chain row with status='approved'
  SELECT COUNT(*) INTO v_approval_chain_count
    FROM approval_chain
    WHERE contract_id = p_contract_id
      AND status = 'approved'
      AND is_active = TRUE;
  IF v_approval_chain_count = 0 THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %', 'precondition_failed:no_approved_chain'
      USING ERRCODE = 'P0001';
  END IF;

  -- 5. Validate p_signers is array of length 1..20
  IF p_signers IS NULL OR jsonb_typeof(p_signers) <> 'array' THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %', 'p_signers:Must be a JSONB array'
      USING ERRCODE = '22023';
  END IF;
  v_signers_len := jsonb_array_length(p_signers);
  IF v_signers_len < 1 OR v_signers_len > 20 THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %',
      format('p_signers:Length must be between 1 and 20 (got %s)', v_signers_len)
      USING ERRCODE = '22023';
  END IF;

  -- 6. At least one element has signer_side='employer' AND is_required=TRUE
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_signers) AS s
    WHERE s->>'signerSide' = 'employer'
      AND COALESCE((s->>'isRequired')::BOOLEAN, TRUE) = TRUE
  ) INTO v_has_employer;
  IF NOT v_has_employer THEN
    RAISE EXCEPTION 'fn_signature_party_create_bulk: %', 'p_signers:At least one employer signer is required'
      USING ERRCODE = '22023';
  END IF;

  -- 7. Loop and INSERT each signer
  FOR v_signer IN SELECT * FROM jsonb_array_elements(p_signers) LOOP
    v_signer_idx := v_signer_idx + 1;

    -- Validate signer_name_en not blank
    IF v_signer->>'signerNameEn' IS NULL OR length(btrim(v_signer->>'signerNameEn')) = 0 THEN
      RAISE EXCEPTION 'fn_signature_party_create_bulk: %',
        format('p_signers[%s].signerNameEn:Required and non-blank', v_signer_idx)
        USING ERRCODE = '22023';
    END IF;

    -- INSERT with idempotency guard
    BEGIN
      INSERT INTO signature_party (
        contract_id, signer_side, signer_user_id,
        signer_name_en, signer_name_ar, signer_email, signer_phone,
        signer_party_id, step_order, is_required,
        created_by, updated_by
      ) VALUES (
        p_contract_id,
        v_signer->>'signerSide',
        NULLIF(v_signer->>'signerUserId','')::BIGINT,
        v_signer->>'signerNameEn',
        v_signer->>'signerNameAr',
        v_signer->>'signerEmail',
        v_signer->>'signerPhone',
        NULLIF(v_signer->>'signerPartyId','')::BIGINT,
        COALESCE((v_signer->>'stepOrder')::INTEGER, 1),
        COALESCE((v_signer->>'isRequired')::BOOLEAN, TRUE),
        p_actor_id, p_actor_id
      )
      ON CONFLICT (contract_id, step_order, lower(signer_email))
        WHERE is_active = TRUE AND signer_email IS NOT NULL
      DO NOTHING
      RETURNING id INTO v_inserted_id;

      IF v_inserted_id IS NOT NULL THEN
        v_created_count := v_created_count + 1;
        v_inserted_id := NULL;
      ELSE
        v_skipped_count := v_skipped_count + 1;
      END IF;
    END;
  END LOOP;

  -- 8. Build response (project active parties)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', sp.id,
      'contractId', sp.contract_id,
      'signerSide', sp.signer_side,
      'signerUserId', sp.signer_user_id,
      'signerNameEn', sp.signer_name_en,
      'signerNameAr', sp.signer_name_ar,
      'signerEmail', sp.signer_email,
      'stepOrder', sp.step_order,
      'isRequired', sp.is_required,
      'isActive', sp.is_active,
      'createdAt', sp.created_at,
      'updatedAt', sp.updated_at
    ) ORDER BY sp.step_order ASC, sp.id ASC
  ), '[]'::jsonb) INTO v_party_summary
  FROM signature_party sp
  WHERE sp.contract_id = p_contract_id AND sp.is_active = TRUE;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'signatureParties', v_party_summary,
      'createdCount', v_created_count,
      'skippedCount', v_skipped_count
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_party_create_bulk(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_party_create_bulk(BIGINT, JSONB, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_party_create_bulk(BIGINT, JSONB, BIGINT) IS
  'M3 (036) — INVOKER. Bulk-creates signature_party roster for an approved contract. Idempotent via unique partial index ON (contract_id, step_order, lower(signer_email)) WHERE is_active=TRUE AND signer_email IS NOT NULL. Permission: signature.send.';

-- ============================================================================
-- 2. fn_signature_send_for_signature (INVOKER)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_send_for_signature(
  p_contract_id BIGINT,
  p_actor_id    BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract        RECORD;
  v_min_step        INTEGER;
  v_party           RECORD;
  v_token_plain     TEXT;
  v_token_hash      TEXT;
  v_invitation_id   BIGINT;
  v_invitations     JSONB := '[]'::JSONB;
  v_lang            TEXT;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_expires_at      TIMESTAMPTZ;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('signature.send') THEN
    RAISE EXCEPTION 'fn_signature_send_for_signature: %', 'permission:signature.send required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Lock contract + validate
  SELECT id, status, is_active INTO v_contract
    FROM contract
    WHERE id = p_contract_id
    FOR UPDATE;
  IF NOT FOUND OR v_contract.is_active IS NOT TRUE THEN
    RAISE EXCEPTION 'fn_signature_send_for_signature: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- 3. Validate status='approved'
  IF v_contract.status IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION 'fn_signature_send_for_signature: %',
      format('precondition_failed:invalid_status_for_send (current=%s,expected=approved)', v_contract.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- 4. Compute v_min_step over required active parties
  SELECT MIN(step_order) INTO v_min_step
    FROM signature_party
    WHERE contract_id = p_contract_id
      AND is_active = TRUE
      AND is_required = TRUE;
  IF v_min_step IS NULL THEN
    RAISE EXCEPTION 'fn_signature_send_for_signature: %', 'precondition_failed:no_signature_parties'
      USING ERRCODE = 'P0001';
  END IF;

  v_expires_at := v_now + INTERVAL '14 days';

  -- 5. For each active signature_party at v_min_step, issue invitation
  FOR v_party IN
    SELECT id, signer_email, signer_user_id
      FROM signature_party
      WHERE contract_id = p_contract_id
        AND step_order = v_min_step
        AND is_active = TRUE
      ORDER BY id ASC
      FOR UPDATE
  LOOP
    -- Token: 32-byte random base64 ~= 44 chars. base64url-ish (replace +/ with -_).
    v_token_plain := translate(encode(gen_random_bytes(32), 'base64'), '+/=' || E'\n', '-_');
    v_token_hash  := encode(digest(v_token_plain, 'sha256'), 'hex');

    -- Determine language: prefer signer_user.preferred locale if present, else 'en'
    v_lang := 'en';

    INSERT INTO signature_invitation (
      signature_party_id, contract_id, invitation_token_hash,
      status, invitation_sent_at, invitation_expires_at,
      language, created_by, updated_by
    ) VALUES (
      v_party.id, p_contract_id, v_token_hash,
      'pending', v_now, v_expires_at,
      v_lang, p_actor_id, p_actor_id
    ) RETURNING id INTO v_invitation_id;

    v_invitations := v_invitations || jsonb_build_object(
      'signaturePartyId', v_party.id,
      'invitationId', v_invitation_id,
      'invitationTokenPlaintext', v_token_plain,
      'expiresAt', v_expires_at,
      'signerEmail', v_party.signer_email
    );
  END LOOP;

  -- 6. Transition contract status approved -> awaiting_signature_employer
  PERFORM fn_contract_status_update_internal(
    p_contract_id, 'awaiting_signature_employer', p_actor_id, NULL
  );

  -- 7. Activity row
  PERFORM fn_contract_activity_create(
    p_contract_id, 'sent_for_signature', p_actor_id, NULL, NULL,
    jsonb_build_object('signersInvited', jsonb_array_length(v_invitations))
  );

  -- 8. Return
  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractId', p_contract_id,
      'newStatus', 'awaiting_signature_employer',
      'invitations', v_invitations
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_send_for_signature(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_send_for_signature(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_send_for_signature(BIGINT, BIGINT) IS
  'M3 (036) — INVOKER. Issues invitation tokens for the lowest-step_order required signers and transitions contract.status approved -> awaiting_signature_employer. Plaintext tokens returned ONCE per signer. Permission: signature.send.';

-- ============================================================================
-- 3. fn_signature_invitation_resend (INVOKER)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_invitation_resend(
  p_signature_party_id BIGINT,
  p_actor_id           BIGINT,
  p_reason             TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_party           RECORD;
  v_old_inv         RECORD;
  v_token_plain     TEXT;
  v_token_hash      TEXT;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_expires_at      TIMESTAMPTZ;
  v_new_invitation_id BIGINT;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('signature.send') THEN
    RAISE EXCEPTION 'fn_signature_invitation_resend: %', 'permission:signature.send required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Lock signature_party row
  SELECT id, contract_id, is_active INTO v_party
    FROM signature_party
    WHERE id = p_signature_party_id
    FOR UPDATE;
  IF NOT FOUND OR v_party.is_active IS NOT TRUE THEN
    RAISE EXCEPTION 'fn_signature_invitation_resend: %', 'id:Signature party not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- 3. Lock existing active invitation
  SELECT id, status INTO v_old_inv
    FROM signature_invitation
    WHERE signature_party_id = p_signature_party_id
      AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_signature_invitation_resend: %', 'id:No active invitation found for party'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_old_inv.status NOT IN ('pending','viewed','expired') THEN
    RAISE EXCEPTION 'fn_signature_invitation_resend: %',
      format('invalid_invitation_status_for_resend (current=%s)', v_old_inv.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- 4. Soft-deactivate old invitation
  UPDATE signature_invitation
    SET is_active = FALSE,
        updated_by = p_actor_id,
        updated_at = v_now
    WHERE id = v_old_inv.id;

  -- 5. Generate new token + INSERT new invitation
  v_token_plain := translate(encode(gen_random_bytes(32), 'base64'), '+/=' || E'\n', '-_');
  v_token_hash  := encode(digest(v_token_plain, 'sha256'), 'hex');
  v_expires_at  := v_now + INTERVAL '14 days';

  INSERT INTO signature_invitation (
    signature_party_id, contract_id, invitation_token_hash,
    status, invitation_sent_at, invitation_expires_at,
    language, created_by, updated_by
  ) VALUES (
    p_signature_party_id, v_party.contract_id, v_token_hash,
    'pending', v_now, v_expires_at,
    'en', p_actor_id, p_actor_id
  ) RETURNING id INTO v_new_invitation_id;

  -- 6. Append 'resent' event linked to OLD invitation
  INSERT INTO signature_event (
    signature_invitation_id, contract_id, event_type,
    actor_user_id, metadata
  ) VALUES (
    v_old_inv.id, v_party.contract_id, 'resent',
    p_actor_id,
    jsonb_build_object('newInvitationId', v_new_invitation_id, 'reason', p_reason)
  );

  -- 7. Return
  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'newInvitationId', v_new_invitation_id,
      'invitationTokenPlaintext', v_token_plain,
      'expiresAt', v_expires_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_invitation_resend(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_invitation_resend(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_invitation_resend(BIGINT, BIGINT, TEXT) IS
  'M3 (036) — INVOKER. Soft-deactivates the active invitation for a signature_party and creates a new one with fresh token. Emits resent event. Permission: signature.send.';

-- ============================================================================
-- 4. fn_signature_invitation_cancel (INVOKER)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_invitation_cancel(
  p_signature_invitation_id BIGINT,
  p_actor_id                BIGINT,
  p_reason                  TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inv             RECORD;
  v_party           RECORD;
  v_contract_id     BIGINT;
  v_current_step    INTEGER;
  v_active_remaining INTEGER;
  v_contract_rolled_back BOOLEAN := FALSE;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
  -- 1. Permission gate (signature.cancel — NOT signature.send)
  IF NOT fn_current_user_has_permission('signature.cancel') THEN
    RAISE EXCEPTION 'fn_signature_invitation_cancel: %', 'permission:signature.cancel required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Validate p_reason
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'fn_signature_invitation_cancel: %', 'reason:missing_reason'
      USING ERRCODE = '22023';
  END IF;

  -- 3. Lock invitation row
  SELECT id, signature_party_id, contract_id, status, is_active
    INTO v_inv
    FROM signature_invitation
    WHERE id = p_signature_invitation_id
    FOR UPDATE;
  IF NOT FOUND OR v_inv.is_active IS NOT TRUE THEN
    RAISE EXCEPTION 'fn_signature_invitation_cancel: %', 'id:Invitation not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_contract_id := v_inv.contract_id;

  -- Lock contract row
  PERFORM 1 FROM contract WHERE id = v_contract_id FOR UPDATE;

  -- 4. Validate invitation status IN ('pending','viewed')
  IF v_inv.status NOT IN ('pending','viewed') THEN
    RAISE EXCEPTION 'fn_signature_invitation_cancel: %',
      format('invalid_invitation_status_for_cancel (current=%s)', v_inv.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- Lock signature_party row + read step_order
  SELECT id, step_order INTO v_party
    FROM signature_party
    WHERE id = v_inv.signature_party_id
    FOR UPDATE;
  v_current_step := v_party.step_order;

  -- 5. UPDATE invitation -> cancelled
  UPDATE signature_invitation
    SET status = 'cancelled',
        updated_by = p_actor_id,
        updated_at = v_now
    WHERE id = p_signature_invitation_id;

  -- 6. Append cancelled event
  INSERT INTO signature_event (
    signature_invitation_id, contract_id, event_type,
    actor_user_id, metadata
  ) VALUES (
    p_signature_invitation_id, v_contract_id, 'cancelled',
    p_actor_id,
    jsonb_build_object('cancelReason', p_reason)
  );

  -- 7. Step-exhaustion check
  SELECT COUNT(*) INTO v_active_remaining
    FROM signature_invitation inv2
    JOIN signature_party sp2 ON sp2.id = inv2.signature_party_id
    WHERE sp2.contract_id = v_contract_id
      AND sp2.step_order IS NOT DISTINCT FROM v_current_step
      AND sp2.is_required = TRUE
      AND sp2.is_active = TRUE
      AND inv2.is_active = TRUE
      AND inv2.status IN ('pending','viewed','signed');

  IF v_active_remaining = 0 THEN
    -- Roll contract back to 'approved' (per design — last active step exhausted via cancel)
    PERFORM fn_contract_status_update_internal(v_contract_id, 'approved', p_actor_id, p_reason);
    PERFORM fn_contract_activity_create(
      v_contract_id, 'signature_invalidated', p_actor_id, NULL, NULL,
      jsonb_build_object('cancelReason', p_reason, 'invalidatedReason', 'cancel_step_exhaustion')
    );
    v_contract_rolled_back := TRUE;
  END IF;

  -- 8. Return
  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'invitationId', p_signature_invitation_id,
      'status', 'cancelled',
      'contractRolledBack', v_contract_rolled_back
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_invitation_cancel(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_invitation_cancel(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_invitation_cancel(BIGINT, BIGINT, TEXT) IS
  'M3 (036) — INVOKER. Cancels an active invitation. If it was the last active required-signer at the current step, rolls contract back to approved. Permission: signature.cancel (NOT signature.send — drafter cannot self-cancel; AC-S8-03).';

-- ============================================================================
-- 5. fn_signature_sign (DEFINER — PUBLIC)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_sign(
  p_invitation_token_plain      TEXT,
  p_signature_method            TEXT,
  p_signature_data              TEXT  DEFAULT NULL,
  p_signature_image_url         TEXT  DEFAULT NULL,
  p_uae_pass_verification_level TEXT  DEFAULT NULL,
  p_ip_address                  INET  DEFAULT NULL,
  p_user_agent                  TEXT  DEFAULT NULL,
  p_metadata                    JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_token_hash       TEXT;
  v_inv              RECORD;
  v_contract         RECORD;
  v_party            RECORD;
  v_current_step     INTEGER;
  v_party_id         BIGINT;
  v_contract_id      BIGINT;
  v_signed_count     INTEGER;
  v_required_count   INTEGER;
  v_step_completed   BOOLEAN := FALSE;
  v_next_step        INTEGER;
  v_method_ok        BOOLEAN;
  v_now              TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_contract_new_status TEXT;
  v_remaining        JSONB;
BEGIN
  -- 1. Hash plaintext
  v_token_hash := encode(digest(p_invitation_token_plain, 'sha256'), 'hex');

  -- 2. Lookup + lock invitation
  SELECT inv.id, inv.signature_party_id, inv.contract_id, inv.status,
         inv.invitation_expires_at, inv.is_active
    INTO v_inv
    FROM signature_invitation inv
    WHERE inv.invitation_token_hash = v_token_hash
      AND inv.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND
     OR v_inv.invitation_expires_at < v_now
     OR v_inv.status NOT IN ('pending','viewed') THEN
    -- Already signed -> 409 idempotent
    IF FOUND AND v_inv.status = 'signed' THEN
      RAISE EXCEPTION 'fn_signature_sign: %', 'already_signed'
        USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'fn_signature_sign: %', 'invitation_invalid_or_expired'
      USING ERRCODE = 'P0001';
  END IF;

  v_contract_id := v_inv.contract_id;
  v_party_id    := v_inv.signature_party_id;

  -- 3. Lock contract
  SELECT id, status INTO v_contract
    FROM contract
    WHERE id = v_contract_id
    FOR UPDATE;

  -- Lock party + load step_order
  SELECT step_order, is_required INTO v_party
    FROM signature_party
    WHERE id = v_party_id
    FOR UPDATE;
  v_current_step := v_party.step_order;

  -- 4. Validate signature_method
  SELECT TRUE INTO v_method_ok
    FROM signature_method
    WHERE code = p_signature_method
      AND is_active = TRUE
      AND is_enabled = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_signature_sign: %', 'invalid_method'
      USING ERRCODE = '22023';
  END IF;

  -- 5. Method-gating
  IF p_signature_method IN ('typed','drawn') THEN
    IF p_signature_data IS NULL OR length(btrim(p_signature_data)) < 2 THEN
      RAISE EXCEPTION 'fn_signature_sign: %', 'missing_signature_data'
        USING ERRCODE = '22023';
    END IF;
    IF p_signature_method = 'drawn' AND p_signature_image_url IS NULL THEN
      RAISE EXCEPTION 'fn_signature_sign: %', 'missing_signature_image'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_signature_method = 'uae_pass' THEN
    IF p_uae_pass_verification_level IS NULL
       OR p_uae_pass_verification_level NOT IN ('basic','verified','premium') THEN
      RAISE EXCEPTION 'fn_signature_sign: %', 'missing_uae_pass_level'
        USING ERRCODE = '22023';
    END IF;
  ELSIF p_signature_method = 'ds_otp' THEN
    IF p_metadata IS NULL OR NOT (p_metadata ? 'otpReceipt')
       OR length(p_metadata->>'otpReceipt') = 0 THEN
      RAISE EXCEPTION 'fn_signature_sign: %', 'missing_otp_receipt'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 6. Append signed event
  INSERT INTO signature_event (
    signature_invitation_id, contract_id, event_type,
    signature_method, uae_pass_verification_level,
    signature_image_url, signature_data,
    ip_address, user_agent, actor_user_id, metadata
  ) VALUES (
    v_inv.id, v_contract_id, 'signed',
    p_signature_method, p_uae_pass_verification_level,
    p_signature_image_url, p_signature_data,
    p_ip_address, p_user_agent, NULL, p_metadata
  );

  -- 7. UPDATE invitation -> signed
  UPDATE signature_invitation
    SET status = 'signed',
        last_viewed_at = v_now,
        ip_address = COALESCE(p_ip_address, ip_address),
        user_agent = COALESCE(p_user_agent, user_agent),
        updated_at = v_now
    WHERE id = v_inv.id;

  -- 8. Step-completion (S2-18 NULL-safe equality on step_order)
  SELECT COUNT(*) FILTER (WHERE inv2.status = 'signed'),
         COUNT(*) FILTER (WHERE sp2.is_required = TRUE)
    INTO v_signed_count, v_required_count
    FROM signature_party sp2
    LEFT JOIN signature_invitation inv2
      ON inv2.signature_party_id = sp2.id AND inv2.is_active = TRUE
    WHERE sp2.contract_id = v_contract_id
      AND sp2.step_order IS NOT DISTINCT FROM v_current_step
      AND sp2.is_active = TRUE;

  v_step_completed := (v_required_count > 0) AND (v_signed_count >= v_required_count);

  -- 9. Status transitions
  IF v_step_completed THEN
    SELECT MIN(step_order) INTO v_next_step
      FROM signature_party
      WHERE contract_id = v_contract_id
        AND step_order > v_current_step
        AND is_active = TRUE
        AND is_required = TRUE;

    IF v_next_step IS NULL THEN
      -- Final step
      PERFORM fn_contract_status_update_internal(v_contract_id, 'fully_signed', NULL, 'final signer signed');
      UPDATE contract SET signed_at = v_now WHERE id = v_contract_id;  -- DN-6 round-trip
      PERFORM fn_contract_activity_create(
        v_contract_id, 'signer_signed', NULL, NULL, NULL,
        jsonb_build_object('signaturePartyId', v_party_id, 'method', p_signature_method)
      );
      PERFORM fn_contract_activity_create(
        v_contract_id, 'fully_executed', NULL, NULL, NULL,
        jsonb_build_object('signedAt', v_now)
      );
      v_contract_new_status := 'fully_signed';
    ELSE
      PERFORM fn_contract_status_update_internal(v_contract_id, 'awaiting_signature_counterparty', NULL, NULL);
      PERFORM fn_contract_activity_create(
        v_contract_id, 'signer_signed', NULL, NULL, NULL,
        jsonb_build_object('signaturePartyId', v_party_id, 'method', p_signature_method, 'nextStep', v_next_step)
      );
      v_contract_new_status := 'awaiting_signature_counterparty';
    END IF;
  ELSE
    PERFORM fn_contract_activity_create(
      v_contract_id, 'signer_signed', NULL, NULL, NULL,
      jsonb_build_object('signaturePartyId', v_party_id, 'method', p_signature_method)
    );
    v_contract_new_status := NULL;
  END IF;

  -- 10. Build remaining-signers list at the current step
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'signaturePartyId', sp3.id,
      'signerSide', sp3.signer_side,
      'status', COALESCE(inv3.status, 'pending')
    ) ORDER BY sp3.id ASC
  ), '[]'::jsonb) INTO v_remaining
  FROM signature_party sp3
  LEFT JOIN signature_invitation inv3
    ON inv3.signature_party_id = sp3.id AND inv3.is_active = TRUE
  WHERE sp3.contract_id = v_contract_id
    AND sp3.is_active = TRUE
    AND sp3.step_order IS NOT DISTINCT FROM v_current_step
    AND COALESCE(inv3.status, 'pending') IN ('pending','viewed');

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'invitationId', v_inv.id,
      'status', 'signed',
      'signedAt', v_now,
      'stepCompleted', v_step_completed,
      'contractNewStatus', v_contract_new_status,
      'remainingSigners', v_remaining
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_signature_sign(TEXT, TEXT, TEXT, TEXT, TEXT, INET, TEXT, JSONB) TO PUBLIC;

COMMENT ON FUNCTION fn_signature_sign(TEXT, TEXT, TEXT, TEXT, TEXT, INET, TEXT, JSONB) IS
  'M3 (036) — DEFINER, PUBLIC. Token-bearer signs. Step-completion uses IS NOT DISTINCT FROM (S2-18). Lock order: invitation FOR UPDATE, then contract FOR UPDATE, then party FOR UPDATE (S2-17). Final-step transitions contract to fully_signed and stamps signed_at (DN-6). signature_data + signature_image_url NEVER returned.';

-- ============================================================================
-- 6. fn_signature_decline (DEFINER — PUBLIC)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_decline(
  p_invitation_token_plain TEXT,
  p_decline_reason         TEXT,
  p_ip_address             INET DEFAULT NULL,
  p_user_agent             TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_token_hash      TEXT;
  v_inv             RECORD;
  v_contract_id     BIGINT;
  v_party           RECORD;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_new_contract_status TEXT;
BEGIN
  -- 1. Validate p_decline_reason length
  IF p_decline_reason IS NULL OR length(p_decline_reason) < 5 THEN
    RAISE EXCEPTION 'fn_signature_decline: %', 'reason_too_short'
      USING ERRCODE = '22023';
  END IF;
  IF length(p_decline_reason) > 2000 THEN
    RAISE EXCEPTION 'fn_signature_decline: %', 'reason_too_long'
      USING ERRCODE = '22023';
  END IF;

  -- 2. Hash + lookup + lock invitation
  v_token_hash := encode(digest(p_invitation_token_plain, 'sha256'), 'hex');

  SELECT inv.id, inv.signature_party_id, inv.contract_id, inv.status,
         inv.invitation_expires_at, inv.is_active
    INTO v_inv
    FROM signature_invitation inv
    WHERE inv.invitation_token_hash = v_token_hash
      AND inv.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND OR v_inv.invitation_expires_at < v_now THEN
    RAISE EXCEPTION 'fn_signature_decline: %', 'invitation_invalid_or_expired'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_inv.status IN ('signed','declined','cancelled') THEN
    RAISE EXCEPTION 'fn_signature_decline: %', 'already_decided'
      USING ERRCODE = 'P0001';
  END IF;
  IF v_inv.status NOT IN ('pending','viewed') THEN
    RAISE EXCEPTION 'fn_signature_decline: %', 'invitation_invalid_or_expired'
      USING ERRCODE = 'P0001';
  END IF;

  v_contract_id := v_inv.contract_id;

  -- Lock contract + party
  PERFORM 1 FROM contract WHERE id = v_contract_id FOR UPDATE;
  SELECT id, is_required INTO v_party
    FROM signature_party
    WHERE id = v_inv.signature_party_id
    FOR UPDATE;

  -- 3. Append declined event
  INSERT INTO signature_event (
    signature_invitation_id, contract_id, event_type,
    decline_reason, ip_address, user_agent, actor_user_id, metadata
  ) VALUES (
    v_inv.id, v_contract_id, 'declined',
    p_decline_reason, p_ip_address, p_user_agent, NULL,
    jsonb_build_object('isRequired', v_party.is_required)
  );

  -- 4. UPDATE invitation -> declined
  UPDATE signature_invitation
    SET status = 'declined',
        ip_address = COALESCE(p_ip_address, ip_address),
        user_agent = COALESCE(p_user_agent, user_agent),
        updated_at = v_now
    WHERE id = v_inv.id;

  -- 5. Required-signer halt logic
  IF v_party.is_required = TRUE THEN
    PERFORM fn_contract_status_update_internal(v_contract_id, 'rejected', NULL, p_decline_reason);
    PERFORM fn_contract_activity_create(
      v_contract_id, 'signer_declined', NULL, NULL, NULL,
      jsonb_build_object('signaturePartyId', v_party.id, 'reason', p_decline_reason)
    );
    v_new_contract_status := 'rejected';
  ELSE
    PERFORM fn_contract_activity_create(
      v_contract_id, 'signer_declined', NULL, NULL, NULL,
      jsonb_build_object('signaturePartyId', v_party.id, 'isRequired', FALSE, 'reason', p_decline_reason)
    );
    v_new_contract_status := NULL;
  END IF;

  -- 6. Return
  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'invitationId', v_inv.id,
      'status', 'declined',
      'contractNewStatus', v_new_contract_status
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_signature_decline(TEXT, TEXT, INET, TEXT) TO PUBLIC;

COMMENT ON FUNCTION fn_signature_decline(TEXT, TEXT, INET, TEXT) IS
  'M3 (036) — DEFINER, PUBLIC. Token-bearer declines. Required-signer decline transitions contract to rejected; non-required (witness) does not transition. Lock order: invitation FOR UPDATE, then contract FOR UPDATE.';

-- ============================================================================
-- 7. fn_signature_invitation_expire_due (DEFINER — system/cron only)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_invitation_expire_due(
  p_batch_size INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inv              RECORD;
  v_expired_count    INTEGER := 0;
  v_halted_count     INTEGER := 0;
  v_active_remaining INTEGER;
  v_now              TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
  IF p_batch_size IS NULL OR p_batch_size < 1 THEN
    p_batch_size := 100;
  END IF;

  FOR v_inv IN
    SELECT inv.id, inv.signature_party_id, inv.contract_id,
           sp.step_order, sp.is_required
      FROM signature_invitation inv
      JOIN signature_party sp ON sp.id = inv.signature_party_id
      WHERE inv.is_active = TRUE
        AND inv.status IN ('pending','viewed')
        AND inv.invitation_expires_at < v_now
      ORDER BY inv.invitation_expires_at ASC
      LIMIT p_batch_size
      FOR UPDATE OF inv SKIP LOCKED
  LOOP
    UPDATE signature_invitation
      SET status = 'expired',
          updated_at = v_now
      WHERE id = v_inv.id;

    INSERT INTO signature_event (
      signature_invitation_id, contract_id, event_type,
      actor_user_id, metadata
    ) VALUES (
      v_inv.id, v_inv.contract_id, 'expired',
      NULL,
      jsonb_build_object('autoExpiredAt', v_now)
    );

    v_expired_count := v_expired_count + 1;

    -- Step-exhaustion check (S2-18 IS NOT DISTINCT FROM)
    IF v_inv.is_required THEN
      SELECT COUNT(*) FILTER (WHERE inv2.status IN ('pending','viewed','signed'))
        INTO v_active_remaining
        FROM signature_invitation inv2
        JOIN signature_party sp2 ON sp2.id = inv2.signature_party_id
        WHERE sp2.contract_id = v_inv.contract_id
          AND sp2.step_order IS NOT DISTINCT FROM v_inv.step_order
          AND sp2.is_required = TRUE
          AND sp2.is_active = TRUE
          AND inv2.is_active = TRUE
          AND inv2.id <> v_inv.id;

      IF v_active_remaining = 0 THEN
        PERFORM fn_contract_status_update_internal(
          v_inv.contract_id, 'expired', NULL, 'all required signers at step expired'
        );
        PERFORM fn_contract_activity_create(
          v_inv.contract_id, 'signature_invalidated', NULL, NULL, NULL,
          jsonb_build_object('autoHaltedReason', 'step_exhaustion')
        );
        v_halted_count := v_halted_count + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'expiredInvitations', v_expired_count,
      'contractsHalted', v_halted_count
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_invitation_expire_due(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_invitation_expire_due(INTEGER) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_invitation_expire_due(INTEGER) IS
  'M3 (036) — DEFINER, system-cron only (REVOKE FROM PUBLIC; GRANT TO neondb_owner). Mirrors fn_approval_escalate. SKIP LOCKED batched. Cron driver MUST SET app.current_user_id=''0'' (S2-20). Halts contract via expired status when all required signers at the step have run out.';

-- ============================================================================
-- 8. fn_signer_qa_session_start (DEFINER — PUBLIC)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signer_qa_session_start(
  p_invitation_token_plain TEXT,
  p_language               TEXT DEFAULT 'en'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_token_hash       TEXT;
  v_inv              RECORD;
  v_lang             TEXT;
  v_active_session_count INTEGER;
  v_oldest_session_id BIGINT;
  v_session_token_plain TEXT;
  v_session_token_hash  TEXT;
  v_session_id       BIGINT;
  v_now              TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
  -- 1. Hash + lookup + lock invitation
  v_token_hash := encode(digest(p_invitation_token_plain, 'sha256'), 'hex');

  SELECT inv.id, inv.status, inv.invitation_expires_at, inv.language, inv.is_active
    INTO v_inv
    FROM signature_invitation inv
    WHERE inv.invitation_token_hash = v_token_hash
      AND inv.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND
     OR v_inv.invitation_expires_at < v_now
     OR v_inv.status IN ('cancelled','expired') THEN
    RAISE EXCEPTION 'fn_signer_qa_session_start: %', 'invitation_invalid_or_expired'
      USING ERRCODE = 'P0001';
  END IF;

  -- 2. Validate p_language; default to invitation.language or 'en'
  IF p_language IS NULL OR p_language NOT IN ('en','ar') THEN
    v_lang := COALESCE(v_inv.language, 'en');
  ELSE
    v_lang := p_language;
  END IF;

  -- 3. Sliding-window enforcement (Gate 2 AN-12 Option A)
  SELECT COUNT(*) INTO v_active_session_count
    FROM signer_qa_session
    WHERE signature_invitation_id = v_inv.id AND is_active = TRUE;

  IF v_active_session_count >= 5 THEN
    SELECT id INTO v_oldest_session_id
      FROM signer_qa_session
      WHERE signature_invitation_id = v_inv.id AND is_active = TRUE
      ORDER BY last_activity_at ASC, id ASC
      LIMIT 1;
    IF v_oldest_session_id IS NOT NULL THEN
      UPDATE signer_qa_session
        SET is_active = FALSE,
            updated_at = v_now
        WHERE id = v_oldest_session_id;
    END IF;
  END IF;

  -- 4. Generate session token
  v_session_token_plain := translate(encode(gen_random_bytes(32), 'base64'), '+/=' || E'\n', '-_');
  v_session_token_hash  := encode(digest(v_session_token_plain, 'sha256'), 'hex');

  -- 5. INSERT session
  INSERT INTO signer_qa_session (
    signature_invitation_id, session_token_hash,
    last_activity_at, rate_limit_window_start, rate_limit_count,
    language, created_by, updated_by
  ) VALUES (
    v_inv.id, v_session_token_hash,
    v_now, v_now, 0,
    v_lang, NULL, NULL
  ) RETURNING id INTO v_session_id;

  -- 6. Return
  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'sessionTokenPlaintext', v_session_token_plain,
      'sessionId', v_session_id,
      'rateLimit', jsonb_build_object(
        'maxMessagesPerHour', 20,
        'remaining', 20
      ),
      'language', v_lang
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_signer_qa_session_start(TEXT, TEXT) TO PUBLIC;

COMMENT ON FUNCTION fn_signer_qa_session_start(TEXT, TEXT) IS
  'M3 (036) — DEFINER, PUBLIC. Opens a Q&A session for a token-bearer signer. Sliding-window: when active session count >= 5, oldest is soft-deactivated (Gate 2 AN-12 Option A). Plaintext session token returned ONCE.';

-- ============================================================================
-- 9. fn_signer_qa_session_record_message (DEFINER — PUBLIC)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signer_qa_session_record_message(
  p_session_token_plain TEXT,
  p_tokens_consumed     INTEGER,
  p_mode                TEXT DEFAULT 'COMMIT'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_session_token_hash TEXT;
  v_session            RECORD;
  v_inv                RECORD;
  v_now                TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_window_start       TIMESTAMPTZ;
  v_rate_count         INTEGER;
  v_per_session_rem    INTEGER;
  v_per_inv_count      INTEGER;
  v_per_inv_rem        INTEGER;
  v_message_count      INTEGER;
  v_tokens_consumed    INTEGER;
  v_remaining          INTEGER;
BEGIN
  -- 1. Validate inputs
  IF p_mode IS NULL OR p_mode NOT IN ('GATE','COMMIT') THEN
    RAISE EXCEPTION 'fn_signer_qa_session_record_message: %', 'mode:Invalid mode (must be GATE or COMMIT)'
      USING ERRCODE = '22023';
  END IF;
  IF p_tokens_consumed IS NULL OR p_tokens_consumed < 0 THEN
    RAISE EXCEPTION 'fn_signer_qa_session_record_message: %', 'tokens_consumed:Must be >= 0'
      USING ERRCODE = '22023';
  END IF;

  v_session_token_hash := encode(digest(p_session_token_plain, 'sha256'), 'hex');

  -- 2. Lookup + lock session
  SELECT s.id, s.signature_invitation_id, s.is_active,
         s.message_count, s.tokens_consumed,
         s.rate_limit_window_start, s.rate_limit_count
    INTO v_session
    FROM signer_qa_session s
    WHERE s.session_token_hash = v_session_token_hash
      AND s.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_signer_qa_session_record_message: %', 'session_invalid_or_expired'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. Validate parent invitation
  SELECT inv.id, inv.status, inv.is_active
    INTO v_inv
    FROM signature_invitation inv
    WHERE inv.id = v_session.signature_invitation_id;

  IF NOT FOUND
     OR v_inv.is_active IS NOT TRUE
     OR v_inv.status IN ('cancelled','expired') THEN
    RAISE EXCEPTION 'fn_signer_qa_session_record_message: %', 'session_invalid_or_expired'
      USING ERRCODE = 'P0001';
  END IF;

  -- 4. Slide window if older than 1h
  v_window_start := v_session.rate_limit_window_start;
  v_rate_count   := v_session.rate_limit_count;

  IF v_window_start < v_now - INTERVAL '1 hour' THEN
    v_window_start := v_now;
    v_rate_count   := 0;
  END IF;

  v_per_session_rem := 20 - v_rate_count;

  SELECT COALESCE(SUM(rate_limit_count), 0) INTO v_per_inv_count
    FROM signer_qa_session
    WHERE signature_invitation_id = v_session.signature_invitation_id
      AND is_active = TRUE
      AND rate_limit_window_start > v_now - INTERVAL '1 hour';
  v_per_inv_rem := 50 - v_per_inv_count;

  -- 5. Mode logic
  IF p_mode = 'GATE' THEN
    IF v_per_session_rem <= 0 OR v_per_inv_rem <= 0 THEN
      RAISE EXCEPTION 'fn_signer_qa_session_record_message: %', 'rate_limit_exceeded'
        USING ERRCODE = 'P0001';
    END IF;
    -- Reserve a slot
    UPDATE signer_qa_session
      SET rate_limit_window_start = v_window_start,
          rate_limit_count = v_rate_count + 1,
          last_activity_at = v_now,
          updated_at = v_now
      WHERE id = v_session.id;
    v_message_count   := v_session.message_count;
    v_tokens_consumed := v_session.tokens_consumed;
    v_remaining       := LEAST(v_per_session_rem - 1, v_per_inv_rem - 1);
  ELSE
    -- COMMIT: increments message_count + tokens_consumed; does NOT re-check rate
    UPDATE signer_qa_session
      SET message_count = message_count + 1,
          tokens_consumed = tokens_consumed + p_tokens_consumed,
          last_activity_at = v_now,
          updated_at = v_now
      WHERE id = v_session.id
      RETURNING message_count, tokens_consumed
        INTO v_message_count, v_tokens_consumed;
    v_remaining := LEAST(v_per_session_rem, v_per_inv_rem);
  END IF;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'messageCount', v_message_count,
      'tokensConsumed', v_tokens_consumed,
      'rateLimitRemaining', v_remaining,
      'mode', p_mode
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_signer_qa_session_record_message(TEXT, INTEGER, TEXT) TO PUBLIC;

COMMENT ON FUNCTION fn_signer_qa_session_record_message(TEXT, INTEGER, TEXT) IS
  'M3 (036) — DEFINER, PUBLIC. Two-call rate-limit pattern (GATE reserves slot pre-AI; COMMIT records actual tokens post-AI). 20 msg/hour per session + 50 msg/hour per invitation. RAISE rate_limit_exceeded on GATE when limit reached. ai_prompt_payload NEVER passed via this fn (controller-level only).';

-- ============================================================================
-- 10. fn_signature_get_by_invitation_token (DEFINER — PUBLIC)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_get_by_invitation_token(
  p_invitation_token_plain TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_token_hash       TEXT;
  v_row              RECORD;
  v_now              TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_first_view_was_null BOOLEAN;
  v_methods          JSONB;
  v_email_masked     TEXT;
BEGIN
  v_token_hash := encode(digest(p_invitation_token_plain, 'sha256'), 'hex');

  SELECT inv.id            AS invitation_id,
         inv.status         AS invitation_status,
         inv.invitation_expires_at,
         inv.language       AS invitation_language,
         inv.view_count,
         inv.first_viewed_at,
         sp.signer_side,
         sp.signer_name_en,
         sp.signer_name_ar,
         sp.signer_email,
         c.id               AS contract_id,
         c.contract_number,
         c.title_en,
         c.title_ar,
         c.contract_type,
         c.value_aed,
         c.start_date,
         c.end_date,
         c.ai_summary_en,
         c.ai_summary_ar,
         c.body_en,
         c.body_ar
    INTO v_row
    FROM signature_invitation inv
    JOIN signature_party sp ON sp.id = inv.signature_party_id
    JOIN contract c ON c.id = inv.contract_id
    WHERE inv.invitation_token_hash = v_token_hash
      AND inv.is_active = TRUE;

  IF NOT FOUND
     OR v_row.invitation_status IN ('expired','cancelled')
     OR v_row.invitation_expires_at < v_now THEN
    RETURN NULL;
  END IF;

  v_first_view_was_null := (v_row.first_viewed_at IS NULL);

  -- UPDATE view counters
  UPDATE signature_invitation
    SET view_count      = view_count + 1,
        last_viewed_at  = v_now,
        first_viewed_at = COALESCE(first_viewed_at, v_now),
        status          = CASE WHEN status = 'pending' THEN 'viewed' ELSE status END,
        updated_at      = v_now
    WHERE id = v_row.invitation_id;

  -- Idempotent 'viewed' event emission (AC-S3-03)
  IF v_first_view_was_null THEN
    INSERT INTO signature_event (
      signature_invitation_id, contract_id, event_type,
      actor_user_id, metadata
    ) VALUES (
      v_row.invitation_id, v_row.contract_id, 'viewed',
      NULL,
      jsonb_build_object('viewSource', 'landing-page')
    );
  END IF;

  -- Email mask: 'j***@example.com'
  IF v_row.signer_email IS NULL THEN
    v_email_masked := NULL;
  ELSE
    v_email_masked := lower(left(split_part(v_row.signer_email, '@', 1), 1))
                      || '***@'
                      || split_part(v_row.signer_email, '@', 2);
  END IF;

  -- Methods
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'code', m.code,
      'labelEn', m.label_en,
      'labelAr', m.label_ar,
      'verificationStrength', m.verification_strength
    ) ORDER BY m.verification_strength DESC, m.code ASC
  ), '[]'::jsonb) INTO v_methods
  FROM signature_method m
  WHERE m.is_active = TRUE AND m.is_enabled = TRUE;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'invitation', jsonb_build_object(
        'id', v_row.invitation_id,
        'status', CASE WHEN v_row.invitation_status = 'pending' THEN 'viewed' ELSE v_row.invitation_status END,
        'expiresAt', v_row.invitation_expires_at,
        'viewCount', v_row.view_count + 1,
        'language', v_row.invitation_language
      ),
      'signer', jsonb_build_object(
        'side', v_row.signer_side,
        'nameEn', v_row.signer_name_en,
        'nameAr', v_row.signer_name_ar,
        'email', v_email_masked
      ),
      'contract', jsonb_build_object(
        'id', v_row.contract_id,
        'contractNumber', v_row.contract_number,
        'titleEn', v_row.title_en,
        'titleAr', v_row.title_ar,
        'contractType', v_row.contract_type,
        'valueAed', v_row.value_aed,
        'startDate', v_row.start_date,
        'endDate', v_row.end_date,
        'ourPartyName', NULL,
        'counterpartyName', NULL,
        'aiSummaryEn', v_row.ai_summary_en,
        'aiSummaryAr', v_row.ai_summary_ar,
        'bodyEnExcerpt', LEFT(v_row.body_en, 4000),
        'bodyArExcerpt', LEFT(v_row.body_ar, 4000)
      ),
      'availableMethods', v_methods
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_signature_get_by_invitation_token(TEXT) TO PUBLIC;

COMMENT ON FUNCTION fn_signature_get_by_invitation_token(TEXT) IS
  'M3 (036) — DEFINER, PUBLIC, VOLATILE. Token-bearer landing-page read. Updates view_count + last_viewed_at + first_viewed_at + status (pending->viewed). Emits idempotent viewed event ONCE on first view. Returns NULL when invalid/expired/cancelled (controller maps to 410). signer_email masked. body_en/body_ar truncated to 4000 chars.';

-- ============================================================================
-- 11. fn_signature_list_for_contract (INVOKER, STABLE)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_signature_list_for_contract(
  p_contract_id BIGINT,
  p_actor_id    BIGINT,
  p_actor_role  TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract        RECORD;
  v_role            TEXT;
  v_unmask          BOOLEAN;
  v_signers         JSONB;
  v_step_progress   JSONB;
BEGIN
  -- 1. Visibility gate (RLS-aware via INVOKER + SELECT)
  SELECT id, status, is_active, drafted_by, reviewed_by, approved_by, created_by
    INTO v_contract
    FROM contract
    WHERE id = p_contract_id;

  IF NOT FOUND OR v_contract.is_active IS NOT TRUE THEN
    RETURN NULL;
  END IF;

  -- 2. Mask policy by role
  IF p_actor_role IS NOT NULL THEN
    v_role := p_actor_role;
  ELSE
    SELECT r.name INTO v_role
      FROM "user" u
      JOIN role r ON r.id = u.role_id
      WHERE u.id = p_actor_id;
  END IF;

  v_unmask := COALESCE(v_role, '') IN ('legal_counsel','platform_admin','Super Admin');

  -- 3. Project signers
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'signaturePartyId', sp.id,
      'signerSide', sp.signer_side,
      'signerNameEn', sp.signer_name_en,
      'signerNameAr', sp.signer_name_ar,
      'signerEmail',
        CASE
          WHEN sp.signer_email IS NULL THEN NULL
          WHEN v_unmask THEN sp.signer_email
          ELSE lower(left(split_part(sp.signer_email,'@',1),1))
               || '***@' || split_part(sp.signer_email,'@',2)
        END,
      'stepOrder', sp.step_order,
      'isRequired', sp.is_required,
      'currentInvitationStatus', inv.status,
      'invitationSentAt', inv.invitation_sent_at,
      'signedAt', (SELECT MAX(e.created_at) FROM signature_event e WHERE e.signature_invitation_id = inv.id AND e.event_type = 'signed'),
      'declinedAt', (SELECT MAX(e.created_at) FROM signature_event e WHERE e.signature_invitation_id = inv.id AND e.event_type = 'declined'),
      'lastEventType', (SELECT e.event_type FROM signature_event e WHERE e.signature_invitation_id = inv.id ORDER BY e.created_at DESC LIMIT 1),
      'signatureMethod', (SELECT e.signature_method FROM signature_event e WHERE e.signature_invitation_id = inv.id AND e.event_type='signed' ORDER BY e.created_at DESC LIMIT 1),
      'uaePassVerificationLevel', (SELECT e.uae_pass_verification_level FROM signature_event e WHERE e.signature_invitation_id = inv.id AND e.event_type='signed' ORDER BY e.created_at DESC LIMIT 1)
    ) ORDER BY sp.step_order ASC, sp.id ASC
  ), '[]'::jsonb) INTO v_signers
  FROM signature_party sp
  LEFT JOIN signature_invitation inv ON inv.signature_party_id = sp.id AND inv.is_active = TRUE
  WHERE sp.contract_id = p_contract_id AND sp.is_active = TRUE;

  -- 4. Step progress
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'stepOrder', sp.step_order,
      'totalRequired', SUM(CASE WHEN sp.is_required THEN 1 ELSE 0 END),
      'signedCount',   SUM(CASE WHEN inv.status='signed'   THEN 1 ELSE 0 END),
      'declinedCount', SUM(CASE WHEN inv.status='declined' THEN 1 ELSE 0 END),
      'pendingCount',  SUM(CASE WHEN inv.status IN ('pending','viewed') THEN 1 ELSE 0 END)
    ) ORDER BY sp.step_order ASC
  ), '[]'::jsonb) INTO v_step_progress
  FROM signature_party sp
  LEFT JOIN signature_invitation inv ON inv.signature_party_id = sp.id AND inv.is_active = TRUE
  WHERE sp.contract_id = p_contract_id AND sp.is_active = TRUE
  GROUP BY sp.step_order;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractId', p_contract_id,
      'currentStatus', v_contract.status,
      'signers', v_signers,
      'stepProgress', v_step_progress
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_list_for_contract(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_list_for_contract(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_list_for_contract(BIGINT, BIGINT, TEXT) IS
  'M3 (036) — INVOKER, STABLE. Internal-user read of signature progress for the Signatures tab. Role-aware email mask: legal_counsel/platform_admin/Super Admin see plain; others see j***@example.com. Returns NULL when contract not visible (controller maps 404). signature_data + signature_image_url NEVER selected.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (36, 'm3_signature_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP FUNCTION IF EXISTS fn_signature_list_for_contract(BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_signature_get_by_invitation_token(TEXT);
DROP FUNCTION IF EXISTS fn_signer_qa_session_record_message(TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS fn_signer_qa_session_start(TEXT, TEXT);
DROP FUNCTION IF EXISTS fn_signature_invitation_expire_due(INTEGER);
DROP FUNCTION IF EXISTS fn_signature_decline(TEXT, TEXT, INET, TEXT);
DROP FUNCTION IF EXISTS fn_signature_sign(TEXT, TEXT, TEXT, TEXT, TEXT, INET, TEXT, JSONB);
DROP FUNCTION IF EXISTS fn_signature_invitation_cancel(BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_signature_invitation_resend(BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_signature_send_for_signature(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS fn_signature_party_create_bulk(BIGINT, JSONB, BIGINT);
DELETE FROM schema_migrations WHERE version = 36;
COMMIT;
-- ROLLBACK END
