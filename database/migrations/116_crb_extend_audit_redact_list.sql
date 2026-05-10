-- Migration: 116_crb_extend_audit_redact_list.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: CREATE OR REPLACE fn_audit_trigger() — append `aliases` + `metadata` to v_redact_fields ARRAY.
--              Body otherwise byte-for-byte identical to 102's M7 version (preserves v_user_id=0 NULL coercion + 30-name M7 list).
--              Re-applies COMMENT + REVOKE/GRANT trio per feedback_fn_rewrites_lose_safety_guards.md.
-- Rollback: Restore prior body from migration 102.

BEGIN;

CREATE OR REPLACE FUNCTION fn_audit_trigger() RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_user_id  BIGINT;
  v_field    TEXT;
  v_redact_fields TEXT[] := ARRAY[
    -- M0 verbatim
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body',
    -- M1a
    'body_en','body_ar',
    -- M2
    'decision_note','matrix_snapshot',
    -- M3
    'invitation_token_hash','session_token_hash','signature_data','signature_image_url',
    -- M4
    'payload','error_message',
    -- M7
    'credential_ref','raw_payload','last_error_message',
    -- M9 (CR-B) — aliases (party) + metadata (party + party_relationship + raw bag)
    'aliases','metadata'
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
  IF v_user_id = 0 THEN v_user_id := NULL; END IF;  -- preserved from 102 (system actor sentinel)
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);
  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION fn_audit_trigger() IS
  'Generic audit trigger. M9 (116): redact list extended to 32 names — added aliases / metadata for party + party_relationship redaction. Preserves M7 102 v_user_id=0 NULL coercion (system actor sentinel).';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (116, 'crb_extend_audit_redact_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (restore from migration 102 body)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 116;
-- (Re-apply migration 102 to restore prior version of fn_audit_trigger.)
