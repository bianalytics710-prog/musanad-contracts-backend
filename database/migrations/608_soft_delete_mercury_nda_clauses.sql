-- Migration: 608_soft_delete_mercury_nda_clauses.sql
-- Module: Demo cleanup — soft-delete 11 clauses extracted from 11-NDA-Mercury
-- Date: 2026-06-09
--
-- Hala uploaded 11-NDA-Mercury.docx earlier in the demo lifecycle and
-- the upload pipeline pushed all 11 clauses into the global library
-- (contract_clause ids 74..84, created 2026-06-06 07:57). With those
-- clauses live, re-uploading the same NDA to validate the new
-- composite-score logic (mig 607 / BE service) would show 11/11
-- "known" and a high coverage score — exactly what the user is trying
-- to avoid. So we soft-delete them.
--
-- Why soft-delete and not DROP:
--   • fn_clause_library_match_each filters on is_active = TRUE, so a
--     flipped flag is enough to exclude the rows from similarity
--     matching. No FK fan-out needed.
--   • No rows in contract_template_clause reference them (probed) —
--     they're library-only entries that never got linked to a template.
--   • Soft-delete keeps the audit trail (we know they existed + when
--     they were extracted) and is fully reversible by flipping is_active
--     back to TRUE.
--
-- Clauses being removed:
--   id=74 confidentiality       "Confidential Information"
--   id=75 confidentiality       "Obligations of the Recipient"
--   id=76 confidentiality       "Permitted Disclosures"
--   id=77 term                   "Term"
--   id=78 confidentiality       "Return or Destruction"
--   id=79 intellectual_property "No Licence, No Representations"
--   id=80 other                  "No Obligation to Proceed"
--   id=81 dispute_resolution    "Injunctive Relief"
--   id=82 other                  "Compliance"
--   id=83 governing_law         "Governing Law and Dispute Resolution"
--   id=84 other                  "Entire Agreement, Assignment and Counterparts"

BEGIN;

UPDATE contract_clause
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE id BETWEEN 74 AND 84
   AND is_seed = FALSE
   AND is_active = TRUE;

-- Belt-and-suspenders: also flip is_active on any template-clause
-- linkage rows so the rows fall out of any list / count queries that
-- traverse via the linkage table. (None expected per pre-flight probe,
-- but harmless if any landed since.)
UPDATE contract_template_clause
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE clause_id BETWEEN 74 AND 84
   AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (608, '608_soft_delete_mercury_nda_clauses', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Rollback (manual): UPDATE contract_clause SET is_active = TRUE WHERE id BETWEEN 74 AND 84;
