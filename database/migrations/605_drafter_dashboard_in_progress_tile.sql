-- Migration: 605_drafter_dashboard_in_progress_tile.sql
-- Module: Drafter dashboard — add "In progress" tile + fix list/count drift
-- Date: 2026-06-09
--
-- The drafter dashboard tiles previously only counted terminal states,
-- so when a drafter created + submitted a contract in one wizard pass
-- nothing visibly changed:
--   • myDraftsCount counts status='draft' only — drops by 1 when the
--     contract moves to in_approval.
--   • awaitingMyActionCount counts status='resubmission_requested' only —
--     unchanged.
--   • readyToSendCount counts awaiting_signature_*  — unchanged.
--   • myRecentlyApprovedCount counts fully_signed/active — unchanged.
-- Net: 0 perceived motion despite real work done.
--
-- Separately, the awaitingMyAction LIST was selecting BOTH 'draft' AND
-- 'resubmission_requested' while the count only used the latter — so the
-- tile said "1" but the list showed 5+ entries.
--
-- This migration rewrites fn_dashboard_drafter to:
--   1. Add a new top-level KPI `inProgressCount` counting every contract
--      the drafter originated that is still in flight (status IN draft,
--      in_approval, resubmission_requested, awaiting_signature_*). This
--      is the tile that ticks up the moment the drafter clicks Submit.
--   2. Keep myDraftsCount on status='draft' (mental model: "things I
--      haven't sent yet").
--   3. Fix awaitingMyAction so the count + list use the SAME filter
--      (status IN draft, resubmission_requested) — these are the
--      contracts where the next move is the drafter's.
--   4. Keep readyToSend + myRecentlyApproved unchanged.
--
-- Returned shape stays backward-compatible — the new `inProgressCount`
-- key is additive; existing FE tiles continue to read their original
-- keys. A follow-up FE patch renames the tile labels.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_dashboard_drafter(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: unauthorized' USING ERRCODE = '42501';
  END IF;
  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;
  IF v_role IS NULL OR v_role NOT IN ('contract_drafter', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: forbidden — drafter dashboard restricted to contract_drafter, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    -- Existing: things I haven't yet sent out (still pure drafts).
    'myDraftsCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE),

    -- NEW: every contract I originated that is still moving through the
    -- pipeline. Includes drafts, things sitting at any approval step, and
    -- things waiting for signatures. This is the tile that visibly jumps
    -- when the drafter clicks Submit.
    'inProgressCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','in_approval','resubmission_requested',
                         'awaiting_signature_employer','awaiting_signature_counterparty')
          AND is_active = TRUE),

    -- FIXED: count now matches the list below — only contracts where the
    -- next action is the drafter's (drafts they're still editing, or
    -- things sent back for revision).
    'awaitingMyActionCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','resubmission_requested')
          AND is_active = TRUE),

    'readyToSendCount',
      (SELECT COUNT(*) FROM contract c
        WHERE c.drafted_by = v_user_id
          AND c.status IN ('awaiting_signature_employer','awaiting_signature_counterparty')
          AND c.is_active = TRUE),

    'myRecentlyApprovedCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('fully_signed','active')
          AND updated_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'myDrafts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'valueAed', c.value_aed,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb),
    'awaitingMyAction5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','resubmission_requested')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (605, '605_drafter_dashboard_in_progress_tile', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
