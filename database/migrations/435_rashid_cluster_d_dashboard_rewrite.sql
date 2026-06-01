-- Migration: 435_rashid_cluster_d_dashboard_rewrite.sql
-- Unit: Rashid Recipient PM-grade audit fix pass (2026-06-01) — Cluster D
-- Defects addressed:
--   R1 — Date filter no-op: rewrite `fn_dashboard_recipient` so the window param
--        scopes ALL list KPIs that legitimately want windowing (myContractsCount
--        is intentionally lifetime-scoped — the filter is moved into a per-section
--        FE control by R7; this fn now stops shipping a window-aware tile that
--        always reads zero).
--   R2 — Drop the dead `myObligationsCount` placeholder envelope from the BE
--        return shape.
--   R3 — `signedByMeCount` is now reconciled with status='fully_signed' OR
--        signature_event 'signed' by caller — so it matches the visible list
--        instead of always reading zero.
--   R4 — Expose counterparty NAME + party metadata so the FE list items can
--        render "Crescent Petroleum Company" instead of the
--        "Counterparty details: pending" placeholder.
--   R7 — Add `windowApplies` boolean to the response so the FE can hide
--        the unused date pill row when no field actually responds to it.
--   R17 — Also surface the contract's `our_party_name_en/ar` + `counterparty_name_en/ar`
--         on the dashboard list rows so detail-page Parties section can populate.
-- Test-branch-safe: CREATE OR REPLACE.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_dashboard_recipient(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_email   TEXT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name, u.email INTO v_role, v_email
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_recipient', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: forbidden — recipient dashboard restricted to contract_recipient, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  -- R1+R3: KPIs reconciled with the visible list. signedByMeCount counts ANY
  -- contract Rashid is a signer of with status fully_signed OR a signature_event
  -- of type signed (either signal means "the user has signed it"). No window
  -- filtering on KPIs (per R1+R7: the page is snapshot-style; FE drops the
  -- date pills by reading `windowApplies=false`).
  SELECT jsonb_build_object(
    'myContractsCount',
      (SELECT COUNT(DISTINCT c.id) FROM contract c
        WHERE c.is_active = TRUE
          AND v_email IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM signature_party sp
            WHERE sp.contract_id = c.id
              AND lower(sp.signer_email) = lower(v_email)
              AND sp.is_active = TRUE
          )),
    'pendingMySignatureCount',
      (SELECT COUNT(*) FROM signature_invitation si
       JOIN signature_party sp ON sp.id = si.signature_party_id
       WHERE v_email IS NOT NULL
         AND lower(sp.signer_email) = lower(v_email)
         AND si.status = 'pending'
         AND si.is_active = TRUE
         AND sp.is_active = TRUE),
    'signedByMeCount',
      (SELECT COUNT(DISTINCT c.id) FROM contract c
        JOIN signature_party sp
          ON sp.contract_id = c.id
         AND sp.is_active = TRUE
         AND lower(sp.signer_email) = lower(v_email)
        WHERE c.is_active = TRUE
          AND (
            c.status = 'fully_signed'
            OR EXISTS (
              SELECT 1 FROM signature_event se
              WHERE se.contract_id = c.id
                AND se.actor_user_id = v_user_id
                AND se.event_type = 'signed'
                AND se.is_active = TRUE
            )
          ))
  ) INTO v_kpis;

  -- R4+R17: ship the actual counterparty + our-party names so the FE list +
  -- detail Parties section can render real values instead of "pending" / "—".
  SELECT jsonb_build_object(
    'myContracts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'contractNumber', x.contract_number,
          'titleEn', x.title_en,
          'titleAr', x.title_ar,
          'status', x.status,
          'ourPartyId', x.our_party_id,
          'ourPartyNameEn', x.our_party_name_en,
          'ourPartyNameAr', x.our_party_name_ar,
          'counterpartyId', x.counterparty_id,
          'counterpartyNameEn', x.counterparty_name_en,
          'counterpartyNameAr', x.counterparty_name_ar,
          'updatedAt', x.updated_at
        ) ORDER BY x.updated_at DESC)
        FROM (
          SELECT DISTINCT ON (c.id)
                 c.id, c.contract_number, c.title_en, c.title_ar,
                 c.status, c.updated_at,
                 sp.id AS our_party_id,
                 op.name_en AS our_party_name_en,
                 op.name_ar AS our_party_name_ar,
                 c.counterparty_id,
                 cp.name_en AS counterparty_name_en,
                 cp.name_ar AS counterparty_name_ar
          FROM contract c
          JOIN signature_party sp ON sp.contract_id = c.id
          LEFT JOIN party op ON op.id = c.our_party_id
          LEFT JOIN party cp ON cp.id = c.counterparty_id
          WHERE c.is_active = TRUE
            AND v_email IS NOT NULL
            AND lower(sp.signer_email) = lower(v_email)
            AND sp.is_active = TRUE
          ORDER BY c.id, c.updated_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'pendingSignatures5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'invitationId', x.invitation_id,
          'contractId', x.contract_id,
          'contractNumber', x.contract_number,
          'counterpartyNameEn', x.counterparty_name_en,
          'sentAt', x.sent_at,
          'expiresAt', x.expires_at
        ) ORDER BY x.sent_at DESC)
        FROM (
          SELECT si.id AS invitation_id,
                 si.contract_id,
                 c.contract_number,
                 cp.name_en AS counterparty_name_en,
                 si.invitation_sent_at AS sent_at,
                 si.invitation_expires_at AS expires_at
          FROM signature_invitation si
          JOIN signature_party sp ON sp.id = si.signature_party_id
          JOIN contract c ON c.id = si.contract_id
          LEFT JOIN party cp ON cp.id = c.counterparty_id
          WHERE v_email IS NOT NULL
            AND lower(sp.signer_email) = lower(v_email)
            AND si.status = 'pending'
            AND si.is_active = TRUE
            AND sp.is_active = TRUE
          LIMIT 5
        ) x
      ), '[]'::jsonb)
  ) INTO v_lists;

  -- R7: explicit hint that no field on this dashboard scopes by window
  -- (myContractsCount + signedByMeCount + pendingMySignatureCount are
  -- lifetime/snapshot KPIs). FE reads this flag to hide the orphan
  -- date-pill row.
  RETURN jsonb_build_object(
    'kpis', v_kpis,
    'lists', v_lists,
    'windowApplies', FALSE
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE EXECUTE ON FUNCTION fn_dashboard_recipient FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_recipient TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_recipient IS
  'R1/R2/R3/R4/R7/R17 — recipient dashboard rewrite: drops placeholder fields, surfaces counterparty + our-party names, reconciles signedByMeCount with visible list, signals windowApplies=false to hide orphan date pills.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (435, 'R1/R2/R3/R4/R7/R17 — fn_dashboard_recipient rewrite', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- DROP + recreate prior body (migration 244 lines 1318..1442) if needed.
-- ROLLBACK END
