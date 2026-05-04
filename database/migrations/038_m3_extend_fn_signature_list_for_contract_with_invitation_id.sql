-- ============================================================================
-- 038_m3_extend_fn_signature_list_for_contract_with_invitation_id.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation (cross-layer patch agent)
-- Depends:   M3 036 (canonical fn_signature_list_for_contract body).
-- Trigger:   Integration Verifier INTEG-FAIL-1 — `fn_signature_list_for_contract`
--            JSONB projection lacked `currentInvitationId`, so the FE
--            ContractSignaturesTab cancel-invitation handler had no real
--            invitation id to send to POST /signature-invitations/:id/cancel.
-- ----------------------------------------------------------------------------
-- Surgical patch: CREATE OR REPLACE fn_signature_list_for_contract with
-- body byte-for-byte identical to migration 036 EXCEPT the step-3 SELECT
-- projection now includes 'currentInvitationId', inv.id (camelCase JSONB
-- key, mirroring 'currentInvitationStatus', inv.status that already lives
-- on the same row builder). The LEFT JOIN to signature_invitation is
-- unchanged (already in 036).
--
-- Stage-2 S2-19 invariant: signature unchanged
--   (BIGINT, BIGINT, TEXT DEFAULT NULL) RETURNS jsonb. No fn-to-fn call sites.
--
-- AC mapping:
--   AC-S6-01 — preserved (single fn call returns full Signatures-tab payload).
--   AC-S8-* — now reachable from the S6 surface: FE has the invitation id
--             needed to call POST /signature-invitations/:id/cancel.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. fn_signature_list_for_contract (INVOKER, STABLE) — REPLACE
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
      'currentInvitationId', inv.id,
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
  'M3 (036+038) — INVOKER, STABLE. Internal-user read of signature progress for the Signatures tab. Role-aware email mask: legal_counsel/platform_admin/Super Admin see plain; others see j***@example.com. Returns NULL when contract not visible (controller maps 404). signature_data + signature_image_url NEVER selected. v038 patch: projects currentInvitationId so the FE Cancel button can target POST /signature-invitations/:id/cancel.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (38, 'm3_extend_fn_signature_list_for_contract_with_invitation_id', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restores fn_signature_list_for_contract to the canonical M3 036 body
-- (no currentInvitationId projection).
BEGIN;

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
  SELECT id, status, is_active, drafted_by, reviewed_by, approved_by, created_by
    INTO v_contract
    FROM contract
    WHERE id = p_contract_id;

  IF NOT FOUND OR v_contract.is_active IS NOT TRUE THEN
    RETURN NULL;
  END IF;

  IF p_actor_role IS NOT NULL THEN
    v_role := p_actor_role;
  ELSE
    SELECT r.name INTO v_role
      FROM "user" u
      JOIN role r ON r.id = u.role_id
      WHERE u.id = p_actor_id;
  END IF;

  v_unmask := COALESCE(v_role, '') IN ('legal_counsel','platform_admin','Super Admin');

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

DELETE FROM schema_migrations WHERE version = 38;

COMMIT;
-- ROLLBACK END
