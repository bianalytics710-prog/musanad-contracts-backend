-- Migration: 610_soft_delete_mercury_nda_clauses_round2.sql
-- Module: Demo cleanup — soft-delete the second batch of Mercury NDA clauses
-- Date: 2026-06-09
--
-- After mig 608 deactivated ids 74..84, we walked the new composite-score
-- panel end-to-end (Hala uploaded 11-NDA-Mercury.docx, clicked "Add 11
-- clause(s) to library"). That inserted ids 85..95 — the same 11 NDA
-- clauses again. This migration soft-deletes those test additions so the
-- library is clean for the next demo cycle.
--
-- Same pattern as 608: flip is_active = FALSE on each row; reversible by
-- flipping back to TRUE. fn_clause_library_match_each filters on
-- is_active, so these rows fall out of similarity matching immediately.
--
-- Clauses being removed (all created 2026-06-09 14:29):
--   id=85 confidentiality       "Confidential Information"
--   id=86 confidentiality       "Obligations of the Recipient"
--   id=87 confidentiality       "Permitted Disclosures"
--   id=88 term                   "Term"
--   id=89 confidentiality       "Return or Destruction"
--   id=90 intellectual_property "No Licence, No Representations"
--   id=91 other                  "No Obligation to Proceed"
--   id=92 other                  "Injunctive Relief"
--   id=93 other                  "Compliance"
--   id=94 governing_law         "Governing Law and Dispute Resolution"
--   id=95 other                  "Entire Agreement, Assignment and Counterparts"

BEGIN;

UPDATE contract_clause
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE id BETWEEN 85 AND 95
   AND is_seed = FALSE
   AND is_active = TRUE;

-- Belt-and-suspenders: deactivate any template-clause links too (none
-- expected — these were added straight to library, not bound to a
-- template — but cheap insurance).
UPDATE contract_template_clause
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE clause_id BETWEEN 85 AND 95
   AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (610, '610_soft_delete_mercury_nda_clauses_round2', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Rollback (manual): UPDATE contract_clause SET is_active = TRUE WHERE id BETWEEN 85 AND 95;
