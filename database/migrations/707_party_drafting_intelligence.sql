-- ============================================================================
-- Migration 707 — Counterparty drafting/review intelligence
-- ============================================================================
-- When a drafter composes (or a reviewer reviews) a contract, we want a compact
-- read of what HISTORY with that counterparty should make them watch out for —
-- aggregated across all of the party's prior contracts. Today nothing rolls up
-- by party (the party page shows only a flat "recent contracts" list).
--
-- fn_party_drafting_intelligence returns a minimal, decision-useful set:
--   • prior / active contract counts
--   • avg versions per contract vs the portfolio norm (negotiation friction)
--   • approval friction — distinct contracts rejected / sent back for resubmission
--   • avg negotiation days (created → signed)
--   • risk cases raised (total + open) + top case types
--   • top redline clause headings (where they push back)
--   • a few recent contracts for context
--
-- Scoping note: contract / contract_version / approval_step / contract_comment
-- carry NO tenant_id column — they are reached through the tenant-scoped `party`
-- via counterparty_id, so we resolve the party within the tenant and filter
-- contracts by counterparty_id only.
--
-- The short AI summary that sits on top of these numbers is generated live by
-- the BE (party-intelligence.service.ts → gpt-4o-mini) and logged to
-- ai_request_log; this fn is the deterministic backbone.
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
  v_recent        JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_party_drafting_intelligence: unauthorized' USING ERRCODE = '42501';
  END IF;
  -- Any contract read/draft/edit scope may see counterparty intelligence
  -- (drafters carry contract.draft/edit; reviewers carry contract.read.*).
  IF NOT (fn_current_user_has_permission('contract.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.read.own')
       OR fn_current_user_has_permission('contract.draft')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: contract read/draft permission required' USING ERRCODE = '42501';
  END IF;

  SELECT id, name_en, name_ar INTO v_party
  FROM party
  WHERE id = p_party_id AND is_active = TRUE;
  IF v_party.id IS NULL THEN
    RAISE EXCEPTION 'Party not found' USING ERRCODE = '22023';
  END IF;

  -- Prior + active contract counts (as counterparty).
  SELECT count(*), count(*) FILTER (WHERE status = 'active')
    INTO v_prior, v_active
  FROM contract
  WHERE counterparty_id = p_party_id AND is_active = TRUE
    AND (p_exclude_contract_id IS NULL OR id <> p_exclude_contract_id);

  -- Avg versions per contract for this party.
  SELECT round(avg(maxv), 1) INTO v_avg_versions FROM (
    SELECT max(cv.version_number) AS maxv
    FROM contract c
    JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY c.id
  ) s;

  -- Portfolio-wide avg versions for comparison.
  SELECT round(avg(maxv), 1) INTO v_portfolio_avg FROM (
    SELECT max(cv.version_number) AS maxv
    FROM contract c
    JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
    WHERE c.is_active = TRUE
    GROUP BY c.id
  ) s;

  -- Approval friction: distinct contracts that were rejected / sent back.
  SELECT count(DISTINCT ac.contract_id) FILTER (WHERE astep.status = 'rejected'),
         count(DISTINCT ac.contract_id) FILTER (WHERE astep.status = 'resubmission_requested')
    INTO v_rejected, v_resubmitted
  FROM approval_step astep
  JOIN approval_chain ac ON ac.id = astep.approval_chain_id
  JOIN contract c ON c.id = ac.contract_id
  WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
    AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id);

  -- Avg negotiation days (created → signed) where signed.
  SELECT round(avg(EXTRACT(EPOCH FROM (signed_at - created_at)) / 86400.0)::numeric, 0)
    INTO v_avg_days
  FROM contract
  WHERE counterparty_id = p_party_id AND is_active = TRUE AND signed_at IS NOT NULL
    AND signed_at >= created_at  -- guard against seed rows with signed_at < created_at
    AND (p_exclude_contract_id IS NULL OR id <> p_exclude_contract_id);

  -- Risk cases across this party's contracts (open = not yet closed).
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
    FROM risk_case rc
    JOIN contract c ON c.id = rc.contract_id
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE AND rc.is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY rc.case_type
    ORDER BY count(*) DESC
    LIMIT 5
  ) t;

  -- Top redline clause headings (where they negotiate hardest).
  SELECT COALESCE(jsonb_agg(jsonb_build_object('heading', heading, 'n', n) ORDER BY n DESC), '[]'::jsonb)
    INTO v_redline
  FROM (
    SELECT cc.anchor_clause_heading AS heading, count(*) AS n
    FROM contract_comment cc
    JOIN contract c ON c.id = cc.contract_id
    WHERE c.counterparty_id = p_party_id AND c.is_active = TRUE
      AND cc.is_active = TRUE AND cc.comment_kind = 'redline'
      AND cc.anchor_clause_heading IS NOT NULL
      AND (p_exclude_contract_id IS NULL OR c.id <> p_exclude_contract_id)
    GROUP BY cc.anchor_clause_heading
    ORDER BY count(*) DESC
    LIMIT 3
  ) t;

  -- A few recent contracts for context.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', id, 'contractNumber', contract_number, 'title', title_en,
           'status', status, 'versions', current_version, 'createdAt', created_at
         ) ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_recent
  FROM (
    SELECT id, contract_number, title_en, status, current_version, created_at
    FROM contract
    WHERE counterparty_id = p_party_id AND is_active = TRUE
      AND (p_exclude_contract_id IS NULL OR id <> p_exclude_contract_id)
    ORDER BY created_at DESC
    LIMIT 5
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
    'recentContracts', v_recent
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_drafting_intelligence: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_party_drafting_intelligence(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_party_drafting_intelligence(BIGINT, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_party_drafting_intelligence(BIGINT, BIGINT) IS
  '707: per-counterparty drafting/review intelligence — aggregates prior contracts, avg versions vs portfolio, approval friction (rejected/resubmitted), avg negotiation days, risk cases + top redline clause headings, across the party''s contracts (excluding p_exclude_contract_id). DEFINER + contract.read gate. Tenant scope via party.';

-- AI prompt config for the short synthesis (FK target for ai_request_log).
INSERT INTO ai_prompt
  (prompt_id, description_en, description_ar, default_model, default_temperature, default_max_tokens,
   default_ttl_seconds, supports_streaming, supports_tool_call, public_endpoint,
   prompt_file_path, rate_limit_per_user_per_hour, rate_limit_per_user_per_day,
   data_classification, created_at, updated_at, is_active)
VALUES
  ('party_intelligence__drafting',
   'Counterparty Drafting Intelligence — writes a short, grounded note for a drafter/reviewer summarising what prior-contract history with a counterparty means for the contract in hand.',
   'ذكاء صياغة الطرف المقابل — يكتب ملاحظة قصيرة وموثقة للمُسوِّد/المراجع تلخص ما يعنيه سجل العقود السابقة مع الطرف المقابل للعقد الحالي.',
   'gpt-4o-mini',
   0.3,
   240,
   0,
   FALSE,
   FALSE,
   FALSE,
   'prompts/party_intelligence__drafting.txt',
   30,
   200,
   'production',
   CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, TRUE)
ON CONFLICT (prompt_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (707, 'party_drafting_intelligence', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DELETE FROM ai_prompt WHERE prompt_id = 'party_intelligence__drafting';
-- DROP FUNCTION IF EXISTS fn_party_drafting_intelligence(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 707;
-- ROLLBACK END
-- ============================================================================
