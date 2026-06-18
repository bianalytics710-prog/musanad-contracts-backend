-- ============================================================================
-- Migration 709 — Make counterparty intelligence realistic
-- ============================================================================
-- Feedback on the Mubadala demo:
--   1. "6 prior contracts, 0 active" is unrealistic — flip a realistic subset to
--      active (signed + running).
--   2. The negotiation positions ("liability cap dispute", "Net 60 push") were
--      seeded as MANUAL RISK CASES — wrong. Those are things the counterparty /
--      our reviewer raised on PAST contracts; they belong to the redline
--      comments, not the risk register. So: delete the two fabricated manual
--      risk cases, and surface the negotiation intelligence from the actual
--      contract_comment (redline) history instead.
--
-- This migration:
--   A. fn_party_drafting_intelligence now also returns redlineComments[] — the
--      real past comments behind the "what they push on" themes (clause, what
--      was said, which contract, who logged it, when).
--   B. Mubadala (party 17): set 3 contracts active; delete the 2 fake manual
--      risk cases; add a few more realistic past redlines for depth.
-- ============================================================================

BEGIN;

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
  v_user_id        BIGINT;
  v_party          RECORD;
  v_prior          INT;
  v_active         INT;
  v_avg_versions   NUMERIC;
  v_portfolio_avg  NUMERIC;
  v_rejected       INT;
  v_resubmitted    INT;
  v_avg_days       NUMERIC;
  v_rc_total       INT;
  v_rc_open        INT;
  v_rc_by_type     JSONB;
  v_redline        JSONB;
  v_contracts      JSONB;
  v_sent_back      JSONB;
  v_risk_list      JSONB;
  v_redline_cmts   JSONB;
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
    FROM contract c JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY c.id
  ) s;

  SELECT round(avg(maxv), 1) INTO v_portfolio_avg FROM (
    SELECT max(cv.version_number) AS maxv
    FROM contract c JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
    WHERE c.is_active = TRUE GROUP BY c.id
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
  FROM risk_case rc JOIN contract c ON c.id = rc.contract_id
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

  -- ── Drill-down: the actual past redline comments (reviewer / counterparty
  --    positions on previous contracts) behind the "what they push on" themes ──
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'contractId', contract_id, 'contractNumber', contract_number,
           'clauseHeading', heading, 'body', body, 'author', author, 'createdAt', created_at
         ) ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_redline_cmts
  FROM (
    SELECT c.id AS contract_id, c.contract_number, cc.anchor_clause_heading AS heading,
           cc.body, NULLIF(trim(concat_ws(' ', u.first_name, u.last_name)), '') AS author,
           cc.created_at
    FROM contract_comment cc
    JOIN contract c ON c.id = cc.contract_id
    LEFT JOIN "user" u ON u.id = cc.created_by
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND cc.is_active = TRUE AND cc.comment_kind = 'redline'
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    ORDER BY cc.created_at DESC LIMIT 40
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
    'riskCaseList', v_risk_list,
    'redlineComments', v_redline_cmts
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_drafting_intelligence: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

-- ── B. Make Mubadala (party 17) realistic ───────────────────────────────────
DO $fix$
DECLARE
  v_legal   BIGINT;
  v_drafter BIGINT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = 17) THEN
    RAISE NOTICE '709 skipped — party 17 absent'; RETURN;
  END IF;
  SELECT id INTO v_legal   FROM "user" WHERE email = 'legal@musanad.local' LIMIT 1;
  SELECT id INTO v_drafter FROM "user" WHERE email = 'drafter@musanad.local' LIMIT 1;
  v_legal   := COALESCE(v_legal, 1);
  v_drafter := COALESCE(v_drafter, v_legal);
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true);
  PERFORM set_config('app.current_user_id', v_legal::text, true);

  -- B1. A realistic active footprint (3 active, signed + running).
  UPDATE contract SET status = 'active', updated_at = now()
   WHERE id = 698 AND status <> 'active';
  UPDATE contract SET status = 'active', signed_at = COALESCE(signed_at, TIMESTAMPTZ '2025-12-20 10:00+04'), updated_at = now()
   WHERE id = 27 AND status <> 'active';
  UPDATE contract SET status = 'active', signed_at = COALESCE(signed_at, TIMESTAMPTZ '2026-03-20 10:00+04'), updated_at = now()
   WHERE id = 7 AND status <> 'active';

  -- B2. Negotiation positions are NOT risk cases — remove the fabricated ones.
  DELETE FROM risk_case
   WHERE dedupe_key IN ('demo-708-mubadala-liability', 'demo-708-mubadala-payment');

  -- B3. A few more realistic past redlines (reviewer-logged counterparty
  --     positions), reinforcing the recurring pattern. Idempotent via marker.
  IF NOT EXISTS (SELECT 1 FROM contract_comment WHERE anchor_clause_id = 'demo-709-mubadala') THEN
    INSERT INTO contract_comment
      (contract_id, body, comment_kind, anchor_clause_id, anchor_clause_heading,
       anchor_quote, anchor_side, anchor_version_number, created_by, updated_by, data_classification)
    VALUES
      (37,  'Counterparty re-opened the liability cap again — same 12-month position as their other engagements.', 'redline', 'demo-709-mubadala', 'Limitation of Liability', 'aggregate liability', 'en', 1, v_legal, v_legal, 'demo'),
      (698, 'Counterparty pushed for DIFC courts; we held Abu Dhabi jurisdiction. Conceded after escalation.', 'redline', 'demo-709-mubadala', 'Governing Law & Jurisdiction', 'courts of', 'en', 1, v_legal, v_legal, 'demo'),
      (17,  'Counterparty requested 3-year confidentiality survival vs our 5-year standard.', 'redline', 'demo-709-mubadala', 'Confidentiality', 'survive termination for', 'en', 1, v_drafter, v_drafter, 'demo'),
      (27,  'Counterparty asked to delete the audit-rights clause; partially retained (annual only).', 'redline', 'demo-709-mubadala', 'Audit Rights', 'right to audit', 'en', 1, v_drafter, v_drafter, 'demo');
  END IF;

  RAISE NOTICE '709 realism applied to party 17';
END;
$fix$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (709, 'party_intelligence_realism', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DELETE FROM contract_comment WHERE anchor_clause_id = 'demo-709-mubadala';
-- DELETE FROM schema_migrations WHERE version = 709;
-- (contract status / deleted risk cases not auto-reverted)
-- ROLLBACK END
-- ============================================================================
