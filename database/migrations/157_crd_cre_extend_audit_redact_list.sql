-- Migration: 157_crd_cre_extend_audit_redact_list.sql
-- Module: M12 / CR-D + M13 / CR-E — Cross-cutting
-- Description: CREATE OR REPLACE fn_audit_trigger() — body byte-for-byte identical to M11 migration 133
--   EXCEPT v_redact_fields extends 37 → 41 names (adds parameters, text_excerpts, match_evidence, match_entities).
--   S2-20 v_actor=0 → NULL sentinel preserved verbatim.
--   M10 CR-C 128 PERFORM fn_audit_log_record_v2(...) chain extension call preserved verbatim.
--   REVOKE FROM PUBLIC + GRANT TO neondb_owner trio re-applied (S2-21 / B14).
--
-- WARN-2 COMPLIANCE (Stage 2 check): Redact list narrowed from design candidate of 10 to 4 new entries.
--   Narrowing rationale documented below.
--   Candidates considered but NOT added:
--   - 'match_yaml' / 'produce_yaml': stored on correlation_rule (SENSITIVE per design). HOWEVER,
--     these columns are only on correlation_rule, which already has FORCE RLS restricting reads
--     to the owning tenant. Redacting them from audit_log would prevent audit trail of rule body
--     changes — not justified. Admin who can edit rules can see rule bodies in audit. KEPT CLEAR.
--   - 'diagnostics' (correlation_evaluation_error): non-sensitive structural JSONB (signal IDs,
--     predicate names). No PII. KEPT CLEAR.
--   - 'given_signal' (correlation_rule_fixture): synthetic test data. No production PII. KEPT CLEAR.
--   - 'expected_correlation': synthetic test data. KEPT CLEAR.
--   - 'version_hash': non-sensitive SHA-256 hash. KEPT CLEAR.
--   - 'meta' (correlation_rule): contains owner + rationale strings, no PII. KEPT CLEAR.
--   Net-new sensitive fields that DO warrant redaction:
--   + 'parameters': contract_clause_extracted.parameters — real extracted contract content (proprietary)
--   + 'text_excerpts': contract_clause_extracted.text_excerpts — verbatim contract source-text (highly proprietary)
--   + 'match_evidence': correlation.match_evidence — SDN entry UIDs, counterparty IDs (sanctions-sensitive)
--   + 'match_entities': correlation.match_entities — sanctioned entity names + designations (PII/sanctions-sensitive)
--   False-positive risk: 'parameters' is a generic name. Verified: clause_taxonomy.parameter_schema ≠ 'parameters'
--   (column name is parameter_schema). ai_prompt has no 'parameters' column. Safe — only contract_clause_extracted
--   carries the sensitive 'parameters' field in this schema.
--
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_audit_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
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
    -- CR-D0 (M11 / 133) — 5 net-new (F-S2-9 patch: 32 → 37)
    'tesseract_text','gpt4o_text','final_text','ingestion_error','extracted_text_uri',
    -- CR-D + CR-E (this migration 157) — 4 net-new (37 → 41)
    'parameters',     -- CR-D contract_clause_extracted.parameters (extracted contract content — proprietary)
    'text_excerpts',  -- CR-D contract_clause_extracted.text_excerpts (verbatim source-text — highly proprietary)
    'match_evidence', -- CR-E correlation.match_evidence (signal raw_payload refs, SDN UIDs, counterparty IDs)
    'match_entities'  -- CR-E correlation.match_entities (sanctioned entity names + designations — PII/sanctions-sensitive)
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
  'AFTER INSERT/UPDATE/DELETE row-level trigger that emits audit_log entries via fn_audit_log_record_v2 (M10 128 hash chain). Redacts 41 sensitive field names from old_values + new_values per project pattern. S2-20 v_actor=0 → NULL sentinel preserved. 37-name baseline (M11 133) + 4 net-new (CR-D/CR-E 157): parameters, text_excerpts, match_evidence, match_entities.';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (157, '157_crd_cre_extend_audit_redact_list', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- Run after rolling back 141..156 to restore M11 migration 133 body)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 157;
-- [Restore fn_audit_trigger() to M11 migration 133 body — 37 redact entries without the 4 CR-D/CR-E entries]
-- ============================================================
