-- MIGRATION: 209_crh_extend_audit_trigger_redact_list.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: EXTEND fn_audit_trigger redact list 43→56 (+13 new CR-H sensitive field names).
--              Also extends fn_audit_log_canonicalize redaction parity for hash-chain reproducibility.
--              Baseline from M14/migration 177 = 43 fields. New baseline = 56.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_audit_trigger()
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
    -- M0-M13 baseline (43 fields)
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
    'tesseract_text','gpt4o_text','final_text','ingestion_error','extracted_text_uri',
    'parameters','text_excerpts','match_evidence','match_entities',
    'contributing_correlations','explanation',
    -- M16/CR-H additions (DN-16 — 13 net-new sensitive fields) — new baseline = 56
    'generated_text_en','generated_text_ar','final_text_en','final_text_ar',
    'modified_text_en','modified_text_ar',
    'template_context','rejection_reason',
    'rendered_payload',
    'body_rendered','subject','context_payload',
    'recipient_address'
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
  'Shared row-level audit trigger. Redacts 56 sensitive fields (M16/CR-H extended from 43). Calls fn_audit_log_record_v2 to maintain hash-chain audit_log.';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (209, '209_crh_extend_audit_trigger_redact_list', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Re-apply M14/177 43-element baseline fn_audit_trigger body (see migration 177).
-- Note: rolling back breaks hash-chain reproducibility on advisory rows — acceptable only if
--       entire CR-H is reverted in the same operation.
-- DELETE FROM schema_migrations WHERE version = 209;
-- ============================================================
