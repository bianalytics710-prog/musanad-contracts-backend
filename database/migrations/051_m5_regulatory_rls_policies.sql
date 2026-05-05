-- ============================================================================
-- 051_m5_regulatory_rls_policies.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   049 (regulation, impact_category, regulatory_update, regulatory_impact),
--            M0 (fn_current_user_has_permission), M1a (contract).
-- ----------------------------------------------------------------------------
-- RLS policies for the 4 M5 entities (regulator policies live in 048).
-- 9 policies total (regulator's 2 already in 048; total M5 RLS surface = 11).
--
-- Policy summary:
--   regulation         — SELECT (regulations.read), modify (regulations.manage)
--   regulatory_update  — SELECT (regulations.read), modify (regulations.manage)
--   impact_category    — SELECT (any authenticated, AC-S14-05), modify (config.manage)
--   regulatory_impact  — SELECT inherits contract visibility (recursive RLS via EXISTS),
--                        INSERT (regulations.manage),
--                        UPDATE (regulations.manage OR contract drafter polymorphic)
--
-- contract_recipient explicit deny: regulations.read not granted in 046 → all
-- regulatory SELECTs return empty rows for that role.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. regulation RLS
-- ============================================================================
ALTER TABLE regulation ENABLE ROW LEVEL SECURITY;

CREATE POLICY regulation_select_authenticated ON regulation
  FOR SELECT
  USING (
    is_active = TRUE
    AND fn_current_user_has_permission('regulations.read')
  );

CREATE POLICY regulation_modify_legal_or_admin ON regulation
  FOR ALL
  USING (fn_current_user_has_permission('regulations.manage'))
  WITH CHECK (fn_current_user_has_permission('regulations.manage'));


-- ============================================================================
-- 2. regulatory_update RLS
-- ============================================================================
ALTER TABLE regulatory_update ENABLE ROW LEVEL SECURITY;

CREATE POLICY regulatory_update_select_authenticated ON regulatory_update
  FOR SELECT
  USING (
    is_active = TRUE
    AND fn_current_user_has_permission('regulations.read')
  );

CREATE POLICY regulatory_update_modify_legal_or_admin ON regulatory_update
  FOR ALL
  USING (fn_current_user_has_permission('regulations.manage'))
  WITH CHECK (fn_current_user_has_permission('regulations.manage'));


-- ============================================================================
-- 3. impact_category RLS
-- ============================================================================
ALTER TABLE impact_category ENABLE ROW LEVEL SECURITY;

CREATE POLICY impact_category_select_authenticated ON impact_category
  FOR SELECT
  USING (is_active = TRUE);

CREATE POLICY impact_category_modify_admin_only ON impact_category
  FOR ALL
  USING (fn_current_user_has_permission('config.manage'))
  WITH CHECK (fn_current_user_has_permission('config.manage'));


-- ============================================================================
-- 4. regulatory_impact RLS
-- ============================================================================
ALTER TABLE regulatory_impact ENABLE ROW LEVEL SECURITY;

-- 4a. SELECT — regulations.read AND contract visibility (recursive RLS via EXISTS)
CREATE POLICY regulatory_impact_select_inherit_contract ON regulatory_impact
  FOR SELECT
  USING (
    is_active = TRUE
    AND fn_current_user_has_permission('regulations.read')
    AND EXISTS (
      SELECT 1 FROM contract c
      WHERE c.id = regulatory_impact.contract_id
      -- contract_select_role_aware applies recursively (M1a) — admin/legal/executive
      -- bypass via role check; otherwise ownership match.
    )
  );

-- 4b. INSERT (direct path) — regulations.manage. fn_regulatory_impact_create_bulk
--     is DEFINER and bypasses RLS for the bulk path.
CREATE POLICY regulatory_impact_insert_legal_or_admin ON regulatory_impact
  FOR INSERT
  WITH CHECK (fn_current_user_has_permission('regulations.manage'));

-- 4c. UPDATE (resolve) — regulations.manage OR contract drafter (polymorphic).
--     The polymorphic ownership check is also enforced at fn body in
--     fn_regulatory_impact_resolve (defence-in-depth).
CREATE POLICY regulatory_impact_update_legal_or_drafter_or_admin ON regulatory_impact
  FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('regulations.manage')
      OR EXISTS (
        SELECT 1 FROM contract c
        WHERE c.id = regulatory_impact.contract_id
          AND c.drafted_by = NULLIF(current_setting('app.current_user_id', TRUE), '')::BIGINT
      )
    )
  )
  WITH CHECK (
    fn_current_user_has_permission('regulations.manage')
    OR EXISTS (
      SELECT 1 FROM contract c
      WHERE c.id = regulatory_impact.contract_id
        AND c.drafted_by = NULLIF(current_setting('app.current_user_id', TRUE), '')::BIGINT
    )
  );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (51, 'm5_regulatory_rls_policies', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP POLICY IF EXISTS regulatory_impact_update_legal_or_drafter_or_admin ON regulatory_impact;
DROP POLICY IF EXISTS regulatory_impact_insert_legal_or_admin            ON regulatory_impact;
DROP POLICY IF EXISTS regulatory_impact_select_inherit_contract          ON regulatory_impact;
DROP POLICY IF EXISTS impact_category_modify_admin_only                  ON impact_category;
DROP POLICY IF EXISTS impact_category_select_authenticated               ON impact_category;
DROP POLICY IF EXISTS regulatory_update_modify_legal_or_admin            ON regulatory_update;
DROP POLICY IF EXISTS regulatory_update_select_authenticated             ON regulatory_update;
DROP POLICY IF EXISTS regulation_modify_legal_or_admin                   ON regulation;
DROP POLICY IF EXISTS regulation_select_authenticated                    ON regulation;
ALTER TABLE regulatory_impact DISABLE ROW LEVEL SECURITY;
ALTER TABLE impact_category   DISABLE ROW LEVEL SECURITY;
ALTER TABLE regulatory_update DISABLE ROW LEVEL SECURITY;
ALTER TABLE regulation        DISABLE ROW LEVEL SECURITY;
DELETE FROM schema_migrations WHERE version = 51;
COMMIT;
-- ROLLBACK END
