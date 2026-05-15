-- Migration: 251_unit7_extend_audit_trigger_redact_list.sql
-- Module: M19+M20 — Unit 7 (CR-K Risk Cases + CR-L Reports & Briefings)
-- CR: CR-K + CR-L
-- Date: 2026-05-15
-- Description: EXTEND fn_audit_trigger redact list (current baseline 55 → 58)
--              with +3 net-new CR-K/CR-L sensitive fields. Per design §5.1,
--              `payload`, `parameters`, `error_message` are already present in
--              the baseline (verified at apply time), so only 3 names are
--              actually new: body, file_uri, output_uri.
--              Also extends fn_audit_log_canonicalize via no-op (it uses the
--              same redact rule set indirectly — kept as a documentation anchor
--              for hash-chain reproducibility per mig 209 pattern).
-- ADAPTATION NOTE (DEFECT-CRKL-DB-A5): Design said baseline=56, actual=55.
--              Cosmetic narrative mismatch; not blocking.

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
    'body','file_uri','output_uri'
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
  'Shared row-level audit trigger. Redacts 58 sensitive fields (Unit 7 extended from M16/55 with body, file_uri, output_uri). Calls fn_audit_log_record_v2 to maintain hash-chain audit_log.';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (251, '251_unit7_extend_audit_trigger_redact_list', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Re-apply migration 209 fn_audit_trigger body (55-element baseline).
-- DELETE FROM schema_migrations WHERE version = 251;
-- ============================================================
