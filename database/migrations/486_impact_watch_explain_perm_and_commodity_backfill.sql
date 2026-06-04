-- Migration: 486_impact_watch_explain_perm_and_commodity_backfill.sql
-- Module: Impact Watch — Executive demo polish (E-rev round E)
-- Date: 2026-06-02
--
-- TWO related fixes:
--
-- (A) Split ai.invoke.regulatory into:
--       ai.invoke.regulatory          — kept as the gate for "Suggest
--                                       amendment language" (legal_counsel
--                                       + platform_admin + Super Admin
--                                       only — drafts contractual language)
--       ai.invoke.regulatory.explain  — NEW, gates "Explain with AI" (read-
--                                       only narrative explanation). Granted
--                                       to every role that already sees
--                                       Impact Watch via fn_impact_signal_list
--                                       (mig 349): executive, compliance_esg,
--                                       legal_counsel, platform_admin,
--                                       Super Admin, plus contract_drafter,
--                                       contract_approver, operations,
--                                       finance_treasury, procurement_supplier_risk.
--
-- (B) Backfill impact_signal_contract rows for commodity_prices signals.
--     Migration 453 attempted this but used title-case contract_type values
--     ('Supply','Gas SPA','Services') while the column actually stores the
--     lowercase slugs ('supply','gas_spa','services'), so 0 rows matched
--     for the commodity branch. Re-insert with the correct casing so
--     Brent USD 95 and Murban 110.75 each light up ~5 impacted contracts.
--     ON CONFLICT skips anything already linked.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- (A) Permission split ---------------------------------------------------

INSERT INTO permission (code, module, action, description)
VALUES (
  'ai.invoke.regulatory.explain',
  'ai', 'invoke',
  'Run AI explain-with-AI on an Impact Watch signal (read-only narrative). Broader than ai.invoke.regulatory which is reserved for amendment drafting.'
)
ON CONFLICT (code) DO NOTHING;

-- Grant the new perm to every role that already passes the Impact Watch
-- list gate (mig 349 codes contract.read.* / contract.edit / insights.*).
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  CROSS JOIN permission p
  WHERE p.code = 'ai.invoke.regulatory.explain'
    AND r.name IN (
      'Super Admin',
      'platform_admin',
      'legal_counsel',
      'executive',
      'compliance_esg',
      'contract_drafter',
      'contract_approver',
      'operations',
      'finance_treasury',
      'procurement_supplier_risk'
    )
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- (B) Commodity signal backfill -----------------------------------------
-- Same body as mig 453 BUT scoped to commodity_prices only AND using the
-- correct lowercase contract_type slugs. Top-5 by value per signal. Idempotent
-- via the UNIQUE (signal_id, contract_id) constraint on impact_signal_contract.

INSERT INTO impact_signal_contract (
  signal_id, contract_id, impact_score, status, is_seed, is_active, data_classification, created_by, updated_by
)
SELECT
  picked.signal_id,
  picked.contract_id,
  CASE picked.severity
    WHEN 'critical' THEN 90
    WHEN 'high'     THEN 75
    WHEN 'medium'   THEN 55
    WHEN 'low'      THEN 30
    ELSE                 15
  END                                                  AS impact_score,
  'pending'                                            AS status,
  TRUE                                                 AS is_seed,
  TRUE                                                 AS is_active,
  'demo'                                               AS data_classification,
  1                                                    AS created_by,
  1                                                    AS updated_by
FROM (
  SELECT
    s.id AS signal_id,
    c.id AS contract_id,
    s.severity,
    ROW_NUMBER() OVER (
      PARTITION BY s.id
      ORDER BY c.value_aed DESC NULLS LAST, c.id
    ) AS rn
  FROM impact_signal s
  CROSS JOIN LATERAL (
    SELECT c.id, c.value_aed
    FROM contract c
    WHERE c.is_active = TRUE
      AND s.category = 'commodity_prices'
      AND c.contract_type IN ('supply','gas_spa','services','epc')
  ) c
  WHERE s.is_active = TRUE
    AND s.category = 'commodity_prices'
) picked
WHERE picked.rn <= 5
ON CONFLICT (signal_id, contract_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (486, '486_impact_watch_explain_perm_and_commodity_backfill', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
