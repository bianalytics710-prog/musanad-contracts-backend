-- Migration: 113_cra2_fix_resolve_role_lookup.sql
-- Module: M8 — Internal Signal Data Path (CR-A2)
-- Description: Surgical patch to fn_internal_signal_resolve from migration 111.
--              Original Q-DA3 role-allowlist EXISTS subquery referenced a non-existent
--              `user_role` junction table. The Musanad schema is single-role-per-user
--              via `"user".role_id BIGINT REFERENCES role(id)` (see 001_foundation.sql §1.6),
--              so every POST /api/v1/internal-signals/:id/resolve currently fails with
--              500 INTERNAL_ERROR (relation "user_role" does not exist), blocking
--              AC-S5-01..S5-04 + AC-S8-04 (pg_notify never reached).
--
--              This migration is a CREATE OR REPLACE FUNCTION that swaps the broken
--              join for the correct single-role lookup. The Q-DA3 per-signal_type
--              role mapping is preserved verbatim from 111. The standard tail block
--              (COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner) is re-applied
--              per feedback_fn_rewrites_lose_safety_guards.md (S2-21).
--
--              No table/permission changes — function body only.
-- Defect ref: M8-DBI-003 (caught by Smoke BE Test, DEFECT-1)
-- Rollback:   See ROLLBACK section below — restores the 111 body verbatim, which
--             would re-introduce the bug. Use only if 113 itself misbehaves.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- 1. fn_internal_signal_resolve — fix user-role lookup
-- ============================================================
CREATE OR REPLACE FUNCTION fn_internal_signal_resolve(
  p_actor_id          BIGINT,
  p_signal_id         BIGINT,
  p_resolution_kind   TEXT,
  p_resolution_note   TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_kind           TEXT;
  v_subtype        TEXT;
  v_existing_meta  JSONB;
  v_existing_at    TIMESTAMPTZ;
  v_resolved_at    TIMESTAMPTZ;
  v_role_ok        BOOLEAN;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Validate resolution_kind
  IF p_resolution_kind NOT IN ('cleared','superseded','mitigated','false_positive') THEN
    RAISE EXCEPTION 'Invalid resolution kind' USING ERRCODE = '22023';
  END IF;

  -- 3. Fetch signal (RLS narrows by tenant; explicit predicate is defence in depth)
  SELECT kind, signal_kind_subtype, metadata
    INTO v_kind, v_subtype, v_existing_meta
  FROM osint_signal
  WHERE id = p_signal_id
    AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Signal not found' USING ERRCODE = 'P0002';
  END IF;

  -- 4. Validate kind = 'internal' (per AC-S5-04)
  IF v_kind != 'internal' THEN
    RAISE EXCEPTION 'Signal is not an internal signal' USING ERRCODE = '22023';
  END IF;

  -- 5. Q-DA3 hardcoded role mapping per signal_kind_subtype.
  --    Caller must hold internal_signal.resolve AND a role in the per-type allowlist.
  IF NOT fn_current_user_has_permission('internal_signal.resolve') THEN
    RAISE EXCEPTION 'forbidden: internal_signal.resolve required' USING ERRCODE = '42501';
  END IF;

  -- ============================================================================
  -- PATCH 113 — single-role lookup via "user".role_id (NOT user_role junction).
  --   Musanad schema (001_foundation §1.6) puts role_id directly on "user" — no
  --   user_role junction exists. The 111 body referenced `user_role ur` which
  --   raised 'relation "user_role" does not exist' → 500 on every resolve call.
  --   Fix: JOIN `"user" u → role r ON r.id = u.role_id`, scoped by u.id and
  --   u.is_active. Q-DA3 role-name CASE/fallback list is preserved verbatim.
  -- ============================================================================
  v_role_ok := EXISTS (
    SELECT 1
    FROM "user" u
    JOIN role r ON r.id = u.role_id
    WHERE u.id = p_actor_id
      AND u.is_active = TRUE
      AND r.is_active = TRUE
      AND r.name IN (
        'Super Admin',
        'platform_admin',
        CASE v_subtype
          WHEN 'milestone_slippage' THEN 'operations'
          WHEN 'sla_breach'         THEN 'operations'
          WHEN 'vendor_incident'    THEN 'operations'
          WHEN 'ics_incident'       THEN 'operations'
          WHEN 'payment_delay'      THEN 'finance_treasury'
          WHEN 'invoice_dispute'    THEN 'finance_treasury'
          WHEN 'icv_status_change'  THEN 'compliance_esg'
          WHEN 'certificate_expiry' THEN 'compliance_esg'
        END,
        -- secondary fallback per Q-DA3 (some subtypes have two non-admin roles)
        CASE v_subtype
          WHEN 'vendor_incident'    THEN 'procurement'
          WHEN 'ics_incident'       THEN 'procurement'
          WHEN 'icv_status_change'  THEN 'procurement'
          WHEN 'certificate_expiry' THEN 'legal_counsel'
        END
      )
  );

  IF NOT v_role_ok THEN
    RAISE EXCEPTION 'Permission denied for signal_type=%', v_subtype
      USING ERRCODE = '42501';
  END IF;

  -- 6. Idempotence — re-resolve returns current payload + skips pg_notify (AC-S5-03)
  IF v_existing_meta IS NOT NULL
     AND v_existing_meta ? 'resolvedAt'
     AND NULLIF(v_existing_meta->>'resolvedAt', '') IS NOT NULL THEN
    v_existing_at := (v_existing_meta->>'resolvedAt')::timestamptz;
    RETURN jsonb_build_object(
      'signalId',       p_signal_id,
      'resolvedAt',     v_existing_at,
      'resolvedBy',     NULLIF(v_existing_meta->>'resolvedBy','')::BIGINT,
      'resolutionKind', v_existing_meta->>'resolutionKind',
      'idempotent',     true
    );
  END IF;

  -- 7. S2-20 actor coercion (CC4 sentinel pattern)
  IF p_actor_id = 0 THEN p_actor_id := NULL; END IF;

  v_resolved_at := now();

  -- 8. UPDATE osint_signal.metadata via Q-DA6 Implementation A
  UPDATE osint_signal
  SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'resolvedAt',      v_resolved_at,
        'resolvedBy',      p_actor_id,
        'resolutionKind',  p_resolution_kind,
        'resolutionNote',  p_resolution_note
      )
  WHERE id = p_signal_id AND tenant_id = v_tenant_id;

  -- 9. pg_notify (only on first-resolve)
  PERFORM pg_notify(
    'internal_signal_resolved',
    jsonb_build_object(
      'signalId',          p_signal_id,
      'tenantId',          v_tenant_id,
      'signalKindSubtype', v_subtype,
      'resolutionKind',    p_resolution_kind,
      'resolvedBy',        p_actor_id,
      'resolvedAt',        v_resolved_at
    )::text
  );

  -- 10. Return
  RETURN jsonb_build_object(
    'signalId',       p_signal_id,
    'resolvedAt',     v_resolved_at,
    'resolvedBy',     p_actor_id,
    'resolutionKind', p_resolution_kind,
    'idempotent',     false
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_internal_signal_resolve: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT) IS
  'M8 — INVOKER. Resolves an internal signal by writing resolution metadata + pg_notify(internal_signal_resolved). Idempotent — re-resolve returns current payload, skips notify. Role gate per signal_type per Q-DA3 hardcoded mapping. Permission: internal_signal.resolve. Patch 113: single-role lookup via "user".role_id (no user_role junction exists in Musanad schema).';
REVOKE EXECUTE ON FUNCTION fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_internal_signal_resolve(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ----------------------------------------------------------------
-- Record this migration
-- ----------------------------------------------------------------
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (113, 'cra2_fix_resolve_role_lookup', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed — restores 111 body verbatim,
--          which RE-INTRODUCES the user_role-junction bug. Use only if 113 itself misbehaves.)
-- ============================================================
-- BEGIN;
-- -- See 111_cra2_internal_signal_functions.sql §2 (lines 191–339) for the original body.
-- DELETE FROM schema_migrations WHERE version = 113;
-- COMMIT;
-- ============================================================
