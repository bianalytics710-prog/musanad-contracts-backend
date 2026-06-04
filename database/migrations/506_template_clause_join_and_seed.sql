-- Migration: 506_template_clause_join_and_seed.sql
-- Module: Compose Wizard revamp — template ↔ clause association
-- Date: 2026-06-03
--
-- Adds the contract_template_clause join so the Compose Wizard can pre-add
-- the clauses that belong to a chosen template (Step 3 "Added" state).
-- Without this table, a drafter who picks the MSA template sees zero
-- clauses pre-selected and has to find + insert every standard clause
-- manually — which is the bug the user flagged.
--
-- Three parts:
--   (1) contract_template_clause table with the project-standard treatment:
--       FORCE RLS, permission-gated SELECT/ALL, deny-direct-DELETE,
--       audit_*_changes trigger, COMMENTs on every column.
--   (2) Seed defaults for the 8 ADNOC-shipped templates (id 9..16). Mappings
--       are by name_en × title_en lookup so the seed survives ID drift.
--   (3) fn_template_default_clauses(actor, template) — SECURITY INVOKER,
--       used by GET /templates/:id/default-clauses to surface the pre-add
--       list to the FE.
--
-- Rollback block lives at the bottom of this file (see -- ROLLBACK markers).

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Table
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS contract_template_clause (
  id              BIGSERIAL    PRIMARY KEY,
  template_id     BIGINT       NOT NULL REFERENCES contract_template(id) ON DELETE CASCADE,
  clause_id       BIGINT       NOT NULL REFERENCES contract_clause(id)   ON DELETE CASCADE,
  sort_order      INTEGER      NOT NULL DEFAULT 0,
  is_default      BOOLEAN      NOT NULL DEFAULT TRUE,

  created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by      BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by      BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT contract_template_clause_uq UNIQUE (template_id, clause_id)
);

COMMENT ON TABLE  contract_template_clause IS
  'Join: standard clauses pre-attached to a contract_template. Drives the "already added" badge in the Compose Wizard clause picker (Step 3).';
COMMENT ON COLUMN contract_template_clause.id          IS 'Surrogate key.';
COMMENT ON COLUMN contract_template_clause.template_id IS 'FK → contract_template(id).';
COMMENT ON COLUMN contract_template_clause.clause_id   IS 'FK → contract_clause(id).';
COMMENT ON COLUMN contract_template_clause.sort_order  IS 'Display order in the composed body, 1-based ascending.';
COMMENT ON COLUMN contract_template_clause.is_default  IS 'TRUE when the clause is pre-added on compose. Reserved for future "library only" associations (is_default = FALSE).';

CREATE INDEX idx_contract_template_clause_template ON contract_template_clause(template_id, sort_order) WHERE is_active = TRUE;
CREATE INDEX idx_contract_template_clause_clause   ON contract_template_clause(clause_id)               WHERE is_active = TRUE;

CREATE TRIGGER audit_contract_template_clause_changes
  BEFORE INSERT OR UPDATE ON contract_template_clause
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ────────────────────────────────────────────────────────────────────────────
-- 2. RLS — same shape as contract_template / contract_clause (mig 081).
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE contract_template_clause ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_template_clause FORCE  ROW LEVEL SECURITY;

CREATE POLICY contract_template_clause_select_perm ON contract_template_clause
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('contract.read.department')
      OR fn_current_user_has_permission('contract.read.all')
      OR fn_current_user_has_permission('contract.edit')
    )
  );

CREATE POLICY contract_template_clause_modify_edit ON contract_template_clause
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

CREATE POLICY contract_template_clause_deny_direct_delete ON contract_template_clause
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Seed — 8 ADNOC-shipped templates × ordered clause sets.
--    Look up by name_en × title_en so the seed survives id drift across envs.
-- ────────────────────────────────────────────────────────────────────────────

WITH seed(template_name, clause_title, sort_order) AS (VALUES
  -- #9  MoHRE Fixed-Term Employment Contract
  ('MoHRE Fixed-Term Employment Contract', 'Emirati Quota Commitment (Tawteen / Nafis)',    1),
  ('MoHRE Fixed-Term Employment Contract', 'Standard Non-Compete (12 Months)',              2),
  ('MoHRE Fixed-Term Employment Contract', 'UAE Federal Law (Standard)',                    3),
  ('MoHRE Fixed-Term Employment Contract', 'Termination for Convenience (30 Days)',         4),
  ('MoHRE Fixed-Term Employment Contract', 'Termination for Material Breach (Cure Period)', 5),
  ('MoHRE Fixed-Term Employment Contract', 'Notice — Electronic Permitted',                 6),

  -- #10 Mutual Non-Disclosure Agreement
  ('Mutual Non-Disclosure Agreement (Bilingual)', 'Mutual Confidentiality (Standard)', 1),
  ('Mutual Non-Disclosure Agreement (Bilingual)', 'UAE PDPL Compliance',               2),
  ('Mutual Non-Disclosure Agreement (Bilingual)', 'UAE Federal Law (Standard)',        3),
  ('Mutual Non-Disclosure Agreement (Bilingual)', 'DIFC-LCIA Arbitration (Tiered)',    4),
  ('Mutual Non-Disclosure Agreement (Bilingual)', 'Notice — Electronic Permitted',     5),

  -- #11 Vendor Services Agreement
  ('Vendor Services Agreement', 'Net 30 Payment Terms',                        1),
  ('Vendor Services Agreement', 'Mutual Confidentiality (Standard)',           2),
  ('Vendor Services Agreement', 'Limitation of Liability (Cap = Annual Fees)', 3),
  ('Vendor Services Agreement', 'Mutual Indemnity (Capped at Annual Fees)',    4),
  ('Vendor Services Agreement', 'Background IP and Foreground IP',             5),
  ('Vendor Services Agreement', 'Workmanlike Performance',                     6),
  ('Vendor Services Agreement', 'Force Majeure (Standard)',                    7),
  ('Vendor Services Agreement', 'Termination for Convenience (30 Days)',       8),
  ('Vendor Services Agreement', 'UAE Federal Law (Standard)',                  9),
  ('Vendor Services Agreement', 'Notice — Electronic Permitted',              10),

  -- #12 Master Services Agreement (MSA)
  ('Master Services Agreement (MSA)', 'Net 30 Payment Terms',                          1),
  ('Master Services Agreement (MSA)', 'Mutual Confidentiality (Standard)',             2),
  ('Master Services Agreement (MSA)', 'UAE PDPL Compliance',                           3),
  ('Master Services Agreement (MSA)', 'Limitation of Liability (Cap = Annual Fees)',   4),
  ('Master Services Agreement (MSA)', 'Mutual Indemnity (Capped at Annual Fees)',      5),
  ('Master Services Agreement (MSA)', 'Background IP and Foreground IP',               6),
  ('Master Services Agreement (MSA)', 'Workmanlike Performance',                       7),
  ('Master Services Agreement (MSA)', 'Termination for Material Breach (Cure Period)', 8),
  ('Master Services Agreement (MSA)', 'Force Majeure (Standard)',                      9),
  ('Master Services Agreement (MSA)', 'No Assignment Without Consent',                10),
  ('Master Services Agreement (MSA)', 'DIFC-LCIA Arbitration (Tiered)',               11),
  ('Master Services Agreement (MSA)', 'UAE Federal Law (Standard)',                   12),
  ('Master Services Agreement (MSA)', 'Notice — Electronic Permitted',                13),

  -- #13 Consultancy Services Agreement
  ('Consultancy Services Agreement', 'Net 30 Payment Terms',                        1),
  ('Consultancy Services Agreement', 'Mutual Confidentiality (Standard)',           2),
  ('Consultancy Services Agreement', 'Limitation of Liability (Cap = Annual Fees)', 3),
  ('Consultancy Services Agreement', 'Background IP and Foreground IP',             4),
  ('Consultancy Services Agreement', 'Termination for Convenience (30 Days)',       5),
  ('Consultancy Services Agreement', 'UAE Federal Law (Standard)',                  6),
  ('Consultancy Services Agreement', 'Notice — Electronic Permitted',               7),

  -- #14 LLC Incorporation Agreement
  ('LLC Incorporation Agreement', 'UAE Federal Law (Standard)',     1),
  ('LLC Incorporation Agreement', 'DIFC-LCIA Arbitration (Tiered)', 2),
  ('LLC Incorporation Agreement', 'No Assignment Without Consent',  3),
  ('LLC Incorporation Agreement', 'Notice — Electronic Permitted',  4),

  -- #15 Distribution Agreement
  ('Distribution Agreement', 'Net 30 Payment Terms',                        1),
  ('Distribution Agreement', 'Limitation of Liability (Cap = Annual Fees)', 2),
  ('Distribution Agreement', 'Mutual Indemnity (IP)',                       3),
  ('Distribution Agreement', 'Force Majeure (Standard)',                    4),
  ('Distribution Agreement', 'Termination for Convenience (30 Days)',       5),
  ('Distribution Agreement', 'Termination for Material Breach (Cure Period)', 6),
  ('Distribution Agreement', 'UAE Federal Law (Standard)',                  7),
  ('Distribution Agreement', 'Notice — Electronic Permitted',               8),

  -- #16 Real Estate Lease (Tenancy)
  ('Real Estate Lease Agreement (Tenancy Contract)', 'UAE Federal Law (Standard)',              1),
  ('Real Estate Lease Agreement (Tenancy Contract)', 'Force Majeure (Standard)',                2),
  ('Real Estate Lease Agreement (Tenancy Contract)', 'Termination for Convenience (30 Days)',   3),
  ('Real Estate Lease Agreement (Tenancy Contract)', 'Notice — Electronic Permitted',           4)
)
INSERT INTO contract_template_clause (template_id, clause_id, sort_order, is_default)
SELECT t.id, c.id, s.sort_order, TRUE
  FROM seed s
  JOIN contract_template t ON t.name_en  = s.template_name AND t.is_active = TRUE
  JOIN contract_clause    c ON c.title_en = s.clause_title  AND c.is_active = TRUE
ON CONFLICT (template_id, clause_id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. fn_template_default_clauses — used by GET /templates/:id/default-clauses.
--    Returns an ordered JSON array of clause id + lightweight projection so
--    the FE can render "Added" badges + the initial body block sequence in
--    one round-trip after template selection.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_template_default_clauses(
  p_actor_id    BIGINT,
  p_template_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_rows JSONB;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'sortOrder')::INT ASC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'id',         tc.id,
        'clauseId',   tc.clause_id,
        'sortOrder',  tc.sort_order,
        'isDefault',  tc.is_default,
        'category',   c.category,
        'variant',    c.variant,
        'titleEn',    c.title_en,
        'titleAr',    c.title_ar
      ) AS row
      FROM contract_template_clause tc
      JOIN contract_clause c ON c.id = tc.clause_id AND c.is_active = TRUE
      WHERE tc.template_id = p_template_id
        AND tc.is_active   = TRUE
    ) sub;

  RETURN jsonb_build_object(
    'templateId', p_template_id,
    'data',       v_rows
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.fn_template_default_clauses(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_template_default_clauses(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (506, '506_template_clause_join_and_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
DROP FUNCTION IF EXISTS public.fn_template_default_clauses(BIGINT, BIGINT);
DROP TABLE IF EXISTS contract_template_clause;
DELETE FROM schema_migrations WHERE version = 506;
-- ROLLBACK END
