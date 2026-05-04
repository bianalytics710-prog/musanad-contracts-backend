-- ============================================================================
-- 024_m2_approval_tables_rls_indexes.sql — Approval tables + indexes + RLS
-- ============================================================================
-- Module:    M2 (Approval Workflows)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   023_m2_extend_contract_status_check.sql,
--            001_foundation.sql (fn_audit_trigger, fn_current_user_has_permission),
--            003_m1a_contracts.sql (contract).
-- ----------------------------------------------------------------------------
-- Creates 4 new tables (approval_matrix, approval_chain, approval_step,
-- approval_decision), their indexes, FORCE RLS with 14 policies, audit
-- triggers binding each to fn_audit_trigger, and 3 BEFORE UPDATE
-- immutability triggers (M2-NEW-2 anti-reassignment via OLD vs NEW
-- comparison instead of self-referencing RLS subqueries — Codex BE-M1c-C1).
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. approval_matrix (master / admin-configurable rules)
-- ============================================================
CREATE TABLE approval_matrix (
  id                       BIGSERIAL PRIMARY KEY,
  contract_type            VARCHAR(50) NOT NULL,
  min_value_aed            NUMERIC(15, 2) NOT NULL DEFAULT 0,
  max_value_aed            NUMERIC(15, 2) NULL,
  step_order               INTEGER NOT NULL,
  parallel_group           INTEGER NULL,
  approver_role            VARCHAR(50) NOT NULL,
  is_required              BOOLEAN NOT NULL DEFAULT TRUE,
  escalation_role          VARCHAR(50) NULL,
  escalation_after_hours   INTEGER NULL,
  created_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_approval_matrix_value_range
    CHECK (max_value_aed IS NULL OR max_value_aed >= min_value_aed),
  CONSTRAINT chk_approval_matrix_min_value_nonneg
    CHECK (min_value_aed >= 0),
  CONSTRAINT chk_approval_matrix_step_order_pos
    CHECK (step_order >= 1),
  CONSTRAINT chk_approval_matrix_parallel_eq_step
    CHECK (parallel_group IS NULL OR parallel_group = step_order),
  CONSTRAINT chk_approval_matrix_escalation_hours_pos
    CHECK (escalation_after_hours IS NULL OR escalation_after_hours > 0),
  CONSTRAINT chk_approval_matrix_contract_type
    CHECK (contract_type IN (
      'employment','msa','sow','nda','vendor','partnership','consulting','other'
    ))
);

COMMENT ON TABLE approval_matrix IS
  'M2 admin-configurable approval rules. Per (contract_type, value range) define ordered approval steps with parallel groups, escalation, and required flags. Drives fn_approval_route_init via snapshot.';
COMMENT ON COLUMN approval_matrix.parallel_group IS
  'G2 first-class. NULL = sequential single step; integer = peers in parallel within step_order. Constraint: parallel_group = step_order when set (AC-S5-05).';
COMMENT ON COLUMN approval_matrix.is_required IS
  'G2 first-class. Drives all-of vs any-of rule for parallel groups (analysisNote-5 interpretation A).';

CREATE INDEX idx_approval_matrix_lookup
  ON approval_matrix (contract_type, min_value_aed, max_value_aed)
  WHERE is_active = TRUE;
CREATE INDEX idx_approval_matrix_active
  ON approval_matrix (id) WHERE is_active = TRUE;
CREATE INDEX idx_approval_matrix_contract_type_step
  ON approval_matrix (contract_type, step_order, parallel_group NULLS FIRST)
  WHERE is_active = TRUE;
CREATE INDEX idx_approval_matrix_created_by
  ON approval_matrix (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_approval_matrix_updated_by
  ON approval_matrix (updated_by) WHERE updated_by IS NOT NULL;

CREATE UNIQUE INDEX uq_approval_matrix_active_rule
  ON approval_matrix (
    contract_type, min_value_aed, COALESCE(max_value_aed, '999999999999.99'::numeric),
    step_order, parallel_group, approver_role
  )
  WHERE is_active = TRUE;

-- ============================================================
-- 2. approval_chain (per-contract chain instance)
-- ============================================================
CREATE TABLE approval_chain (
  id                  BIGSERIAL PRIMARY KEY,
  contract_id         BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  matrix_snapshot     JSONB NOT NULL,
  status              VARCHAR(30) NOT NULL DEFAULT 'in_progress'
                        CHECK (status IN ('in_progress','approved','rejected','resubmission_requested','cancelled')),
  current_step_order  INTEGER NOT NULL DEFAULT 1
                        CHECK (current_step_order >= 1),
  initiated_by        BIGINT NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  initiated_at        TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at        TIMESTAMP WITH TIME ZONE NULL,
  created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_approval_chain_completed_at_status
    CHECK (
      (status IN ('approved','rejected','resubmission_requested','cancelled') AND completed_at IS NOT NULL)
      OR
      (status = 'in_progress' AND completed_at IS NULL)
    )
);

COMMENT ON TABLE approval_chain IS
  'M2 per-contract approval chain instance. One chain per submission of a contract for approval. matrix_snapshot frozen at init. At most one chain per contract may be in_progress at any time.';
COMMENT ON COLUMN approval_chain.matrix_snapshot IS
  'Frozen JSONB copy of approval_matrix rules used to generate this chain. Immutable post-creation (M2-NEW-2 — trg_approval_chain_immutable_fields). Sensitive — included in fn_audit_trigger redact list (migration 029).';

CREATE UNIQUE INDEX uq_approval_chain_one_active_per_contract
  ON approval_chain (contract_id)
  WHERE status = 'in_progress' AND is_active = TRUE;
CREATE INDEX idx_approval_chain_contract_id ON approval_chain (contract_id);
CREATE INDEX idx_approval_chain_status_initiated_at
  ON approval_chain (status, initiated_at DESC) WHERE is_active = TRUE;
CREATE INDEX idx_approval_chain_initiated_by
  ON approval_chain (initiated_by) WHERE is_active = TRUE;
CREATE INDEX idx_approval_chain_active
  ON approval_chain (id) WHERE is_active = TRUE;
CREATE INDEX idx_approval_chain_created_by
  ON approval_chain (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_approval_chain_updated_by
  ON approval_chain (updated_by) WHERE updated_by IS NOT NULL;

-- ============================================================
-- 3. approval_step (one row per approver in a chain)
-- ============================================================
CREATE TABLE approval_step (
  id                       BIGSERIAL PRIMARY KEY,
  approval_chain_id        BIGINT NOT NULL REFERENCES approval_chain(id) ON DELETE CASCADE,
  step_order               INTEGER NOT NULL,
  parallel_group           INTEGER NULL,
  approver_user_id         BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  approver_role            VARCHAR(50) NULL,
  is_required              BOOLEAN NOT NULL DEFAULT TRUE,
  escalation_role          VARCHAR(50) NULL,
  escalation_after_hours   INTEGER NULL,
  reassigned_to            BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  delegated_to             BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  status                   VARCHAR(30) NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending','approved','rejected','resubmission_requested','escalated','reassigned','delegated','skipped')),
  decided_at               TIMESTAMP WITH TIME ZONE NULL,
  created_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_approval_step_step_order_pos
    CHECK (step_order >= 1),
  CONSTRAINT chk_approval_step_escalation_hours_pos
    CHECK (escalation_after_hours IS NULL OR escalation_after_hours > 0),
  CONSTRAINT chk_approval_step_assignment
    CHECK (approver_user_id IS NOT NULL OR approver_role IS NOT NULL),
  CONSTRAINT chk_approval_step_parallel_eq_step
    CHECK (parallel_group IS NULL OR parallel_group = step_order),
  CONSTRAINT chk_approval_step_decided_at_terminal
    CHECK (
      (status = 'pending' AND decided_at IS NULL)
      OR
      (status IN ('approved','rejected','resubmission_requested','skipped') AND decided_at IS NOT NULL)
      OR
      (status IN ('escalated','reassigned','delegated'))
    )
);

COMMENT ON TABLE approval_step IS
  'M2 per-step row in an approval chain. Carries G2 first-class columns: parallel_group, is_required, escalation_role, escalation_after_hours, reassigned_to, delegated_to.';
COMMENT ON COLUMN approval_step.reassigned_to IS
  'G2 first-class. Distinct from delegated_to: reassignment is admin-forced override (fn_approval_reassign); delegation is voluntary by the assigned approver (fn_approval_delegate).';

CREATE INDEX idx_approval_step_chain_id
  ON approval_step (approval_chain_id);
CREATE INDEX idx_approval_step_chain_order
  ON approval_step (approval_chain_id, step_order, parallel_group NULLS FIRST);
CREATE INDEX idx_approval_step_approver_user_pending
  ON approval_step (approver_user_id, status)
  WHERE approver_user_id IS NOT NULL AND status = 'pending' AND is_active = TRUE;
CREATE INDEX idx_approval_step_approver_role_pending
  ON approval_step (approver_role, status)
  WHERE approver_role IS NOT NULL AND status = 'pending' AND is_active = TRUE;
CREATE INDEX idx_approval_step_delegated_to_pending
  ON approval_step (delegated_to, status)
  WHERE delegated_to IS NOT NULL AND status = 'pending' AND is_active = TRUE;
CREATE INDEX idx_approval_step_reassigned_to_pending
  ON approval_step (reassigned_to, status)
  WHERE reassigned_to IS NOT NULL AND status = 'pending' AND is_active = TRUE;
CREATE INDEX idx_approval_step_status_pending_escalation
  ON approval_step (escalation_after_hours, created_at)
  WHERE status = 'pending' AND escalation_after_hours IS NOT NULL AND is_active = TRUE;
CREATE INDEX idx_approval_step_active
  ON approval_step (id) WHERE is_active = TRUE;
CREATE INDEX idx_approval_step_created_by
  ON approval_step (created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_approval_step_updated_by
  ON approval_step (updated_by) WHERE updated_by IS NOT NULL;

-- ============================================================
-- 4. approval_decision (append-only decision audit log)
-- ============================================================
CREATE TABLE approval_decision (
  id                       BIGSERIAL PRIMARY KEY,
  approval_step_id         BIGINT NOT NULL REFERENCES approval_step(id) ON DELETE CASCADE,
  decision                 VARCHAR(30) NOT NULL
                             CHECK (decision IN ('approve','reject','request_resubmission','delegate','reassign','escalate')),
  decided_by               BIGINT NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  decision_note            TEXT NULL,
  delegated_to_user_id     BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  reassigned_to_user_id    BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  metadata                 JSONB NULL,
  decided_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_approval_decision_delegated_population
    CHECK (
      (decision = 'delegate' AND delegated_to_user_id IS NOT NULL)
      OR
      (decision <> 'delegate' AND delegated_to_user_id IS NULL)
    ),
  CONSTRAINT chk_approval_decision_reassigned_population
    CHECK (
      (decision = 'reassign' AND reassigned_to_user_id IS NOT NULL)
      OR
      (decision <> 'reassign' AND reassigned_to_user_id IS NULL)
    )
);

COMMENT ON TABLE approval_decision IS
  'M2 append-only decision log. One row per decision event (approve/reject/request_resubmission/delegate/reassign/escalate). RLS deny-update + deny-direct-delete; trigger trg_approval_decision_deny_update is the primary append-only enforcement.';
COMMENT ON COLUMN approval_decision.decision_note IS
  'Sensitive field. May contain internal commercial / legal commentary. Redacted by fn_audit_trigger (migration 029). Required at fn_ level for decision IN (reject, request_resubmission).';

CREATE INDEX idx_approval_decision_step_decided_at
  ON approval_decision (approval_step_id, decided_at DESC);
CREATE INDEX idx_approval_decision_decided_by
  ON approval_decision (decided_by, decided_at DESC);
CREATE INDEX idx_approval_decision_decision
  ON approval_decision (decision, decided_at DESC);
CREATE INDEX idx_approval_decision_active
  ON approval_decision (id) WHERE is_active = TRUE;
CREATE INDEX idx_approval_decision_created_by
  ON approval_decision (created_by) WHERE created_by IS NOT NULL;

-- ============================================================
-- 5. Audit triggers (fan-out to fn_audit_trigger)
-- ============================================================
CREATE TRIGGER audit_approval_matrix_changes
  AFTER INSERT OR UPDATE OR DELETE ON approval_matrix
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_approval_chain_changes
  AFTER INSERT OR UPDATE OR DELETE ON approval_chain
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_approval_step_changes
  AFTER INSERT OR UPDATE OR DELETE ON approval_step
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_approval_decision_changes
  AFTER INSERT OR UPDATE OR DELETE ON approval_decision
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================
-- 6. Immutability triggers (M2-NEW-2 — OLD vs NEW; not RLS subqueries)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trg_approval_chain_immutable_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.matrix_snapshot::text IS DISTINCT FROM OLD.matrix_snapshot::text THEN
    RAISE EXCEPTION
      'fn_trg_approval_chain_immutable_fields: matrix_snapshot is frozen at chain init'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.contract_id IS DISTINCT FROM OLD.contract_id THEN
    RAISE EXCEPTION
      'fn_trg_approval_chain_immutable_fields: contract_id cannot be reassigned'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.initiated_by IS DISTINCT FROM OLD.initiated_by THEN
    RAISE EXCEPTION
      'fn_trg_approval_chain_immutable_fields: initiated_by cannot be reassigned'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_approval_chain_immutable_fields
  BEFORE UPDATE ON approval_chain
  FOR EACH ROW EXECUTE FUNCTION fn_trg_approval_chain_immutable_fields();

CREATE OR REPLACE FUNCTION fn_trg_approval_step_immutable_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.approval_chain_id IS DISTINCT FROM OLD.approval_chain_id THEN
    RAISE EXCEPTION
      'fn_trg_approval_step_immutable_fields: approval_chain_id cannot be reassigned'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.step_order IS DISTINCT FROM OLD.step_order THEN
    RAISE EXCEPTION
      'fn_trg_approval_step_immutable_fields: step_order cannot be reassigned (use fn_approval_escalate to add peers)'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_approval_step_immutable_fields
  BEFORE UPDATE ON approval_step
  FOR EACH ROW EXECUTE FUNCTION fn_trg_approval_step_immutable_fields();

CREATE OR REPLACE FUNCTION fn_trg_approval_decision_deny_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'fn_trg_approval_decision_deny_update: approval_decision is append-only'
    USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_approval_decision_deny_update
  BEFORE UPDATE ON approval_decision
  FOR EACH ROW EXECUTE FUNCTION fn_trg_approval_decision_deny_update();

-- ============================================================
-- 7. RLS — ENABLE + FORCE on all 4 tables
-- ============================================================
ALTER TABLE approval_matrix   ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_matrix   FORCE  ROW LEVEL SECURITY;
ALTER TABLE approval_chain    ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_chain    FORCE  ROW LEVEL SECURITY;
ALTER TABLE approval_step     ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_step     FORCE  ROW LEVEL SECURITY;
ALTER TABLE approval_decision ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_decision FORCE  ROW LEVEL SECURITY;

-- approval_matrix policies (3)
CREATE POLICY approval_matrix_select_matrix_read_perm ON approval_matrix
  AS PERMISSIVE FOR SELECT
  USING ( fn_current_user_has_permission('approval.matrix.read') );

CREATE POLICY approval_matrix_modify_admin ON approval_matrix
  AS PERMISSIVE FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
    )
  );

CREATE POLICY approval_matrix_deny_direct_delete ON approval_matrix
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- approval_chain policies (4)
CREATE POLICY approval_chain_select_via_contract ON approval_chain
  AS PERMISSIVE FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM contract c
        WHERE c.id = approval_chain.contract_id
          AND c.is_active = TRUE
    )
    AND (
      is_active = TRUE
      OR EXISTS (
        SELECT 1 FROM "user" u INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin','Super Admin','legal_counsel')
      )
    )
  );

CREATE POLICY approval_chain_insert_drafter_or_admin ON approval_chain
  AS PERMISSIVE FOR INSERT
  WITH CHECK (
    fn_current_user_has_permission('approval.submit_for_review')
    AND initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    AND status = 'in_progress'
    AND is_active = TRUE
  );

CREATE POLICY approval_chain_update_engine_or_admin ON approval_chain
  AS PERMISSIVE FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u INNER JOIN role r ON r.id=u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin','Super Admin','legal_counsel')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR EXISTS (
        SELECT 1 FROM approval_step s
          WHERE s.approval_chain_id = approval_chain.id
            AND s.status = 'pending'
            AND (
              s.approver_user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
              OR s.delegated_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
              OR s.reassigned_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            )
      )
    )
  )
  WITH CHECK (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u INNER JOIN role r ON r.id=u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin','Super Admin','legal_counsel')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR EXISTS (
        SELECT 1 FROM approval_step s
          WHERE s.approval_chain_id = approval_chain.id
            AND s.status = 'pending'
            AND (
              s.approver_user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
              OR s.delegated_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
              OR s.reassigned_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            )
      )
    )
  );

CREATE POLICY approval_chain_deny_direct_delete ON approval_chain
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- approval_step policies (4)
CREATE POLICY approval_step_select_via_chain ON approval_step
  AS PERMISSIVE FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM approval_chain ch
        WHERE ch.id = approval_step.approval_chain_id
          AND ch.is_active = TRUE
    )
  );

CREATE POLICY approval_step_insert_via_route_init ON approval_step
  AS PERMISSIVE FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM approval_chain ch
        WHERE ch.id = approval_step.approval_chain_id
          AND ch.status = 'in_progress'
          AND ch.is_active = TRUE
          AND (
            ch.initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR EXISTS (
              SELECT 1 FROM "user" u INNER JOIN role r ON r.id=u.role_id
                WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
                  AND r.name IN ('platform_admin','Super Admin','legal_counsel')
            )
          )
    )
  );

CREATE POLICY approval_step_update_assigned_or_admin ON approval_step
  AS PERMISSIVE FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      approver_user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR delegated_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR reassigned_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR EXISTS (
        SELECT 1 FROM "user" u INNER JOIN role r ON r.id=u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin','Super Admin','legal_counsel')
      )
    )
  )
  WITH CHECK (
    is_active = TRUE
    AND (
      approver_user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR delegated_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR reassigned_to = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR EXISTS (
        SELECT 1 FROM "user" u INNER JOIN role r ON r.id=u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin','Super Admin','legal_counsel')
      )
    )
  );

CREATE POLICY approval_step_deny_direct_delete ON approval_step
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- approval_decision policies (4)
CREATE POLICY approval_decision_select_via_step ON approval_decision
  AS PERMISSIVE FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM approval_step s
        WHERE s.id = approval_decision.approval_step_id
          AND s.is_active = TRUE
    )
  );

CREATE POLICY approval_decision_insert_via_engine ON approval_decision
  AS PERMISSIVE FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM approval_step s
        WHERE s.id = approval_decision.approval_step_id
          AND s.is_active = TRUE
          AND (
            s.approver_user_id = approval_decision.decided_by
            OR s.delegated_to = approval_decision.decided_by
            OR s.reassigned_to = approval_decision.decided_by
            OR EXISTS (
              SELECT 1 FROM "user" u INNER JOIN role r ON r.id=u.role_id
                WHERE u.id = approval_decision.decided_by
                  AND r.name IN ('platform_admin','Super Admin','legal_counsel')
            )
          )
    )
  );

CREATE POLICY approval_decision_deny_update ON approval_decision
  AS RESTRICTIVE FOR UPDATE
  USING (FALSE);

CREATE POLICY approval_decision_deny_direct_delete ON approval_decision
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (24, 'm2_approval_tables_rls_indexes', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP TRIGGER IF EXISTS audit_approval_decision_changes  ON approval_decision;
DROP TRIGGER IF EXISTS audit_approval_step_changes      ON approval_step;
DROP TRIGGER IF EXISTS audit_approval_chain_changes     ON approval_chain;
DROP TRIGGER IF EXISTS audit_approval_matrix_changes    ON approval_matrix;
DROP TRIGGER IF EXISTS trg_approval_decision_deny_update    ON approval_decision;
DROP TRIGGER IF EXISTS trg_approval_step_immutable_fields   ON approval_step;
DROP TRIGGER IF EXISTS trg_approval_chain_immutable_fields  ON approval_chain;
DROP FUNCTION IF EXISTS fn_trg_approval_decision_deny_update();
DROP FUNCTION IF EXISTS fn_trg_approval_step_immutable_fields();
DROP FUNCTION IF EXISTS fn_trg_approval_chain_immutable_fields();
DROP TABLE IF EXISTS approval_decision;
DROP TABLE IF EXISTS approval_step;
DROP TABLE IF EXISTS approval_chain;
DROP TABLE IF EXISTS approval_matrix;
DELETE FROM schema_migrations WHERE version = 24;
COMMIT;
-- ROLLBACK END
