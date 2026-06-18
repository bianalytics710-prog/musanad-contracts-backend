-- ============================================================================
-- Migration 699 — Soft-delete the "USD/AED peg deviation" Tier-2 triage case
-- ============================================================================
-- Per request, remove the demo Risk Triage item "USD/AED peg deviation 0.38%
-- — short-window" (risk_case id 30). Reversible soft delete (is_active=false).
-- ============================================================================

BEGIN;

DO $$
DECLARE v_tenant UUID := '00000000-0000-0000-0000-000000000001'::uuid;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id', '1', true);

  UPDATE risk_case
     SET is_active = FALSE, updated_at = now(), updated_by = 1
   WHERE tenant_id = v_tenant
     AND is_active = TRUE
     AND title ILIKE 'USD/AED peg deviation%short-window%';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (699, 'soft-delete USD/AED peg deviation triage case', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
