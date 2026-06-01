-- Migration: 436_rashid_cluster_d_signable_demo.sql
-- Unit: Rashid Recipient PM-grade audit fix pass (2026-06-01) — Cluster D
-- Defect addressed:
--   R16 — There was no Sign button on contract detail for Rashid because
--         every contract he's a signer of is already in a terminal state
--         (active / fully_signed / expired). Flip MUSANAD-2026-013 (Emaar)
--         to `awaiting_signature_counterparty` and seed a pending
--         signature_invitation row for Rashid so the Sign button surfaces
--         AND `fn_signature_invitation_resolve_for_self` can mint a fresh
--         /sign/{token} URL.
-- Test-branch-safe: guards by email + contract_number; idempotent.
-- Rollback: revert status to 'active' and mark invitation cancelled.

BEGIN;

DO $$
DECLARE
  v_user_id    BIGINT;
  v_contract_id BIGINT;
  v_party_id   BIGINT;
BEGIN
  SELECT id INTO v_user_id FROM "user" WHERE lower(email) = 'recipient@musanad.local';
  IF v_user_id IS NULL THEN
    RAISE NOTICE 'mig 436: recipient@musanad.local not present — skipping';
    RETURN;
  END IF;

  SELECT id INTO v_contract_id
    FROM contract
   WHERE contract_number = 'MUSANAD-2026-013' AND is_active = TRUE
   LIMIT 1;
  IF v_contract_id IS NULL THEN
    RAISE NOTICE 'mig 436: MUSANAD-2026-013 not present — skipping';
    RETURN;
  END IF;

  -- Flip the contract into a state where a counterparty signature is awaited
  -- (does not advance the demo data into a "broken" state because the row is
  -- only one of Rashid's contracts; the other 4 keep their existing statuses).
  UPDATE contract
     SET status = 'awaiting_signature_counterparty',
         updated_at = NOW(),
         updated_by = 1
   WHERE id = v_contract_id
     AND status <> 'awaiting_signature_counterparty';

  SELECT sp.id INTO v_party_id
    FROM signature_party sp
   WHERE sp.contract_id = v_contract_id
     AND lower(sp.signer_email) = 'recipient@musanad.local'
     AND sp.is_active = TRUE
   LIMIT 1;

  IF v_party_id IS NULL THEN
    RAISE NOTICE 'mig 436: no signature_party for recipient on contract — skipping invitation seed';
    RETURN;
  END IF;

  -- Cancel any non-pending past invitations on the party first.
  UPDATE signature_invitation
     SET is_active = FALSE,
         updated_at = NOW(),
         updated_by = 1
   WHERE signature_party_id = v_party_id
     AND is_active = TRUE
     AND status <> 'pending';

  -- Insert ONE active pending invitation if none exists yet (the UNIQUE
  -- partial index uq_signature_invitation_one_active_per_party blocks dups).
  IF NOT EXISTS (
    SELECT 1 FROM signature_invitation
     WHERE signature_party_id = v_party_id
       AND is_active = TRUE
  ) THEN
    INSERT INTO signature_invitation (
      signature_party_id, contract_id, invitation_token_hash, status,
      invitation_sent_at, invitation_expires_at, language,
      created_by, updated_by
    ) VALUES (
      v_party_id,
      v_contract_id,
      encode(digest('R16-seed-token-' || v_party_id::text || '-' || extract(epoch from NOW())::text, 'sha256'), 'hex'),
      'pending',
      NOW() - INTERVAL '6 hours',
      NOW() + INTERVAL '30 days',
      'en',
      1,
      1
    );
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (436, 'R16 — flip MUSANAD-2026-013 to awaiting_signature_counterparty + seed pending invitation for Rashid', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE contract SET status='active'
--    WHERE contract_number='MUSANAD-2026-013' AND status='awaiting_signature_counterparty';
--   UPDATE signature_invitation SET is_active=FALSE
--    WHERE signature_party_id IN (
--      SELECT id FROM signature_party WHERE lower(signer_email)='recipient@musanad.local'
--    ) AND status='pending';
--   DELETE FROM schema_migrations WHERE version=436;
-- COMMIT;
-- ROLLBACK END
