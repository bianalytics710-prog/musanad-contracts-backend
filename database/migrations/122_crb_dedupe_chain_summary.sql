-- Migration: 122_crb_dedupe_chain_summary.sql
-- Module: M9 — Counterparty Graph (CR-B) — DEFECT-2 patch
-- Description: fn_party_chain_traverse_up + fn_party_chain_traverse_down emitted
--              duplicate (party_id, depth, via) tuples whenever a node was
--              reachable through more than one path at the same depth (e.g.
--              party_relationship 'edge' AND a self-FK shortcut converging on
--              the same ancestor at the same depth, or two distinct edge paths
--              that happen to land on the same node at the same depth from
--              different intermediate hops). The FE renders chain nodes with
--              key={`${partyId}-${depth}-${via}`} → React duplicate-key warning.
--
--              Fix: re-aggregate over a `DISTINCT ON (party_id, depth, via)`
--              projection in the inner CTE, keeping a deterministic
--              representative row (highest ownership_pct first, then
--              relationship_type asc to break further ties). Surface columns
--              are unchanged.
--
--              Per `feedback_fn_rewrites_lose_safety_guards.md`: every
--              CREATE OR REPLACE re-applies REVOKE-FROM-PUBLIC + GRANT-TO
--              neondb_owner + COMMENT trio, identical to migration 119.
--
-- Rollback: re-apply migration 119 bodies (drops the DISTINCT ON pivot).

BEGIN;

-- ============================================================
-- 4.2 fn_party_chain_traverse_up — dedupe (party_id, depth, via)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_chain_traverse_up(
  p_actor_id   BIGINT,
  p_party_id   BIGINT,
  p_max_depth  INTEGER DEFAULT 5
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_ancestors      JSONB;
  v_truncated      BOOLEAN;
  v_depth_reached  INTEGER;
  v_cycle_hit_any  BOOLEAN;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 2. p_max_depth bounds
  IF p_max_depth IS NULL OR p_max_depth < 1 OR p_max_depth > 10 THEN
    RAISE EXCEPTION 'maxDepth:max_depth_out_of_range' USING ERRCODE = '22023';
  END IF;

  -- 3. Pre-check party existence
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_party_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 4. Tenant GUC (used by SOURCE A)
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;

  -- 5. Recursive CTE
  WITH RECURSIVE chain AS (
    SELECT
      p_party_id::bigint    AS party_id,
      0                     AS depth,
      NULL::text            AS relationship_type,
      NULL::numeric         AS ownership_pct,
      NULL::text            AS via,
      ARRAY[p_party_id]::bigint[] AS visited,
      FALSE                 AS cycle_hit
    UNION ALL
    SELECT
      hop.hop_party_id,
      c.depth + 1,
      hop.relationship_type,
      hop.ownership_pct,
      hop.via,
      c.visited || hop.hop_party_id,
      hop.hop_party_id = ANY(c.visited)
    FROM chain c
    CROSS JOIN LATERAL (
      SELECT
        pr.parent_id     AS hop_party_id,
        pr.relationship_type,
        pr.ownership_pct,
        'edge'::text     AS via
      FROM party_relationship pr
      WHERE pr.child_id = c.party_id
        AND pr.is_active = TRUE
        AND pr.tenant_id = v_tenant_id
      UNION ALL
      SELECT
        pa.parent_id, 'parent'::text, NULL::numeric, 'self_fk_parent'::text
      FROM party pa
      WHERE pa.id = c.party_id AND pa.parent_id IS NOT NULL
      UNION ALL
      SELECT
        pa.ubo_id, 'ubo'::text, NULL::numeric, 'self_fk_ubo'::text
      FROM party pa
      WHERE pa.id = c.party_id AND pa.ubo_id IS NOT NULL
    ) hop
    WHERE c.depth < p_max_depth
      AND NOT c.cycle_hit
      AND hop.hop_party_id IS NOT NULL
      AND NOT (hop.hop_party_id = ANY(c.visited))
  ),
  ancestors_with_party AS (
    SELECT
      c.party_id,
      c.depth,
      c.relationship_type,
      c.ownership_pct,
      c.via,
      p.name_en,
      p.name_ar,
      p.sanctions_status
    FROM chain c
    JOIN party p ON p.id = c.party_id
    WHERE c.depth > 0
  ),
  -- DEDUPE: collapse convergent paths to a single representative row per
  -- (party_id, depth, via). Highest ownership_pct first (NULLs last),
  -- then relationship_type asc for determinism.
  ancestors_dedup AS (
    SELECT DISTINCT ON (party_id, depth, via)
      party_id,
      depth,
      relationship_type,
      ownership_pct,
      via,
      name_en,
      name_ar,
      sanctions_status
    FROM ancestors_with_party
    ORDER BY party_id, depth, via, ownership_pct DESC NULLS LAST, relationship_type ASC
  ),
  truncation AS (
    SELECT
      bool_or(depth >= p_max_depth) AS hit_cap,
      bool_or(cycle_hit)            AS hit_cycle,
      MAX(depth)                    AS depth_reached
    FROM chain
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'partyId',           a.party_id,
      'depth',             a.depth,
      'relationshipType',  a.relationship_type,
      'ownershipPct',      a.ownership_pct,
      'sanctionsStatus',   a.sanctions_status,
      'nameEn',            a.name_en,
      'nameAr',            a.name_ar,
      'via',               a.via
    ) ORDER BY a.depth, a.party_id, a.via), '[]'::jsonb),
    (SELECT COALESCE(hit_cap, FALSE) OR COALESCE(hit_cycle, FALSE) FROM truncation),
    (SELECT COALESCE(depth_reached, 0) FROM truncation),
    (SELECT COALESCE(hit_cycle, FALSE) FROM truncation)
  INTO v_ancestors, v_truncated, v_depth_reached, v_cycle_hit_any
  FROM ancestors_dedup a;

  RETURN jsonb_build_object(
    'rootPartyId',     p_party_id,
    'ancestors',       COALESCE(v_ancestors, '[]'::jsonb),
    'chainTruncated',  COALESCE(v_truncated, FALSE),
    'depthReached',    COALESCE(v_depth_reached, 0)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_chain_traverse_up: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_chain_traverse_up(BIGINT, BIGINT, INTEGER) IS
  'M9 — recursive ancestors traversal up to p_max_depth. UNION of party_relationship (tenant-scoped) + party self-FK shortcuts (single-tenant per Q-DA7). Silent cap with chainTruncated metadata flag (Q-DA3=3a). Mig-122 dedupes (party_id, depth, via) convergent paths. Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_chain_traverse_up(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_chain_traverse_up(BIGINT, BIGINT, INTEGER) TO neondb_owner;


-- ============================================================
-- 4.3 fn_party_chain_traverse_down — dedupe (party_id, depth, via)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_chain_traverse_down(
  p_actor_id   BIGINT,
  p_party_id   BIGINT,
  p_max_depth  INTEGER DEFAULT 5
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_descendants    JSONB;
  v_truncated      BOOLEAN;
  v_depth_reached  INTEGER;
BEGIN
  IF NOT fn_current_user_has_permission('party.graph.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_max_depth IS NULL OR p_max_depth < 1 OR p_max_depth > 10 THEN
    RAISE EXCEPTION 'maxDepth:max_depth_out_of_range' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_party_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;

  WITH RECURSIVE chain AS (
    SELECT
      p_party_id::bigint    AS party_id,
      0                     AS depth,
      NULL::text            AS relationship_type,
      NULL::numeric         AS ownership_pct,
      NULL::text            AS via,
      ARRAY[p_party_id]::bigint[] AS visited,
      FALSE                 AS cycle_hit
    UNION ALL
    SELECT
      hop.hop_party_id,
      c.depth + 1,
      hop.relationship_type,
      hop.ownership_pct,
      hop.via,
      c.visited || hop.hop_party_id,
      hop.hop_party_id = ANY(c.visited)
    FROM chain c
    CROSS JOIN LATERAL (
      SELECT
        pr.child_id      AS hop_party_id,
        pr.relationship_type,
        pr.ownership_pct,
        'edge'::text     AS via
      FROM party_relationship pr
      WHERE pr.parent_id = c.party_id
        AND pr.is_active = TRUE
        AND pr.tenant_id = v_tenant_id
      UNION ALL
      SELECT
        pa.id, 'parent'::text, NULL::numeric, 'self_fk_parent'::text
      FROM party pa
      WHERE pa.parent_id = c.party_id AND pa.is_active = TRUE
      UNION ALL
      SELECT
        pa.id, 'ubo'::text, NULL::numeric, 'self_fk_ubo'::text
      FROM party pa
      WHERE pa.ubo_id = c.party_id AND pa.is_active = TRUE
    ) hop
    WHERE c.depth < p_max_depth
      AND NOT c.cycle_hit
      AND hop.hop_party_id IS NOT NULL
      AND NOT (hop.hop_party_id = ANY(c.visited))
  ),
  descendants_with_party AS (
    SELECT
      c.party_id,
      c.depth,
      c.relationship_type,
      c.ownership_pct,
      c.via,
      p.name_en,
      p.name_ar,
      p.sanctions_status
    FROM chain c
    JOIN party p ON p.id = c.party_id
    WHERE c.depth > 0
  ),
  -- DEDUPE — same pattern as the up-traversal
  descendants_dedup AS (
    SELECT DISTINCT ON (party_id, depth, via)
      party_id,
      depth,
      relationship_type,
      ownership_pct,
      via,
      name_en,
      name_ar,
      sanctions_status
    FROM descendants_with_party
    ORDER BY party_id, depth, via, ownership_pct DESC NULLS LAST, relationship_type ASC
  ),
  truncation AS (
    SELECT
      bool_or(depth >= p_max_depth) AS hit_cap,
      bool_or(cycle_hit)            AS hit_cycle,
      MAX(depth)                    AS depth_reached
    FROM chain
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'partyId',           a.party_id,
      'depth',             a.depth,
      'relationshipType',  a.relationship_type,
      'ownershipPct',      a.ownership_pct,
      'sanctionsStatus',   a.sanctions_status,
      'nameEn',            a.name_en,
      'nameAr',            a.name_ar,
      'via',               a.via
    ) ORDER BY a.depth, a.party_id, a.via), '[]'::jsonb),
    (SELECT COALESCE(hit_cap, FALSE) OR COALESCE(hit_cycle, FALSE) FROM truncation),
    (SELECT COALESCE(depth_reached, 0) FROM truncation)
  INTO v_descendants, v_truncated, v_depth_reached
  FROM descendants_dedup a;

  RETURN jsonb_build_object(
    'rootPartyId',     p_party_id,
    'descendants',     COALESCE(v_descendants, '[]'::jsonb),
    'chainTruncated',  COALESCE(v_truncated, FALSE),
    'depthReached',    COALESCE(v_depth_reached, 0)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_chain_traverse_down: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_chain_traverse_down(BIGINT, BIGINT, INTEGER) IS
  'M9 — recursive descendants traversal up to p_max_depth. UNION of party_relationship (tenant-scoped) + party self-FK inverse shortcuts (single-tenant per Q-DA7). Silent cap with chainTruncated metadata flag (Q-DA3=3a). Mig-122 dedupes (party_id, depth, via) convergent paths. Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_chain_traverse_down(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_chain_traverse_down(BIGINT, BIGINT, INTEGER) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (122, 'crb_dedupe_chain_summary', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Re-apply 119_crb_party_chain_functions.sql to restore non-dedupe bodies.
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 122;
-- COMMIT;
