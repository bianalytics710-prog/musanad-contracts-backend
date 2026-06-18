-- ============================================================================
-- Migration 712 — fn_contract_version_create: lazy-seed original as v1
-- ============================================================================
-- Bug: merging a counterparty redline into a "new version" overwrote the sense
-- of V1 instead of creating V2. Root cause: legacy contracts (created before
-- mig 688) have current_version=1 but NO contract_version snapshot rows, so
-- fn_contract_version_create computed MAX(version_number)+1 = 1 and inserted the
-- merged body AS v1 — the original was never preserved.
--
-- Fix: mirror what mig 688 did for fn_contract_update — if the contract has no
-- version rows yet, snapshot its CURRENT (pre-edit) body as v1 'Original draft'
-- BEFORE creating the new version. The new version then becomes v2, and the
-- original is preserved.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_version_create(
  p_contract_id BIGINT,
  p_data        JSONB,
  p_actor_id    BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing      contract%ROWTYPE;
  v_new_version   INTEGER;
  v_body_en_new   TEXT;
  v_body_ar_new   TEXT;
  v_change_note   TEXT;
  v_new_id        BIGINT;
  v_now           TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
  SELECT * INTO v_existing
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'contractId:Contract not found';
  END IF;

  v_body_en_new := NULLIF(p_data->>'bodyEn','');
  v_body_ar_new := NULLIF(p_data->>'bodyAr','');
  IF v_body_en_new IS NULL AND v_body_ar_new IS NULL THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'body:At least one of bodyEn or bodyAr must be provided';
  END IF;

  v_change_note := NULLIF(TRIM(p_data->>'changeNote'),'');
  IF v_change_note IS NULL THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'changeNote:Change note is required';
  END IF;

  -- 712 — preserve the original body as v1 for legacy contracts that have no
  -- version snapshot yet (otherwise the new version would BE v1 and the original
  -- body would be lost). Only when there's a body to preserve.
  IF NOT EXISTS (SELECT 1 FROM contract_version WHERE contract_id = p_contract_id)
     AND (v_existing.body_en IS NOT NULL OR v_existing.body_ar IS NOT NULL) THEN
    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note,
      changed_by, created_at, created_by
    ) VALUES (
      p_contract_id, 1, v_existing.body_en, v_existing.body_ar, NULL, 'Original draft',
      COALESCE(v_existing.created_by, p_actor_id), v_existing.created_at, p_actor_id
    );
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1
    INTO v_new_version
    FROM contract_version
    WHERE contract_id = p_contract_id;

  BEGIN
    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note, changed_by, created_by
    ) VALUES (
      p_contract_id,
      v_new_version,
      COALESCE(v_body_en_new, v_existing.body_en),
      COALESCE(v_body_ar_new, v_existing.body_ar),
      NULLIF(p_data->>'diffSummary',''),
      v_change_note,
      p_actor_id,
      p_actor_id
    ) RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'versionNumber:Version conflict — please retry';
  END;

  UPDATE contract
    SET body_en         = COALESCE(v_body_en_new, body_en),
        body_ar         = COALESCE(v_body_ar_new, body_ar),
        current_version = v_new_version,
        updated_at      = v_now,
        updated_by      = p_actor_id
    WHERE id = p_contract_id;

  RETURN jsonb_build_object(
    'id', v_new_id,
    'versionNumber', v_new_version,
    'contractId', p_contract_id,
    'createdAt', v_now
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_version_create: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_version_create: %', SQLERRM;
    END IF;
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (712, 'version_create_lazy_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- (restore the mig-005 body of fn_contract_version_create without the seed block)
-- DELETE FROM schema_migrations WHERE version = 712;
-- ROLLBACK END
-- ============================================================================
