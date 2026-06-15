-- ============================================================================
-- Migration 684 — Personal "work status" overlay for the unified My Work inbox
-- ============================================================================
-- WHY: The drafter's My Work has an editable Stage dropdown because drafter
-- rows are real work_order rows with a manual_stage column. Legal Counsel (and
-- the other unified-inbox personas) see synthesized, read-only rows
-- (approval_step / risk_case / tpa_review / advisory_draft / …) that don't
-- share one updatable status. This adds a lightweight PERSONAL status the user
-- sets per work item — independent of the underlying entity's real lifecycle —
-- mirroring what manual_stage is for the drafter.
--
-- Keyed by the synthesized My Work row id (BIGINT, stable per entity; negative
-- for synthesized rows per mig 640). Sparse: only items the user has touched
-- have a row; everything else defaults to 'to_do' on read.
--
-- Composite PK (tenant_id, user_id, work_item_id) → no `id` column, so no audit
-- trigger (matches mig 634 tenant_action_setting precedent; personal toggles,
-- low audit value). FORCE RLS for defence-in-depth via the session GUC.
-- ============================================================================

BEGIN;

-- 1. Table -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.my_work_user_status (
  tenant_id     UUID         NOT NULL REFERENCES public.tenant(id) ON DELETE CASCADE,
  user_id       BIGINT       NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
  work_item_id  BIGINT       NOT NULL,
  status        TEXT         NOT NULL
                  CHECK (status IN ('to_do', 'in_progress', 'done', 'blocked')),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by    BIGINT       REFERENCES public."user"(id) ON DELETE SET NULL,
  updated_by    BIGINT       REFERENCES public."user"(id) ON DELETE SET NULL,
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, user_id, work_item_id)
);

COMMENT ON TABLE public.my_work_user_status IS
  'Per-user personal status overlay for unified My Work rows (to_do/in_progress/done/blocked). Sparse — only touched items have rows; default is to_do.';
COMMENT ON COLUMN public.my_work_user_status.work_item_id IS
  'The synthesized My Work row id (mig 640; negative for synthesized rows). Stable per underlying entity.';

CREATE INDEX IF NOT EXISTS idx_my_work_user_status_user
  ON public.my_work_user_status (tenant_id, user_id);

ALTER TABLE public.my_work_user_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.my_work_user_status FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS my_work_user_status_tenant_isolation ON public.my_work_user_status;
CREATE POLICY my_work_user_status_tenant_isolation ON public.my_work_user_status
  FOR ALL USING (
    tenant_id IS NOT DISTINCT FROM NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

-- 2. fn_my_work_status_list — the actor's personal-status map ----------------
CREATE OR REPLACE FUNCTION public.fn_my_work_status_list(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_data      JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actorId:Actor id is required' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_agg(
           jsonb_build_object('workItemId', s.work_item_id, 'status', s.status)
         )
    INTO v_data
    FROM public.my_work_user_status s
   WHERE s.tenant_id = v_tenant_id
     AND s.user_id = p_actor_id
     AND s.is_active = TRUE;

  RETURN jsonb_build_object('data', COALESCE(v_data, '[]'::jsonb));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_my_work_status_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_my_work_status_list(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_my_work_status_list(BIGINT) IS
  'Returns the actor''s personal My Work statuses as [{workItemId,status}]. Items without a row default to to_do on the FE.';

-- 3. fn_my_work_status_set — upsert the actor's personal status --------------
CREATE OR REPLACE FUNCTION public.fn_my_work_status_set(
  p_actor_id     BIGINT,
  p_work_item_id BIGINT,
  p_status       TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL OR p_work_item_id IS NULL THEN
    RAISE EXCEPTION 'actorId + workItemId required' USING ERRCODE = '22023';
  END IF;
  IF p_status NOT IN ('to_do', 'in_progress', 'done', 'blocked') THEN
    RAISE EXCEPTION 'status:Invalid status %', p_status USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.my_work_user_status
    (tenant_id, user_id, work_item_id, status, created_by, updated_by)
  VALUES
    (v_tenant_id, p_actor_id, p_work_item_id, p_status, p_actor_id, p_actor_id)
  ON CONFLICT (tenant_id, user_id, work_item_id) DO UPDATE
    SET status     = EXCLUDED.status,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id,
        is_active  = TRUE;

  RETURN jsonb_build_object('workItemId', p_work_item_id, 'status', p_status);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_my_work_status_set(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_my_work_status_set(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_my_work_status_set(BIGINT, BIGINT, TEXT) IS
  'Upserts the actor''s personal status (to_do/in_progress/done/blocked) for a unified My Work row, keyed by the synthesized work_item_id.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (684, 'my_work_user_status', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
