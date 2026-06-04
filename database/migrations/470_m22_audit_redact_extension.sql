-- Migration: 470_m22_audit_redact_extension.sql
-- Module: M22 / CR-MIG-DRIVE — fn_audit_trigger redact list +3
-- Date: 2026-06-02
--
-- Add 3 net-new field names to the audit redact list so token blobs and
-- scope arrays on external_connection are never written to audit_log:
--   - oauth_access_token_encrypted
--   - oauth_refresh_token_encrypted
--   - oauth_scopes
--
-- error_message is ALREADY in the list (M4 mig 041) and covers
-- external_connection.error_message + migration_batch error fields.
-- raw_payload (M7) + metadata (M9) already cover JSONB blobs that may
-- echo OAuth state, etc.
--
-- This rewrites the full function body to keep all prior additions
-- intact (M0/M1a/M2/M3/M4/M7/M9/CR-D0/CR-D/CR-E/CR-F/CR-H/Unit7/CR-M/CR-O).

CREATE OR REPLACE FUNCTION public.fn_audit_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_user_id  BIGINT;
  v_field    TEXT;
  v_redact_fields TEXT[] := ARRAY[
    -- M0 verbatim (17)
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
    -- CR-D0 (mig 133) — 4 net-new
    'tesseract_text','final_text','ingestion_error','extracted_text_uri',
    -- CR-D + CR-E (mig 157) — 4 net-new
    'parameters','text_excerpts','match_evidence','match_entities',
    -- CR-F (mig 173) — 2 net-new
    'contributing_correlations','explanation',
    -- CR-H (mig 209) — 13 net-new
    'generated_text_en','generated_text_ar','final_text_en','final_text_ar',
    'modified_text_en','modified_text_ar',
    'template_context','rejection_reason','rendered_payload',
    'body_rendered','subject','context_payload','recipient_address',
    -- Unit 7 (mig 251) — 3 net-new
    'body','file_uri','output_uri',
    -- CR-M (mig 281) — 2 net-new
    'penalty_basis','remediation_note',
    -- CR-O (mig 314) — 1 net-new
    'breakdown',
    -- M22 / CR-MIG-DRIVE (mig 470) — 3 net-new
    'oauth_access_token_encrypted',
    'oauth_refresh_token_encrypted',
    'oauth_scopes'
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
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);
  RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMENT ON FUNCTION public.fn_audit_trigger() IS
  'Generic audit trigger. M22 (470): redact list +3 (oauth_access_token_encrypted, oauth_refresh_token_encrypted, oauth_scopes).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (470, '470_m22_audit_redact_extension', CURRENT_TIMESTAMP);
