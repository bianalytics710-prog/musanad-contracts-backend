-- ============================================================
-- Migration 128 — CRC audit_chain_extend
-- ============================================================
-- Module:      M10 — CR-C
-- Description: THE critical migration. Single TX. Adds hash chain to audit_log.
--
-- Order (per db-design.md §9; entire safety property):
--   (a) CREATE EXTENSION IF NOT EXISTS pgcrypto                    — required by digest()
--   (b) ALTER audit_log ADD prev_hash + this_hash NULL columns
--   (c) CREATE OR REPLACE fn_audit_log_canonicalize(JSONB)         — used by backfill (d)
--   (d) DO block: walk audit_log id ASC, compute each prev/this hash
--   (e) ALTER audit_log SET NOT NULL on both hash columns
--   (f) CREATE idx_audit_log_this_hash                             — verify drill-down
--   (g) CREATE OR REPLACE fn_audit_log_record_v2(...)              — chain writer
--   (h) CREATE OR REPLACE fn_audit_trigger() — body now PERFORMs v2 instead of direct INSERT
--                                              (re-applies trio per A4/B14)
--   (i) CREATE OR REPLACE fn_audit_log_record(...) — M1b shim → v2 (re-applies trio)
--   (j) CREATE OR REPLACE fn_audit_log_no_update_guard / fn_audit_log_no_delete_guard
--       + BEFORE UPDATE / DELETE triggers on audit_log
--
-- Decisions:
--   OPEN-DECISION-A — keep M0 audit_log column names; honor Annex D.7.1 at canonical level.
--   OPEN-DECISION-D — SELECT FOR UPDATE on prev row id (pessimistic lock).
--   OPEN-DECISION-G — single TX ordering; no bypass GUC.
--   S2-20          — v_actor=0 → NULL coercion preserved in v2 + fn_audit_trigger.
--   A4 / B14       — every CREATE OR REPLACE re-applies COMMENT + REVOKE/GRANT trio.
-- ============================================================

BEGIN;

-- (a) pgcrypto for sha256
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- (b) Add NULL columns
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS prev_hash TEXT;
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS this_hash TEXT;

-- (c) Canonicalize fn (used by both backfill and v2 + verify)
CREATE OR REPLACE FUNCTION fn_audit_log_canonicalize(p_payload JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $fn$
DECLARE
  v_type  TEXT;
  v_parts TEXT[];
BEGIN
  IF p_payload IS NULL THEN
    RETURN 'null';
  END IF;
  v_type := jsonb_typeof(p_payload);
  IF v_type = 'null' THEN
    RETURN 'null';
  ELSIF v_type = 'boolean' THEN
    RETURN CASE WHEN (p_payload)::TEXT = 'true' THEN 'true' ELSE 'false' END;
  ELSIF v_type = 'number' THEN
    RETURN (p_payload)::TEXT;
  ELSIF v_type = 'string' THEN
    -- JSONB ::TEXT for strings yields a JSON-quoted literal
    RETURN (p_payload)::TEXT;
  ELSIF v_type = 'array' THEN
    SELECT array_agg(fn_audit_log_canonicalize(elem) ORDER BY ord)
      INTO v_parts
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY arr(elem, ord);
    RETURN '[' || array_to_string(COALESCE(v_parts, ARRAY[]::TEXT[]), ',') || ']';
  ELSIF v_type = 'object' THEN
    SELECT array_agg(
             to_json(k)::TEXT || ':' || fn_audit_log_canonicalize(v)
             ORDER BY k
           )
      INTO v_parts
    FROM jsonb_each(p_payload) AS j(k, v);
    RETURN '{' || array_to_string(COALESCE(v_parts, ARRAY[]::TEXT[]), ',') || '}';
  END IF;
  RETURN 'null';
END;
$fn$;

COMMENT ON FUNCTION fn_audit_log_canonicalize(JSONB) IS
  'CR-C deterministic JSON serializer. IMMUTABLE PARALLEL SAFE. Mirrors BE audit-canonical.util.ts byte-for-byte. Keys sorted alphabetically at every depth; NULLs explicit; arrays preserve order. Used by fn_audit_log_record_v2 + fn_audit_chain_verify hash construction.';
REVOKE EXECUTE ON FUNCTION fn_audit_log_canonicalize(JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_log_canonicalize(JSONB) TO neondb_owner;

-- (d) Backfill — walk id ASC, compute prev/this for every row
DO $backfill$
DECLARE
  v_prev      TEXT := repeat('0', 64);
  v_canonical TEXT;
  v_this      TEXT;
  r           RECORD;
  v_count     INTEGER := 0;
BEGIN
  FOR r IN
    SELECT id, table_name, record_id, action, old_values, new_values, changed_by, changed_at
      FROM audit_log
     ORDER BY id ASC
  LOOP
    v_canonical := fn_audit_log_canonicalize(jsonb_build_object(
      'action',     r.action,
      'changedAt',  to_char(r.changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'changedBy',  r.changed_by,
      'newValues',  COALESCE(r.new_values, 'null'::jsonb),
      'oldValues',  COALESCE(r.old_values, 'null'::jsonb),
      'recordId',   r.record_id,
      'tableName',  r.table_name
    ));
    v_this := encode(digest(v_prev || v_canonical, 'sha256'), 'hex');
    UPDATE audit_log SET prev_hash = v_prev, this_hash = v_this WHERE id = r.id;
    v_prev  := v_this;
    v_count := v_count + 1;
  END LOOP;
  RAISE NOTICE 'audit chain backfill — rows hashed: %', v_count;
END;
$backfill$;

-- (e) Promote to NOT NULL after backfill
ALTER TABLE audit_log ALTER COLUMN prev_hash SET NOT NULL;
ALTER TABLE audit_log ALTER COLUMN this_hash SET NOT NULL;

-- (f) Index on this_hash for fn_audit_chain_verify drill-down
CREATE INDEX IF NOT EXISTS idx_audit_log_this_hash ON audit_log(this_hash);

COMMENT ON COLUMN audit_log.prev_hash IS
  'CR-C: SHA-256 hex of previous row''s this_hash. Genesis row = repeat(''0'', 64). Set by fn_audit_log_record_v2 only.';
COMMENT ON COLUMN audit_log.this_hash IS
  'CR-C: SHA-256 hex of (prev_hash || canonical_row_payload). Computed by fn_audit_log_record_v2 with SELECT FOR UPDATE on prev row.';

-- (g) fn_audit_log_record_v2 — chain writer (DEFINER bypasses RLS deny-direct-INSERT)
CREATE OR REPLACE FUNCTION fn_audit_log_record_v2(
  p_table_name TEXT,
  p_record_id  BIGINT,
  p_action     TEXT,
  p_old_values JSONB,
  p_new_values JSONB,
  p_changed_by BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_actor       BIGINT;
  v_prev_id     BIGINT;
  v_prev_hash   TEXT;
  v_this_hash   TEXT;
  v_id          BIGINT;
  v_now         TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_canonical   TEXT;
BEGIN
  IF p_action NOT IN ('INSERT','UPDATE','DELETE') THEN
    RAISE EXCEPTION 'fn_audit_log_record_v2: invalid_action_value' USING ERRCODE = '22023';
  END IF;

  v_actor := COALESCE(
    p_changed_by,
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );
  IF v_actor = 0 THEN v_actor := NULL; END IF;  -- S2-20 system actor sentinel

  -- OPEN-DECISION-D: pessimistic concurrency lock on prev row.
  -- Throughput ceiling acceptable for demo+pilot load (largest single emit ~10 rows; A18).
  SELECT id, this_hash
    INTO v_prev_id, v_prev_hash
    FROM audit_log
   ORDER BY id DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    v_prev_hash := repeat('0', 64);   -- genesis row
  ELSIF v_prev_hash IS NULL THEN
    -- Defensive: post-backfill no row should have NULL hash
    RAISE EXCEPTION 'fn_audit_log_record_v2: audit_chain_integrity_violation at prev id %', v_prev_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Canonical payload built deterministically from input + computed timestamp
  v_canonical := fn_audit_log_canonicalize(jsonb_build_object(
    'action',     p_action,
    'changedAt',  to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'changedBy',  v_actor,
    'newValues',  COALESCE(p_new_values, 'null'::jsonb),
    'oldValues',  COALESCE(p_old_values, 'null'::jsonb),
    'recordId',   p_record_id,
    'tableName',  p_table_name
  ));
  v_this_hash := encode(digest(v_prev_hash || v_canonical, 'sha256'), 'hex');

  INSERT INTO audit_log (
    table_name, record_id, action, old_values, new_values,
    changed_by, changed_at, prev_hash, this_hash
  ) VALUES (
    p_table_name, p_record_id, p_action, p_old_values, p_new_values,
    v_actor, v_now, v_prev_hash, v_this_hash
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id',       v_id,
    'prevHash', v_prev_hash,
    'thisHash', v_this_hash
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_audit_log_record_v2: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_audit_log_record_v2(TEXT, BIGINT, TEXT, JSONB, JSONB, BIGINT) IS
  'CR-C single source of truth for audit_log writes. Computes hash chain with FOR UPDATE on prev row. Genesis prev_hash = ''0''x64. SECURITY DEFINER bypasses audit_log RLS deny-direct-INSERT. Canonical payload via fn_audit_log_canonicalize. v_actor=0 → NULL coercion (S2-20).';
REVOKE EXECUTE ON FUNCTION fn_audit_log_record_v2(TEXT, BIGINT, TEXT, JSONB, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_log_record_v2(TEXT, BIGINT, TEXT, JSONB, JSONB, BIGINT) TO neondb_owner;

-- (h) fn_audit_trigger — body now PERFORMs fn_audit_log_record_v2 (was: direct INSERT)
--     Body byte-for-byte 116 baseline EXCEPT the final write — trio re-applied per A4/B14.
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
    'aliases','metadata'
    -- CR-C: 0 new redact entries (data_classification + prev/this_hash + branding/colors are NOT sensitive).
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

  -- CR-C 128: route through hash-chain writer (was: direct INSERT into audit_log).
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
  'Generic audit trigger. CR-C (128): now PERFORMs fn_audit_log_record_v2 for hash-chained writes (replaces direct INSERT). Redact list = 32 names (M0..M9 baseline). Preserves v_user_id=0 → NULL coercion (S2-20). REVOKE/GRANT trio re-applied per A4/B14.';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- (i) fn_audit_log_record (M1b 011) — rewrite as thin shim → v2. Re-apply trio (A4).
CREATE OR REPLACE FUNCTION fn_audit_log_record(
  p_table_name TEXT,
  p_record_id  BIGINT,
  p_action     TEXT,
  p_new_values JSONB,
  p_actor_id   BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- CR-C shim: delegate to fn_audit_log_record_v2 to keep cross-cutting events
  -- (M1b XLSX list export, R-PA7 system_setting_set, etc.) on the hash chain (A6).
  RETURN fn_audit_log_record_v2(
    p_table_name,
    p_record_id,
    p_action,
    NULL,           -- M1b shape never carried old_values
    p_new_values,
    p_actor_id
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_audit_log_record: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_audit_log_record(TEXT, BIGINT, TEXT, JSONB, BIGINT) IS
  'M1b 011 baseline + CR-C 128 rewrite: thin shim delegating to fn_audit_log_record_v2 to keep cross-cutting events on the hash chain (agentNote A6). Signature preserved for backward compat. old_values is always NULL via this path (M1b shape never carried it).';
REVOKE EXECUTE ON FUNCTION fn_audit_log_record(TEXT, BIGINT, TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_log_record(TEXT, BIGINT, TEXT, JSONB, BIGINT) TO neondb_owner;

-- (j) Append-only enforcement triggers (defence-in-depth on top of M0 RLS deny policies)
CREATE OR REPLACE FUNCTION fn_audit_log_no_update_guard() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only' USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION fn_audit_log_no_update_guard() IS
  'CR-C append-only enforcement: raises P0001 on any UPDATE to audit_log. Fires regardless of RLS bypass. Defence-in-depth on top of M0 audit_log_deny_update RLS policy.';
REVOKE EXECUTE ON FUNCTION fn_audit_log_no_update_guard() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_log_no_update_guard() TO neondb_owner;

CREATE OR REPLACE FUNCTION fn_audit_log_no_delete_guard() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only' USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION fn_audit_log_no_delete_guard() IS
  'CR-C append-only enforcement: raises P0001 on any DELETE from audit_log. Fires regardless of RLS bypass. Defence-in-depth on top of M0 audit_log_deny_delete RLS policy.';
REVOKE EXECUTE ON FUNCTION fn_audit_log_no_delete_guard() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_log_no_delete_guard() TO neondb_owner;

DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;
CREATE TRIGGER audit_log_no_update
  BEFORE UPDATE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION fn_audit_log_no_update_guard();

DROP TRIGGER IF EXISTS audit_log_no_delete ON audit_log;
CREATE TRIGGER audit_log_no_delete
  BEFORE DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION fn_audit_log_no_delete_guard();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (128, 'crc_audit_chain_extend', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_log_no_delete ON audit_log;
-- DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;
-- DROP FUNCTION IF EXISTS fn_audit_log_no_delete_guard();
-- DROP FUNCTION IF EXISTS fn_audit_log_no_update_guard();
-- -- Restore fn_audit_log_record body from migration 011 manually.
-- -- Restore fn_audit_trigger body from migration 116 manually.
-- DROP FUNCTION IF EXISTS fn_audit_log_record_v2(TEXT, BIGINT, TEXT, JSONB, JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_audit_log_canonicalize(JSONB);
-- DROP INDEX IF EXISTS idx_audit_log_this_hash;
-- ALTER TABLE audit_log DROP COLUMN IF EXISTS this_hash;
-- ALTER TABLE audit_log DROP COLUMN IF EXISTS prev_hash;
-- DELETE FROM schema_migrations WHERE version = 128;
-- COMMIT;
-- ROLLBACK END
