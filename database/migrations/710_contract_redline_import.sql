-- ============================================================================
-- Migration 710 — Counterparty redline upload + diff (Scenario 2)
-- ============================================================================
-- A drafter uploads the counterparty's returned contract file (.docx/.pdf). The
-- BE extracts its text (mammoth / pdf-parse — reused from tpa-analyzer), splits
-- both our current contract_version body and theirs into "## " clause sections,
-- and computes a clause-section diff (added / removed / modified). The drafter
-- accepts or rejects each change; accepted changes are assembled into a new
-- contract_version (via fn_contract_version_create).
--
-- Storage: two plain tables (no RLS / no audit trigger — access is enforced by
-- the DEFINER fn permission gates; reached via contract_id, which carries no
-- tenant_id in this schema). The diff itself is computed in the BE (text work);
-- these fns persist + serve + decide + mark-applied.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS contract_redline_import (
  id                     BIGSERIAL PRIMARY KEY,
  contract_id            BIGINT NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  base_version_number    INTEGER NOT NULL,
  filename               TEXT NOT NULL,
  mime_type              TEXT,
  engine                 TEXT,
  status                 TEXT NOT NULL DEFAULT 'review'
                           CHECK (status IN ('review', 'applied', 'discarded')),
  changes_total          INTEGER NOT NULL DEFAULT 0,
  changes_added          INTEGER NOT NULL DEFAULT 0,
  changes_removed        INTEGER NOT NULL DEFAULT 0,
  changes_modified       INTEGER NOT NULL DEFAULT 0,
  applied_version_number INTEGER,
  extracted_text         TEXT,
  data_classification    VARCHAR(20) NOT NULL DEFAULT 'demo',
  is_active              BOOLEAN NOT NULL DEFAULT TRUE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by             BIGINT,
  updated_by             BIGINT
);
CREATE INDEX IF NOT EXISTS idx_redline_import_contract
  ON contract_redline_import (contract_id, created_at DESC);

CREATE TABLE IF NOT EXISTS contract_redline_change (
  id              BIGSERIAL PRIMARY KEY,
  import_id       BIGINT NOT NULL REFERENCES contract_redline_import(id) ON DELETE CASCADE,
  seq             INTEGER NOT NULL DEFAULT 0,
  clause_id       TEXT,
  clause_heading  TEXT,
  change_type     TEXT NOT NULL CHECK (change_type IN ('added', 'removed', 'modified')),
  our_text        TEXT,
  their_text      TEXT,
  decision        TEXT NOT NULL DEFAULT 'pending'
                    CHECK (decision IN ('pending', 'accepted', 'rejected')),
  decided_by      BIGINT,
  decided_at      TIMESTAMPTZ,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_redline_change_import
  ON contract_redline_change (import_id, seq);

COMMENT ON TABLE contract_redline_import IS
  '710: a counterparty redline upload + its computed clause-section diff vs the contract body at base_version_number. status review→applied/discarded.';
COMMENT ON TABLE contract_redline_change IS
  '710: one row per clause-section change in a redline import (added/removed/modified) + the drafter''s accept/reject decision.';

-- ── Permission helpers (inline) ─────────────────────────────────────────────
-- read: any contract read/draft/edit scope; write: contract.edit or contract.draft.

CREATE OR REPLACE FUNCTION fn_contract_redline_import_create(
  p_actor_id     BIGINT,
  p_contract_id  BIGINT,
  p_filename     TEXT,
  p_mime         TEXT,
  p_engine       TEXT,
  p_base_version INTEGER,
  p_extracted    TEXT,
  p_changes      JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_import_id BIGINT;
  v_ch        JSONB;
  v_added     INT := 0;
  v_removed   INT := 0;
  v_modified  INT := 0;
  v_seq       INT := 0;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.edit')
       OR fn_current_user_has_permission('contract.draft')) THEN
    RAISE EXCEPTION 'forbidden: contract.edit or contract.draft required' USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contract not found' USING ERRCODE = '22023';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'array' THEN
    RAISE EXCEPTION 'changes must be a JSON array' USING ERRCODE = '22023';
  END IF;

  INSERT INTO contract_redline_import
    (contract_id, base_version_number, filename, mime_type, engine, extracted_text,
     created_by, updated_by)
  VALUES
    (p_contract_id, p_base_version, p_filename, p_mime, p_engine, left(p_extracted, 200000),
     p_actor_id, p_actor_id)
  RETURNING id INTO v_import_id;

  FOR v_ch IN SELECT * FROM jsonb_array_elements(p_changes)
  LOOP
    v_seq := v_seq + 1;
    INSERT INTO contract_redline_change
      (import_id, seq, clause_id, clause_heading, change_type, our_text, their_text)
    VALUES (
      v_import_id, v_seq,
      v_ch->>'clauseId', v_ch->>'clauseHeading', v_ch->>'changeType',
      v_ch->>'ourText', v_ch->>'theirText'
    );
    CASE v_ch->>'changeType'
      WHEN 'added'    THEN v_added := v_added + 1;
      WHEN 'removed'  THEN v_removed := v_removed + 1;
      WHEN 'modified' THEN v_modified := v_modified + 1;
      ELSE NULL;
    END CASE;
  END LOOP;

  UPDATE contract_redline_import
     SET changes_total = v_seq, changes_added = v_added,
         changes_removed = v_removed, changes_modified = v_modified
   WHERE id = v_import_id;

  RETURN fn_contract_redline_import_get(p_actor_id, v_import_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION fn_contract_redline_import_get(
  p_actor_id   BIGINT,
  p_import_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_imp RECORD;
  v_changes JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.read.own')
       OR fn_current_user_has_permission('contract.draft')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: contract read permission required' USING ERRCODE = '42501';
  END IF;

  SELECT ri.*, c.contract_number, c.current_version
    INTO v_imp
  FROM contract_redline_import ri
  JOIN contract c ON c.id = ri.contract_id
  WHERE ri.id = p_import_id AND ri.is_active = TRUE;
  IF v_imp.id IS NULL THEN
    RAISE EXCEPTION 'Redline import not found' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', id, 'seq', seq, 'clauseId', clause_id, 'clauseHeading', clause_heading,
           'changeType', change_type, 'ourText', our_text, 'theirText', their_text,
           'decision', decision, 'decidedAt', decided_at
         ) ORDER BY seq), '[]'::jsonb)
    INTO v_changes
  FROM contract_redline_change WHERE import_id = p_import_id AND is_active = TRUE;

  RETURN jsonb_build_object(
    'id', v_imp.id,
    'contractId', v_imp.contract_id,
    'contractNumber', v_imp.contract_number,
    'baseVersionNumber', v_imp.base_version_number,
    'currentVersion', v_imp.current_version,
    'filename', v_imp.filename,
    'engine', v_imp.engine,
    'status', v_imp.status,
    'counts', jsonb_build_object('total', v_imp.changes_total, 'added', v_imp.changes_added,
                                 'removed', v_imp.changes_removed, 'modified', v_imp.changes_modified),
    'appliedVersionNumber', v_imp.applied_version_number,
    'createdAt', v_imp.created_at,
    'changes', v_changes
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION fn_contract_redline_import_list(
  p_actor_id    BIGINT,
  p_contract_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_rows JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.read.own')
       OR fn_current_user_has_permission('contract.draft')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: contract read permission required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', ri.id, 'filename', ri.filename, 'status', ri.status,
           'baseVersionNumber', ri.base_version_number,
           'appliedVersionNumber', ri.applied_version_number,
           'counts', jsonb_build_object('total', ri.changes_total, 'added', ri.changes_added,
                                        'removed', ri.changes_removed, 'modified', ri.changes_modified),
           'createdAt', ri.created_at
         ) ORDER BY ri.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM contract_redline_import ri
  WHERE ri.contract_id = p_contract_id AND ri.is_active = TRUE;

  RETURN jsonb_build_object('data', v_rows);
END;
$fn$;

CREATE OR REPLACE FUNCTION fn_contract_redline_change_decide(
  p_actor_id   BIGINT,
  p_change_id  BIGINT,
  p_decision   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_import_id BIGINT;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.edit')
       OR fn_current_user_has_permission('contract.draft')) THEN
    RAISE EXCEPTION 'forbidden: contract.edit or contract.draft required' USING ERRCODE = '42501';
  END IF;
  IF p_decision NOT IN ('pending', 'accepted', 'rejected') THEN
    RAISE EXCEPTION 'Invalid decision' USING ERRCODE = '22023';
  END IF;

  UPDATE contract_redline_change
     SET decision = p_decision,
         decided_by = CASE WHEN p_decision = 'pending' THEN NULL ELSE p_actor_id END,
         decided_at = CASE WHEN p_decision = 'pending' THEN NULL ELSE now() END,
         updated_at = now()
   WHERE id = p_change_id AND is_active = TRUE
   RETURNING import_id INTO v_import_id;
  IF v_import_id IS NULL THEN
    RAISE EXCEPTION 'Change not found' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object('id', p_change_id, 'decision', p_decision, 'importId', v_import_id);
END;
$fn$;

-- Mark an import applied (called by BE after fn_contract_version_create).
CREATE OR REPLACE FUNCTION fn_contract_redline_import_set_status(
  p_actor_id          BIGINT,
  p_import_id         BIGINT,
  p_status            TEXT,
  p_applied_version   INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT (fn_current_user_has_permission('contract.edit')
       OR fn_current_user_has_permission('contract.draft')) THEN
    RAISE EXCEPTION 'forbidden: contract.edit or contract.draft required' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('review', 'applied', 'discarded') THEN
    RAISE EXCEPTION 'Invalid status' USING ERRCODE = '22023';
  END IF;

  UPDATE contract_redline_import
     SET status = p_status,
         applied_version_number = COALESCE(p_applied_version, applied_version_number),
         updated_by = p_actor_id, updated_at = now()
   WHERE id = p_import_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Redline import not found' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object('id', p_import_id, 'status', p_status, 'appliedVersionNumber', p_applied_version);
END;
$fn$;

REVOKE ALL ON FUNCTION fn_contract_redline_import_create(BIGINT, BIGINT, TEXT, TEXT, TEXT, INTEGER, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_import_get(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_import_list(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_contract_redline_import_set_status(BIGINT, BIGINT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_redline_import_create(BIGINT, BIGINT, TEXT, TEXT, TEXT, INTEGER, TEXT, JSONB) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_import_get(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_import_list(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_contract_redline_import_set_status(BIGINT, BIGINT, TEXT, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (710, 'contract_redline_import', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DROP FUNCTION IF EXISTS fn_contract_redline_import_set_status(BIGINT, BIGINT, TEXT, INTEGER);
-- DROP FUNCTION IF EXISTS fn_contract_redline_change_decide(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_contract_redline_import_list(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_contract_redline_import_get(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_contract_redline_import_create(BIGINT, BIGINT, TEXT, TEXT, TEXT, INTEGER, TEXT, JSONB);
-- DROP TABLE IF EXISTS contract_redline_change;
-- DROP TABLE IF EXISTS contract_redline_import;
-- DELETE FROM schema_migrations WHERE version = 710;
-- ROLLBACK END
-- ============================================================================
