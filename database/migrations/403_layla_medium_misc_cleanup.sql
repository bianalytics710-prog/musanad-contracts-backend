-- Migration: 403_layla_medium_misc_cleanup.sql
-- Unit: Layla Counsel QA medium-pass — L35
--
-- L35 — Eman Executive (user_id=8, role=executive) drafted MUSANAD-2026-039
--       Dubai South Logistics Cancelled SOW. Executives don't draft SOWs.
--       Re-attribute to Dana Drafter (user 5).

UPDATE contract
   SET drafted_by = COALESCE(
         (SELECT id FROM "user" WHERE email = 'drafter@musanad.local' LIMIT 1),
         drafted_by
       ),
       updated_at = NOW()
 WHERE contract_number = 'MUSANAD-2026-039';
