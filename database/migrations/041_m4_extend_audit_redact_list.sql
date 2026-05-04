-- ============================================================================
-- 041_m4_extend_audit_redact_list.sql
-- ============================================================================
-- Module:    M4 (AI Features)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   034_m3_extend_audit_redact_list.sql (canonical 25-name list).
-- ----------------------------------------------------------------------------
-- DN-7 / Q-Recommend-YES: extend the fn_audit_trigger redact list with 2
-- net-new M4 sensitive-field names. Body byte-for-byte identical to canonical
-- M3 034 EXCEPT the v_redact_fields literal array.
--
-- Net-new M4 names (2):
--   payload         — ai_insight column (AI output may contain contract excerpts)
--   error_message   — ai_request_log column (provider error strings may echo
--                     prompt fragments)
--
-- ai_prompt_payload is NOT added here — already present in M0 baseline list.
-- ai_insight + ai_request_log already pino-redacted at controller; this is
-- defence-in-depth.
--
-- Final list = 27 names.
--
-- S2-19 fidelity: body verbatim against 034_m3_extend_audit_redact_list.sql
-- lines 28-76. Only the array literal changes. SECURITY DEFINER + search_path
-- + jsonb_set redaction loop + GUC fallback + INSERT INTO audit_log preserved.
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
    'body_en','body_ar',
    -- M2 additions (AE-Sensitive — approval_decision.decision_note, approval_chain.matrix_snapshot)
    'decision_note','matrix_snapshot',
    -- M3 additions (DN-4 — 4 net-new; signer_email/signer_phone/signature_image already above)
    'invitation_token_hash','session_token_hash','signature_data','signature_image_url',
    -- M4 additions (DN-7 — 2 net-new; ai_prompt_payload already above)
    'payload','error_message'
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

COMMENT ON FUNCTION fn_audit_trigger() IS
  'Generic audit trigger. Logs INSERT/UPDATE/DELETE to audit_log. M4 (041): redact list extended to 27 names (M0 17 + M1a body_en/body_ar + M2 decision_note/matrix_snapshot + M3 invitation_token_hash/session_token_hash/signature_data/signature_image_url + M4 payload/error_message).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (41, 'm4_extend_audit_redact_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
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
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body',
    'body_en','body_ar',
    'decision_note','matrix_snapshot',
    'invitation_token_hash','session_token_hash','signature_data','signature_image_url'
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
DELETE FROM schema_migrations WHERE version = 41;
COMMIT;
-- ROLLBACK END
