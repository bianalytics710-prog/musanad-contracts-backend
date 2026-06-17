-- ============================================================================
-- Migration 695 — Soft-delete demo-created manual cases + fix milestone wording
-- ============================================================================
-- 1. Soft-delete the manual risk cases created through the new-case form during
--    this session (case_type='manual' AND metadata carries the form's riskType;
--    the original seeded manual cases have no metadata.riskType and are kept).
-- 2. The milestone-slippage demo case overpromised: "forecast to finish 21 days
--    after baseline" + a "Forecast finish" field implies we can predict the
--    completion date. We can only observe that a milestone has slipped past its
--    baseline. Reword title/body + the source-record snapshot to an OBSERVED
--    slip (N days past baseline, still open) — no forecast.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001'::uuid;
  v_sig_id BIGINT;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id', '1', true);

  -- 1. Soft-delete form-created manual cases.
  UPDATE risk_case
     SET is_active = FALSE, updated_at = now(), updated_by = 1
   WHERE tenant_id = v_tenant
     AND is_active = TRUE
     AND case_type = 'manual'
     AND metadata ? 'riskType';

  -- 2. Reword the milestone-slippage case (id 44) — observed slip, not forecast.
  UPDATE risk_case
     SET title = 'Milestone slippage — critical-path activity 21 days past baseline (still open) on EPC Crude Stabilization',
         body  = 'Oracle Primavera P6 shows critical-path activity A1340 (Mechanical Completion) is 21 days past its baseline finish date and has not been marked complete — an active milestone slip that exposes the contract to liquidated damages. Confirm as an operations risk or dismiss as noise.',
         updated_at = now()
   WHERE id = 44 AND tenant_id = v_tenant;

  -- Reword the underlying signal title + snapshot (replace the "forecast" framing
  -- with observed "days past baseline" + an explicit not-completed status).
  SELECT os.id INTO v_sig_id
    FROM osint_signal os
    JOIN correlation co ON co.signal_id = os.id
    JOIN risk_case rc   ON rc.correlation_id = co.id
   WHERE rc.id = 44;

  IF v_sig_id IS NOT NULL THEN
    UPDATE osint_signal
       SET title = 'Milestone Slippage — EPC Crude Stabilization critical activity 21d past baseline',
           source_record_snapshot = jsonb_build_object(
             'systemName','Oracle Primavera P6','systemCode','primavera_p6','systemKind','scm',
             'recordType','Schedule activity','recordId','A1340 — Mechanical Completion',
             'recordUrl','https://p6.adnoc.ae/record/A1340',
             'capturedAt', now(),
             'fields', jsonb_build_array(
               jsonb_build_object('label','Activity ID','value','A1340 — Mechanical Completion'),
               jsonb_build_object('label','Baseline finish','value','2026-04-30'),
               jsonb_build_object('label','Status','value','In progress — not completed'),
               jsonb_build_object('label','Days past baseline','value','21 days'),
               jsonb_build_object('label','On critical path','value','Yes')
             ))
     WHERE id = v_sig_id;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (695, 'soft-delete form-created manual cases + observed (not forecast) milestone wording', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
