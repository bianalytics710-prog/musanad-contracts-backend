-- ============================================================================
-- 035_m3_signature_tables.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0/M1a/M1b/M1c/M2 (user, role, permission, contract,
--            contract_activity, approval_chain, fn_audit_trigger).
-- ----------------------------------------------------------------------------
-- M3 6 new tables + 20 RLS policies + 6 audit triggers + 3 immutability /
-- consistency triggers + 3 supporting trigger functions + 2 reference-table
-- seeds. Single migration so CREATE TABLE + RLS + triggers land atomically
-- (RLS-enabled-but-no-policies is a Stage-2 escape vector).
--
-- Tables:
--   1. signature_party_side  — reference (3 rows)
--   2. signature_method       — reference (4 rows)
--   3. signature_party        — transactional
--   4. signature_invitation   — transactional
--   5. signature_event        — transactional, append-only
--   6. signer_qa_session      — transactional
--
-- Trigger functions:
--   - fn_trg_signature_event_deny_update              (mirrors M2 fn_trg_approval_decision_deny_update)
--   - fn_trg_signature_invitation_contract_id_consistent
--   - fn_trg_signature_event_contract_id_consistent
--
-- Triggers:
--   - audit_signature_party_side_changes              AFTER I/U/D
--   - audit_signature_method_changes                  AFTER I/U/D
--   - audit_signature_party_changes                   AFTER I/U/D
--   - audit_signature_invitation_changes              AFTER I/U/D
--   - audit_signature_event_changes                   AFTER INSERT (append-only)
--   - audit_signer_qa_session_changes                 AFTER I/U/D
--   - trg_signature_event_deny_update                 BEFORE UPDATE (deny)
--   - trg_signature_invitation_contract_id_consistent BEFORE I/U
--   - trg_signature_event_contract_id_consistent      BEFORE INSERT
--
-- RLS pattern mandate (M1c-021 / M2-024): no self-ref subqueries in WITH
-- CHECK; immutability via BEFORE UPDATE triggers; ENABLE AND FORCE on all 6.
-- 20 policies total: 4 each on signature_party / signature_invitation /
-- signature_event / signer_qa_session + 2 each on the 2 reference tables.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 0. Required extension (pgcrypto for digest() + gen_random_bytes() in M3 036)
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 1. signature_party_side — reference
-- ============================================================
CREATE TABLE signature_party_side (
  code            VARCHAR(20)  NOT NULL PRIMARY KEY,
  label_en        VARCHAR(80)  NOT NULL,
  label_ar        VARCHAR(80)  NOT NULL,
  sort_order      INTEGER      NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by      BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by      BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE signature_party_side IS
  'M3 reference table for signature_party.signer_side enum. Replaces a CHECK constraint per Agent 4 Rule 8 (lookup table for dropdown values). Seeded with employer/counterparty/witness in this migration.';

CREATE INDEX idx_signature_party_side_active ON signature_party_side(code) WHERE is_active = TRUE;
CREATE INDEX idx_signature_party_side_sort   ON signature_party_side(sort_order);

-- ============================================================
-- 2. signature_method — reference
-- ============================================================
CREATE TABLE signature_method (
  code                    VARCHAR(20)  NOT NULL PRIMARY KEY,
  label_en                VARCHAR(80)  NOT NULL,
  label_ar                VARCHAR(80)  NOT NULL,
  verification_strength   INTEGER      NOT NULL CHECK (verification_strength BETWEEN 1 AND 4),
  is_enabled              BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by              BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by              BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active               BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE signature_method IS
  'M3 reference table for signature_event.signature_method enum (uae_pass, ds_otp, drawn, typed). is_enabled allows runtime feature-flag of a method without dropping rows.';

CREATE INDEX idx_signature_method_active  ON signature_method(code) WHERE is_active = TRUE;
CREATE INDEX idx_signature_method_enabled ON signature_method(code) WHERE is_active = TRUE AND is_enabled = TRUE;

-- ============================================================
-- 3. signature_party — transactional
-- ============================================================
CREATE TABLE signature_party (
  id                BIGSERIAL PRIMARY KEY,
  contract_id       BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  signer_side       VARCHAR(20) NOT NULL REFERENCES signature_party_side(code) ON DELETE RESTRICT,
  signer_user_id    BIGINT REFERENCES "user"(id) ON DELETE RESTRICT,
  signer_name_en    VARCHAR(200) NOT NULL,
  signer_name_ar    VARCHAR(200),
  signer_email      VARCHAR(255),
  signer_phone      VARCHAR(40),
  signer_party_id   BIGINT,                                             -- Forward-FK to future party(id) — NO FK in M3 (AN-6 / ND-2)
  step_order        INTEGER NOT NULL CHECK (step_order >= 1),
  is_required       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT chk_signature_party_name_en_not_blank
    CHECK (length(btrim(signer_name_en)) > 0),
  CONSTRAINT chk_signature_party_email_format
    CHECK (signer_email IS NULL OR signer_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

COMMENT ON TABLE signature_party IS
  'M3 per-contract roster of who signs (employer / counterparty / witness). One row per signer per contract. signer_user_id may be NULL for external counterparty signers without a user account. signer_party_id is a forward-reference to future Parties module — NO FK constraint in M3 (mirrors M1a contract.our_party_id forward-FK).';
COMMENT ON COLUMN signature_party.signer_email IS 'SENSITIVE — pino-redacted in logs, fn_audit_trigger-redacted (already in M2 029 redact list).';
COMMENT ON COLUMN signature_party.signer_phone IS 'SENSITIVE — pino-redacted in logs, fn_audit_trigger-redacted (already in M2 029 redact list).';
COMMENT ON COLUMN signature_party.signer_party_id IS 'Forward reference to party(id) (Parties module). FK constraint deferred — added by Parties migration when it lands.';

-- Idempotency guard for fn_signature_party_create_bulk re-call (AC-S1-08)
CREATE UNIQUE INDEX uq_signature_party_active_per_step_email
  ON signature_party (contract_id, step_order, lower(signer_email))
  WHERE is_active = TRUE AND signer_email IS NOT NULL;

CREATE INDEX idx_signature_party_contract_id      ON signature_party(contract_id);
CREATE INDEX idx_signature_party_signer_user_id   ON signature_party(signer_user_id) WHERE signer_user_id IS NOT NULL;
CREATE INDEX idx_signature_party_signer_side      ON signature_party(signer_side);
CREATE INDEX idx_signature_party_step_order       ON signature_party(contract_id, step_order) WHERE is_active = TRUE;
CREATE INDEX idx_signature_party_active           ON signature_party(id) WHERE is_active = TRUE;
CREATE INDEX idx_signature_party_created_by       ON signature_party(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_signature_party_updated_by       ON signature_party(updated_by) WHERE updated_by IS NOT NULL;

-- ============================================================
-- 4. signature_invitation — transactional
-- ============================================================
CREATE TABLE signature_invitation (
  id                          BIGSERIAL PRIMARY KEY,
  signature_party_id          BIGINT NOT NULL REFERENCES signature_party(id) ON DELETE RESTRICT,
  contract_id                 BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,  -- denormalised; trigger-enforced equality
  invitation_token_hash       TEXT NOT NULL UNIQUE,
  status                      VARCHAR(20) NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','viewed','signed','declined','expired','cancelled')),
  invitation_sent_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  invitation_expires_at       TIMESTAMPTZ NOT NULL,
  first_viewed_at             TIMESTAMPTZ,
  last_viewed_at              TIMESTAMPTZ,
  view_count                  INTEGER NOT NULL DEFAULT 0,
  ip_address                  INET,
  user_agent                  TEXT,
  language                    VARCHAR(8) NOT NULL DEFAULT 'en' CHECK (language IN ('en','ar')),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by                  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT chk_signature_invitation_expires_after_sent
    CHECK (invitation_expires_at > invitation_sent_at)
);

COMMENT ON TABLE signature_invitation IS
  'M3 per-signer invitation token + lifecycle. One ACTIVE invitation per signature_party (UNIQUE partial index). invitation_token_hash stores SHA-256 hash of plaintext token; plaintext is returned ONCE on creation via JSONB and never persisted. Resending creates a new active row + soft-deactivates the prior. CC-5 (storage shape) — column is *_hash, not plaintext, mirrors M0 token_blacklist.';
COMMENT ON COLUMN signature_invitation.invitation_token_hash IS
  'SHA-256 hex hash of the plaintext invitation_token (encode(digest($1, ''sha256''), ''hex'')). The fn_ hashes plaintext on entry and compares to this column. Plaintext is NEVER persisted. Sensitive — added to fn_audit_trigger redact list in M3 034.';
COMMENT ON COLUMN signature_invitation.contract_id IS
  'Denormalised for RLS performance (avoids signature_party JOIN on every row). Trigger-enforced equality with signature_party.contract_id — see trg_signature_invitation_contract_id_consistent.';

CREATE UNIQUE INDEX uq_signature_invitation_one_active_per_party
  ON signature_invitation (signature_party_id)
  WHERE is_active = TRUE;

CREATE INDEX idx_signature_invitation_due
  ON signature_invitation (invitation_expires_at)
  WHERE is_active = TRUE AND status IN ('pending','viewed');

CREATE INDEX idx_signature_invitation_contract_id    ON signature_invitation(contract_id);
CREATE INDEX idx_signature_invitation_party_id       ON signature_invitation(signature_party_id);
CREATE INDEX idx_signature_invitation_status         ON signature_invitation(status, contract_id) WHERE is_active = TRUE;
CREATE INDEX idx_signature_invitation_active         ON signature_invitation(id) WHERE is_active = TRUE;
CREATE INDEX idx_signature_invitation_created_by     ON signature_invitation(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_signature_invitation_updated_by     ON signature_invitation(updated_by) WHERE updated_by IS NOT NULL;

-- ============================================================
-- 5. signature_event — append-only
-- ============================================================
CREATE TABLE signature_event (
  id                            BIGSERIAL PRIMARY KEY,
  signature_invitation_id       BIGINT NOT NULL REFERENCES signature_invitation(id) ON DELETE RESTRICT,
  contract_id                   BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  event_type                    VARCHAR(30) NOT NULL
                                  CHECK (event_type IN ('viewed','signed','declined','expired','cancelled','resent')),
  signature_method              VARCHAR(20) REFERENCES signature_method(code) ON DELETE RESTRICT,
  uae_pass_verification_level   VARCHAR(20)
                                  CHECK (uae_pass_verification_level IS NULL OR uae_pass_verification_level IN ('basic','verified','premium')),
  signature_image_url           TEXT,
  signature_data                TEXT,
  decline_reason                TEXT,
  ip_address                    INET,
  user_agent                    TEXT,
  actor_user_id                 BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  metadata                      JSONB,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active                     BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT chk_signature_event_signed_has_method
    CHECK (event_type <> 'signed' OR signature_method IS NOT NULL),
  CONSTRAINT chk_signature_event_declined_has_reason
    CHECK (event_type <> 'declined' OR (decline_reason IS NOT NULL AND length(btrim(decline_reason)) >= 5)),
  CONSTRAINT chk_signature_event_uae_pass_level_required
    CHECK (signature_method IS DISTINCT FROM 'uae_pass' OR uae_pass_verification_level IS NOT NULL),
  CONSTRAINT chk_signature_event_decline_reason_length
    CHECK (decline_reason IS NULL OR length(decline_reason) BETWEEN 5 AND 2000)
);

COMMENT ON TABLE signature_event IS
  'M3 append-only event log for signature lifecycle. One row per signed/declined/expired/cancelled/viewed/resent action. Mirrors M2 approval_decision append-only pattern (AN-5). RLS deny-update + BEFORE UPDATE trigger trg_signature_event_deny_update is the primary append-only enforcement. UPDATE/DELETE both blocked. is_active is schema-uniformity only — never flips to FALSE.';
COMMENT ON COLUMN signature_event.actor_user_id IS
  'NULL for external-signer events (signed via invitation_token). Distinct from system-event sentinel (AN-9): external signer = NULL outright; cron-driven = SET app.current_user_id=''0'' which fn_contract_activity_create coerces to NULL. Both reach actor_user_id=NULL via different paths.';
COMMENT ON COLUMN signature_event.signature_image_url IS 'SENSITIVE — never returned in fn_signature_list response, redacted by fn_audit_trigger (added in M3 034).';
COMMENT ON COLUMN signature_event.signature_data IS 'SENSITIVE — verbatim signature payload. Never returned, never logged, redacted in audit_log (M3 034).';

CREATE INDEX idx_signature_event_invitation_id    ON signature_event(signature_invitation_id, created_at DESC);
CREATE INDEX idx_signature_event_contract_id      ON signature_event(contract_id, created_at DESC);
CREATE INDEX idx_signature_event_event_type       ON signature_event(event_type, created_at DESC);
CREATE INDEX idx_signature_event_actor_user_id    ON signature_event(actor_user_id) WHERE actor_user_id IS NOT NULL;
CREATE INDEX idx_signature_event_active           ON signature_event(id) WHERE is_active = TRUE;

-- ============================================================
-- 6. signer_qa_session — transactional
-- ============================================================
CREATE TABLE signer_qa_session (
  id                          BIGSERIAL PRIMARY KEY,
  signature_invitation_id     BIGINT NOT NULL REFERENCES signature_invitation(id) ON DELETE RESTRICT,
  session_token_hash          TEXT NOT NULL UNIQUE,
  message_count               INTEGER NOT NULL DEFAULT 0,
  tokens_consumed             INTEGER NOT NULL DEFAULT 0,
  last_activity_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  rate_limit_window_start     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  rate_limit_count            INTEGER NOT NULL DEFAULT 0,
  language                    VARCHAR(8) NOT NULL DEFAULT 'en' CHECK (language IN ('en','ar')),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by                  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE signer_qa_session IS
  'M3 per-invitation Q&A chat session. Stores ONLY metadata (counters + last-activity + rate-limit window) — NO chat transcript persisted (AN-2 transcriptStorage). One row per invitation_token + browser session; up to 5 active sessions per invitation (sliding window — Gate 2 locked AN-12 Option A).';
COMMENT ON COLUMN signer_qa_session.session_token_hash IS
  'SHA-256 hex hash of the plaintext session_token. Sensitive — added to fn_audit_trigger redact list in M3 034. Plaintext returned ONCE on creation.';
COMMENT ON COLUMN signer_qa_session.language IS
  'Locked at session start — prevents mid-conversation persona switching (AN-2 languageLock). Default = invitation.language.';

CREATE INDEX idx_signer_qa_session_invitation_id  ON signer_qa_session(signature_invitation_id);
CREATE INDEX idx_signer_qa_session_active         ON signer_qa_session(id) WHERE is_active = TRUE;
CREATE INDEX idx_signer_qa_session_active_per_inv ON signer_qa_session(signature_invitation_id, last_activity_at DESC) WHERE is_active = TRUE;
CREATE INDEX idx_signer_qa_session_created_by     ON signer_qa_session(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_signer_qa_session_updated_by     ON signer_qa_session(updated_by) WHERE updated_by IS NOT NULL;

-- ============================================================
-- 7. Trigger functions
-- ============================================================

-- 7.1 Append-only enforcement on signature_event
CREATE OR REPLACE FUNCTION fn_trg_signature_event_deny_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'fn_trg_signature_event_deny_update: signature_event is append-only'
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION fn_trg_signature_event_deny_update() IS
  'M3 append-only enforcement trigger for signature_event. Mirrors M2 fn_trg_approval_decision_deny_update precisely. RAISE 42501 on any UPDATE.';

-- 7.2 Denormalised contract_id consistency on signature_invitation
CREATE OR REPLACE FUNCTION fn_trg_signature_invitation_contract_id_consistent()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_party_contract_id BIGINT;
BEGIN
  SELECT contract_id INTO v_party_contract_id FROM signature_party WHERE id = NEW.signature_party_id;
  IF NEW.contract_id IS DISTINCT FROM v_party_contract_id THEN
    RAISE EXCEPTION
      'fn_trg_signature_invitation_contract_id_consistent: contract_id must equal parent signature_party.contract_id'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_trg_signature_invitation_contract_id_consistent() IS
  'M3 BEFORE I/U trigger fn enforcing signature_invitation.contract_id = signature_party.contract_id (denormalised FK invariant — RLS perf optimisation).';

-- 7.3 Denormalised contract_id consistency on signature_event
CREATE OR REPLACE FUNCTION fn_trg_signature_event_contract_id_consistent()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inv_contract_id BIGINT;
BEGIN
  SELECT contract_id INTO v_inv_contract_id FROM signature_invitation WHERE id = NEW.signature_invitation_id;
  IF NEW.contract_id IS DISTINCT FROM v_inv_contract_id THEN
    RAISE EXCEPTION
      'fn_trg_signature_event_contract_id_consistent: contract_id must equal parent signature_invitation.contract_id'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_trg_signature_event_contract_id_consistent() IS
  'M3 BEFORE INSERT trigger fn enforcing signature_event.contract_id = signature_invitation.contract_id (denormalised FK invariant — RLS perf optimisation). UPDATE blocked by trg_signature_event_deny_update.';

-- ============================================================
-- 8. Triggers
-- ============================================================

-- NOTE (DB Impl finding): canonical fn_audit_trigger references NEW.id / OLD.id,
-- so it can ONLY be attached to tables that have an `id` column. The two
-- reference tables use `code` as PK (no `id` column), which makes
-- fn_audit_trigger raise 42703 record "new" has no field "id" on every
-- INSERT/UPDATE/DELETE — including the seed inserts in this migration. The
-- design specified audit triggers on all 6 tables but did not account for the
-- canonical fn_audit_trigger contract. The 4 transactional tables (which all
-- have an `id` BIGSERIAL PK) are audited as designed. signature_party_side and
-- signature_method are LOOKUP tables seeded by this migration and only mutated
-- by platform_admin via the modify_admin RLS policy; their churn is ~zero.
-- Audit coverage on those two tables is therefore omitted in M3 — if regulatory
-- needs change, an additive M4+ migration can extend fn_audit_trigger to handle
-- non-id PKs (e.g., COALESCE-with-row::text fallback) without breaking M0..M3.

CREATE TRIGGER audit_signature_party_changes
  AFTER INSERT OR UPDATE OR DELETE ON signature_party
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_signature_invitation_changes
  AFTER INSERT OR UPDATE OR DELETE ON signature_invitation
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_signature_event_changes
  AFTER INSERT ON signature_event
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER audit_signer_qa_session_changes
  AFTER INSERT OR UPDATE OR DELETE ON signer_qa_session
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER trg_signature_event_deny_update
  BEFORE UPDATE ON signature_event
  FOR EACH ROW EXECUTE FUNCTION fn_trg_signature_event_deny_update();

CREATE TRIGGER trg_signature_invitation_contract_id_consistent
  BEFORE INSERT OR UPDATE OF contract_id, signature_party_id ON signature_invitation
  FOR EACH ROW EXECUTE FUNCTION fn_trg_signature_invitation_contract_id_consistent();

CREATE TRIGGER trg_signature_event_contract_id_consistent
  BEFORE INSERT ON signature_event
  FOR EACH ROW EXECUTE FUNCTION fn_trg_signature_event_contract_id_consistent();

-- ============================================================
-- 9. RLS — ENABLE + FORCE all 6 tables
-- ============================================================

ALTER TABLE signature_party_side    ENABLE ROW LEVEL SECURITY;
ALTER TABLE signature_party_side    FORCE  ROW LEVEL SECURITY;
ALTER TABLE signature_method        ENABLE ROW LEVEL SECURITY;
ALTER TABLE signature_method        FORCE  ROW LEVEL SECURITY;
ALTER TABLE signature_party         ENABLE ROW LEVEL SECURITY;
ALTER TABLE signature_party         FORCE  ROW LEVEL SECURITY;
ALTER TABLE signature_invitation    ENABLE ROW LEVEL SECURITY;
ALTER TABLE signature_invitation    FORCE  ROW LEVEL SECURITY;
ALTER TABLE signature_event         ENABLE ROW LEVEL SECURITY;
ALTER TABLE signature_event         FORCE  ROW LEVEL SECURITY;
ALTER TABLE signer_qa_session       ENABLE ROW LEVEL SECURITY;
ALTER TABLE signer_qa_session       FORCE  ROW LEVEL SECURITY;

-- ============================================================
-- 10. RLS Policies (20 total)
-- ============================================================

-- 10.1 signature_party_side (2)
CREATE POLICY signature_party_side_select_authenticated ON signature_party_side
  FOR SELECT
  USING (
    is_active = TRUE
    AND NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL
  );

CREATE POLICY signature_party_side_modify_admin ON signature_party_side
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin','Super Admin')
    )
  );

-- 10.2 signature_method (2)
CREATE POLICY signature_method_select_public ON signature_method
  FOR SELECT
  USING (is_active = TRUE);

CREATE POLICY signature_method_modify_admin ON signature_method
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin','Super Admin')
    )
  );

-- 10.3 signature_party (4)
CREATE POLICY signature_party_select_role_aware ON signature_party
  FOR SELECT
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'executive', 'Super Admin')
      )
      OR EXISTS (
        SELECT 1 FROM contract c
        WHERE c.id = signature_party.contract_id
          AND c.is_active = TRUE
          AND (
            c.drafted_by  = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR c.reviewed_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR c.approved_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR c.created_by  = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          )
      )
      OR signer_user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  );

CREATE POLICY signature_party_deny_direct_insert ON signature_party
  AS RESTRICTIVE
  FOR INSERT
  WITH CHECK (FALSE);

CREATE POLICY signature_party_deny_direct_update ON signature_party
  AS RESTRICTIVE
  FOR UPDATE
  USING (TRUE)
  WITH CHECK (FALSE);

CREATE POLICY signature_party_deny_direct_delete ON signature_party
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

-- 10.4 signature_invitation (4)
CREATE POLICY signature_invitation_select_role_aware ON signature_invitation
  FOR SELECT
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'executive', 'Super Admin')
      )
      OR EXISTS (
        SELECT 1 FROM contract c
        WHERE c.id = signature_invitation.contract_id
          AND c.is_active = TRUE
          AND (
            c.drafted_by  = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR c.reviewed_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR c.approved_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            OR c.created_by  = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          )
      )
    )
  );

CREATE POLICY signature_invitation_deny_direct_insert ON signature_invitation
  AS RESTRICTIVE FOR INSERT WITH CHECK (FALSE);

CREATE POLICY signature_invitation_deny_direct_update ON signature_invitation
  AS RESTRICTIVE FOR UPDATE USING (TRUE) WITH CHECK (FALSE);

CREATE POLICY signature_invitation_deny_direct_delete ON signature_invitation
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- 10.5 signature_event (4)
CREATE POLICY signature_event_select_parent_aware ON signature_event
  FOR SELECT
  USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = signature_event.contract_id)
  );

CREATE POLICY signature_event_deny_direct_insert ON signature_event
  AS RESTRICTIVE FOR INSERT WITH CHECK (FALSE);

CREATE POLICY signature_event_deny_direct_update ON signature_event
  AS RESTRICTIVE FOR UPDATE USING (FALSE) WITH CHECK (FALSE);

CREATE POLICY signature_event_deny_direct_delete ON signature_event
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- 10.6 signer_qa_session (4)
CREATE POLICY signer_qa_session_select_admin ON signer_qa_session
  FOR SELECT
  USING (
    is_active = TRUE
    AND EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
    )
  );

CREATE POLICY signer_qa_session_deny_direct_insert ON signer_qa_session
  AS RESTRICTIVE FOR INSERT WITH CHECK (FALSE);

CREATE POLICY signer_qa_session_deny_direct_update ON signer_qa_session
  AS RESTRICTIVE FOR UPDATE USING (TRUE) WITH CHECK (FALSE);

CREATE POLICY signer_qa_session_deny_direct_delete ON signer_qa_session
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- ============================================================
-- 11. Reference seed data (idempotent)
-- ============================================================

INSERT INTO signature_party_side (code, label_en, label_ar, sort_order, is_active)
VALUES
  ('employer',     'Employer / Our Party', 'صاحب العمل / طرفنا',   1, TRUE),
  ('counterparty', 'Counterparty',         'الطرف المقابل',         2, TRUE),
  ('witness',      'Witness',              'شاهد',                  3, TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO signature_method (code, label_en, label_ar, verification_strength, is_enabled, is_active)
VALUES
  ('uae_pass', 'UAE Pass',           'الهوية الرقمية', 4, TRUE, TRUE),
  ('ds_otp',   'Email / SMS OTP',    'رمز التحقق',     3, TRUE, TRUE),
  ('drawn',    'Drawn signature',    'توقيع مرسوم',    2, TRUE, TRUE),
  ('typed',    'Typed signature',    'توقيع مكتوب',    1, TRUE, TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (35, 'm3_signature_tables', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;

-- Drop triggers (names only — cascading not needed for triggers)
DROP TRIGGER IF EXISTS audit_signature_party_changes           ON signature_party;
DROP TRIGGER IF EXISTS audit_signature_invitation_changes      ON signature_invitation;
DROP TRIGGER IF EXISTS audit_signature_event_changes           ON signature_event;
DROP TRIGGER IF EXISTS audit_signer_qa_session_changes         ON signer_qa_session;
DROP TRIGGER IF EXISTS trg_signature_event_deny_update         ON signature_event;
DROP TRIGGER IF EXISTS trg_signature_invitation_contract_id_consistent ON signature_invitation;
DROP TRIGGER IF EXISTS trg_signature_event_contract_id_consistent      ON signature_event;

-- Drop tables in reverse FK order
DROP TABLE IF EXISTS signer_qa_session;
DROP TABLE IF EXISTS signature_event;
DROP TABLE IF EXISTS signature_invitation;
DROP TABLE IF EXISTS signature_party;
DROP TABLE IF EXISTS signature_method;
DROP TABLE IF EXISTS signature_party_side;

-- Drop trigger functions
DROP FUNCTION IF EXISTS fn_trg_signature_event_contract_id_consistent();
DROP FUNCTION IF EXISTS fn_trg_signature_invitation_contract_id_consistent();
DROP FUNCTION IF EXISTS fn_trg_signature_event_deny_update();

DELETE FROM schema_migrations WHERE version = 35;
COMMIT;
-- ROLLBACK END
