-- ============================================================================
-- 004_m1a_extend_sensitive_fields.sql — Append body_en/body_ar to redact array
-- ============================================================================
-- Module:   M1a (Contracts: Core CRUD & Lifecycle)
-- Owner:    Agent 4 — DB Architect
-- Depends:  001_foundation.sql, 002_security_hardening.sql, 003_m1a_contracts.sql
-- ----------------------------------------------------------------------------
-- W2 — Extends fn_audit_trigger redact array with body_en/body_ar so audit_log
-- never records raw contract body text on contract or contract_version
-- INSERT/UPDATE. Backward-compatible: M0's 17 names preserved verbatim, only
-- 2 new names appended.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_audit_trigger() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
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
    -- M1a additions (W2 — physical column names of contract.body_en / contract.body_ar / contract_version.body_en / contract_version.body_ar)
    'body_en','body_ar'
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
$$;

COMMENT ON FUNCTION fn_audit_trigger() IS 'Generic audit trigger. Logs INSERT/UPDATE/DELETE to audit_log. Redacts 19 sensitive field names project-wide before insertion (M0 17 + M1a body_en/body_ar).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (4, 'm1a_extend_sensitive_fields', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 004_m1a_extend_sensitive_fields.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  -- Restore the M0 17-name redact array (verbatim from 002_security_hardening.sql)
  CREATE OR REPLACE FUNCTION fn_audit_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
  AS $$
  DECLARE
    v_old_data JSONB;
    v_new_data JSONB;
    v_user_id  BIGINT;
    v_field    TEXT;
    v_redact_fields TEXT[] := ARRAY[
      'password_hash','password','token_hash','refresh_token','access_token',
      'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
      'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
      'signer_email','signer_phone','ai_prompt_payload','contract_body'
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
  $$;
  DELETE FROM schema_migrations WHERE version = 4;
COMMIT;
-- ROLLBACK END
