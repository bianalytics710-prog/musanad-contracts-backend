-- Migration: 585_fix_role_resolver.sql
-- Module: Notification trigger rules v2 — fix role resolver
-- Date: 2026-06-05
--
-- mig 582's fn_internal_resolve_recipient referenced a "user_role" join table
-- that doesn't exist — the user model is single-role via "user".role_id FK.
-- Patch the role branch to read from "user" directly.

BEGIN;

CREATE OR REPLACE FUNCTION fn_internal_resolve_recipient(
  p_recipient_type  TEXT,
  p_recipient_value TEXT,
  p_payload         JSONB,
  p_caller_user_id  BIGINT,
  p_caller_email    TEXT
) RETURNS TABLE (user_id BIGINT, email TEXT)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_json_arr JSONB;
  v_single   TEXT;
BEGIN
  IF p_recipient_type = 'role' THEN
    -- Single-role-per-user model: read u.role_id directly.
    RETURN QUERY
      SELECT u.id, NULL::TEXT
      FROM "user" u
      JOIN role r ON r.id = u.role_id
      WHERE r.name = p_recipient_value
        AND u.is_active = TRUE
        AND r.is_active = TRUE;
    RETURN;
  END IF;

  IF p_recipient_type = 'user' THEN
    BEGIN
      RETURN QUERY SELECT p_recipient_value::BIGINT, NULL::TEXT;
    EXCEPTION WHEN OTHERS THEN
      RETURN;
    END;
    RETURN;
  END IF;

  IF p_recipient_type = 'email' THEN
    RETURN QUERY SELECT NULL::BIGINT, p_recipient_value;
    RETURN;
  END IF;

  IF p_recipient_type = 'context' THEN
    IF p_recipient_value = 'caller' THEN
      IF p_caller_user_id IS NOT NULL OR p_caller_email IS NOT NULL THEN
        RETURN QUERY SELECT p_caller_user_id, p_caller_email;
      END IF;
      RETURN;
    END IF;

    v_single := p_payload->>p_recipient_value;
    IF v_single IS NOT NULL AND v_single ~ '^[0-9]+$' THEN
      RETURN QUERY SELECT v_single::BIGINT, NULL::TEXT;
      RETURN;
    END IF;

    v_json_arr := p_payload->p_recipient_value;
    IF v_json_arr IS NOT NULL AND jsonb_typeof(v_json_arr) = 'array' THEN
      RETURN QUERY
        SELECT (val::TEXT)::BIGINT, NULL::TEXT
        FROM jsonb_array_elements_text(v_json_arr) val
        WHERE val ~ '^[0-9]+$';
      RETURN;
    END IF;

    RETURN;
  END IF;
END $$;

REVOKE ALL ON FUNCTION fn_internal_resolve_recipient(TEXT, TEXT, JSONB, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_resolve_recipient(TEXT, TEXT, JSONB, BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (585, '585_fix_role_resolver', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
