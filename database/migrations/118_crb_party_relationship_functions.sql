-- Migration: 118_crb_party_relationship_functions.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: 4 fn_'s — fn_party_relationship_create / _update / _delete / _list. INVOKER.
-- Rollback: DROP FUNCTION ... (4 fns)

BEGIN;

-- ============================================================
-- 3.1 fn_party_relationship_create
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_relationship_create(
  p_actor_id           BIGINT,
  p_parent_id          BIGINT,
  p_child_id           BIGINT,
  p_relationship_type  TEXT,
  p_ownership_pct      NUMERIC(5,2)  DEFAULT NULL,
  p_effective_from     DATE          DEFAULT NULL,
  p_effective_to       DATE          DEFAULT NULL,
  p_source             TEXT          DEFAULT 'manual',
  p_confidence         NUMERIC(3,2)  DEFAULT 1.00,
  p_metadata           JSONB         DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
  v_result    JSONB;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_context_not_set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 3. Self-loop pre-check
  IF p_parent_id = p_child_id THEN
    RAISE EXCEPTION 'self_loop_not_allowed' USING ERRCODE = '22023';
  END IF;

  -- 4. relationship_type whitelist
  IF p_relationship_type NOT IN ('parent','ubo','subsidiary','sub_contractor','jv','controlling_shareholder') THEN
    RAISE EXCEPTION 'invalid relationship_type' USING ERRCODE = '22023';
  END IF;

  -- 5. FK pre-validation (S2-23)
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_parent_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'parentId:party_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_child_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'childId:party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 6. INSERT (catch unique violation)
  BEGIN
    INSERT INTO party_relationship (
      tenant_id, parent_id, child_id, relationship_type,
      ownership_pct, effective_from, effective_to,
      source, confidence, metadata,
      created_by, updated_by
    )
    VALUES (
      v_tenant_id, p_parent_id, p_child_id, p_relationship_type,
      p_ownership_pct, p_effective_from, p_effective_to,
      COALESCE(p_source, 'manual'), COALESCE(p_confidence, 1.00),
      COALESCE(p_metadata, '{}'::jsonb),
      p_actor_id, p_actor_id
    )
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'relationship_already_exists' USING ERRCODE = '23505';
  END;

  -- 7. Build response
  SELECT jsonb_build_object(
    'id',                pr.id,
    'tenantId',          pr.tenant_id,
    'parentId',          pr.parent_id,
    'childId',           pr.child_id,
    'relationshipType',  pr.relationship_type,
    'ownershipPct',      pr.ownership_pct,
    'effectiveFrom',     pr.effective_from,
    'effectiveTo',       pr.effective_to,
    'source',            pr.source,
    'confidence',        pr.confidence,
    'metadata',          pr.metadata,
    'createdAt',         pr.created_at,
    'updatedAt',         pr.updated_at,
    'isActive',          pr.is_active
  ) INTO v_result
  FROM party_relationship pr
  WHERE pr.id = v_id;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_relationship_create: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_relationship_create(BIGINT, BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB) IS
  'M9 — inserts a directed-typed party_relationship edge under app.current_tenant_id. Permission: party.graph.manage. FK pre-validates parent + child active.';
REVOKE EXECUTE ON FUNCTION fn_party_relationship_create(BIGINT, BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_relationship_create(BIGINT, BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB) TO neondb_owner;


-- ============================================================
-- 3.2 fn_party_relationship_update
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_relationship_update(
  p_actor_id           BIGINT,
  p_relationship_id    BIGINT,
  p_relationship_type  TEXT          DEFAULT NULL,
  p_ownership_pct      NUMERIC(5,2)  DEFAULT NULL,
  p_effective_from     DATE          DEFAULT NULL,
  p_effective_to       DATE          DEFAULT NULL,
  p_source             TEXT          DEFAULT NULL,
  p_confidence         NUMERIC(3,2)  DEFAULT NULL,
  p_metadata           JSONB         DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_result    JSONB;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_context_not_set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 3. Existence + active check (S2-22)
  IF NOT EXISTS (
    SELECT 1 FROM party_relationship
    WHERE id = p_relationship_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'relationship_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 4. relationship_type whitelist (only when provided)
  IF p_relationship_type IS NOT NULL
     AND p_relationship_type NOT IN ('parent','ubo','subsidiary','sub_contractor','jv','controlling_shareholder') THEN
    RAISE EXCEPTION 'invalid relationship_type' USING ERRCODE = '22023';
  END IF;

  -- 5. UPDATE
  UPDATE party_relationship SET
    relationship_type = COALESCE(p_relationship_type, relationship_type),
    ownership_pct     = COALESCE(p_ownership_pct,    ownership_pct),
    effective_from    = COALESCE(p_effective_from,   effective_from),
    effective_to      = COALESCE(p_effective_to,     effective_to),
    source            = COALESCE(p_source,           source),
    confidence        = COALESCE(p_confidence,       confidence),
    metadata          = COALESCE(p_metadata,         metadata),
    updated_at        = CURRENT_TIMESTAMP,
    updated_by        = p_actor_id
  WHERE id = p_relationship_id
    AND tenant_id = v_tenant_id
    AND is_active = TRUE;

  -- 6. Build response
  SELECT jsonb_build_object(
    'id',                pr.id,
    'tenantId',          pr.tenant_id,
    'parentId',          pr.parent_id,
    'childId',           pr.child_id,
    'relationshipType',  pr.relationship_type,
    'ownershipPct',      pr.ownership_pct,
    'effectiveFrom',     pr.effective_from,
    'effectiveTo',       pr.effective_to,
    'source',            pr.source,
    'confidence',        pr.confidence,
    'metadata',          pr.metadata,
    'createdAt',         pr.created_at,
    'updatedAt',         pr.updated_at,
    'isActive',          pr.is_active
  ) INTO v_result
  FROM party_relationship pr
  WHERE pr.id = p_relationship_id;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_relationship_update: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_relationship_update(BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB) IS
  'M9 — partial update of an existing party_relationship edge. parentId/childId immutable post-create. Permission: party.graph.manage.';
REVOKE EXECUTE ON FUNCTION fn_party_relationship_update(BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_relationship_update(BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB) TO neondb_owner;


-- ============================================================
-- 3.3 fn_party_relationship_delete
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_relationship_delete(
  p_actor_id         BIGINT,
  p_relationship_id  BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id  UUID;
  v_is_active  BOOLEAN;
  v_updated_at TIMESTAMPTZ;
  v_deleted_at TIMESTAMPTZ;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_context_not_set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 3. Existence (allow already-inactive for idempotence)
  SELECT is_active, updated_at
    INTO v_is_active, v_updated_at
  FROM party_relationship
  WHERE id = p_relationship_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'relationship_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 4. Idempotent path
  IF NOT v_is_active THEN
    RETURN jsonb_build_object(
      'success',    TRUE,
      'deletedAt',  v_updated_at,
      'idempotent', TRUE
    );
  END IF;

  -- 5. Soft-delete
  UPDATE party_relationship
     SET is_active  = FALSE,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE id = p_relationship_id
   RETURNING updated_at INTO v_deleted_at;

  RETURN jsonb_build_object(
    'success',    TRUE,
    'deletedAt',  v_deleted_at,
    'idempotent', FALSE
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_relationship_delete: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_relationship_delete(BIGINT, BIGINT) IS
  'M9 — soft-delete a party_relationship edge. Idempotent: re-deleting an already-soft-deleted edge returns idempotent=true. Permission: party.graph.manage.';
REVOKE EXECUTE ON FUNCTION fn_party_relationship_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_relationship_delete(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================
-- 4.1 fn_party_relationship_list (STABLE; defined here so fn_party_chain_summary in 119 can call it)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_relationship_list(
  p_actor_id  BIGINT,
  p_party_id  BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_incoming  JSONB;
  v_outgoing  JSONB;
  v_in_count  INTEGER;
  v_out_count INTEGER;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_context_not_set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 3. Pre-check party existence
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_party_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 4. incoming edges (child_id = p_party_id; other_party = parent)
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'id',               pr.id,
      'relationshipType', pr.relationship_type,
      'ownershipPct',     pr.ownership_pct,
      'source',           pr.source,
      'confidence',       pr.confidence,
      'createdAt',        pr.created_at,
      'otherParty', jsonb_build_object(
        'partyId',          po.id,
        'nameEn',           po.name_en,
        'nameAr',           po.name_ar,
        'sanctionsStatus',  po.sanctions_status
      )
    ) ORDER BY pr.created_at DESC), '[]'::jsonb),
    COUNT(*)
  INTO v_incoming, v_in_count
  FROM party_relationship pr
  JOIN party po ON po.id = pr.parent_id
  WHERE pr.child_id = p_party_id
    AND pr.is_active = TRUE
    AND pr.tenant_id = v_tenant_id;

  -- 5. outgoing edges (parent_id = p_party_id; other_party = child)
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'id',               pr.id,
      'relationshipType', pr.relationship_type,
      'ownershipPct',     pr.ownership_pct,
      'source',           pr.source,
      'confidence',       pr.confidence,
      'createdAt',        pr.created_at,
      'otherParty', jsonb_build_object(
        'partyId',          po.id,
        'nameEn',           po.name_en,
        'nameAr',           po.name_ar,
        'sanctionsStatus',  po.sanctions_status
      )
    ) ORDER BY pr.created_at DESC), '[]'::jsonb),
    COUNT(*)
  INTO v_outgoing, v_out_count
  FROM party_relationship pr
  JOIN party po ON po.id = pr.child_id
  WHERE pr.parent_id = p_party_id
    AND pr.is_active = TRUE
    AND pr.tenant_id = v_tenant_id;

  RETURN jsonb_build_object(
    'incoming', v_incoming,
    'outgoing', v_outgoing,
    'counts',   jsonb_build_object(
      'incoming', COALESCE(v_in_count, 0),
      'outgoing', COALESCE(v_out_count, 0)
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_relationship_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_relationship_list(BIGINT, BIGINT) IS
  'M9 — returns incoming + outgoing party_relationship edges (with joined other-party light projection) for a given party. Tenant-auto-scoped via app.current_tenant_id GUC + RLS. Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_relationship_list(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_relationship_list(BIGINT, BIGINT) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (118, 'crb_party_relationship_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_party_relationship_list(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_party_relationship_delete(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_party_relationship_update(BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB);
-- DROP FUNCTION IF EXISTS fn_party_relationship_create(BIGINT, BIGINT, BIGINT, TEXT, NUMERIC, DATE, DATE, TEXT, NUMERIC, JSONB);
-- DELETE FROM schema_migrations WHERE version = 118;
-- COMMIT;
