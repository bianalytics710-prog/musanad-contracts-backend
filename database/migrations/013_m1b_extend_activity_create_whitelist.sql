-- ============================================================================
-- 013_m1b_extend_activity_create_whitelist.sql — Extend fn_contract_activity_create whitelist
-- ============================================================================
-- Module:    M1b (patch on 010)
-- Depends:   005 (fn_contract_activity_create defined), 010 (CHECK constraint extended)
-- ----------------------------------------------------------------------------
-- Bug:
--   Migration 010 extended the contract_activity_activity_type_check constraint to allow
--   'payment_schedule_replaced' and 'exported' (M1b CMW-1), and migration 011 introduced
--   fn_payment_schedule_create_bulk + fn_contract_export_pdf which both call
--   fn_contract_activity_create with these new activity types.
--
--   However, fn_contract_activity_create (defined in 005) has its OWN whitelist guard:
--     IF p_activity_type NOT IN ('created','updated','status_changed','version_created',
--                                 'tagged','soft_deleted','restored') THEN
--       RAISE EXCEPTION 'activityType:Invalid activity type';
--     END IF;
--
--   This guard was NOT updated in 010 — so fn_payment_schedule_create_bulk and
--   fn_contract_export_pdf both fail at runtime with 'activityType:Invalid activity type',
--   blocking PUT /contracts/:id/payment-schedules and GET /contracts/:id/export.pdf.
--
--   Smoke testing surfaced this as a P0 — the table CHECK and the function whitelist
--   diverged.
--
-- Fix:
--   CREATE OR REPLACE fn_contract_activity_create with the whitelist extended to include
--   the two M1b activity types. All other attributes preserved verbatim from 005:
--   SECURITY DEFINER, search_path=public,pg_temp, GRANT to neondb_owner only.
--
--   Body is identical to 005 except the IN-list on line corresponding to the guard.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_activity_create(
  p_contract_id    BIGINT,
  p_activity_type  TEXT,
  p_actor_id       BIGINT       DEFAULT NULL,
  p_description_en TEXT         DEFAULT NULL,
  p_description_ar TEXT         DEFAULT NULL,
  p_metadata       JSONB        DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id      BIGINT;
  v_actor   BIGINT;
BEGIN
  -- Whitelist extended in M1b (013) to include 'payment_schedule_replaced' and 'exported'
  -- (CMW-1 already extended the table CHECK constraint in 010).
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) IS
  'INTERNAL helper. SECURITY DEFINER. Invoked ONLY by contract activity-write triggers (and fn_contract_status_update / fn_contract_set_tags / fn_payment_schedule_create_bulk / fn_contract_export_pdf directly when richer metadata than the trigger has access to is needed). Not exposed via HTTP API. EXECUTE granted only to neondb_owner — bypasses contract_activity RLS deny-direct-INSERT. M1b: whitelist extended to include payment_schedule_replaced and exported.';

COMMIT;

-- ============================================================================
-- ROLLBACK (manual)
-- ============================================================================
-- BEGIN;
-- CREATE OR REPLACE FUNCTION fn_contract_activity_create(
--   p_contract_id    BIGINT,
--   p_activity_type  TEXT,
--   p_actor_id       BIGINT       DEFAULT NULL,
--   p_description_en TEXT         DEFAULT NULL,
--   p_description_ar TEXT         DEFAULT NULL,
--   p_metadata       JSONB        DEFAULT NULL
-- ) RETURNS JSONB
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = public, pg_temp
-- AS $$ ... (M1a-only whitelist of 7 values — see 005) ... $$;
-- COMMIT;
