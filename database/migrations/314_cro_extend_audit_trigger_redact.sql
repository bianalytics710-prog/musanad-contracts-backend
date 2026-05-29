-- Migration: 314_cro_extend_audit_trigger_redact.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: Extend fn_audit_trigger v_redact_fields 60 → 61 by adding:
--              'breakdown'  — margin_snapshot.breakdown JSONB (commercially sensitive per-bbl cost waterfall)
--              Base body from mig 281 (CR-M, 60-field list) — byte-aware diff.
--              Re-applies COMMENT ON + REVOKE/GRANT on fn_audit_trigger (B14/S2-21).
--
--   BYTE-AWARE DIFF vs mig 281 (60 fields):
--   ✓ Preserved: all 60 fields from mig 281 verbatim (M0-M16 + CR-B + CR-D0 + CR-D/CR-E + CR-F + CR-H + Unit7 + CR-M)
--   ✓ RETURNS TRIGGER / LANGUAGE plpgsql / SECURITY DEFINER
--   ✓ DECLARE: v_old_data JSONB, v_new_data JSONB, v_user_id BIGINT, v_field TEXT, v_redact_fields TEXT[]
--   ✓ BEGIN/LOOP/PERFORM fn_audit_log_record_v2 / RETURN COALESCE(NEW,OLD) all preserved
--   ✓ S2-20 sentinel: v_user_id := NULLIF(...) / IF v_user_id = 0 THEN v_user_id := NULL preserved
--   NET NEW: 'breakdown' — margin_snapshot column (per-bbl cost waterfall). False-positive check:
--     No other table in the schema has a 'breakdown' column. Safe to add. DB Impl verified.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_audit_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    -- CR-D0 (mig 133) — 5 net-new
    'tesseract_text','final_text','ingestion_error','extracted_text_uri',
    -- CR-D + CR-E (mig 157) — 4 net-new
    'parameters','text_excerpts','match_evidence','match_entities',
    -- CR-F (mig 173) — 2 net-new
    'contributing_correlations','explanation',
    -- CR-H (mig 209) — 13 net-new
    'generated_text_en','generated_text_ar','final_text_en','final_text_ar',
    'modified_text_en','modified_text_ar',
    'template_context','rejection_reason',
    'rendered_payload',
    'body_rendered','subject','context_payload',
    'recipient_address',
    -- Unit 7 (mig 251) — 3 net-new
    'body','file_uri','output_uri',
    -- CR-M (mig 281) — 2 net-new (58 → 60)
    'penalty_basis','remediation_note',
    -- ===== CR-O (mig 314) — 1 net-new (60 → 61) =====
    'breakdown'   -- margin_snapshot.breakdown: commercially sensitive per-bbl cost waterfall. No other table uses this column name (false-positive-safe).
    -- ===== end CR-O additive block =====
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
  PERFORM fn_audit_log_record_v2(TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id);
  RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMENT ON FUNCTION fn_audit_trigger() IS
  'Universal row-level audit trigger. Redacts 61 sensitive fields before writing to audit_log via fn_audit_log_record_v2. CR-O (314) extended from 60 to 61 (+breakdown = margin_snapshot commercially sensitive per-bbl cost waterfall).';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (314, '314_cro_extend_audit_trigger_redact', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 314;
-- -- Restore fn_audit_trigger() to migration 281 body (60-field list — remove 'breakdown' line).
-- COMMIT;
-- ============================================================
