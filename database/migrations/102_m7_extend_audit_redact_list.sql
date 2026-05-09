-- Migration: 102_m7_extend_audit_redact_list.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: CREATE OR REPLACE fn_audit_trigger — append `credential_ref`, `raw_payload`,
--              `last_error_message` to v_redact_fields ARRAY. Body otherwise byte-for-byte
--              identical to 041's M4 version, plus the v_user_id=0 → NULL coercion (CC4 / S2-20).
--              Re-applies REVOKE FROM PUBLIC + GRANT TO neondb_owner trio per Stage 2 patch +
--              feedback_fn_rewrites_lose_safety_guards.md.
-- Rollback: Restore 041's M4-extended array (without credential_ref / raw_payload / last_error_message).
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

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
    -- M0 names (verbatim from 002_security_hardening.sql, preserved order)
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body',
    -- M1a additions (W2)
    'body_en','body_ar',
    -- M2 additions (AE-Sensitive)
    'decision_note','matrix_snapshot',
    -- M3 additions (DN-4)
    'invitation_token_hash','session_token_hash','signature_data','signature_image_url',
    -- M4 additions (DN-7)
    'payload','error_message',
    -- M7 (AE1) — credential ref + raw payload + last_error_message
    'credential_ref','raw_payload','last_error_message'
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
  -- S2-20 / CC4: actor=0 sentinel coercion (cron-driven inserts use SYSTEM_ACTOR_ID=0)
  IF v_user_id = 0 THEN v_user_id := NULL; END IF;
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);
  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION fn_audit_trigger() IS
  'Generic audit trigger. M7 (102): redact list extended to 30 names — added credential_ref / raw_payload / last_error_message; v_user_id=0 sentinel coerced to NULL for cron-driven inserts (CC4 / S2-20).';

-- Stage 2 patch — CREATE OR REPLACE drops EXECUTE grants per feedback_fn_rewrites_lose_safety_guards.md.
-- Re-apply explicit REVOKE FROM PUBLIC + GRANT TO neondb_owner.
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (102, 'm7_extend_audit_redact_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- Restore 041's body — drop credential_ref / raw_payload / last_error_message from v_redact_fields,
-- and remove the v_user_id=0 NULL coercion.
-- DELETE FROM schema_migrations WHERE version = 102;
-- ============================================================
