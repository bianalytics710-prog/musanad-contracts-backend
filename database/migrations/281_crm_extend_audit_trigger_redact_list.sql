-- Migration: 281_crm_extend_audit_trigger_redact_list.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: Extend fn_audit_trigger v_redact_fields 58→60 by adding:
--              'penalty_basis'   (internal penalty derivation trace — keep audit_log lean)
--              'remediation_note' (free-text; may contain counterparty-sensitive remediation detail)
--              Re-applies COMMENT ON + REVOKE/GRANT on fn_audit_trigger (B14).
--              Must run BEFORE migrations 282-284 so the extended redact list
--              is active from the first INSERT on the new tables.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_audit_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_user_id  BIGINT;
  v_field    TEXT;
  v_redact_fields TEXT[] := ARRAY[
    -- M0-M13 baseline
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body',
    'body_en','body_ar',
    'decision_note','matrix_snapshot',
    'invitation_token_hash','session_token_hash','signature_data','signature_image_url',
    'payload','error_message',
    'credential_ref','raw_payload','last_error_message',
    'aliases','metadata',
    'tesseract_text','final_text','ingestion_error','extracted_text_uri',
    'parameters','text_excerpts','match_evidence','match_entities',
    'contributing_correlations','explanation',
    -- M16/CR-H additions (mig 209) — 13 fields
    'generated_text_en','generated_text_ar','final_text_en','final_text_ar',
    'modified_text_en','modified_text_ar',
    'template_context','rejection_reason',
    'rendered_payload',
    'body_rendered','subject','context_payload',
    'recipient_address',
    -- Unit 7 (mig 251) — CR-K + CR-L additions: +3 net-new fields
    -- (payload + parameters + error_message already present in baseline)
    'body','file_uri','output_uri',
    -- CR-M (mig 281) additions: 58 → 60
    'penalty_basis',       -- internal penalty derivation; redact to keep audit_log lean
    'remediation_note'     -- free-text; may contain counterparty-sensitive remediation detail
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
  IF v_user_id = 0 THEN v_user_id := NULL; END IF;
  PERFORM fn_audit_log_record_v2(TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id);
  RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMENT ON FUNCTION fn_audit_trigger() IS
  'Universal row-level audit trigger. Redacts 60 sensitive fields before writing to audit_log via fn_audit_log_record_v2. CR-M (281) extended from 58 to 60 (+penalty_basis, +remediation_note).';

REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (281, '281_crm_extend_audit_trigger_redact_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 281;
-- -- Restore prior fn_audit_trigger body (58-field list — see migration 280 or 251 body).
-- -- Remove the two CR-M lines: 'penalty_basis', 'remediation_note'
-- COMMIT;
-- ============================================================
