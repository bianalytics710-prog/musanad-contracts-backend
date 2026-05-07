-- ================================================================
-- Migration 083 — R-DA9-3b: close S2-21 PUBLIC EXECUTE leaks
-- across drafter + approver session migrations (058, 065, 066).
-- ================================================================
-- Up: BEGIN
-- The Stage-2 mandatory check S2-21 requires explicit
-- "REVOKE ALL ... FROM PUBLIC" on every new fn_, because
-- PostgreSQL grants PUBLIC EXECUTE by default unless revoked.
-- The R-LC9-3 audit caught two leak surfaces:
--
--   058 (M_parity entities) — granted EXECUTE TO neondb_owner
--                             but never revoked PUBLIC. This puts
--                             the empty-role entry into proacl,
--                             making it visible to the M4 / M6
--                             S2-21 regression guards.
--                             Affected: fn_template_list,
--                                       fn_template_get_by_id,
--                                       fn_clause_list,
--                                       fn_clause_get_by_id,
--                                       fn_obligation_list.
--                             (fn_party_list / fn_party_get_by_id
--                              already fixed by 075.)
--
--   065 (contract_comment) + 066 (approver R5 analytics) —
--                             never issued any GRANT or REVOKE.
--                             The fn_'s still hold effective
--                             PUBLIC EXECUTE through PostgreSQL's
--                             NULL-proacl default. The S2-21
--                             regression guards do NOT see these
--                             (they unnest proacl, which is empty),
--                             but the underlying access is real.
--                             Affected: fn_contract_comment_list,
--                                       fn_contract_comment_create,
--                                       fn_contract_comment_resolve,
--                                       fn_contract_comment_delete,
--                                       fn_contract_watch_set,
--                                       fn_approval_my_decisions,
--                                       fn_approval_watching.
--
-- For each leak: REVOKE ALL FROM PUBLIC + GRANT EXECUTE TO
-- neondb_owner. Re-running the GRANT is idempotent.
-- ================================================================

-- ── 058 — M_parity read fn_'s (5) ────────────────────────────────
REVOKE ALL ON FUNCTION fn_template_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_template_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_clause_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_clause_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) FROM PUBLIC;

-- ── 065 — contract comment fn_'s (4) ─────────────────────────────
REVOKE ALL ON FUNCTION fn_contract_comment_list(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_list(BIGINT, BIGINT, TEXT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_contract_comment_create(BIGINT, BIGINT, TEXT, BIGINT, BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_create(BIGINT, BIGINT, TEXT, BIGINT, BIGINT[]) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_contract_comment_resolve(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_resolve(BIGINT, BIGINT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_contract_comment_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_delete(BIGINT, BIGINT) TO neondb_owner;

-- ── 066 — approver R5 analytics + watch toggle fn_'s (3) ─────────
REVOKE ALL ON FUNCTION fn_contract_watch_set(BIGINT, BIGINT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_watch_set(BIGINT, BIGINT, BOOLEAN) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_approval_my_decisions(BIGINT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_approval_my_decisions(BIGINT, TEXT, INTEGER, INTEGER) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_approval_watching(BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_approval_watching(BIGINT, INTEGER, INTEGER) TO neondb_owner;

-- ================================================================
-- Up: END
-- Down: BEGIN
-- ================================================================
-- GRANT EXECUTE ON FUNCTION fn_template_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_template_get_by_id(BIGINT, BIGINT) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_clause_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_clause_get_by_id(BIGINT, BIGINT) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_contract_comment_list(BIGINT, BIGINT, TEXT) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_contract_comment_create(BIGINT, BIGINT, TEXT, BIGINT, BIGINT[]) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_contract_comment_resolve(BIGINT, BIGINT) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_contract_comment_delete(BIGINT, BIGINT) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_contract_watch_set(BIGINT, BIGINT, BOOLEAN) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_approval_my_decisions(BIGINT, TEXT, INTEGER, INTEGER) TO PUBLIC;
-- GRANT EXECUTE ON FUNCTION fn_approval_watching(BIGINT, INTEGER, INTEGER) TO PUBLIC;
-- ================================================================
-- Down: END
