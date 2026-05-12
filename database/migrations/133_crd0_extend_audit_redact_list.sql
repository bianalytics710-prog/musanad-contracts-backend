-- ============================================================
-- Migration 133 — CRD0 extend_audit_redact_list
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: CREATE OR REPLACE fn_audit_trigger() extending v_redact_fields
--              ARRAY from 32 → 37 names (+5 CR-D0 entries per F-S2-9 patch):
--                tesseract_text, gpt4o_text, final_text, ingestion_error,
--                extracted_text_uri.
--              Body byte-for-byte identical to CR-C 128 EXCEPT the redact ARRAY
--              literal AND the COMMENT version bump.
--              Preserves:
--                - M7 102 v_user_id=0 → NULL coercion (S2-20)
--                - CR-C 128 PERFORM fn_audit_log_record_v2 hash-chain routing
--              Re-applies COMMENT + REVOKE/GRANT trio per A4 / B14 /
--              feedback_fn_rewrites_lose_safety_guards.md.
-- SOT: §16 audit immutability, A3 / A4 / A9 / N19.
-- Patch note (F-S2-9): 5 net-new entries (32 → 37), not 4 (32 → 36) as some
--              earlier docs stated. extracted_text_uri is the 5th entry
--              (confirmed by M11_SENSITIVE_FIELD_EXTENSIONS in types.ts §13).
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
    -- CR-D0 (M11 / 133) — 5 net-new redact entries (F-S2-9 patch: 32 → 37)
    'tesseract_text','gpt4o_text','final_text','ingestion_error','extracted_text_uri'
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
  'Generic audit trigger. CR-D0 (M11 / 133): redact list extended to 37 names (5 net-new per F-S2-9 patch) — added tesseract_text / gpt4o_text / final_text / ingestion_error / extracted_text_uri for ingestion_review_queue + contract_version sensitive content. Preserves CR-C 128 PERFORM fn_audit_log_record_v2 hash-chain routing AND M7 102 v_user_id=0 → NULL coercion (S2-20). Trio re-applied per A4/B14.';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (133, 'crd0_extend_audit_redact_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- Restore body from migration 128 (CR-C audit_chain_extend) manually.
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 133;
-- COMMIT;
-- ROLLBACK END
