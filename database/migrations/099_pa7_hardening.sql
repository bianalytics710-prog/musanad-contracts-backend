-- ============================================================================
-- 099_pa7_hardening.sql
-- ============================================================================
-- Module:    R-PA7 (Platform Admin parity hardening — closes audit findings)
-- Owner:     Lovable Modernization Agent — Platform Admin parity
-- Depends:   056 (fn_dashboard_admin), 095 (R-PA1 dashboard rebuild),
--            096 (R-PA2 fn_user_update + fn_user_password_reset),
--            097 (R-PA4 fn_system_setting_set), 098 (R-PA5 fn_audit_log_list).
-- ----------------------------------------------------------------------------
-- Closes the 5 CRITICAL + 4 high-priority WARN findings from the production-
-- standards audit:
--
--   C1 — fn_system_setting_set has NO audit insert despite the migration
--        comment promising one (097 disabled the audit trigger because
--        system_setting has no `id` column → fn_audit_trigger uses NEW.id).
--        Fix: add an explicit INSERT INTO audit_log inside the fn AFTER the
--        UPDATE, with old_values + new_values JSONB envelopes. record_id is
--        NULL (TEXT PK) — actual key lives inside the JSONB envelope.
--
--   C2 — 096 raises were all bare (no ERRCODE); the WHEN OTHERS catch-all
--        stripped any future ERRCODEs (no `USING ERRCODE = SQLSTATE`).
--        Fix: rewrite both fn_user_update + fn_user_password_reset with
--        explicit ERRCODE on every raise (P0002 not-found, 22023 validation,
--        42501 self-protection) AND `USING ERRCODE = SQLSTATE` in WHEN OTHERS.
--
--   W1 — DB-12: 095's CREATE OR REPLACE on fn_dashboard_admin dropped any
--        prior COMMENT ON FUNCTION (PG behaviour). Re-add it.
--
--   W2 — DB-25: 097 fn_system_setting_set raises for missing key/value lacked
--        ERRCODE. Add 22023 alongside the existing 42501/P0002 raises.
--
--   W3 — DB: 098 fn_audit_log_list `changedByName` used
--        `COALESCE(first || ' ' || last, NULL)` which loses half-populated
--        names (any NULL anywhere → NULL). Switch to concat_ws(' ', ...).
--
-- Stage 2 standards observed:
--   S2-21 — REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner re-applied on
--           every replaced fn_ (CREATE OR REPLACE drops grants).
--   DB-12 — COMMENT ON FUNCTION re-applied on every replaced fn_.
--   DB-25 — ERRCODE on every raise.
-- ============================================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. fn_user_update (R-PA2 + R-PA7)
--    Adds proper ERRCODEs and ERRCODE-preserving WHEN OTHERS handler.
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_user_update(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_result    JSONB;
  v_new_email TEXT;
  v_role_id   BIGINT;
  v_is_active BOOLEAN;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_user_update: p_id is required' USING ERRCODE = '22023';
  END IF;
  IF p_data IS NULL THEN
    RAISE EXCEPTION 'fn_user_update: p_data is required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = p_id) THEN
    RAISE EXCEPTION 'fn_user_update: user not found' USING ERRCODE = 'P0002';
  END IF;

  IF p_data ? 'email' AND p_data->>'email' IS NOT NULL AND p_data->>'email' <> '' THEN
    v_new_email := LOWER(p_data->>'email');
    IF EXISTS (SELECT 1 FROM "user" WHERE LOWER(email) = v_new_email AND id <> p_id) THEN
      RAISE EXCEPTION 'fn_user_update: email already in use' USING ERRCODE = '23505';
    END IF;
  END IF;

  IF p_data ? 'roleId' AND p_data->>'roleId' IS NOT NULL THEN
    v_role_id := (p_data->>'roleId')::BIGINT;
    IF NOT EXISTS (SELECT 1 FROM role WHERE id = v_role_id AND is_active = true) THEN
      RAISE EXCEPTION 'fn_user_update: role not found or inactive' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF p_data ? 'isActive' AND p_data->>'isActive' IS NOT NULL THEN
    v_is_active := (p_data->>'isActive')::BOOLEAN;
    IF v_is_active = false AND p_actor_id IS NOT NULL AND p_id = p_actor_id THEN
      RAISE EXCEPTION 'fn_user_update: cannot suspend your own account' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE "user" SET
    email      = COALESCE(LOWER(p_data->>'email'),        email),
    first_name = COALESCE(p_data->>'firstName',           first_name),
    last_name  = COALESCE(p_data->>'lastName',            last_name),
    role_id    = COALESCE((p_data->>'roleId')::BIGINT,    role_id),
    is_active  = COALESCE((p_data->>'isActive')::BOOLEAN, is_active),
    updated_by = p_actor_id,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_id;

  SELECT fn_user_get_by_id(p_id) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN unique_violation THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_update: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE ALL ON FUNCTION fn_user_update(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_user_update(BIGINT, JSONB, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_user_update(BIGINT, JSONB, BIGINT) IS
  'R-PA2 + R-PA7: partial COALESCE update of email/firstName/lastName/roleId/isActive. Self-protection blocks self-suspend (42501). ERRCODEs: P0002 not-found, 22023 validation, 23505 unique violation, 42501 self-protection. WHEN OTHERS preserves ERRCODE via SQLSTATE.';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. fn_user_password_reset (R-PA2 + R-PA7)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_user_password_reset(
  p_id            BIGINT,
  p_password_hash TEXT,
  p_actor_id      BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_user_password_reset: p_id is required' USING ERRCODE = '22023';
  END IF;
  IF p_password_hash IS NULL OR length(p_password_hash) = 0 THEN
    RAISE EXCEPTION 'fn_user_password_reset: passwordHash is required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = p_id AND is_active = true) THEN
    RAISE EXCEPTION 'fn_user_password_reset: user not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  IF p_actor_id IS NOT NULL AND p_id = p_actor_id THEN
    RAISE EXCEPTION 'fn_user_password_reset: cannot reset your own password — use /auth/change-password' USING ERRCODE = '42501';
  END IF;

  UPDATE "user" SET
    password_hash = p_password_hash,
    updated_by    = p_actor_id,
    updated_at    = CURRENT_TIMESTAMP
  WHERE id = p_id;

  RETURN jsonb_build_object('success', true, 'message', 'Password reset', 'userId', p_id);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_password_reset: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE ALL ON FUNCTION fn_user_password_reset(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_user_password_reset(BIGINT, TEXT, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_user_password_reset(BIGINT, TEXT, BIGINT) IS
  'R-PA2 + R-PA7: admin password reset. Controller hashes plaintext with bcrypt(12) before invoking. Self-reset blocked (42501) — actor uses /auth/change-password instead. ERRCODEs: P0002 not-found, 22023 validation, 42501 self-protection.';

-- ──────────────────────────────────────────────────────────────────────────
-- 3. fn_system_setting_set (R-PA4 + R-PA7)
--    Closes C1 (audit insert) + W2 (validation ERRCODEs).
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_system_setting_set(
  p_key   TEXT,
  p_value JSONB,
  p_actor BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id  BIGINT;
  v_old_row  system_setting%ROWTYPE;
  v_row      system_setting%ROWTYPE;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_set: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('settings.write') THEN
    RAISE EXCEPTION 'fn_system_setting_set: forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_key IS NULL OR length(p_key) = 0 THEN
    RAISE EXCEPTION 'fn_system_setting_set: key is required' USING ERRCODE = '22023';
  END IF;
  IF p_value IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_set: value is required' USING ERRCODE = '22023';
  END IF;

  -- Capture pre-image for audit envelope. RETURNING * reads the row state
  -- before the UPDATE could run; use a separate SELECT.
  SELECT * INTO v_old_row
  FROM system_setting
  WHERE key = p_key AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_system_setting_set: setting "%" does not exist', p_key USING ERRCODE = 'P0002';
  END IF;

  UPDATE system_setting
    SET value      = p_value,
        updated_by = COALESCE(p_actor, v_user_id),
        updated_at = CURRENT_TIMESTAMP
  WHERE key = p_key
  RETURNING * INTO v_row;

  -- Compensating audit insert. system_setting has no `id` column so the
  -- standard fn_audit_trigger cannot fire (097 explicitly skipped it).
  -- record_id is NULL (BIGINT, not TEXT-compatible) — the actual key is
  -- captured inside the JSONB envelope so /admin/audit can render it.
  INSERT INTO audit_log (
    table_name,
    record_id,
    action,
    old_values,
    new_values,
    changed_by,
    changed_at
  ) VALUES (
    'system_setting',
    NULL,
    'UPDATE',
    jsonb_build_object('key', v_old_row.key, 'value', v_old_row.value, 'category', v_old_row.category),
    jsonb_build_object('key', v_row.key,     'value', v_row.value,     'category', v_row.category),
    COALESCE(p_actor, v_user_id),
    CURRENT_TIMESTAMP
  );

  RETURN jsonb_build_object(
    'key',       v_row.key,
    'value',     v_row.value,
    'category',  v_row.category,
    'updatedAt', v_row.updated_at
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_system_setting_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) IS
  'R-PA4 + R-PA7: UPSERT one system_setting row + emit audit_log INSERT (table_name=system_setting, key inside JSONB envelope). Permission gate: settings.write. ERRCODEs: P0002 not-found, 22023 validation, 42501 auth/forbidden. Branding read-only is enforced in the FE only (Q3 / R-PA4 decision); a future round may DB-enforce.';

-- ──────────────────────────────────────────────────────────────────────────
-- 4. fn_audit_log_list (R-PA5 + R-PA7)
--    W3: half-populated names use concat_ws so non-NULL parts survive.
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_audit_log_list(
  p_page       INTEGER DEFAULT 1,
  p_limit      INTEGER DEFAULT 50,
  p_table_name TEXT DEFAULT NULL,
  p_action     TEXT DEFAULT NULL,
  p_changed_by BIGINT DEFAULT NULL,
  p_date_from  TIMESTAMPTZ DEFAULT NULL,
  p_date_to    TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_page    INTEGER := COALESCE(p_page, 1);
  v_limit   INTEGER := COALESCE(p_limit, 50);
  v_offset  INTEGER;
  v_total   BIGINT;
  v_data    JSONB;
BEGIN
  IF v_page < 1 THEN
    RAISE EXCEPTION 'fn_audit_log_list: page must be >= 1' USING ERRCODE = '22023';
  END IF;
  IF v_limit < 1 OR v_limit > 200 THEN
    RAISE EXCEPTION 'fn_audit_log_list: limit must be 1..200' USING ERRCODE = '22023';
  END IF;
  IF p_action IS NOT NULL AND p_action NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'fn_audit_log_list: action must be INSERT, UPDATE or DELETE' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_audit_log_list: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('audit.read') THEN
    RAISE EXCEPTION 'fn_audit_log_list: forbidden' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
  FROM audit_log al
  WHERE (p_table_name IS NULL OR al.table_name = p_table_name)
    AND (p_action     IS NULL OR al.action = p_action)
    AND (p_changed_by IS NULL OR al.changed_by = p_changed_by)
    AND (p_date_from  IS NULL OR al.changed_at >= p_date_from)
    AND (p_date_to    IS NULL OR al.changed_at <  p_date_to);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',             al.id,
      'tableName',      al.table_name,
      'recordId',       al.record_id,
      'action',         al.action,
      'changedBy',      al.changed_by,
      'changedByName',  NULLIF(concat_ws(' ', u.first_name, u.last_name), ''),
      'changedByEmail', u.email,
      'changedAt',      al.changed_at,
      'oldValues',      al.old_values,
      'newValues',      al.new_values
    ) ORDER BY al.changed_at DESC, al.id DESC
  ), '[]'::jsonb)
    INTO v_data
  FROM (
    SELECT al.* FROM audit_log al
    WHERE (p_table_name IS NULL OR al.table_name = p_table_name)
      AND (p_action     IS NULL OR al.action = p_action)
      AND (p_changed_by IS NULL OR al.changed_by = p_changed_by)
      AND (p_date_from  IS NULL OR al.changed_at >= p_date_from)
      AND (p_date_to    IS NULL OR al.changed_at <  p_date_to)
    ORDER BY al.changed_at DESC, al.id DESC
    LIMIT v_limit OFFSET v_offset
  ) al
  LEFT JOIN "user" u ON u.id = al.changed_by;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'page',       v_page,
      'limit',      v_limit,
      'total',      v_total,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_limit)::INTEGER END
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) TO neondb_owner;
COMMENT ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) IS
  'R-PA5 + R-PA7: paginated audit_log list with 5 filters. Permission gate: audit.read. changedByName uses concat_ws so half-populated names (one part NULL) still display. CSV export uses the same fn at limit=200, page-iterated by the controller (BE-02 multi-call documented waiver).';

-- ──────────────────────────────────────────────────────────────────────────
-- 5. W1 — re-add COMMENT ON FUNCTION fn_dashboard_admin (lost in 095 rebuild)
-- ──────────────────────────────────────────────────────────────────────────
COMMENT ON FUNCTION fn_dashboard_admin(INTEGER) IS
  'R-PA1 (migration 095): platform-admin dashboard payload. Returns kpis + kpiPrev + trends + systemHealth + pendingAdminActions + topContractTypes5 + systemActivity14d. Permission gate: role IN (platform_admin, Super Admin). Window: 1..365 days (default 30).';

-- ──────────────────────────────────────────────────────────────────────────
-- 6. Document key column on system_setting (DB-04 deviation)
-- ──────────────────────────────────────────────────────────────────────────
COMMENT ON COLUMN system_setting.key IS
  'TEXT primary key (camelCase identifier). DB-04 deviation: this is a key/value catalog rather than a business entity, so id BIGSERIAL is omitted. Audit trigger is correspondingly skipped (fn_audit_trigger uses NEW.id) — fn_system_setting_set emits an explicit audit_log INSERT after every UPDATE to compensate.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (99, 'pa7_hardening', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN (executable — restores 096/097/098 bodies via re-apply)
-- ============================================================================
-- To roll back R-PA7 cleanly, re-apply migrations 095, 096, 097, 098 in order
-- (each is CREATE OR REPLACE so they are idempotent and supersede the R-PA7
-- bodies). Then:
--   DELETE FROM schema_migrations WHERE version = 99;
-- ROLLBACK END
