-- ============================================================================
-- 048_m5_regulator_lookup.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0 (user, fn_audit_trigger, fn_current_user_has_permission).
-- ----------------------------------------------------------------------------
-- Per Gate 2 Q3 = (b) shared lookup. Creates the regulator lookup table referenced
-- by both regulation.issuer_id (M5 049) and regulatory_update.regulator_id (049).
-- 9 default UAE regulator seed rows; ON CONFLICT DO NOTHING idempotent.
--
-- Audit trigger: STANDARD (id BIGSERIAL is fn_audit_trigger.NEW.id compatible).
-- RLS: SELECT — any authenticated; INSERT/UPDATE/DELETE — config.manage gated.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. regulator (lookup table)
-- ============================================================================
CREATE TABLE regulator (
  id             BIGSERIAL PRIMARY KEY,

  code           VARCHAR(40)  NOT NULL UNIQUE,
  name_en        VARCHAR(200) NOT NULL,
  name_ar        VARCHAR(200),
  jurisdiction   VARCHAR(40),
  description_en TEXT,
  description_ar TEXT,
  source_url     TEXT,
  display_order  INTEGER      NOT NULL DEFAULT 0,
  is_seed        BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by     BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by     BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active      BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE regulator IS
  'M5 shared lookup table for UAE regulators. Used by both regulation.issuer_id and regulatory_update.regulator_id (Q3 option (b)). Admin-managed.';

-- ============================================================================
-- 2. Indexes
-- ============================================================================
CREATE INDEX idx_regulator_active     ON regulator(id) WHERE is_active = TRUE;
CREATE INDEX idx_regulator_created_by ON regulator(created_by);
CREATE INDEX idx_regulator_updated_by ON regulator(updated_by);
CREATE INDEX idx_regulator_code       ON regulator(code) WHERE is_active = TRUE;

-- ============================================================================
-- 3. Audit trigger (STANDARD; id BIGSERIAL is trigger-compatible per M5-CC-2)
-- ============================================================================
CREATE TRIGGER audit_regulator_changes
  AFTER INSERT OR UPDATE OR DELETE ON regulator
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================================
-- 4. RLS — SELECT any authenticated; modify config.manage only
-- ============================================================================
ALTER TABLE regulator ENABLE ROW LEVEL SECURITY;

CREATE POLICY regulator_select_authenticated ON regulator
  FOR SELECT
  USING (TRUE);

CREATE POLICY regulator_modify_admin_only ON regulator
  FOR ALL
  USING (fn_current_user_has_permission('config.manage'))
  WITH CHECK (fn_current_user_has_permission('config.manage'));

-- ============================================================================
-- 5. Seed — 9 UAE regulators (Q3=(b) shared lookup)
-- ============================================================================
INSERT INTO regulator (code, name_en, name_ar, jurisdiction, display_order, is_seed) VALUES
  ('MoHRE',        'Ministry of Human Resources and Emiratisation', 'وزارة الموارد البشرية والتوطين', 'uae_federal', 10, TRUE),
  ('FTA',          'Federal Tax Authority',                          'الهيئة الاتحادية للضرائب',     'uae_federal', 20, TRUE),
  ('Central Bank', 'Central Bank of the UAE',                        'مصرف الإمارات المركزي',         'uae_federal', 30, TRUE),
  ('DIFC',         'Dubai International Financial Centre',           'مركز دبي المالي العالمي',       'difc',         40, TRUE),
  ('ADGM',         'Abu Dhabi Global Market',                        'سوق أبوظبي العالمي',           'adgm',         50, TRUE),
  ('TDRA',         'Telecommunications and Digital Government Regulatory Authority', 'هيئة تنظيم الاتصالات والحكومة الرقمية', 'uae_federal', 60, TRUE),
  ('MoJ',          'Ministry of Justice',                            'وزارة العدل',                   'uae_federal', 70, TRUE),
  ('MoE',          'Ministry of Economy',                            'وزارة الاقتصاد',                'uae_federal', 80, TRUE),
  ('Other',        'Other / Unspecified',                            'أخرى',                          NULL,           99, TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (48, 'm5_regulator_lookup', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP POLICY IF EXISTS regulator_modify_admin_only        ON regulator;
DROP POLICY IF EXISTS regulator_select_authenticated     ON regulator;
DROP TRIGGER IF EXISTS audit_regulator_changes ON regulator;
DROP TABLE IF EXISTS regulator;
DELETE FROM schema_migrations WHERE version = 48;
COMMIT;
-- ROLLBACK END
