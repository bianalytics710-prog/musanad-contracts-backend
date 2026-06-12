-- MIGRATION: 635_action_invocation_log.sql
-- Date: 2026-06-12
-- Module: AI Chat Actions
-- Description:
--   Append-only audit log for the AI Chat Orchestrator. One row per
--   action proposal AND one update per proposal lifecycle event
--   (executed / rejected / expired / failed). Outcomes flow through:
--
--     proposed → executed   (user clicked Confirm, handler succeeded)
--     proposed → rejected   (user clicked Cancel or explicitly rejected)
--     proposed → expired    (10-min TTL hit without confirm)
--     proposed → failed     (user confirmed but handler errored)
--
--   The proposalId (UUID generated at propose time) is the idempotency
--   key: re-confirming the same proposalId always returns the original
--   receipt (or the explicit failure).
--
--   Also extends fn_audit_trigger redact list with params_json and
--   receipt_json so the audit_log mirror never echoes back free-text
--   instruction notes, prospect names, or other sensitive payload.

BEGIN;

-- 1. Table -------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.action_invocation_log (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID         NOT NULL REFERENCES public.tenant(id) ON DELETE RESTRICT,
  request_id      UUID         NOT NULL UNIQUE,
  user_id         BIGINT       NOT NULL REFERENCES public."user"(id),
  action_code     TEXT         NOT NULL REFERENCES public.action_registry(code),

  -- The args the LLM filled in. Redacted by fn_audit_trigger when mirrored
  -- to audit_log so free-text bodies never reach the secondary table.
  params_json     JSONB        NOT NULL,

  -- Lifecycle timestamps. proposed_at is set at insert; the others are
  -- patched in place by the lifecycle helpers below.
  proposed_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  confirmed_at    TIMESTAMPTZ,
  executed_at     TIMESTAMPTZ,

  outcome         TEXT         NOT NULL DEFAULT 'proposed'
                    CHECK (outcome IN ('proposed','executed','rejected','expired','failed')),

  receipt_json    JSONB,
  error_text      TEXT,
  latency_ms      INTEGER,

  -- Soft-link to the chat conversation context so /admin/ai-actions can
  -- show "proposed by Hala on 2026-06-12 from prompt #abc".
  context_payload JSONB        NOT NULL DEFAULT '{}'::jsonb,

  created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  public.action_invocation_log IS
  'Append-only audit log for AI Chat Orchestrator action proposals + executions. Idempotency key = request_id.';
COMMENT ON COLUMN public.action_invocation_log.request_id IS
  'Server-issued UUID. The FE echoes this back on /ai/chat/execute so the BE can re-find the proposal idempotently.';
COMMENT ON COLUMN public.action_invocation_log.params_json IS
  'LLM-supplied tool args. Redacted in audit_log mirror. Read at execute time to call the handler.';
COMMENT ON COLUMN public.action_invocation_log.outcome IS
  'Lifecycle state. proposed → {executed, rejected, expired, failed}. Terminal once non-proposed.';
COMMENT ON COLUMN public.action_invocation_log.receipt_json IS
  'Handler return value on outcome=executed (shape depends on action). Redacted in audit_log mirror.';
COMMENT ON COLUMN public.action_invocation_log.error_text IS
  'Handler error message on outcome=failed. Not redacted — handlers must avoid embedding sensitive payload in their errors.';

CREATE INDEX IF NOT EXISTS idx_action_invocation_log_tenant_user
  ON public.action_invocation_log (tenant_id, user_id, proposed_at DESC);

CREATE INDEX IF NOT EXISTS idx_action_invocation_log_outcome
  ON public.action_invocation_log (tenant_id, outcome, proposed_at DESC);

CREATE INDEX IF NOT EXISTS idx_action_invocation_log_pending
  ON public.action_invocation_log (proposed_at)
  WHERE outcome = 'proposed';

ALTER TABLE public.action_invocation_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.action_invocation_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS action_invocation_log_tenant_isolation ON public.action_invocation_log;
CREATE POLICY action_invocation_log_tenant_isolation ON public.action_invocation_log
  FOR ALL USING (
    tenant_id IS NOT DISTINCT FROM NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

-- Append-only enforcement at the policy layer (block direct DELETE).
DROP POLICY IF EXISTS action_invocation_log_no_direct_delete ON public.action_invocation_log;
CREATE POLICY action_invocation_log_no_direct_delete ON public.action_invocation_log
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

DROP TRIGGER IF EXISTS audit_action_invocation_log_changes ON public.action_invocation_log;
CREATE TRIGGER audit_action_invocation_log_changes
  AFTER INSERT OR UPDATE ON public.action_invocation_log
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_trigger();

-- 2. fn_action_proposal_create -----------------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_proposal_create(
  p_request_id  UUID,
  p_action_code TEXT,
  p_params      JSONB,
  p_context     JSONB,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_id BIGINT;
  v_kind TEXT;
  v_enabled_by_default BOOLEAN;
  v_tenant_override BOOLEAN;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT a.kind, a.enabled_by_default
    INTO v_kind, v_enabled_by_default
  FROM public.action_registry a
  WHERE a.code = p_action_code AND a.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'actionCode:Action % not found', p_action_code USING ERRCODE = 'P0002';
  END IF;
  IF v_kind <> 'write_action' THEN
    RAISE EXCEPTION 'actionCode:Action % is not a write_action — only write_actions create proposals', p_action_code
      USING ERRCODE = '22023';
  END IF;

  SELECT s.is_enabled INTO v_tenant_override
    FROM public.tenant_action_setting s
   WHERE s.tenant_id = v_tenant_id AND s.action_code = p_action_code AND s.is_active = TRUE;

  IF NOT COALESCE(v_tenant_override, v_enabled_by_default) THEN
    RAISE EXCEPTION 'actionCode:Action % is disabled for this tenant', p_action_code USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.action_invocation_log
    (tenant_id, request_id, user_id, action_code, params_json, context_payload)
  VALUES
    (v_tenant_id, p_request_id, p_actor_id, p_action_code, p_params, COALESCE(p_context, '{}'::jsonb))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'requestId', p_request_id,
    'actionCode', p_action_code,
    'outcome', 'proposed'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_proposal_create(UUID, TEXT, JSONB, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_proposal_create(UUID, TEXT, JSONB, JSONB, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_action_proposal_create(UUID, TEXT, JSONB, JSONB, BIGINT) IS
  'Inserts a chat-action proposal row. Re-checks tenant_action_setting + action kind. Idempotent on request_id (UNIQUE).';

-- 3. fn_action_proposal_mark_executed ----------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_proposal_mark_executed(
  p_request_id  UUID,
  p_receipt     JSONB,
  p_latency_ms  INTEGER,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_existing_outcome TEXT;
  v_existing_receipt JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Read-modify-write under the tenant policy. Idempotency: if already
  -- executed we return the original receipt verbatim.
  SELECT outcome, receipt_json INTO v_existing_outcome, v_existing_receipt
    FROM public.action_invocation_log
   WHERE request_id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'requestId:Proposal % not found', p_request_id USING ERRCODE = 'P0002';
  END IF;

  IF v_existing_outcome = 'executed' THEN
    RETURN jsonb_build_object(
      'requestId', p_request_id,
      'outcome', 'executed',
      'receipt', v_existing_receipt,
      'idempotent', TRUE
    );
  END IF;

  IF v_existing_outcome <> 'proposed' THEN
    RAISE EXCEPTION 'requestId:Proposal % is in terminal state %', p_request_id, v_existing_outcome
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.action_invocation_log
     SET confirmed_at = COALESCE(confirmed_at, CURRENT_TIMESTAMP),
         executed_at  = CURRENT_TIMESTAMP,
         outcome      = 'executed',
         receipt_json = p_receipt,
         latency_ms   = p_latency_ms,
         updated_at   = CURRENT_TIMESTAMP
   WHERE request_id = p_request_id;

  RETURN jsonb_build_object(
    'requestId', p_request_id,
    'outcome', 'executed',
    'receipt', p_receipt,
    'idempotent', FALSE
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_proposal_mark_executed(UUID, JSONB, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_proposal_mark_executed(UUID, JSONB, INTEGER, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_action_proposal_mark_executed(UUID, JSONB, INTEGER, BIGINT) IS
  'Marks a proposal as executed and stamps its receipt. Idempotent: re-call with the same request_id returns the original receipt.';

-- 4. fn_action_proposal_mark_rejected ----------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_proposal_mark_rejected(
  p_request_id  UUID,
  p_reason      TEXT,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_existing_outcome TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT outcome INTO v_existing_outcome
    FROM public.action_invocation_log
   WHERE request_id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'requestId:Proposal % not found', p_request_id USING ERRCODE = 'P0002';
  END IF;

  IF v_existing_outcome = 'rejected' THEN
    RETURN jsonb_build_object('requestId', p_request_id, 'outcome', 'rejected', 'idempotent', TRUE);
  END IF;

  IF v_existing_outcome <> 'proposed' THEN
    RAISE EXCEPTION 'requestId:Proposal % is in terminal state %', p_request_id, v_existing_outcome
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.action_invocation_log
     SET outcome    = 'rejected',
         error_text = p_reason,
         updated_at = CURRENT_TIMESTAMP
   WHERE request_id = p_request_id;

  RETURN jsonb_build_object('requestId', p_request_id, 'outcome', 'rejected', 'idempotent', FALSE);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_proposal_mark_rejected(UUID, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_proposal_mark_rejected(UUID, TEXT, BIGINT) TO neondb_owner;

-- 5. fn_action_proposal_mark_failed ------------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_proposal_mark_failed(
  p_request_id  UUID,
  p_error       TEXT,
  p_latency_ms  INTEGER,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_existing_outcome TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT outcome INTO v_existing_outcome
    FROM public.action_invocation_log
   WHERE request_id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'requestId:Proposal % not found', p_request_id USING ERRCODE = 'P0002';
  END IF;

  IF v_existing_outcome <> 'proposed' THEN
    RAISE EXCEPTION 'requestId:Proposal % is in terminal state %', p_request_id, v_existing_outcome
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.action_invocation_log
     SET outcome      = 'failed',
         error_text   = p_error,
         confirmed_at = COALESCE(confirmed_at, CURRENT_TIMESTAMP),
         executed_at  = CURRENT_TIMESTAMP,
         latency_ms   = p_latency_ms,
         updated_at   = CURRENT_TIMESTAMP
   WHERE request_id = p_request_id;

  RETURN jsonb_build_object('requestId', p_request_id, 'outcome', 'failed');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_proposal_mark_failed(UUID, TEXT, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_proposal_mark_failed(UUID, TEXT, INTEGER, BIGINT) TO neondb_owner;

-- 6. fn_action_proposal_get_pending ------------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_proposal_get_pending(
  p_request_id  UUID,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_row public.action_invocation_log%ROWTYPE;
  v_age_seconds INTEGER;
  v_ttl_seconds CONSTANT INTEGER := 600; -- 10 min
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
    FROM public.action_invocation_log
   WHERE request_id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'requestId:Proposal % not found', p_request_id USING ERRCODE = 'P0002';
  END IF;

  -- Caller must own the proposal — no executing someone else's pending action.
  IF v_row.user_id <> p_actor_id THEN
    RAISE EXCEPTION 'requestId:Proposal % does not belong to caller', p_request_id USING ERRCODE = '42501';
  END IF;

  -- Already-executed → return the receipt for idempotent replay.
  IF v_row.outcome = 'executed' THEN
    RETURN jsonb_build_object(
      'requestId', v_row.request_id,
      'actionCode', v_row.action_code,
      'outcome', 'executed',
      'receipt', v_row.receipt_json,
      'params', v_row.params_json
    );
  END IF;

  IF v_row.outcome <> 'proposed' THEN
    RAISE EXCEPTION 'requestId:Proposal % is in terminal state %', p_request_id, v_row.outcome
      USING ERRCODE = '22023';
  END IF;

  v_age_seconds := EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - v_row.proposed_at))::INTEGER;
  IF v_age_seconds > v_ttl_seconds THEN
    -- Expire in-line so the caller sees a consistent 'expired' state.
    UPDATE public.action_invocation_log
       SET outcome = 'expired',
           updated_at = CURRENT_TIMESTAMP
     WHERE request_id = p_request_id;
    RAISE EXCEPTION 'requestId:Proposal % expired (TTL %s)', p_request_id, v_ttl_seconds USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'requestId', v_row.request_id,
    'actionCode', v_row.action_code,
    'outcome', 'proposed',
    'params', v_row.params_json,
    'ageSeconds', v_age_seconds
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_proposal_get_pending(UUID, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_proposal_get_pending(UUID, BIGINT) TO neondb_owner;

-- 7. Extend fn_audit_trigger redact list -------------------------------
--
-- Add `params_json`, `receipt_json` and `context_payload` so the audit_log
-- mirror never echoes back instruction notes, prospect names, or receipt
-- contents.

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
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);
  RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMENT ON FUNCTION public.fn_audit_trigger() IS
  'Generic audit trigger. Mig 635: redact list +2 (params_json, receipt_json) for action_invocation_log + action_registry mirroring.';

COMMIT;
