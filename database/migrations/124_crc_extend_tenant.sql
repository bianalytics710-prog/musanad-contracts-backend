-- ============================================================
-- Migration 124 — CRC extend_tenant
-- ============================================================
-- Module:      M10 — CR-C
-- Description: ALTER tenant ADD `name` (UNIQUE, backfilled from display_name) +
--              `industry` + `risk_appetite` (CHECK enum, default 'standard') +
--              `data_region`. UPDATE the ADNOC seed row with brief defaults.
--              Add additive `tenant_admin_read` SELECT policy gated by tenant.read
--              (per OPEN-DECISION-H — preserves M7 baseline policies).
-- Decisions:   NAMING-CONFLICT-1 (ADD `name` as new column; preserve slug + display_name).
--              OPEN-DECISION-H (additive policy).
-- ============================================================

BEGIN;

-- 1. Add NULL columns (backfill before SET NOT NULL on `name`)
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS name TEXT;
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS industry TEXT;
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS risk_appetite TEXT NOT NULL DEFAULT 'standard'
  CHECK (risk_appetite IN ('low','standard','high'));
ALTER TABLE tenant ADD COLUMN IF NOT EXISTS data_region TEXT;

-- 2. Backfill name from display_name (NAMING-CONFLICT-1)
UPDATE tenant SET name = display_name WHERE name IS NULL;

-- 3. UPDATE ADNOC seed row defaults (idempotent — no-op once populated)
UPDATE tenant
   SET industry    = 'oil_gas',
       data_region = 'UAE'
 WHERE id = '00000000-0000-0000-0000-000000000001'::uuid
   AND (industry IS NULL OR data_region IS NULL);

-- 4. Promote name to NOT NULL + UNIQUE (after backfill complete)
ALTER TABLE tenant ALTER COLUMN name SET NOT NULL;
DO $tenant_name_unique$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'tenant_name_unique' AND conrelid = 'tenant'::regclass
  ) THEN
    ALTER TABLE tenant ADD CONSTRAINT tenant_name_unique UNIQUE (name);
  END IF;
END
$tenant_name_unique$;

-- 5. Index on name (partial — active rows only)
CREATE INDEX IF NOT EXISTS idx_tenant_name ON tenant(name) WHERE is_active = TRUE;

-- 6. Additive SELECT policy gated by tenant.read (OPEN-DECISION-H)
DROP POLICY IF EXISTS tenant_admin_read ON tenant;
CREATE POLICY tenant_admin_read ON tenant
  FOR SELECT
  USING (fn_current_user_has_permission('tenant.read'));

-- 7. COMMENT ON COLUMNs (Stage 2 standards)
COMMENT ON COLUMN tenant.name IS
  'NAMING-CONFLICT-1 resolution: human-display name, UNIQUE. Backfilled from display_name on existing rows. Slug retained for URL/code stability.';
COMMENT ON COLUMN tenant.industry IS
  'Free-form industry tag (oil_gas, energy, banking, ...). Lookup-table candidate post-pilot.';
COMMENT ON COLUMN tenant.risk_appetite IS
  'Closed-enum risk band: low / standard / high. CHECK enforced. DEFAULT ''standard''.';
COMMENT ON COLUMN tenant.data_region IS
  'ISO/region code for data-residency hints (UAE, EU, US). Free-form for now; lookup-table candidate post-pilot.';

COMMENT ON TABLE tenant IS
  'Customer tenant root. ADNOC (00000000-0000-0000-0000-000000000001) is the seed row. M7 introduced (slug + display_name + config_pack); CR-C (124) extends with name + industry + risk_appetite + data_region. config_pack default stays ''default'' per OPEN-DECISION-I; ADNOC seed has explicit ''adnoc''. parent_tenant_id deferred to pilot (INFO-E).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (124, 'crc_extend_tenant', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP POLICY IF EXISTS tenant_admin_read ON tenant;
-- DROP INDEX IF EXISTS idx_tenant_name;
-- ALTER TABLE tenant DROP CONSTRAINT IF EXISTS tenant_name_unique;
-- ALTER TABLE tenant DROP COLUMN IF EXISTS data_region;
-- ALTER TABLE tenant DROP COLUMN IF EXISTS risk_appetite;
-- ALTER TABLE tenant DROP COLUMN IF EXISTS industry;
-- ALTER TABLE tenant DROP COLUMN IF EXISTS name;
-- DELETE FROM schema_migrations WHERE version = 124;
-- COMMIT;
-- ROLLBACK END
