-- Migration: 468_m22_connector_catalog_seed.sql
-- Module: M22 / CR-MIG-DRIVE — connector catalog + tenant config
-- Date: 2026-06-02
--
-- Seeds the 9 source-picker tiles. Only Google Drive is `available` in
-- Phase 1; the others are `coming_soon` (tooltip-only in UI).
-- Also seeds the per-tenant confidence threshold (default 80).

BEGIN;

CREATE TABLE IF NOT EXISTS connector_catalog (
  id              BIGSERIAL PRIMARY KEY,
  provider        TEXT NOT NULL UNIQUE
    CHECK (provider IN ('google_drive','sharepoint','onedrive','box','dropbox',
                        'email_imap','sftp','ivalua','sap_ariba')),
  display_name    TEXT NOT NULL,
  tagline         TEXT,
  status          TEXT NOT NULL DEFAULT 'coming_soon'
    CHECK (status IN ('available','coming_soon','deprecated')),
  phase           INTEGER NOT NULL DEFAULT 2 CHECK (phase IN (1, 2, 3)),
  logo_key        TEXT,
  sort_order      INTEGER NOT NULL DEFAULT 100,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE connector_catalog IS
  'M22 — public catalog of source-picker tiles. Phase 1 ships google_drive=available; others coming_soon.';

INSERT INTO connector_catalog (provider, display_name, tagline, status, phase, logo_key, sort_order)
VALUES
  ('google_drive',  'Google Drive',                'OAuth · PDF / DOCX / Sheets', 'available',   1, 'google_drive',  10),
  ('sharepoint',    'Microsoft SharePoint',        'Graph API · enterprise sites','coming_soon', 2, 'sharepoint',    20),
  ('onedrive',      'Microsoft OneDrive',          'Personal + business drives',  'coming_soon', 2, 'onedrive',      30),
  ('box',           'Box',                         'Enterprise content cloud',    'coming_soon', 2, 'box',           40),
  ('dropbox',       'Dropbox Business',            'Team folders',                'coming_soon', 2, 'dropbox',       50),
  ('email_imap',    'Email inbox (Gmail / Outlook)','IMAP · attachment harvest',  'coming_soon', 2, 'email_imap',    60),
  ('sftp',          'SFTP / network folder',       'Legacy file shares',          'coming_soon', 2, 'sftp',          70),
  ('ivalua',        'Ivalua CLM',                  'Direct migration · Phase 3',  'coming_soon', 3, 'ivalua',        80),
  ('sap_ariba',     'SAP Ariba',                   'Direct migration · Phase 3',  'coming_soon', 3, 'sap_ariba',     90)
ON CONFLICT (provider) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  tagline      = EXCLUDED.tagline,
  status       = EXCLUDED.status,
  phase        = EXCLUDED.phase,
  logo_key     = EXCLUDED.logo_key,
  sort_order   = EXCLUDED.sort_order,
  updated_at   = now();

-- Extend system_setting.category to include 'migration'
ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
  CHECK (category = ANY (ARRAY[
    'general','uae_pass','branding','security','email','calendar',
    'audit_retention','ai','scoring','risk_case','regulatory','financial',
    'migration'
  ]));

-- Per-tenant confidence threshold for `imported` vs `needs_review`. Default 80.
INSERT INTO system_setting (key, value, description, category, is_secret, is_active)
SELECT
  'migration.confidence_threshold',
  jsonb_build_object('threshold', 80, 'updatedAt', now()),
  'M22 — confidence floor for auto-import. Records with avg confidence < this land in needs_review.',
  'migration',
  FALSE,
  TRUE
WHERE NOT EXISTS (
  SELECT 1 FROM system_setting WHERE key = 'migration.confidence_threshold'
);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (468, '468_m22_connector_catalog_seed', CURRENT_TIMESTAMP);

COMMIT;
