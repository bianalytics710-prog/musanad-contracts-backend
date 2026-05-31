-- Migration: 387_layla_remove_compose_from_legal_counsel.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — L91 Compose sidebar leak
--
-- Removes legal_counsel from default_role_codes of the contracts.compose module.
-- Layla reviews contracts; she does not author them from scratch via Compose.

UPDATE product_module
   SET default_role_codes = (
         SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb)
           FROM jsonb_array_elements(default_role_codes) AS elem
          WHERE elem #>> '{}' <> 'legal_counsel'
       ),
       updated_at = NOW()
 WHERE key = 'contracts.compose'
   AND default_role_codes ? 'legal_counsel';

-- Also revoke from any explicit role_module_access grants for legal_counsel
UPDATE role_module_access
   SET is_allowed = FALSE, updated_at = NOW(),
       reason = 'L91 — Compose not appropriate for legal_counsel'
 WHERE module_key = 'contracts.compose'
   AND role_id = (SELECT id FROM role WHERE name = 'legal_counsel')
   AND is_allowed = TRUE;
