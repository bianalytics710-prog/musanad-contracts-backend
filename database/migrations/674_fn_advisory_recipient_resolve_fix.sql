-- Migration 674 — drop contract.tenant_id reference in fn_advisory_recipient_resolve.
-- Same root cause as mig 672: contract has no tenant_id column; RLS isolates by role.
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_advisory_recipient_resolve(
  p_actor_id    BIGINT,
  p_contract_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id      UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_party_name     TEXT;
  v_party_email    TEXT;
  v_signer_email   TEXT;
  v_signer_name    TEXT;
  v_email          TEXT;
  v_name           TEXT;
  v_source         TEXT;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'contractId required' USING ERRCODE = '22023';
  END IF;

  -- mig 674 fix: drop "AND c.tenant_id = v_tenant_id" — contract has no
  -- tenant_id column; RLS (contract_select_role_aware) restricts visibility.
  SELECT p.name_en, p.contact_email
    INTO v_party_name, v_party_email
    FROM contract c
    LEFT JOIN party p ON p.id = c.counterparty_id
   WHERE c.id = p_contract_id;
  IF v_party_name IS NULL AND v_party_email IS NULL THEN
    RAISE EXCEPTION 'contract not found: %', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  SELECT sp.signer_email, sp.signer_name_en
    INTO v_signer_email, v_signer_name
    FROM signature_party sp
   WHERE sp.contract_id = p_contract_id
     AND sp.is_active   = TRUE
     AND sp.signer_email IS NOT NULL
   ORDER BY sp.step_order ASC
   LIMIT 1;

  IF v_party_email IS NOT NULL AND v_party_email <> '' THEN
    v_email := v_party_email; v_name := COALESCE(v_party_name, 'Counterparty contact'); v_source := 'party_contact';
  ELSIF v_signer_email IS NOT NULL AND v_signer_email <> '' THEN
    v_email := v_signer_email; v_name := COALESCE(v_signer_name, v_party_name, 'Signer'); v_source := 'signer';
  ELSE
    v_email := LOWER(REGEXP_REPLACE(COALESCE(v_party_name, 'counterparty'), '[^a-z0-9]+', '', 'gi')) || '@demo.local';
    v_name  := COALESCE(v_party_name, 'Counterparty contact'); v_source := 'demo_fallback';
  END IF;

  RETURN jsonb_build_object(
    'recipientAddress', v_email,
    'recipientName',    v_name,
    'source',           v_source,
    'counterpartyName', v_party_name
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (674, 'fn_advisory_recipient_resolve_fix', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
