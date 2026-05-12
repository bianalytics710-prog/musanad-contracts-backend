-- ============================================================
-- Migration 136 — CRD0 permissions_grants_seed
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: INSERT seed data for CR-D0:
--              §7.1 — 3 net-new permission rows
--              §7.2 — 6 role_permission grants (Super Admin × 3 pre-emptive +
--                      legal_counsel × 1 + platform_admin × 2)
--              §7.3 — 1 ai_prompt row ('ai-document-ingestion-vision')
--                      FK prerequisite for Vision telemetry (N17 / A22 / X3).
--              §7.4 — 2 system_setting keys (category='ai').
--              All INSERTs use ON CONFLICT DO NOTHING (idempotent).
-- Ordering invariants:
--   - Runs AFTER 135 (category CHECK must allow 'ai' before INSERT).
--   - Runs BEFORE 137 (ai_prompt row must exist before Vision fn_'s reference it
--     via FK ON DELETE RESTRICT).
-- SOT: §9 CR-D0, §7 Seed Data, OPEN-DECISION-L Path A.
-- ============================================================

BEGIN;

-- ============================================================
-- §7.1 — 3 net-new permission rows
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('document.ingest',
   'document', 'ingest',
   'CR-D0 system-only — invoke document ingestion fn_''s (queued by upload controller). Granted to Super Admin for break-glass debugging only; normal flow uses DEFINER fn + system-bootstrap context.',
   TRUE),
  ('document.review',
   'document', 'review',
   'CR-D0 — review low-confidence ingestion pages (confirm/correct/reject). Granted to legal_counsel, platform_admin, and Super Admin (pre-emptive).',
   TRUE),
  ('ingestion_queue.read',
   'ingestion_queue', 'read',
   'CR-D0 — read-only access to admin ingestion-queue monitor (/app/admin/ingestion-queue). Granted to platform_admin and Super Admin.',
   TRUE)
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- §7.2 — 6 role_permission grants
-- Super Admin × document.ingest   (break-glass debugging — OPEN-DECISION-L Path A)
-- Super Admin × document.review   (pre-emptive — M1a 006 / M3 037 / M4 044 lesson)
-- legal_counsel × document.review
-- platform_admin × document.review
-- Super Admin × ingestion_queue.read   (pre-emptive)
-- platform_admin × ingestion_queue.read
-- ============================================================
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('Super Admin',    'document.ingest'),
  ('Super Admin',    'document.review'),
  ('legal_counsel',  'document.review'),
  ('platform_admin', 'document.review'),
  ('Super Admin',    'ingestion_queue.read'),
  ('platform_admin', 'ingestion_queue.read')
) AS grants(role_name, perm_code)
JOIN role       r ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================
-- §7.3 — 1 ai_prompt row (FK prerequisite for Vision telemetry)
-- CRITICAL: Must be present before 137 creates fn_'s that write ai_request_log
--           rows referencing this prompt_id via FK ON DELETE RESTRICT.
-- Note: ai_prompt table has no prompt_body/prompt_text column — text stored in file.
-- ============================================================
INSERT INTO ai_prompt (
  prompt_id, description_en, description_ar,
  default_model, default_temperature, default_max_tokens, default_ttl_seconds,
  supports_streaming, supports_tool_call, public_endpoint, prompt_file_path,
  rate_limit_per_user_per_hour, rate_limit_per_user_per_day,
  is_active
) VALUES
  ('ai-document-ingestion-vision',
   'CR-D0 §4.11 — gpt-4o Vision verbatim text extraction for low-confidence Tesseract pages and Arabic-heavy contracts.',
   'CR-D0 §4.11 — استخراج نصي حرفي عبر gpt-4o Vision للصفحات منخفضة الثقة من Tesseract والعقود ذات المحتوى العربي الكثيف.',
   'gpt-4o', 0.10, 4096, 86400,
   FALSE, FALSE, FALSE, 'prompts/ai-document-ingestion-vision.txt',
   50, 500,
   TRUE)
ON CONFLICT (prompt_id) DO NOTHING;

-- ============================================================
-- §7.4 — 2 system_setting keys (category='ai')
-- Requires migration 135 to have widened the CHECK constraint first.
-- Q1 lock (0.75) + Q2 lock (500) — autonomous HITL Gate 2 decisions.
-- ============================================================
INSERT INTO system_setting (key, value, description, category, is_secret) VALUES
  ('ocr.confidence_threshold',
   '0.75'::jsonb,
   'Tesseract confidence below which a page is routed to gpt-4o Vision. Range [0.00..1.00]. Q1 lock (autonomous-mode default 0.75). Configurable at admin/config without redeploy (OPEN-DECISION-K / N20).',
   'ai',
   FALSE),
  ('ai.daily_vision_cap_pages',
   '500'::jsonb,
   'Per-tenant daily gpt-4o Vision page consumption cap. Q2 lock (autonomous-mode default 500 pages/day — ADNOC demo budget). When 80% reached, admin notification queued; at 100%, low-confidence pages route to pending_human review_status without invoking Vision (AC-S3-03 / AC-S3-05).',
   'ai',
   FALSE)
ON CONFLICT (key) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (136, 'crd0_permissions_grants_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM system_setting WHERE key IN ('ocr.confidence_threshold', 'ai.daily_vision_cap_pages');
-- DELETE FROM ai_prompt WHERE prompt_id = 'ai-document-ingestion-vision';
-- DELETE FROM role_permission
--   WHERE (role_id, permission_id) IN (
--     SELECT r.id, p.id FROM role r JOIN permission p ON TRUE
--      WHERE (r.name, p.code) IN (
--        ('Super Admin','document.ingest'), ('Super Admin','document.review'),
--        ('legal_counsel','document.review'), ('platform_admin','document.review'),
--        ('Super Admin','ingestion_queue.read'), ('platform_admin','ingestion_queue.read')
--      )
--   );
-- DELETE FROM permission WHERE code IN ('document.ingest','document.review','ingestion_queue.read');
-- DELETE FROM schema_migrations WHERE version = 136;
-- COMMIT;
-- ROLLBACK END
