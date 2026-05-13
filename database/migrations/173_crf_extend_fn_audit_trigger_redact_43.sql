-- Migration: 173_crf_extend_fn_audit_trigger_redact_43.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: CREATE OR REPLACE fn_audit_trigger() — body byte-identical to migration 157
--   EXCEPT v_redact_fields extends 41 → 43 names (adds 'contributing_correlations', 'explanation').
--
--   BYTE-AWARE DIFF (feedback_fn_rewrites_lose_safety_guards.md — non-negotiable):
--   Preserved invariants verified vs live pg_get_functiondef + migration 157:
--   ✓ RETURNS TRIGGER / LANGUAGE plpgsql / SECURITY DEFINER
--   ✓ DECLARE: v_old_data JSONB, v_new_data JSONB, v_user_id BIGINT, v_field TEXT, v_redact_fields TEXT[]
--   ✓ All 41 baseline redact fields preserved verbatim (M0×16 + M1a×2 + M2×2 + M3×4 + M4×2 + M7×3 + M9/CR-B×2 + CR-D0×5 + CR-D/CR-E×4)
--   ✓ BEGIN block: TG_OP = 'DELETE' / 'INSERT' / else (UPDATE) logic
--   ✓ FOREACH v_field IN ARRAY v_redact_fields LOOP with jsonb_set redact pattern
--   ✓ S2-20 sentinel: v_user_id := NULLIF(current_setting('app.current_user_id', true),'')::BIGINT
--   ✓ EXCEPTION WHEN OTHERS THEN v_user_id := NULL (inner block)
--   ✓ IF v_user_id = 0 THEN v_user_id := NULL; END IF (S2-20 system actor sentinel)
--   ✓ M10 CR-C 128 hash-chain: PERFORM fn_audit_log_record_v2(TG_TABLE_NAME, COALESCE(NEW.id,OLD.id), TG_OP, v_old_data, v_new_data, v_user_id)
--   ✓ RETURN COALESCE(NEW, OLD)
--   ✓ COMMENT ON FUNCTION (updated to mention 43 names + CR-F 2 net-new)
--   ✓ REVOKE EXECUTE + GRANT EXECUTE trio re-issued (S2-21 / B14)
--
--   QA Stage 3 W3 compliance: fn_audit_trigger 'contributing_correlations' + 'explanation' added to
--   v_redact_fields — covers risk_score rows written by fn_risk_score_compute.
--   False-positive verification (per db-design.md §2.6):
--   - 'contributing_correlations': only risk_score has this column — safe.
--   - 'explanation': verified against ai_request_log (no column), correlation_evaluation_error (no column),
--     correlation_rule.meta JSONB (free-form keys — redaction acceptable; rule body not PII-sensitive).
--
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_audit_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_user_id  BIGINT;
  v_field    TEXT;
  v_redact_fields TEXT[] := ARRAY[
    -- M0 verbatim (16)
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body',
    -- M1a (2)
    'body_en','body_ar',
    -- M2 (2)
    'decision_note','matrix_snapshot',
    -- M3 (4)
    'invitation_token_hash','session_token_hash','signature_data','signature_image_url',
    -- M4 (2)
    'payload','error_message',
    -- M7 (3)
    'credential_ref','raw_payload','last_error_message',
    -- M9 / CR-B (2)
    'aliases','metadata',
    -- CR-D0 (M11 / 133) — 5 net-new (F-S2-9 patch: 32 → 37)
    'tesseract_text','gpt4o_text','final_text','ingestion_error','extracted_text_uri',
    -- CR-D + CR-E (157) — 4 net-new (37 → 41)
    'parameters',     -- CR-D contract_clause_extracted.parameters (extracted contract content — proprietary)
    'text_excerpts',  -- CR-D contract_clause_extracted.text_excerpts (verbatim source-text — highly proprietary)
    'match_evidence', -- CR-E correlation.match_evidence (signal raw_payload refs, SDN UIDs, counterparty IDs)
    'match_entities', -- CR-E correlation.match_entities (sanctioned entity names + designations — PII/sanctions-sensitive)
    -- ===== CR-F migration 173 — 2 net-new (41 → 43) =====
    'contributing_correlations',  -- risk_score.contributing_correlations — refs correlation IDs + signal raw_payload pointers
    'explanation'                  -- risk_score.explanation — reason codes + clause text snippets
    -- ===== end CR-F additive block =====
  ];
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old_data := to_jsonb(OLD); v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old_data := NULL; v_new_data := to_jsonb(NEW);
  ELSE
    v_old_data := to_jsonb(OLD); v_new_data := to_jsonb(NEW);
  END IF;
  FOREACH v_field IN ARRAY v_redact_fields LOOP
    IF v_old_data IS NOT NULL AND v_old_data ? v_field THEN
      v_old_data := jsonb_set(v_old_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
    IF v_new_data IS NOT NULL AND v_new_data ? v_field THEN
      v_new_data := jsonb_set(v_new_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
  END LOOP;
  BEGIN
    v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN v_user_id := NULL;
  END;
  IF v_user_id = 0 THEN v_user_id := NULL; END IF;  -- S2-20 system actor sentinel

  -- Preserve CR-C 128 hash-chain routing.
  PERFORM fn_audit_log_record_v2(
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id),
    TG_OP,
    v_old_data,
    v_new_data,
    v_user_id
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION fn_audit_trigger() IS
  'AFTER INSERT/UPDATE/DELETE row-level trigger that emits audit_log entries via fn_audit_log_record_v2 (M10 128 hash chain). Redacts 43 sensitive field names from old_values + new_values per project pattern. S2-20 v_actor=0 → NULL sentinel preserved. 41-name baseline (CR-D/CR-E 157) + 2 net-new (CR-F 173): contributing_correlations, explanation.';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (173, '173_crf_extend_fn_audit_trigger_redact_43', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 173;
-- [Restore fn_audit_trigger() to migration 157 body — 41 redact entries without the 2 CR-F entries]
-- See migration 157_crd_cre_extend_audit_redact_list.sql for the verbatim rollback body.
-- ============================================================
