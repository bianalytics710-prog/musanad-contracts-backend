-- ============================================================================
-- Migration 708 — Counterparty intelligence drill-downs + a rich demo party
-- ============================================================================
-- Two parts:
--  A. fn_party_drafting_intelligence now also returns the LISTS behind each
--     tile (contracts, sent-back contracts, risk cases) so the FE can expand a
--     detail frame on click (Expiry-Cliff pattern) instead of showing bare
--     numbers.
--  B. Enrich Mubadala Investment Company (party 17) into a compelling demo
--     counterparty: recurring counterparty redlines (Limitation of Liability /
--     Payment Terms / Indemnification), extra negotiation versions, and a
--     couple of manual risk cases — so a drafter/reviewer sees a real pattern
--     ("they always push the liability cap; budget 3-4 versions").
-- ============================================================================

BEGIN;

-- ── A. Recreate the fn with drill-down detail arrays ────────────────────────
CREATE OR REPLACE FUNCTION fn_party_drafting_intelligence(
  p_party_id            BIGINT,
  p_exclude_contract_id BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id       BIGINT;
  v_party         RECORD;
  v_prior         INT;
  v_active        INT;
  v_avg_versions  NUMERIC;
  v_portfolio_avg NUMERIC;
  v_rejected      INT;
  v_resubmitted   INT;
  v_avg_days      NUMERIC;
  v_rc_total      INT;
  v_rc_open       INT;
  v_rc_by_type    JSONB;
  v_redline       JSONB;
  v_contracts     JSONB;
  v_sent_back     JSONB;
  v_risk_list     JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_party_drafting_intelligence: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT (fn_current_user_has_permission('contract.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.read.own')
       OR fn_current_user_has_permission('contract.draft')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: contract read/draft permission required' USING ERRCODE = '42501';
  END IF;

  SELECT id, name_en, name_ar INTO v_party
  FROM party WHERE id = p_party_id AND is_active = TRUE;
  IF v_party.id IS NULL THEN
    RAISE EXCEPTION 'Party not found' USING ERRCODE = '22023';
  END IF;

  SELECT count(*), count(*) FILTER (WHERE status = 'active')
    INTO v_prior, v_active
  FROM contract
  WHERE counterparty_id = p_party_id AND is_active = TRUE
    AND (p_exclude_contract_id IS NULL OR id <> p_exclude_contract_id);

  SELECT round(avg(maxv), 1) INTO v_avg_versions FROM (
    SELECT max(cv.version_number) AS maxv
    FROM contract c
    JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY c.id
  ) s;

  SELECT round(avg(maxv), 1) INTO v_portfolio_avg FROM (
    SELECT max(cv.version_number) AS maxv
    FROM contract c
    JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
    WHERE c.is_active = TRUE
    GROUP BY c.id
  ) s;

  SELECT count(DISTINCT ac.contract_id) FILTER (WHERE astep.status = 'rejected'),
         count(DISTINCT ac.contract_id) FILTER (WHERE astep.status = 'resubmission_requested')
    INTO v_rejected, v_resubmitted
  FROM approval_step astep
  JOIN approval_chain ac ON ac.id = astep.approval_chain_id
  JOIN contract c ON c.id = ac.contract_id
  WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
    AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id);

  SELECT round(avg(EXTRACT(EPOCH FROM (signed_at - created_at)) / 86400.0)::numeric, 0)
    INTO v_avg_days
  FROM contract
  WHERE counterparty_id = p_party_id AND is_active = TRUE AND signed_at IS NOT NULL
    AND signed_at >= created_at
    AND (p_exclude_contract_id IS NULL OR id <> p_exclude_contract_id);

  SELECT count(*), count(*) FILTER (WHERE rc.closed_at IS NULL)
    INTO v_rc_total, v_rc_open
  FROM risk_case rc
  JOIN contract c ON c.id = rc.contract_id
  WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE AND rc.is_active = TRUE
    AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object('type', case_type, 'n', n) ORDER BY n DESC), '[]'::jsonb)
    INTO v_rc_by_type
  FROM (
    SELECT rc.case_type, count(*) AS n
    FROM risk_case rc JOIN contract c ON c.id = rc.contract_id
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE AND rc.is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY rc.case_type ORDER BY count(*) DESC LIMIT 5
  ) t;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('heading', heading, 'n', n) ORDER BY n DESC), '[]'::jsonb)
    INTO v_redline
  FROM (
    SELECT cc.anchor_clause_heading AS heading, count(*) AS n
    FROM contract_comment cc JOIN contract c ON c.id = cc.contract_id
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND cc.is_active = TRUE AND cc.comment_kind = 'redline'
      AND cc.anchor_clause_heading IS NOT NULL
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY cc.anchor_clause_heading ORDER BY count(*) DESC LIMIT 5
  ) t;

  -- ── Drill-down: all contracts (newest first) ──
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', id, 'contractNumber', contract_number, 'title', title_en,
           'status', status, 'valueAed', value_aed, 'versions', current_version,
           'signedAt', signed_at, 'createdAt', created_at
         ) ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_contracts
  FROM (
    SELECT id, contract_number, title_en, status, value_aed, current_version, signed_at, created_at
    FROM contract
    WHERE counterparty_id = p_party_id AND is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR id <> p_exclude_contract_id)
    ORDER BY created_at DESC LIMIT 50
  ) t;

  -- ── Drill-down: sent-back (rejected / resubmission) approval steps ──
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'contractId', contract_id, 'contractNumber', contract_number, 'title', title_en,
           'action', action, 'role', role, 'decidedAt', decided_at
         ) ORDER BY decided_at DESC NULLS LAST), '[]'::jsonb)
    INTO v_sent_back
  FROM (
    SELECT c.id AS contract_id, c.contract_number, c.title_en,
           astep.status AS action, astep.approver_role AS role, astep.decided_at
    FROM approval_step astep
    JOIN approval_chain ac ON ac.id = astep.approval_chain_id
    JOIN contract c ON c.id = ac.contract_id
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND astep.status IN ('rejected', 'resubmission_requested')
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    ORDER BY astep.decided_at DESC NULLS LAST LIMIT 50
  ) t;

  -- ── Drill-down: risk cases ──
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', id, 'title', title, 'caseType', case_type, 'priority', priority,
           'status', status, 'open', (closed_at IS NULL),
           'contractId', contract_id, 'contractNumber', contract_number, 'createdAt', created_at
         ) ORDER BY (closed_at IS NULL) DESC, created_at DESC), '[]'::jsonb)
    INTO v_risk_list
  FROM (
    SELECT rc.id, rc.title, rc.case_type, rc.priority, rc.status, rc.closed_at,
           rc.contract_id, c.contract_number, rc.created_at
    FROM risk_case rc JOIN contract c ON c.id = rc.contract_id
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE AND rc.is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    ORDER BY (rc.closed_at IS NULL) DESC, rc.created_at DESC LIMIT 50
  ) t;

  RETURN jsonb_build_object(
    'party', jsonb_build_object('id', v_party.id, 'nameEn', v_party.name_en, 'nameAr', v_party.name_ar),
    'priorContracts', COALESCE(v_prior, 0),
    'activeContracts', COALESCE(v_active, 0),
    'avgVersions', v_avg_versions,
    'portfolioAvgVersions', v_portfolio_avg,
    'approvalFriction', jsonb_build_object('rejected', COALESCE(v_rejected, 0), 'resubmitted', COALESCE(v_resubmitted, 0)),
    'avgNegotiationDays', v_avg_days,
    'riskCases', jsonb_build_object('total', COALESCE(v_rc_total, 0), 'open', COALESCE(v_rc_open, 0), 'byType', v_rc_by_type),
    'topRedlineClauses', v_redline,
    'contracts', v_contracts,
    'sentBack', v_sent_back,
    'riskCaseList', v_risk_list
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_drafting_intelligence: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

-- ── B. Enrich Mubadala (party 17) into a rich demo counterparty ─────────────
DO $demo$
DECLARE
  v_party   BIGINT := 17;
  v_drafter BIGINT;
  v_legal   BIGINT;
  r RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = v_party) THEN
    RAISE NOTICE '708 demo skipped — party 17 absent'; RETURN;
  END IF;
  SELECT id INTO v_drafter FROM "user" WHERE email = 'drafter@musanad.local' LIMIT 1;
  SELECT id INTO v_legal   FROM "user" WHERE email = 'legal@musanad.local' LIMIT 1;
  v_drafter := COALESCE(v_drafter, 1);
  v_legal   := COALESCE(v_legal, v_drafter);

  -- contract_comment / risk_case inserts fire triggers (work-order auto-insert,
  -- audit) that read tenant/user GUCs. Set them for this transaction.
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true);
  PERFORM set_config('app.current_user_id', v_legal::text, true);

  -- Skip if already seeded (idempotent).
  IF EXISTS (SELECT 1 FROM contract_comment WHERE comment_kind = 'redline'
             AND anchor_clause_id = 'demo-708-mubadala') THEN
    RAISE NOTICE '708 demo already applied'; RETURN;
  END IF;

  -- B1. Recurring counterparty redlines across Mubadala contracts. The
  --     clause heading is what the intelligence aggregates ("what they push on").
  --     contracts: 7, 698, 27, 697 (all party 17).
  INSERT INTO contract_comment
    (contract_id, body, comment_kind, anchor_clause_id, anchor_clause_heading,
     anchor_quote, anchor_side, anchor_version_number, created_by, updated_by, data_classification)
  VALUES
    (7,   'Counterparty proposes capping aggregate liability at 12 months fees — below our 24-month floor.', 'redline', 'demo-708-mubadala', 'Limitation of Liability', 'aggregate liability shall not exceed', 'en', 1, v_legal, v_legal, 'demo'),
    (7,   'Counterparty requests Net 60 payment terms vs our Net 30 standard.', 'redline', 'demo-708-mubadala', 'Payment Terms', 'payment shall be due within', 'en', 1, v_legal, v_legal, 'demo'),
    (698, 'Counterparty seeks mutual liability cap and carve-out deletion.', 'redline', 'demo-708-mubadala', 'Limitation of Liability', 'liability cap', 'en', 1, v_legal, v_legal, 'demo'),
    (698, 'Counterparty wants indemnity narrowed to direct third-party IP claims only.', 'redline', 'demo-708-mubadala', 'Indemnification', 'shall indemnify and hold harmless', 'en', 1, v_legal, v_legal, 'demo'),
    (27,  'Counterparty pushes Net 60 again + early-payment discount removal.', 'redline', 'demo-708-mubadala', 'Payment Terms', 'net 30', 'en', 1, v_drafter, v_drafter, 'demo'),
    (27,  'Counterparty requests unilateral termination-for-convenience on 30 days notice.', 'redline', 'demo-708-mubadala', 'Termination for Convenience', 'terminate for convenience', 'en', 1, v_drafter, v_drafter, 'demo'),
    (697, 'Counterparty re-opens the liability cap negotiation (3rd contract running).', 'redline', 'demo-708-mubadala', 'Limitation of Liability', 'limitation of liability', 'en', 1, v_legal, v_legal, 'demo');

  -- B2. Extra negotiation versions → raise avg versions well above the norm.
  --     Add version rows up to a target, then sync contract.current_version.
  FOR r IN
    SELECT * FROM (VALUES (7, 4), (698, 3), (27, 3), (697, 2)) AS x(cid, target)
  LOOP
    INSERT INTO contract_version (contract_id, version_number, body_en, body_ar, change_note, changed_by, created_by, is_active, data_classification)
    SELECT r.cid, gs,
           COALESCE((SELECT body_en FROM contract WHERE id = r.cid), 'Negotiation draft v' || gs),
           (SELECT body_ar FROM contract WHERE id = r.cid),
           'Counterparty redline round ' || (gs - 1) || ' — liability / payment terms',
           v_legal, v_legal, TRUE, 'demo'
    FROM generate_series(2, r.target) gs
    WHERE NOT EXISTS (
      SELECT 1 FROM contract_version cv WHERE cv.contract_id = r.cid AND cv.version_number = gs
    );
    UPDATE contract SET current_version = GREATEST(current_version, r.target), updated_at = now()
    WHERE id = r.cid;
  END LOOP;

  -- B3. A couple of manual risk cases for variety in the risk drill-down.
  INSERT INTO risk_case
    (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status,
     dedupe_key, data_classification, created_by, updated_by)
  VALUES
    ('00000000-0000-0000-0000-000000000001', 7, 'manual', 'high',
     'Liability cap dispute — counterparty rejecting 24-month floor',
     'Mubadala has rejected the 24-month aggregate liability floor across three engagements. Escalate to Legal before re-issuing.',
     'legal_counsel', 'open', 'demo-708-mubadala-liability', 'internal', v_legal, v_legal),
    ('00000000-0000-0000-0000-000000000001', 27, 'manual', 'medium',
     'Repeated Net 60 payment-term push',
     'Counterparty consistently negotiates Net 60 against our Net 30 standard; finance flagged working-capital impact.',
     'finance_treasury', 'open', 'demo-708-mubadala-payment', 'internal', v_legal, v_legal)
  ON CONFLICT DO NOTHING;

  RAISE NOTICE '708 demo applied to party 17 (Mubadala)';
END;
$demo$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (708, 'party_intelligence_drilldown_and_demo', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DELETE FROM contract_comment WHERE anchor_clause_id = 'demo-708-mubadala';
-- DELETE FROM risk_case WHERE dedupe_key IN ('demo-708-mubadala-liability','demo-708-mubadala-payment');
-- DELETE FROM contract_version WHERE contract_id IN (7,698,27,697) AND change_note LIKE 'Counterparty redline round%';
-- (current_version not auto-reverted)
-- DELETE FROM schema_migrations WHERE version = 708;
-- ROLLBACK END
-- ============================================================================
