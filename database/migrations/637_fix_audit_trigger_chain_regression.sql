-- Migration: 637_fix_audit_trigger_chain_regression.sql
-- Module: AI Chat Actions — emergency fix
-- Date: 2026-06-12
--
-- Mig 635 rewrote fn_audit_trigger to add params_json + receipt_json to the
-- redact list, but used mig 470's stale body as the diff source instead of
-- mig 472. Mig 472 had restored the M10/CR-C hash-chain routing via
-- fn_audit_log_record_v2 — my rewrite reverted it back to a direct
-- INSERT that lacks prev_hash, breaking EVERY audited write
-- (including login → audit_log of user_session).
--
-- This is the EXACT same regression mig 472 fixed for mig 470. Captured in
-- memory feedback_fn_rewrites_lose_safety_guards.md — must always diff a
-- CREATE OR REPLACE against the IMMEDIATELY PREVIOUS body, not against any
-- predecessor.
--
-- This migration restores the hash-chain routing + keeps my mig 635 redact
-- additions (params_json, receipt_json).

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
    'oauth_scopes',
    -- AI Chat Actions (mig 635) — 2 net-new (context_payload already in CR-H)
    'params_json',
    'receipt_json'
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

  -- M10 / CR-C (mig 128) + M22 (mig 472): route through the hash-chain writer
  -- (NOT direct INSERT). mig 470 + mig 635 both regressed this — always diff
  -- against the IMMEDIATELY PREVIOUS body before rewriting.
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
$function$;

COMMENT ON FUNCTION public.fn_audit_trigger() IS
  'Mig 637 — restored hash-chain routing via fn_audit_log_record_v2 after mig 635 regression. Redact list 58 names (mig 635 added params_json + receipt_json for AI Chat Actions).';
