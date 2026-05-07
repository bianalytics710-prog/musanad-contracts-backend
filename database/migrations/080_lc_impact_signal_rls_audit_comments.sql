-- Migration 080: R-LC9-1 — production hardening for impact_signal +
-- impact_signal_contract.
--
-- R-LC7 (079) shipped these tables without RLS, audit triggers, or
-- COMMENTs — three things v2.6 mandates for every business table.
-- This migration brings both tables to v2.6 standard:
--
--   1. FORCE ROW LEVEL SECURITY + 2 policies per table (read + write).
--   2. AFTER INSERT OR UPDATE OR DELETE audit_*_changes triggers
--      (fan out to fn_audit_trigger from M0).
--   3. COMMENT ON TABLE + COMMENT ON COLUMN for every column on both
--      tables.
--
-- S2-21 verification (PUBLIC grants enumeration): confirmed unchanged
-- — no PUBLIC GRANTs were added in 079 (the 5-fn invariant from M3
-- holds).

-- ============================================================
-- 1. RLS — impact_signal
-- ============================================================
ALTER TABLE impact_signal           ENABLE ROW LEVEL SECURITY;
ALTER TABLE impact_signal           FORCE  ROW LEVEL SECURITY;
ALTER TABLE impact_signal_contract  ENABLE ROW LEVEL SECURITY;
ALTER TABLE impact_signal_contract  FORCE  ROW LEVEL SECURITY;

-- Read policy: anyone with contract.read.department or contract.edit
-- (mirrors the fn_-level gate so the policy check matches the API
-- contract).
CREATE POLICY impact_signal_select_read_perm ON impact_signal
  AS PERMISSIVE FOR SELECT
  USING (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.edit')
  );

-- Write policy: only contract.edit (mirrors fn_impact_signal_*_create /
-- mutation gates).
CREATE POLICY impact_signal_modify_edit_perm ON impact_signal
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

-- Block raw DELETE (soft-delete via is_active=FALSE only).
CREATE POLICY impact_signal_deny_direct_delete ON impact_signal
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- ============================================================
-- 2. RLS — impact_signal_contract
-- ============================================================
CREATE POLICY impact_signal_contract_select_read_perm ON impact_signal_contract
  AS PERMISSIVE FOR SELECT
  USING (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.edit')
  );

CREATE POLICY impact_signal_contract_modify_edit_perm ON impact_signal_contract
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

CREATE POLICY impact_signal_contract_deny_direct_delete ON impact_signal_contract
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- ============================================================
-- 3. Audit triggers (fan-out to fn_audit_trigger)
-- ============================================================
CREATE TRIGGER audit_impact_signal_changes
  AFTER INSERT OR UPDATE OR DELETE ON impact_signal
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_impact_signal_contract_changes
  AFTER INSERT OR UPDATE OR DELETE ON impact_signal_contract
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================
-- 4. Table + column COMMENTs (data dictionary input)
-- ============================================================
COMMENT ON TABLE impact_signal IS
  'R-LC7 multi-source intelligence signal — covers regulatory updates, commodity-price moves, supply-chain disruption, geopolitical events, and market/financial signals affecting contracts. Single unified entity; category column drives the FE Impact Watch filter pills.';

COMMENT ON COLUMN impact_signal.ext_id IS
  'External reference identifier (e.g. CBUAE-AML-08-2025, BRENT-OIL-95-2026). UNIQUE — second insert with the same ext_id is rejected.';
COMMENT ON COLUMN impact_signal.category IS
  'One of regulatory / commodity_prices / supply_chain / geopolitical / market_financial. Drives FE filter pills + Impact Radar axis.';
COMMENT ON COLUMN impact_signal.source IS
  'Authority / index / event source name (e.g. Central Bank, Brent Crude, OFAC).';
COMMENT ON COLUMN impact_signal.severity IS
  'Free-text severity label (critical / major / sharp_move / shifting / volatile / etc.). Lovable uses varied vocabulary per category — keep flexible.';
COMMENT ON COLUMN impact_signal.title_en IS 'English headline.';
COMMENT ON COLUMN impact_signal.title_ar IS 'Arabic headline (optional).';
COMMENT ON COLUMN impact_signal.description_en IS 'Long-form English description / context.';
COMMENT ON COLUMN impact_signal.description_ar IS 'Long-form Arabic description (optional).';
COMMENT ON COLUMN impact_signal.affected_clause_categories IS
  'Array of clause categories (confidentiality / payment / etc.) most likely impacted. Drives the FE chip strip on the detail panel.';
COMMENT ON COLUMN impact_signal.published_date IS
  'Date the signal was first observed / published.';
COMMENT ON COLUMN impact_signal.effective_date IS
  'Date the signal takes effect (e.g. regulation effective date). Optional.';
COMMENT ON COLUMN impact_signal.compliance_deadline IS
  'Hard deadline by which contracts must be amended. Optional.';
COMMENT ON COLUMN impact_signal.is_seed IS 'TRUE for rows inserted by migration seed.';
COMMENT ON COLUMN impact_signal.created_at IS 'Audit column.';
COMMENT ON COLUMN impact_signal.updated_at IS 'Audit column.';
COMMENT ON COLUMN impact_signal.created_by IS 'Audit column — user.id.';
COMMENT ON COLUMN impact_signal.updated_by IS 'Audit column — user.id.';
COMMENT ON COLUMN impact_signal.is_active IS 'Soft-delete flag (FALSE = deleted).';

COMMENT ON TABLE impact_signal_contract IS
  'R-LC7 junction table — N:N between impact_signal and contract. Each row carries an impact_score (0-100) + per-contract review/amendment workflow status (pending / reviewed / amended / dismissed).';

COMMENT ON COLUMN impact_signal_contract.signal_id IS 'FK → impact_signal.id (CASCADE).';
COMMENT ON COLUMN impact_signal_contract.contract_id IS 'FK → contract.id (CASCADE).';
COMMENT ON COLUMN impact_signal_contract.impact_score IS
  'Estimated severity for this specific contract (0-100). Set by extraction logic or manually overridden by counsel.';
COMMENT ON COLUMN impact_signal_contract.status IS
  'Per-contract workflow state: pending (initial), reviewed (counsel acknowledged), amended (bulk-amend completed), dismissed (no action needed).';
COMMENT ON COLUMN impact_signal_contract.reviewed_at IS 'Set by fn_impact_signal_mark_reviewed.';
COMMENT ON COLUMN impact_signal_contract.reviewed_by IS 'Set by fn_impact_signal_mark_reviewed — user.id.';
COMMENT ON COLUMN impact_signal_contract.is_seed IS 'TRUE for rows inserted by migration seed.';
COMMENT ON COLUMN impact_signal_contract.created_at IS 'Audit column.';
COMMENT ON COLUMN impact_signal_contract.updated_at IS 'Audit column.';
COMMENT ON COLUMN impact_signal_contract.created_by IS 'Audit column — user.id.';
COMMENT ON COLUMN impact_signal_contract.updated_by IS 'Audit column — user.id.';
COMMENT ON COLUMN impact_signal_contract.is_active IS 'Soft-delete flag (FALSE = deleted).';

-- ============================================================
-- 5. ROLLBACK
-- ============================================================
-- ROLLBACK BEGIN
-- DROP TRIGGER IF EXISTS audit_impact_signal_changes ON impact_signal;
-- DROP TRIGGER IF EXISTS audit_impact_signal_contract_changes ON impact_signal_contract;
-- DROP POLICY IF EXISTS impact_signal_select_read_perm ON impact_signal;
-- DROP POLICY IF EXISTS impact_signal_modify_edit_perm ON impact_signal;
-- DROP POLICY IF EXISTS impact_signal_deny_direct_delete ON impact_signal;
-- DROP POLICY IF EXISTS impact_signal_contract_select_read_perm ON impact_signal_contract;
-- DROP POLICY IF EXISTS impact_signal_contract_modify_edit_perm ON impact_signal_contract;
-- DROP POLICY IF EXISTS impact_signal_contract_deny_direct_delete ON impact_signal_contract;
-- ALTER TABLE impact_signal NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE impact_signal DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE impact_signal_contract NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE impact_signal_contract DISABLE ROW LEVEL SECURITY;
-- ROLLBACK END
