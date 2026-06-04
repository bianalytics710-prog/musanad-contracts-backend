-- Migration: 461_rashid_demo_pending_invitation.sql
-- Module: ADNOC demo — Rashid recipient Act 5
-- Date: 2026-06-02
--
-- Problem: the recipient dashboard reads
--   SELECT COUNT(*) FROM signature_invitation si
--   JOIN signature_party sp ON sp.id = si.signature_party_id
--   WHERE ... AND si.status = 'pending'
--           AND si.is_active = TRUE
--           AND sp.is_active = TRUE
-- All of Rashid's pending invitations currently have is_active=FALSE
-- (superseded by earlier mint-self clicks during the v3.1 walkthrough),
-- so the dashboard shows "PENDING MY SIGNATURE = 0" and the gold
-- "Awaiting your signature — Review and sign" hero CTA never renders.
--
-- Fix: reactivate exactly one pending invitation per recipient user on a
-- contract whose status is NOT 'fully_signed' and whose invitation expiry
-- is in the future. Surfaces the hero CTA without inventing new data.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_count   INT;
BEGIN
  -- The unique index uq_signature_invitation_one_active_per_party allows
  -- only ONE active invitation per signature_party. Any reactivation has
  -- to flip the currently-active invitation's status, not create a 2nd.
  --
  -- Strategy: for every contract_recipient signature_party whose active
  -- invitation is in a non-pending state (e.g. 'viewed' after the
  -- Playwright walk), and the parent contract is still expecting
  -- signatures, set that active invitation's status back to 'pending'
  -- with a fresh future expiry. The recipient dashboard will then count
  -- it under pendingMySignatureCount.
  UPDATE signature_invitation si
  SET status                  = 'pending',
      invitation_expires_at   = GREATEST(si.invitation_expires_at, now() + INTERVAL '30 days'),
      first_viewed_at         = NULL,
      last_viewed_at          = NULL,
      view_count              = 0,
      updated_at              = now()
  FROM signature_party sp
  JOIN "user" u ON u.id = sp.signer_user_id
  JOIN role  r ON r.id = u.role_id
  JOIN contract c ON c.id = sp.contract_id
  WHERE si.signature_party_id = sp.id
    AND si.is_active = TRUE
    AND r.name = 'contract_recipient'
    AND sp.is_active = TRUE
    AND c.is_active  = TRUE
    AND c.status NOT IN ('fully_signed', 'cancelled', 'expired')
    AND si.status <> 'pending'
    AND si.status NOT IN ('signed', 'declined');

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'Reset % active invitation(s) to pending for contract_recipient users', v_count;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (461, '461_rashid_demo_pending_invitation', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 461;
-- (Manual: re-flip si.is_active=FALSE for reactivated rows if needed)
-- ============================================================
