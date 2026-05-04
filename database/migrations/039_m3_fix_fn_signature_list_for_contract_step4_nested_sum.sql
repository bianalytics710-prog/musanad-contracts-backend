-- ============================================================================
-- 039_m3_fix_fn_signature_list_for_contract_step4_nested_sum.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation (tight DB-only patch agent)
-- Depends:   M3 038 (canonical fn_signature_list_for_contract body w/ currentInvitationId).
-- Trigger:   Pre-existing latent bug surfaced during INTEG-FAIL-1 functional probe
--            (see .claude/workspace/current-module/integ-fail-1-patch-summary.md §7).
--            Step 4 (per-step aggregates) nests SUM() inside jsonb_agg(), which
--            PostgreSQL rejects with `aggregate function calls cannot be nested`
--            once any signature_event / signature_invitation row triggers grouping.
--            Bug originated in migration 036 verbatim; 038 inherited it.
-- ----------------------------------------------------------------------------
-- Surgical patch: CREATE OR REPLACE fn_signature_list_for_contract with body
-- byte-for-byte identical to migration 038 EXCEPT step 4 (the v_step_progress
-- builder). Step 4 is refactored to:
--   1. CTE `step_agg` pre-aggregates per step_order via COUNT(*) FILTER (WHERE ...)
--      (idiomatic Postgres replacement for SUM(CASE WHEN ...)).
--   2. Outer SELECT jsonb_agg(jsonb_build_object(...)) ORDER BY step_order over
--      the pre-aggregated rows — no nested aggregates.
--
-- Output JSONB shape per step row is unchanged:
--   { stepOrder, totalRequired, signedCount, declinedCount, pendingCount }
--
-- Stage-2 invariants (S2-19 byte-for-byte):
--   - Function signature unchanged: (BIGINT, BIGINT, TEXT DEFAULT NULL) RETURNS jsonb.
--   - Step 1 (visibility gate), step 2 (role/mask), step 3 (signer projection
--     incl. currentInvitationId from 038), step 5 (RETURN envelope) — all
--     byte-for-byte identical to 038.
--   - Visibility gate, role-aware email mask, LEFT JOIN, helper scalar
--     subqueries — unchanged.
--   - No fn-to-fn call drift; no other call sites need updating.
--
-- AC mapping:
--   AC-S6-02 (per-step progress aggregates) — now reachable end-to-end whenever
--             contract has signature_event rows (previously raised SQL error).
--   AC-S6-01 — unchanged (single fn call returns full Signatures-tab payload).
--   AC-S8-*  — unchanged (currentInvitationId from 038 still projected in step 3).
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

  -- 4. Step progress (PATCHED — pre-aggregate per step_order in a CTE, then
  --    jsonb_agg the pre-aggregated rows so no aggregates are nested).
  WITH step_agg AS (
    SELECT
      sp.step_order                                                    AS step_order,
      COUNT(*) FILTER (WHERE sp.is_required)                           AS total_required,
      COUNT(*) FILTER (WHERE inv.status = 'signed')                    AS signed_count,
      COUNT(*) FILTER (WHERE inv.status = 'declined')                  AS declined_count,
      COUNT(*) FILTER (WHERE inv.status IN ('pending','viewed'))       AS pending_count
    FROM signature_party sp
    LEFT JOIN signature_invitation inv
           ON inv.signature_party_id = sp.id AND inv.is_active = TRUE
    WHERE sp.contract_id = p_contract_id
      AND sp.is_active = TRUE
    GROUP BY sp.step_order
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'stepOrder',     sa.step_order,
      'totalRequired', sa.total_required,
      'signedCount',   sa.signed_count,
      'declinedCount', sa.declined_count,
      'pendingCount',  sa.pending_count
    ) ORDER BY sa.step_order ASC
  ), '[]'::jsonb) INTO v_step_progress
  FROM step_agg sa;

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
  'M3 (036+038+039) — INVOKER, STABLE. Internal-user read of signature progress for the Signatures tab. Role-aware email mask: legal_counsel/platform_admin/Super Admin see plain; others see j***@example.com. Returns NULL when contract not visible (controller maps 404). signature_data + signature_image_url NEVER selected. v038 patch: projects currentInvitationId so the FE Cancel button can target POST /signature-invitations/:id/cancel. v039 patch: refactors step-4 (stepProgress) to pre-aggregate via CTE — eliminates nested-aggregate SQL error that fired whenever signature_event rows existed.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (39, 'm3_fix_fn_signature_list_for_contract_step4_nested_sum', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restores fn_signature_list_for_contract to the canonical migration 038 body
-- (currentInvitationId projected, but step 4 with nested SUM(CASE...) — the
-- known-bad pre-fix shape). Use only if downstream M3 work breaks against the
-- 039 CTE-based body.
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

DELETE FROM schema_migrations WHERE version = 39;

COMMIT;
-- ROLLBACK END
