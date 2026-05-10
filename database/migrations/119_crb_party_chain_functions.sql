-- Migration: 119_crb_party_chain_functions.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: 4 fn_'s — fn_party_chain_traverse_up / _down (STABLE recursive CTE),
--              fn_party_chain_summary (STABLE wrapper), fn_party_sanctions_match (STABLE pg_trgm fuzzy match + chain expansion).
--              Each with COMMENT + REVOKE/GRANT trio tail.
-- Rollback: DROP FUNCTION ... (4 fns)

BEGIN;

-- ============================================================
-- 4.2 fn_party_chain_traverse_up — ancestors via party_relationship + self-FK shortcuts
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
  -- v_tenant_id may be NULL when called outside an HTTP-context (e.g., admin SQL probe).
  -- In that case SOURCE A returns no rows; SOURCE B (single-tenant self-FK) still walks. Q-DA7.

  -- 5. Recursive CTE
  WITH RECURSIVE chain AS (
    -- Seed: root party at depth 0
    SELECT
      p_party_id::bigint    AS party_id,
      0                     AS depth,
      NULL::text            AS relationship_type,
      NULL::numeric         AS ownership_pct,
      NULL::text            AS via,
      ARRAY[p_party_id]::bigint[] AS visited,
      FALSE                 AS cycle_hit
    UNION ALL
    -- Step: hop UP (toward parents)
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
      -- SOURCE A — party_relationship edges (tenant-scoped)
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
      -- SOURCE B — party self-FK shortcuts (single-tenant per Q-DA7)
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
    ) ORDER BY a.depth, a.party_id), '[]'::jsonb),
    (SELECT COALESCE(hit_cap, FALSE) OR COALESCE(hit_cycle, FALSE) FROM truncation),
    (SELECT COALESCE(depth_reached, 0) FROM truncation),
    (SELECT COALESCE(hit_cycle, FALSE) FROM truncation)
  INTO v_ancestors, v_truncated, v_depth_reached, v_cycle_hit_any
  FROM ancestors_with_party a;

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
  'M9 — recursive ancestors traversal up to p_max_depth. UNION of party_relationship (tenant-scoped) + party self-FK shortcuts (single-tenant per Q-DA7). Silent cap with chainTruncated metadata flag (Q-DA3=3a). Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_chain_traverse_up(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_chain_traverse_up(BIGINT, BIGINT, INTEGER) TO neondb_owner;


-- ============================================================
-- 4.3 fn_party_chain_traverse_down — descendants
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
      -- SOURCE A — party_relationship edges (tenant-scoped). Walk parent_id -> child_id (downward).
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
      -- SOURCE B — inverse self-FK shortcut (single-tenant). Other parties whose parent_id = current.
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
    ) ORDER BY a.depth, a.party_id), '[]'::jsonb),
    (SELECT COALESCE(hit_cap, FALSE) OR COALESCE(hit_cycle, FALSE) FROM truncation),
    (SELECT COALESCE(depth_reached, 0) FROM truncation)
  INTO v_descendants, v_truncated, v_depth_reached
  FROM descendants_with_party a;

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
  'M9 — recursive descendants traversal up to p_max_depth. UNION of party_relationship (tenant-scoped) + party self-FK inverse shortcuts (single-tenant per Q-DA7). Silent cap with chainTruncated metadata flag (Q-DA3=3a). Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_chain_traverse_down(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_chain_traverse_down(BIGINT, BIGINT, INTEGER) TO neondb_owner;


-- ============================================================
-- 4.4 fn_party_chain_summary — single-roundtrip wrapper
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_chain_summary(
  p_actor_id   BIGINT,
  p_party_id   BIGINT,
  p_max_depth  INTEGER DEFAULT 5
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_up                    JSONB;
  v_down                  JSONB;
  v_root                  JSONB;
  v_ancestors_by_depth    JSONB;
  v_descendants_by_depth  JSONB;
  v_counts                JSONB;
  v_truncated             BOOLEAN;
  v_tenant_id             UUID;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 2. Existence pre-check
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_party_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 3. Call the two traversal fns (delegated permission + bounds checks)
  v_up   := fn_party_chain_traverse_up(p_actor_id, p_party_id, p_max_depth);
  v_down := fn_party_chain_traverse_down(p_actor_id, p_party_id, p_max_depth);

  -- 4. Root party light projection
  SELECT jsonb_build_object(
    'id',              p.id,
    'nameEn',          p.name_en,
    'nameAr',          p.name_ar,
    'sanctionsStatus', p.sanctions_status,
    'esgScore',        p.esg_score,
    'icvStatus',       p.icv_status,
    'icvPct',          p.icv_pct
  ) INTO v_root
  FROM party p
  WHERE p.id = p_party_id;

  -- 5. ancestorsByDepth — pivot v_up.ancestors[] grouped by depth (S2-24: inner subquery + outer aggregate)
  WITH a AS (
    SELECT
      (e->>'depth')::int AS depth,
      e                  AS node
    FROM jsonb_array_elements(v_up->'ancestors') e
  ),
  grouped AS (
    SELECT depth, jsonb_agg(node ORDER BY (node->>'partyId')::bigint) AS nodes
    FROM a
    GROUP BY depth
  )
  SELECT COALESCE(jsonb_object_agg(depth::text, nodes), '{}'::jsonb)
    INTO v_ancestors_by_depth
  FROM grouped;

  -- 6. descendantsByDepth — same pattern
  WITH d AS (
    SELECT
      (e->>'depth')::int AS depth,
      e                  AS node
    FROM jsonb_array_elements(v_down->'descendants') e
  ),
  grouped AS (
    SELECT depth, jsonb_agg(node ORDER BY (node->>'partyId')::bigint) AS nodes
    FROM d
    GROUP BY depth
  )
  SELECT COALESCE(jsonb_object_agg(depth::text, nodes), '{}'::jsonb)
    INTO v_descendants_by_depth
  FROM grouped;

  -- 7. directRelationshipCounts — all 6 keys with default 0 (AC-S8-03 invariant)
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;

  WITH direct AS (
    SELECT pr.relationship_type AS rt
    FROM party_relationship pr
    WHERE pr.is_active = TRUE
      AND pr.tenant_id = v_tenant_id
      AND (pr.parent_id = p_party_id OR pr.child_id = p_party_id)
  )
  SELECT jsonb_build_object(
    'parent',                  COUNT(*) FILTER (WHERE rt = 'parent'),
    'ubo',                     COUNT(*) FILTER (WHERE rt = 'ubo'),
    'subsidiary',              COUNT(*) FILTER (WHERE rt = 'subsidiary'),
    'sub_contractor',          COUNT(*) FILTER (WHERE rt = 'sub_contractor'),
    'jv',                      COUNT(*) FILTER (WHERE rt = 'jv'),
    'controlling_shareholder', COUNT(*) FILTER (WHERE rt = 'controlling_shareholder')
  ) INTO v_counts
  FROM direct;

  -- 8. chainTruncated rollup
  v_truncated := COALESCE((v_up->>'chainTruncated')::boolean, FALSE)
              OR COALESCE((v_down->>'chainTruncated')::boolean, FALSE);

  RETURN jsonb_build_object(
    'rootParty',                v_root,
    'ancestorsByDepth',         COALESCE(v_ancestors_by_depth, '{}'::jsonb),
    'descendantsByDepth',       COALESCE(v_descendants_by_depth, '{}'::jsonb),
    'directRelationshipCounts', COALESCE(v_counts, jsonb_build_object(
       'parent', 0, 'ubo', 0, 'subsidiary', 0,
       'sub_contractor', 0, 'jv', 0, 'controlling_shareholder', 0
    )),
    'chainTruncated',           COALESCE(v_truncated, FALSE)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_chain_summary: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_chain_summary(BIGINT, BIGINT, INTEGER) IS
  'M9 — single-roundtrip wrapper for party detail view. Combines fn_party_chain_traverse_up + fn_party_chain_traverse_down + by-depth pivots + relationship-type histogram (always-6-keys per AC-S8-03). chainTruncated rolls up from either direction. Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_chain_summary(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_chain_summary(BIGINT, BIGINT, INTEGER) TO neondb_owner;


-- ============================================================
-- 4.5 fn_party_sanctions_match — pg_trgm fuzzy match + chain expansion (return-only per Q-DA4)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_sanctions_match(
  p_actor_id              BIGINT,
  p_signal_entities       JSONB,
  p_similarity_threshold  NUMERIC(3,2) DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_threshold  NUMERIC;
  v_matches    JSONB;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('party.graph.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 2. Shape validation
  IF p_signal_entities IS NULL
     OR jsonb_typeof(p_signal_entities) <> 'array'
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_signal_entities) e
       WHERE jsonb_typeof(e) <> 'object'
          OR (e->>'name') IS NULL
          OR length(trim(e->>'name')) = 0
     ) THEN
    RAISE EXCEPTION 'invalid_signal_entities_shape' USING ERRCODE = '22023';
  END IF;

  -- 3. Resolve threshold (per-call > GUC > 0.7 default)
  v_threshold := COALESCE(
    p_similarity_threshold,
    NULLIF(current_setting('app.party_sanctions_match_threshold', true), '')::numeric,
    0.7
  );

  -- 4. Direct + chain-expansion matches
  WITH signal_entities AS (
    SELECT
      e->>'name' AS entity_name
    FROM jsonb_array_elements(p_signal_entities) e
    WHERE length(trim(e->>'name')) > 0
  ),
  -- 4a. Direct name matches
  direct_name AS (
    SELECT DISTINCT
      se.entity_name                          AS matched_entity_name,
      p.id                                    AS party_id,
      p.name_en                               AS name,
      'direct_name'::text                     AS match_type,
      similarity(p.name_en, se.entity_name)   AS sim
    FROM signal_entities se
    JOIN party p ON p.is_active = TRUE
    WHERE similarity(p.name_en, se.entity_name) >= v_threshold
  ),
  -- 4b. Direct alias matches (any string element of party.aliases)
  direct_alias AS (
    SELECT
      se.entity_name                                         AS matched_entity_name,
      p.id                                                   AS party_id,
      p.name_en                                              AS name,
      'direct_alias'::text                                   AS match_type,
      MAX(similarity(alias_elem #>> '{}', se.entity_name))   AS sim
    FROM signal_entities se
    JOIN party p ON p.is_active = TRUE
    JOIN LATERAL jsonb_array_elements(p.aliases) alias_elem ON TRUE
    WHERE similarity(alias_elem #>> '{}', se.entity_name) >= v_threshold
    GROUP BY se.entity_name, p.id, p.name_en
  ),
  -- 4c. Combine direct matches; one row per (party_id, matched_entity_name) keeping highest sim across name/alias
  direct AS (
    SELECT * FROM direct_name
    UNION ALL
    SELECT * FROM direct_alias
  ),
  direct_dedup AS (
    SELECT DISTINCT ON (party_id, matched_entity_name)
      matched_entity_name, party_id, name, match_type, sim
    FROM direct
    ORDER BY party_id, matched_entity_name, sim DESC
  ),
  -- 4d. Chain ancestors of each direct match (parties UP the chain — they are above the matched/sanctioned party)
  chain_ancestors AS (
    SELECT
      d.matched_entity_name,
      (anc->>'partyId')::bigint                                   AS party_id,
      (anc->>'nameEn')::text                                      AS name,
      'chain_ancestor'::text                                      AS match_type,
      d.sim                                                       AS sim,
      jsonb_build_array(
        jsonb_build_object(
          'partyId',          (anc->>'partyId')::bigint,
          'depth',            (anc->>'depth')::int,
          'relationshipType', anc->>'relationshipType'
        )
      ) AS chain_path
    FROM direct_dedup d
    CROSS JOIN LATERAL jsonb_array_elements(
      (fn_party_chain_traverse_up(p_actor_id, d.party_id, 5))->'ancestors'
    ) anc
  ),
  -- 4e. Chain descendants of each direct match (parties DOWN the chain — OFAC chain hero scenario)
  chain_descendants AS (
    SELECT
      d.matched_entity_name,
      (desc_n->>'partyId')::bigint                                AS party_id,
      (desc_n->>'nameEn')::text                                   AS name,
      'chain_descendant'::text                                    AS match_type,
      d.sim                                                       AS sim,
      jsonb_build_array(
        jsonb_build_object(
          'partyId',          (desc_n->>'partyId')::bigint,
          'depth',            (desc_n->>'depth')::int,
          'relationshipType', desc_n->>'relationshipType'
        )
      ) AS chain_path
    FROM direct_dedup d
    CROSS JOIN LATERAL jsonb_array_elements(
      (fn_party_chain_traverse_down(p_actor_id, d.party_id, 5))->'descendants'
    ) desc_n
  ),
  -- 4f. Combine all matches; chain matches keep direct's sim score
  all_matches AS (
    SELECT
      matched_entity_name, party_id, name, match_type, sim,
      NULL::jsonb AS chain_path
    FROM direct_dedup
    UNION ALL
    SELECT matched_entity_name, party_id, name, match_type, sim, chain_path FROM chain_ancestors
    UNION ALL
    SELECT matched_entity_name, party_id, name, match_type, sim, chain_path FROM chain_descendants
  ),
  -- 4g. Deduplicate by (party_id, matched_entity_name): direct beats chain; otherwise highest sim
  ranked AS (
    SELECT
      matched_entity_name, party_id, name, match_type, sim, chain_path,
      ROW_NUMBER() OVER (
        PARTITION BY party_id, matched_entity_name
        ORDER BY
          CASE match_type
            WHEN 'direct_name'      THEN 1
            WHEN 'direct_alias'     THEN 2
            WHEN 'chain_descendant' THEN 3
            WHEN 'chain_ancestor'   THEN 4
          END,
          sim DESC NULLS LAST
      ) AS rn
    FROM all_matches
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'partyId',           party_id,
    'name',              name,
    'matchedEntityName', matched_entity_name,
    'matchType',         match_type,
    'similarity',        sim,
    'chainPath',         chain_path
  ) ORDER BY sim DESC NULLS LAST, party_id), '[]'::jsonb)
    INTO v_matches
  FROM ranked
  WHERE rn = 1;

  RETURN jsonb_build_object(
    'matches', COALESCE(v_matches, '[]'::jsonb)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_sanctions_match: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_sanctions_match(BIGINT, JSONB, NUMERIC) IS
  'M9 — pg_trgm fuzzy match (threshold = per-call > app.party_sanctions_match_threshold GUC > 0.7) on party.name_en + aliases, expanded via fn_party_chain_traverse_up/_down. RETURN-ONLY per Q-DA4=4a — does NOT update party.sanctions_status. Permission: party.graph.read.';
REVOKE EXECUTE ON FUNCTION fn_party_sanctions_match(BIGINT, JSONB, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_sanctions_match(BIGINT, JSONB, NUMERIC) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (119, 'crb_party_chain_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_party_sanctions_match(BIGINT, JSONB, NUMERIC);
-- DROP FUNCTION IF EXISTS fn_party_chain_summary(BIGINT, BIGINT, INTEGER);
-- DROP FUNCTION IF EXISTS fn_party_chain_traverse_down(BIGINT, BIGINT, INTEGER);
-- DROP FUNCTION IF EXISTS fn_party_chain_traverse_up(BIGINT, BIGINT, INTEGER);
-- DELETE FROM schema_migrations WHERE version = 119;
-- COMMIT;
