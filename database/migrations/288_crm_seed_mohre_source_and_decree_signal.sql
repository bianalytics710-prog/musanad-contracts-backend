-- Migration: 288_crm_seed_mohre_source_and_decree_signal.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: (1) INSERT osint_source row for MOHRE Labor-Law Feed (mohre_labor).
--              (2) Seed the Federal Decree-Law No.9/2024 osint_signal via DEFINER
--                  fn_osint_signal_upsert (direct INSERT blocked by RESTRICTIVE RLS).
--                  GUCs set before call per migration 112 backfill precedent.
--                  dedupHash is REQUIRED by fn body (validated explicitly).
--              Both idempotent: ON CONFLICT DO NOTHING / UNIQUE on dedup_hash.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: MOHRE osint_source
INSERT INTO osint_source
  (tenant_id, source_id, display_name, display_name_ar, kind, format,
   refresh_seconds, source_reliability, enabled, metadata, data_classification,
   created_at, updated_at, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'mohre_labor',
  'MOHRE Labor-Law Feed',
  'تغذية قوانين العمل - وزارة الموارد البشرية',
  'regulatory',
  'json',
  86400,
  1.00,
  TRUE,
  '{"adapter":"mohre-labor","onDemand":true,"description":"Ministry of Human Resources and Emiratisation labor-law regulatory feed"}'::jsonb,
  'demo',
  NOW(), NOW(), TRUE
)
ON CONFLICT (tenant_id, source_id) DO NOTHING;

-- Step 2: Federal Decree-Law No.9/2024 signal via DEFINER fn_osint_signal_upsert
-- Direct INSERT is blocked by RESTRICTIVE RLS on osint_signal.
-- dedupHash is REQUIRED by fn_osint_signal_upsert body (validated at lines ~35-38).
-- Hash formula: source_id || '|' || event_date || '|' || lower(trim(title))
-- = 'mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments'
DO $$
DECLARE
  v_result JSONB;
BEGIN
  -- Set GUC context required by DEFINER fn (mirrors migration 112 backfill pattern)
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true);
  PERFORM set_config('app.current_user_id',
    (SELECT MIN(id)::text FROM "user" WHERE is_active = TRUE),
    true);

  SELECT fn_osint_signal_upsert(
    p_payload := '{
      "sourceId": "mohre_labor",
      "sourceReliability": 1.00,
      "fetchedAt": "2026-05-28T00:00:00Z",
      "eventDate": "2024-08-30",
      "kind": "regulatory",
      "signalKindSubtype": "manual_curated",
      "title": "Federal Decree-Law No. 9 of 2024 — Labor Relations Amendments",
      "summary": "Federal Decree-Law No. 9 of 2024, effective 2024-08-30, amends the UAE Labour Relations Law. Key provisions: (1) Emiratisation expanded to the 20–49 headcount band — employers must hire at least 1 Emirati by end-2024 and 2 Emiratis by 2025; (2) Fines for non-compliance range from AED 100,000 to AED 1,000,000 per violation; (3) MOHRE rulings carry court-equivalent enforcement force; (4) Fake-Emiratisation (fictitious registration) constitutes a criminal offence with additional sanctions.",
      "geographies": [{"isoCountry": "AE", "regionCode": "AE-AZ", "free": "United Arab Emirates — Federal"}],
      "affectedEntities": [{"entityType": "regulation", "name": "Federal Decree-Law No. 9 of 2024", "identifier": "UAE-FDL-9-2024"}],
      "severity": "high",
      "confidence": 1.00,
      "url": "https://mohre.gov.ae/en/laws-and-regulations/federal-laws.aspx",
      "rawPayload": {
        "decreeRef": "Federal Decree-Law No. 9 of 2024",
        "effectiveDate": "2024-08-30",
        "fineMin": 100000,
        "fineMax": 1000000,
        "emiratisationBand": "20-49",
        "bandTargets": {"end2024": 1, "2025": 2},
        "enforcement": "MOHRE rulings carry court-equivalent force",
        "criminalExposure": "fake-emiratisation is a criminal offence"
      },
      "dedupHash": "mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments",
      "dataClassification": "demo"
    }'::jsonb
  ) INTO v_result;

  RAISE NOTICE 'fn_osint_signal_upsert result: %', v_result;
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (288, '288_crm_seed_mohre_source_and_decree_signal', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 288;
-- -- Note: osint_signal has RESTRICTIVE DELETE-deny RLS; soft-delete or manual workaround needed.
-- -- UPDATE osint_signal SET is_active = FALSE WHERE dedup_hash = 'mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments';
-- DELETE FROM osint_source WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND source_id = 'mohre_labor';
-- COMMIT;
-- ============================================================
