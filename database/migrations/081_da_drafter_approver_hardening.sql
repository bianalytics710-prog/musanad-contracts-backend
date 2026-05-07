-- Migration 081: R-DA9-1 — production hardening for drafter + approver
-- session work that shipped without v2.6 standards compliance:
--
--   058 (M_parity entities)    — party / contract_template /
--                                 contract_clause / contract_obligation:
--                                 ENABLE-only RLS (no FORCE), weak SELECT
--                                 policies (just is_active=TRUE), no
--                                 COMMENT ON COLUMN.
--   061 (contract_attachment)  — ENABLE-only RLS, no COMMENTs.
--   065 (contract_comment)     — zero RLS, zero audit trigger, zero
--                                 COMMENTs.
--   066 (contract_watch)       — zero RLS, zero audit trigger, zero
--                                 COMMENTs.
--
-- This migration brings every one of the above to v2.6 standard:
--   * FORCE ROW LEVEL SECURITY on all 6 tables.
--   * Tighten the M_parity SELECT policies — drop the
--     "is_active = TRUE" pseudo-policy and replace with a real permission
--     check (contract.read.department OR contract.edit), aligned with the
--     fn_*_list / fn_*_get_by_id permission gate.
--   * Add audit_*_changes triggers + COMMENT ON TABLE/COLUMN to 065 and
--     066 (which had none).
--   * Add COMMENT ON COLUMN coverage to all 6 tables (where missing).
--
-- S2-21 PUBLIC-grant verification: no PUBLIC GRANTs added or modified —
-- count remains stable at 5 (M3 signing token-bearer fns).

BEGIN;

-- ============================================================================
-- 1. M_parity entities — upgrade ENABLE → FORCE + tighter policies
-- ============================================================================

-- party --------------------------------------------------------------------
ALTER TABLE party FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS party_select       ON party;
DROP POLICY IF EXISTS party_modify_admin ON party;

CREATE POLICY party_select_perm ON party
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('contract.read.department')
      OR fn_current_user_has_permission('contract.edit')
    )
  );

CREATE POLICY party_modify_edit ON party
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

CREATE POLICY party_deny_direct_delete ON party
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

COMMENT ON COLUMN party.id              IS 'Surrogate key.';
COMMENT ON COLUMN party.party_type      IS 'individual | company.';
COMMENT ON COLUMN party.name_en         IS 'Legal name (English).';
COMMENT ON COLUMN party.name_ar         IS 'Legal name (Arabic, optional).';
COMMENT ON COLUMN party.trade_license_number IS 'UAE trade-licence number (e.g. DMCC-12345).';
COMMENT ON COLUMN party.trade_license_issuer IS 'Issuing authority (DED, DMCC, JAFZA, etc.).';
COMMENT ON COLUMN party.emirate         IS 'Emirate code (abu_dhabi / dubai / sharjah / …).';
COMMENT ON COLUMN party.free_zone       IS 'Free-zone name (DMCC, DIFC, JAFZA, ADGM, …) or NULL for onshore.';
COMMENT ON COLUMN party.country         IS 'ISO country (default United Arab Emirates).';
COMMENT ON COLUMN party.contact_email   IS 'Primary contact email (optional).';
COMMENT ON COLUMN party.contact_phone   IS 'Primary contact phone (optional).';
COMMENT ON COLUMN party.registered_address IS 'Full registered address (optional).';
COMMENT ON COLUMN party.notes           IS 'Free-text notes (optional).';
COMMENT ON COLUMN party.is_verified     IS 'R-LC5 — TRUE when trade-licence + issuer both present (rough KYC heuristic).';

-- contract_template --------------------------------------------------------
ALTER TABLE contract_template FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS template_select       ON contract_template;
DROP POLICY IF EXISTS template_modify_admin ON contract_template;

CREATE POLICY template_select_perm ON contract_template
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('contract.read.department')
      OR fn_current_user_has_permission('contract.edit')
    )
  );

CREATE POLICY template_modify_edit ON contract_template
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

CREATE POLICY template_deny_direct_delete ON contract_template
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

COMMENT ON COLUMN contract_template.id              IS 'Surrogate key.';
COMMENT ON COLUMN contract_template.name_en         IS 'Template title (English).';
COMMENT ON COLUMN contract_template.name_ar         IS 'Template title (Arabic, optional).';
COMMENT ON COLUMN contract_template.contract_type   IS 'Contract type slug — keys i18n contractType.* labels.';
COMMENT ON COLUMN contract_template.description_en  IS 'Short description (English).';
COMMENT ON COLUMN contract_template.description_ar  IS 'Short description (Arabic).';
COMMENT ON COLUMN contract_template.body_en         IS 'Markdown body (English).';
COMMENT ON COLUMN contract_template.body_ar         IS 'Markdown body (Arabic).';
COMMENT ON COLUMN contract_template.language        IS 'Primary language: en | ar | bilingual.';
COMMENT ON COLUMN contract_template.regulatory_tags IS 'Array of regulator/compliance refs (e.g. MoHRE, FTA, PDPL).';
COMMENT ON COLUMN contract_template.usage_count     IS 'Counter incremented every time the template is used to compose a contract.';

-- contract_clause ----------------------------------------------------------
ALTER TABLE contract_clause FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS clause_select       ON contract_clause;
DROP POLICY IF EXISTS clause_modify_admin ON contract_clause;

CREATE POLICY clause_select_perm ON contract_clause
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('contract.read.department')
      OR fn_current_user_has_permission('contract.edit')
    )
  );

CREATE POLICY clause_modify_edit ON contract_clause
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

CREATE POLICY clause_deny_direct_delete ON contract_clause
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

COMMENT ON COLUMN contract_clause.id                  IS 'Surrogate key.';
COMMENT ON COLUMN contract_clause.category            IS 'Clause family (confidentiality / payment / non_compete / …).';
COMMENT ON COLUMN contract_clause.title_en            IS 'Title (English).';
COMMENT ON COLUMN contract_clause.title_ar            IS 'Title (Arabic, optional).';
COMMENT ON COLUMN contract_clause.variant             IS 'standard | alternative | fallback.';
COMMENT ON COLUMN contract_clause.body_en             IS 'Clause body text (English).';
COMMENT ON COLUMN contract_clause.body_ar             IS 'Clause body text (Arabic).';
COMMENT ON COLUMN contract_clause.legal_commentary_en IS 'Counsel-facing context / enforceability notes (English).';
COMMENT ON COLUMN contract_clause.legal_commentary_ar IS 'Counsel-facing context / enforceability notes (Arabic).';
COMMENT ON COLUMN contract_clause.regulatory_refs     IS 'Array of regulatory/legal-source references.';
COMMENT ON COLUMN contract_clause.usage_count         IS 'Counter incremented every time clause is inserted into a contract.';

-- contract_obligation ------------------------------------------------------
ALTER TABLE contract_obligation FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS obligation_select       ON contract_obligation;
DROP POLICY IF EXISTS obligation_modify_admin ON contract_obligation;

CREATE POLICY obligation_select_perm ON contract_obligation
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('contract.read.department')
      OR fn_current_user_has_permission('contract.edit')
    )
  );

CREATE POLICY obligation_modify_edit ON contract_obligation
  AS PERMISSIVE FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

CREATE POLICY obligation_deny_direct_delete ON contract_obligation
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

COMMENT ON COLUMN contract_obligation.id                IS 'Surrogate key.';
COMMENT ON COLUMN contract_obligation.contract_id       IS 'FK → contract.id (CASCADE).';
COMMENT ON COLUMN contract_obligation.title_en          IS 'Short obligation title (English).';
COMMENT ON COLUMN contract_obligation.title_ar          IS 'Short obligation title (Arabic).';
COMMENT ON COLUMN contract_obligation.description_en    IS 'Long description (English).';
COMMENT ON COLUMN contract_obligation.description_ar    IS 'Long description (Arabic).';
COMMENT ON COLUMN contract_obligation.obligation_type   IS 'payment | delivery | reporting | renewal | compliance | notice | other.';
COMMENT ON COLUMN contract_obligation.due_date          IS 'Date the obligation falls due. NULL when open-ended.';
COMMENT ON COLUMN contract_obligation.recurrence        IS 'once | monthly | quarterly | annually.';
COMMENT ON COLUMN contract_obligation.responsible_party IS 'our_party | counterparty | both.';
COMMENT ON COLUMN contract_obligation.assignee_user_id  IS 'Optional named owner.';
COMMENT ON COLUMN contract_obligation.status            IS 'open | in_progress | completed | overdue | waived.';
COMMENT ON COLUMN contract_obligation.completed_at      IS 'Set when status flips to completed.';

-- ============================================================================
-- 2. contract_attachment — upgrade ENABLE → FORCE + add COMMENTs
-- ============================================================================
ALTER TABLE contract_attachment FORCE ROW LEVEL SECURITY;

COMMENT ON TABLE contract_attachment IS 'Per-contract file uploads. Files live in Supabase Storage; this row is metadata only.';
COMMENT ON COLUMN contract_attachment.id             IS 'Surrogate key.';
COMMENT ON COLUMN contract_attachment.contract_id    IS 'FK → contract.id.';
COMMENT ON COLUMN contract_attachment.filename       IS 'Display filename for the user.';
COMMENT ON COLUMN contract_attachment.mime_type      IS 'IANA media type.';
COMMENT ON COLUMN contract_attachment.size_bytes     IS 'File size in bytes (max 50 MiB).';
COMMENT ON COLUMN contract_attachment.storage_bucket IS 'Supabase Storage bucket name.';
COMMENT ON COLUMN contract_attachment.storage_path   IS 'Object path within the bucket; UNIQUE per (bucket, path).';
COMMENT ON COLUMN contract_attachment.uploaded_by    IS 'User who initiated the upload.';
COMMENT ON COLUMN contract_attachment.description    IS 'Optional caption / context.';

-- ============================================================================
-- 3. contract_comment — full standards (was zero)
-- ============================================================================
ALTER TABLE contract_comment ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_comment FORCE  ROW LEVEL SECURITY;

CREATE POLICY contract_comment_select_perm ON contract_comment
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND (
      fn_current_user_has_permission('contract.read.department')
      OR fn_current_user_has_permission('contract.edit')
    )
  );

-- Insert / update / soft-delete are all gated on contract.read.department or
-- contract.edit (anyone who can READ the contract can comment — Lovable
-- parity). Hard DELETE is denied.
CREATE POLICY contract_comment_modify_perm ON contract_comment
  AS PERMISSIVE FOR ALL
  USING (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.edit')
  )
  WITH CHECK (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.edit')
  );

CREATE POLICY contract_comment_deny_direct_delete ON contract_comment
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

CREATE TRIGGER audit_contract_comment_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_comment
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE contract_comment IS
  'R4 (065) — threaded discussion against a contract. Drives the contract-detail Comments tab. Top-level rows have parent_id NULL; replies set parent_id = parent comment id.';
COMMENT ON COLUMN contract_comment.id                 IS 'Surrogate key.';
COMMENT ON COLUMN contract_comment.contract_id        IS 'FK → contract.id (CASCADE).';
COMMENT ON COLUMN contract_comment.parent_id          IS 'NULL for top-level; FK → contract_comment.id for replies (CASCADE).';
COMMENT ON COLUMN contract_comment.body               IS 'Markdown-light comment text. 1..4000 chars (CHECK constraint).';
COMMENT ON COLUMN contract_comment.mentioned_user_ids IS '@-mention array of user.id values; FE renders chips, future module wires notifications.';
COMMENT ON COLUMN contract_comment.resolved_at        IS 'Set when a reviewer hits Resolve. NULL = open.';
COMMENT ON COLUMN contract_comment.resolved_by        IS 'User who resolved the thread.';
COMMENT ON COLUMN contract_comment.is_active          IS 'Soft-delete flag (FALSE = removed).';

-- ============================================================================
-- 4. contract_watch — full standards (was zero)
-- ============================================================================
-- contract_watch has a (user_id, contract_id) composite primary key — no
-- audit columns + no soft-delete column (rows are physically removed when
-- a user unwatches). RLS still applies.
ALTER TABLE contract_watch ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_watch FORCE  ROW LEVEL SECURITY;

-- Users see/manage only their own watch rows. Admins see all.
CREATE POLICY contract_watch_self_or_admin_select ON contract_watch
  AS PERMISSIVE FOR SELECT
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    OR EXISTS (
      SELECT 1 FROM "user" u
      JOIN role r ON r.id = u.role_id
      WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
        AND r.name IN ('platform_admin', 'Super Admin')
    )
  );

CREATE POLICY contract_watch_self_modify ON contract_watch
  AS PERMISSIVE FOR ALL
  USING (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  )
  WITH CHECK (
    user_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );

CREATE TRIGGER audit_contract_watch_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_watch
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE contract_watch IS
  'R5 (066) — user opt-in follow list. Drives the "Watching" tab on the approvals inbox + the Watch toggle on contract detail. Composite PK (user_id, contract_id); rows physically removed on unwatch (no soft delete).';
COMMENT ON COLUMN contract_watch.user_id     IS 'FK → user.id (CASCADE).';
COMMENT ON COLUMN contract_watch.contract_id IS 'FK → contract.id (CASCADE).';
COMMENT ON COLUMN contract_watch.created_at  IS 'When the user started watching.';

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_contract_comment_changes ON contract_comment;
-- DROP TRIGGER IF EXISTS audit_contract_watch_changes   ON contract_watch;
-- DROP POLICY IF EXISTS party_select_perm                  ON party;
-- DROP POLICY IF EXISTS party_modify_edit                  ON party;
-- DROP POLICY IF EXISTS party_deny_direct_delete           ON party;
-- DROP POLICY IF EXISTS template_select_perm               ON contract_template;
-- DROP POLICY IF EXISTS template_modify_edit               ON contract_template;
-- DROP POLICY IF EXISTS template_deny_direct_delete        ON contract_template;
-- DROP POLICY IF EXISTS clause_select_perm                 ON contract_clause;
-- DROP POLICY IF EXISTS clause_modify_edit                 ON contract_clause;
-- DROP POLICY IF EXISTS clause_deny_direct_delete          ON contract_clause;
-- DROP POLICY IF EXISTS obligation_select_perm             ON contract_obligation;
-- DROP POLICY IF EXISTS obligation_modify_edit             ON contract_obligation;
-- DROP POLICY IF EXISTS obligation_deny_direct_delete      ON contract_obligation;
-- DROP POLICY IF EXISTS contract_comment_select_perm       ON contract_comment;
-- DROP POLICY IF EXISTS contract_comment_modify_perm       ON contract_comment;
-- DROP POLICY IF EXISTS contract_comment_deny_direct_delete ON contract_comment;
-- DROP POLICY IF EXISTS contract_watch_self_or_admin_select ON contract_watch;
-- DROP POLICY IF EXISTS contract_watch_self_modify          ON contract_watch;
-- ALTER TABLE party                NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE contract_template    NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE contract_clause      NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE contract_obligation  NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE contract_attachment  NO FORCE ROW LEVEL SECURITY;
-- ALTER TABLE contract_comment     DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE contract_watch       DISABLE ROW LEVEL SECURITY;
-- COMMIT;
-- ROLLBACK END
