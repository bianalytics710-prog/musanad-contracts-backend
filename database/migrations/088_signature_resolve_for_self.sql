-- ================================================================
-- Migration 088 — R-RC2: in-app self-service signing for recipients.
-- ================================================================
-- Up: BEGIN
-- The M3 design assumed signers come from EMAIL: they receive a
-- link `/sign/{plaintextToken}` and the public `/sign/...` route
-- resolves the token. The plaintext token is returned ONCE at
-- invitation creation and never re-issued through any read path.
--
-- For an authenticated recipient already inside our app, this means
-- the on-screen "Sign" button needs a way to obtain a usable token
-- without going through email. Calling fn_signature_invitation_resend
-- works but requires `signature.send` permission, which recipients
-- (role=contract_recipient) do not hold.
--
-- New fn fn_signature_invitation_resolve_for_self:
--   - SECURITY DEFINER (carve-out — bypasses INVOKER's permission gate)
--   - Verifies the caller is the actual signer party in the given
--     contract (signer_user_id = actor OR signer_email = actor.email)
--   - Soft-deactivates the existing pending|viewed invitation
--   - Mints a fresh token, inserts a new active invitation
--   - Emits a 'resent' signature_event linked to the old invitation
--   - Returns the new plaintext token to the FE
--
-- Key safety properties:
--   1. Caller-bound — cannot resolve a token for someone else's signing
--      step. The party-match check uses BOTH user_id and email so
--      both seeded paths (auth'd user with an account, external email)
--      remain rejected.
--   2. Token rotation — old invitation is invalidated before the new
--      one is minted, so a leaked old token cannot be re-used to sign.
--   3. Status guard — only resolves invitations in {pending, viewed,
--      expired}. signed / declined / cancelled invitations cannot be
--      revived through this path.
--   4. Audit trail — the existing 'resent' signature_event records
--      the new invitation id and the actor, mirroring the staff
--      resend flow.
-- ================================================================

CREATE OR REPLACE FUNCTION fn_signature_invitation_resolve_for_self(
  p_actor_id    BIGINT,
  p_contract_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor_email   TEXT;
  v_party         RECORD;
  v_old_inv       RECORD;
  v_token_plain   TEXT;
  v_token_hash    TEXT;
  v_now           TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_expires_at    TIMESTAMPTZ;
  v_new_inv_id    BIGINT;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %', 'contractId:Contract id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT lower(email) INTO v_actor_email
    FROM "user"
    WHERE id = p_actor_id AND is_active = TRUE;
  IF v_actor_email IS NULL THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %', 'actorId:User not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- 1. Find the caller's signature_party for this contract. Match on
  --    signer_user_id OR signer_email so both seed paths work.
  SELECT id, contract_id INTO v_party
    FROM signature_party
    WHERE contract_id = p_contract_id
      AND is_active = TRUE
      AND (signer_user_id = p_actor_id OR lower(signer_email) = v_actor_email)
    ORDER BY step_order ASC
    LIMIT 1
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %', 'contractId:You are not a signer on this contract'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Lock existing active invitation
  SELECT id, status INTO v_old_inv
    FROM signature_invitation
    WHERE signature_party_id = v_party.id
      AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %', 'id:No active invitation for this signer'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_old_inv.status NOT IN ('pending','viewed','expired') THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %',
      format('invalid_invitation_status_for_resolve (current=%s)', v_old_inv.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. Soft-deactivate old invitation
  UPDATE signature_invitation
    SET is_active = FALSE,
        updated_by = p_actor_id,
        updated_at = v_now
    WHERE id = v_old_inv.id;

  -- 4. Mint fresh token + insert new invitation
  v_token_plain := translate(encode(gen_random_bytes(32), 'base64'), '+/=' || E'\n', '-_');
  v_token_hash  := encode(digest(v_token_plain, 'sha256'), 'hex');
  v_expires_at  := v_now + INTERVAL '14 days';

  INSERT INTO signature_invitation (
    signature_party_id, contract_id, invitation_token_hash,
    status, invitation_sent_at, invitation_expires_at,
    language, created_by, updated_by
  ) VALUES (
    v_party.id, v_party.contract_id, v_token_hash,
    'pending', v_now, v_expires_at,
    'en', p_actor_id, p_actor_id
  ) RETURNING id INTO v_new_inv_id;

  -- 5. Append 'resent' event linked to OLD invitation (audit trail)
  INSERT INTO signature_event (
    signature_invitation_id, contract_id, event_type,
    actor_user_id, metadata
  ) VALUES (
    v_old_inv.id, v_party.contract_id, 'resent',
    p_actor_id,
    jsonb_build_object('newInvitationId', v_new_inv_id, 'source', 'in_app_self_resolve')
  );

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'newInvitationId',           v_new_inv_id,
      'invitationTokenPlaintext',  v_token_plain,
      'expiresAt',                 v_expires_at,
      'contractId',                v_party.contract_id,
      'signaturePartyId',          v_party.id
    )
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN raise_exception THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_signature_invitation_resolve_for_self: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE ALL ON FUNCTION fn_signature_invitation_resolve_for_self(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_signature_invitation_resolve_for_self(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_signature_invitation_resolve_for_self(BIGINT, BIGINT) IS
  'INVOKER-bypass carve-out (DEFINER). Resolves an in-app authenticated signer to a fresh /sign/{token} URL by rolling the existing pending|viewed|expired invitation. Caller-bound (signer_user_id OR signer_email match). Audit trail via signature_event ''resent'' with metadata.source=''in_app_self_resolve''. R-RC2 — recipients sign from email by default; this carve-out gives them a frictionless in-app entry too.';

-- ================================================================
-- Up: END
-- Down: BEGIN
-- DROP FUNCTION IF EXISTS fn_signature_invitation_resolve_for_self(BIGINT, BIGINT);
-- ================================================================
-- Down: END
