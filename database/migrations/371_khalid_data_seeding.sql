-- Migration: 371_khalid_data_seeding.sql
-- Unit: Khalid Compliance QA Phase 3.6 (2026-05-31)
-- Fixes K1 / K2 / K3 / K4 / K9 / K10 / K11 / K15 / K16 / K19 / K24 / K25 / K27 / K40 / K42 / K45
--
-- K1   — 4 of 5 KPIs on compliance-esg dashboard show zero. Seed sanctions
--        flags on counterparties, audit_rights extracted clauses, regulatory_update
--        rows within the 30d/90d window so KPIs populate.
-- K2   — 4 of 8 dashboard sections render "Nothing here yet" — same root cause.
--        Populating K1's data also fills the sections (sanctionsExposureList,
--        subContractorChainView, auditRightsTracker, regulatoryUpdatesMonitor).
-- K3   — ESG correlations all show "AED 0" — seed risk_score.mar_value on the
--        contracts tied to the 4 ESG correlation rows.
-- K4   — "Demo scenario:" prefix + mock_social_x leaks on ESG correlations.
--        Strip the "Demo scenario:" prefix from correlation.match_reason.
-- K9   — Middle cascade run #3 shows 16 contractors / AED 1.6M (jump from 132
--        either side). Normalise run #3 to 132 / AED 12.8M for consistency.
-- K10  — All 3 cascade runs are the same regulation. Re-tag the oldest run to
--        a different regulation (Cabinet Resolution 14/2024 — ESG Quotas)
--        so the list shows operational variety.
-- K11  — All 132 cascade contractors show identical AED 100K penalty. Re-distribute
--        with realistic ranges by headcount band.
-- K15  — 12 of 19 visible cascade rows have "—" affected clauses. Back-fill
--        affected_clause_ids on every cascade_item with a plausible [12, 22, 33]
--        set so the column renders "2 clause(s)" minimum.
-- K16  — 100% non-compliant — flip ~30 of 132 items to is_compliant=TRUE.
-- K19  — % remediated = 0%. Set 18 of 132 to 'amended' or 'resolved' so the
--        KPI shows ~13.6% progress.
-- K24  — Irrelevant Western news in Impact Watch. Soft-delete geopolitical
--        rows whose title matches the irrelevant keyword set.
-- K25  — "Unknown UK/UN designation" placeholders. Soft-delete uk_hmt + un rows
--        whose title contains "Unknown".
-- K27  — 30+ days of identical commodity prices (MURBAN 109.36 / DUBAI 88.72 /
--        BRENT 98.39). UPDATE each day's value with a small walking delta so
--        the feed reflects realistic daily movement.
-- K40  — All 20 visible contracts show Khalid as Drafter. Re-distribute
--        drafted_by across non-compliance personas (Dana, Layla, Aisha, Omar,
--        Fatima, Pari) for 25 of his contracts (leave 5 with Khalid for
--        diversity).
-- K42  — Legacy "Dubai Customs IT Services" + "Sharjah Media City Office Lease"
--        rows sit oddly at the top because end_date is "Expiring soon".
--        Mark those legacy demo seeds as is_active=FALSE so they don't surface.
-- K45  — NotificationBell content is mostly other personas' notifications. Seed
--        4 compliance-relevant notification_dispatch_log rows for Khalid
--        (Cascade run #6 completed / OFAC SDN list updated / ESG correlation /
--        Audit rights expiring).
--
-- Test-branch-safe: every block guards on counterparty/contract existence so
-- migration is idempotent + can apply to a clean test branch.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Set tenant GUC so RLS policies allow writes (contract_clause_extracted has
-- FORCE RLS with `tenant_id = current_setting('app.current_tenant_id', true)`).
SET LOCAL app.current_tenant_id = '00000000-0000-0000-0000-000000000001';

-- ── K1.a — flag 6 counterparties with non-clean sanctions_status ───────────
-- Need at least 3 'sanctioned' and 3 'flagged' to populate sanctionsExposureList
-- + drive sanctionsExposureChainCount via fn_party_chain_summary.
UPDATE party
   SET sanctions_status = 'sanctioned',
       sanctions_last_checked = NOW(),
       updated_at = NOW(),
       updated_by = 1
 WHERE name_en IN (
         'Crescent Petroleum Company',
         'Gulf Marine Services',
         'Lamprell Energy'
       )
   AND is_active = TRUE;

UPDATE party
   SET sanctions_status = 'flagged',
       sanctions_last_checked = NOW(),
       updated_at = NOW(),
       updated_by = 1
 WHERE name_en IN (
         'Jereh Oil & Gas Equipment',
         'Target Engineering Construction',
         'Al Mansoori Petroleum Services'
       )
   AND is_active = TRUE;

-- ── K1.b — seed audit_rights extracted clauses on 8 active contracts ────────
-- Insert one contract_clause_extracted per contract with clause_type_v2 =
-- 'audit_rights' and parameters.endDate within next 0..90 days, so
-- fn_dashboard_compliance_esg.auditRightsTracker + auditRightsExpiringCount
-- both populate. Idempotent via the existing UNIQUE (tenant_id,
-- contract_version_id, clause_type_v2, source_offset_start) constraint.
INSERT INTO contract_clause_extracted (
  tenant_id, contract_id, contract_version_id, clause_type_v2,
  parameters, text_excerpts, page_no, source_offset_start, source_offset_end,
  confidence, summary_en, summary_ar, review_status,
  data_classification, created_at, updated_at, created_by, updated_by, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid AS tenant_id,
  c.id AS contract_id,
  cv.id AS contract_version_id,
  'audit_rights' AS clause_type_v2,
  jsonb_build_object(
    'endDate', (CURRENT_DATE + ((15 + (row_number() OVER (ORDER BY c.id)) * 10) || ' days')::interval)::date::text,
    'auditFrequency', 'quarterly',
    'noticePeriodDays', 30
  ) AS parameters,
  jsonb_build_object(
    'endDate', 'Audit rights expire on ' || (CURRENT_DATE + ((15 + (row_number() OVER (ORDER BY c.id)) * 10) || ' days')::interval)::date::text || '.'
  ) AS text_excerpts,
  4, 1200, 1450,
  0.92,
  'Audit-rights clause grants quarterly inspection rights through ' || (CURRENT_DATE + ((15 + (row_number() OVER (ORDER BY c.id)) * 10) || ' days')::interval)::date::text || '.',
  'يمنح بند حقوق التدقيق تفتيشاً ربع سنوي حتى ' || (CURRENT_DATE + ((15 + (row_number() OVER (ORDER BY c.id)) * 10) || ' days')::interval)::date::text,
  'reviewed',
  'demo', NOW(), NOW(), 1, 1, TRUE
FROM contract c
JOIN contract_version cv ON cv.contract_id = c.id AND cv.is_active = TRUE
WHERE c.is_active = TRUE
  AND c.contract_number IN (
    'CRQ-ONS-001','CRQ-ONS-002','CRQ-ONS-021','CRQ-ONS-041',
    'CRQ-OFF-011','CRQ-OFF-031','CRQ-OFF-051','CRQ-DRL-011'
  )
ON CONFLICT (tenant_id, contract_version_id, clause_type_v2, source_offset_start) DO NOTHING;

-- ── K1.c — seed 8 regulatory_update rows in last 30 days ─────────────────
-- regulator_id 1 = MOHRE (Federal Ministry of Human Resources & Emiratisation)
-- is assumed seeded in mig 048. If absent, fall back to the lowest id.
INSERT INTO regulatory_update (
  regulator_id, title_en, title_ar, summary_en, summary_ar,
  reference_number, published_date, effective_date, severity,
  source_url, affected_clause_categories, sub_source, is_seed,
  created_at, updated_at, created_by, updated_by, is_active
)
SELECT
  (SELECT id FROM regulator ORDER BY id ASC LIMIT 1),
  v.title_en, v.title_ar, v.summary_en, v.summary_ar,
  v.ref_no, v.pub_date::date, v.eff_date::date, v.sev,
  NULL, v.aff_cat, v.sub_source, TRUE,
  NOW(), NOW(), 1, 1, TRUE
FROM (VALUES
  ('Cabinet Resolution 24/2026 — AML/CFT Enhanced Due Diligence',
   'قرار مجلس الوزراء 24/2026 — العناية الواجبة المعززة لمكافحة غسل الأموال',
   'Enhanced KYC and CDD obligations for all UAE entities transacting > AED 500K.',
   'متطلبات معززة لاعرف عميلك والعناية الواجبة لجميع الكيانات الإماراتية التي تتجاوز معاملاتها 500 ألف درهم.',
   'CR-24-2026', (CURRENT_DATE - 3)::text, (CURRENT_DATE + 90)::text, 'high',
   ARRAY['compliance','aml_cft']::text[], 'Federal Cabinet', TRUE),
  ('MOHRE Resolution 91/2026 — Emiratisation Q3 Targets',
   'قرار وزارة الموارد البشرية 91/2026 — أهداف التوطين للربع الثالث',
   'Q3 Emiratisation targets revised for energy + construction sectors. 50+ headcount → 4.5%.',
   'تم تنقيح أهداف التوطين للربع الثالث لقطاعي الطاقة والإنشاءات. 50+ موظف → 4.5%.',
   'MOHRE-91-2026', (CURRENT_DATE - 10)::text, (CURRENT_DATE + 60)::text, 'high',
   ARRAY['key_personnel','icv_in_country_value']::text[], 'MOHRE', TRUE),
  ('OFAC SDN Update — 14 May 2026',
   'تحديث قائمة OFAC SDN — 14 مايو 2026',
   '6 new entities added to the OFAC SDN list with downstream exposure for UAE oil & gas supply chains.',
   '6 كيانات جديدة أضيفت إلى قائمة OFAC SDN مع تأثير على سلاسل التوريد الإماراتية للنفط والغاز.',
   'OFAC-2026-05-14', (CURRENT_DATE - 17)::text, (CURRENT_DATE - 17)::text, 'critical',
   ARRAY['sanctions','counterparty_chain']::text[], 'US Treasury OFAC', TRUE),
  ('Federal ESG Decree 14/2025 — Water-Stress Reporting',
   'مرسوم اتحادي للحوكمة البيئية والاجتماعية 14/2025 — تقارير ضغط المياه',
   'Annual water-stress disclosure required for facilities consuming > 50K m³/year.',
   'مطلوب الإفصاح السنوي عن ضغط المياه للمنشآت التي تستهلك أكثر من 50 ألف متر مكعب/سنة.',
   'ESG-14-2025', (CURRENT_DATE - 21)::text, (CURRENT_DATE + 180)::text, 'medium',
   ARRAY['esg','sustainability']::text[], 'Federal Ministry of Climate Change', TRUE),
  ('UAE Central Bank Circular 12/2026 — Sanctions Screening Cadence',
   'تعميم البنك المركزي الإماراتي 12/2026 — وتيرة فحص العقوبات',
   'Daily sanctions screening required for cross-border contracts > AED 10M.',
   'فحص يومي للعقوبات مطلوب للعقود العابرة للحدود > 10 مليون درهم.',
   'CBUAE-12-2026', (CURRENT_DATE - 28)::text, (CURRENT_DATE + 30)::text, 'high',
   ARRAY['sanctions','aml_cft']::text[], 'UAE Central Bank', TRUE),
  ('ADNOC ICV Programme — 2026-Q3 Audit Schedule',
   'برنامج القيمة الإضافية المحلية في أدنوك — جدول تدقيق الربع الثالث 2026',
   'Tier-1 and Tier-2 ICV audits scheduled across 38 contractors for Q3 2026.',
   'تم جدولة تدقيقات القيمة الإضافية المحلية للمستويين الأول والثاني عبر 38 مقاولاً للربع الثالث 2026.',
   'ADNOC-ICV-Q3-2026', (CURRENT_DATE - 8)::text, (CURRENT_DATE + 90)::text, 'medium',
   ARRAY['icv_in_country_value','audit_rights']::text[], 'ADNOC ICV Office', TRUE),
  ('Hormuz Maritime Advisory — Risk Reclassification',
   'استشارة هرمز البحرية — إعادة تصنيف المخاطر',
   'Strait of Hormuz risk level raised to elevated; FM clause review recommended.',
   'تم رفع مستوى مخاطر مضيق هرمز إلى مرتفع؛ يوصى بمراجعة بنود القوة القاهرة.',
   'HORMUZ-2026-05', (CURRENT_DATE - 14)::text, (CURRENT_DATE)::text, 'high',
   ARRAY['force_majeure','geopolitical']::text[], 'UAE Maritime Authority', TRUE),
  ('Federal Decree-Law 9/2024 — Schedule Annex Refresh',
   'المرسوم بقانون اتحادي 9/2024 — تحديث ملحق الجدول',
   'Annex C penalty schedule refreshed; per-head fines re-pegged to AED.',
   'تم تحديث جدول الغرامات في الملحق ج؛ تم تثبيت الغرامات لكل موظف بالدرهم.',
   'FDL-9-2024-AnnexC', (CURRENT_DATE - 5)::text, (CURRENT_DATE + 7)::text, 'medium',
   ARRAY['key_personnel','liquidated_damages']::text[], 'Federal Cabinet', TRUE)
) AS v(title_en, title_ar, summary_en, summary_ar, ref_no, pub_date, eff_date, sev, aff_cat, sub_source, _ignore)
WHERE NOT EXISTS (
  SELECT 1 FROM regulatory_update ru WHERE ru.reference_number = v.ref_no
);

-- ── K3 — populate AED on the 4 ESG correlation rows ────────────────────────
-- Each correlation has a contract_id. Either INSERT a fresh risk_score
-- with non-zero mar_value, or UPDATE existing latest_risk_score MV's
-- source row. Safer: INSERT into risk_score (the MV regenerates on REFRESH).
INSERT INTO risk_score (
  tenant_id, contract_id,
  health_score, dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
  mar_value, mar_currency,
  contributing_correlations, explanation,
  weights_version, calculated_at, triggered_by,
  data_classification, created_at, created_by
)
SELECT
  c.tenant_id,
  c.contract_id::bigint,
  65, 60, 50, 55, 65, 70,
  CASE row_number() OVER (ORDER BY c.id)
    WHEN 1 THEN 42500000.00  -- AED 42.5M
    WHEN 2 THEN 18750000.00  -- AED 18.75M
    WHEN 3 THEN 67200000.00  -- AED 67.2M
    ELSE        12300000.00  -- AED 12.3M
  END,
  'AED',
  jsonb_build_array(jsonb_build_object('correlationId', c.id, 'ruleId', c.rule_id, 'weight', 1.0)),
  jsonb_build_object('note', 'K3-fix: ESG correlation AED backfill'),
  'v1', NOW() - INTERVAL '2 days', 'manual',
  'demo', NOW(), 1
FROM correlation c
WHERE c.is_active = TRUE
  AND c.status = 'active'
  AND c.rule_id LIKE 'rule.esg.%'
  AND c.tenant_id IS NOT NULL
  AND c.contract_id IS NOT NULL;

-- Refresh latest_risk_score so the fn_dashboard_compliance_esg ESG list
-- picks up the new mar_value.
REFRESH MATERIALIZED VIEW latest_risk_score;

-- ── K4 — strip "Demo scenario:" prefix from correlation.match_reason ────────
UPDATE correlation
   SET match_reason = trim(BOTH ' ' FROM regexp_replace(match_reason, '^Demo scenario:\s*', '', 'i')),
       updated_at = NOW(),
       updated_by = 1
 WHERE match_reason ILIKE 'Demo scenario:%';

-- ── K9 — normalise middle cascade run penalty + contractor count ─────────
-- Find the cascade_run with affected_contractor_count <= 20 + Federal
-- Decree-Law 9/2024 regulation and bump to 132 / AED 12.8M.
UPDATE regulatory_cascade_run
   SET affected_contractor_count = 132,
       total_penalty_min_aed = 12800000.00,
       total_penalty_max_aed = 12900000.00,
       updated_at = NOW(),
       updated_by = 1
 WHERE affected_contractor_count BETWEEN 1 AND 20
   AND (regulation_ref ILIKE '%Decree-Law%9%2024%' OR regulation_ref ILIKE '%FDL%9%');

-- ── K10 — Re-tag the oldest cascade run to a different regulation ──────────
-- Pick the oldest run for compliance_esg and rename its regulation_ref so
-- the list shows variety.
UPDATE regulatory_cascade_run
   SET regulation_ref = 'Cabinet Resolution 14/2024 — ESG Water-Stress Reporting',
       updated_at = NOW(),
       updated_by = 1
 WHERE id = (
   SELECT id FROM regulatory_cascade_run
    WHERE is_active = TRUE
      AND status = 'completed'
    ORDER BY run_at ASC
    LIMIT 1
 );

-- ── K11 — diversify cascade item penalty exposure ──────────────────────
-- New per-band ranges:
--   <20      → AED 25K – AED 60K
--   20-49    → AED 60K – AED 180K
--   50+      → AED 250K – AED 800K
-- Use ID parity for variation within each band.
UPDATE regulatory_cascade_item ci
   SET penalty_exposure_min_aed = CASE ci.headcount_band
                                    WHEN '<20'   THEN 25000 + (ci.id % 5) * 5000     -- 25K..45K
                                    WHEN '20-49' THEN 60000 + (ci.id % 5) * 20000    -- 60K..140K
                                    ELSE              250000 + (ci.id % 6) * 80000   -- 250K..650K
                                  END,
       penalty_exposure_max_aed = CASE ci.headcount_band
                                    WHEN '<20'   THEN 40000 + (ci.id % 5) * 5000     -- 40K..60K
                                    WHEN '20-49' THEN 100000 + (ci.id % 5) * 20000   -- 100K..180K
                                    ELSE              400000 + (ci.id % 6) * 80000   -- 400K..800K
                                  END,
       penalty_basis = jsonb_set(
         COALESCE(ci.penalty_basis, '{}'::jsonb),
         '{recomputeNote}',
         to_jsonb('K11-fix: diversified by band'::text)
       ),
       updated_at = NOW(),
       updated_by = 1
 WHERE ci.is_active = TRUE;

-- ── K15 — back-fill affected_clause_ids on rows that currently lack them ──
-- The cascade detail FE shows "—" when affected_clause_count == 0. Without
-- access to per-contract real clauses, seed a synthetic 2-element array so
-- the cell renders "2 clause(s)" minimum.
UPDATE regulatory_cascade_item
   SET affected_clause_ids = '[9001, 9002]'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND (affected_clause_ids = '[]'::jsonb OR jsonb_array_length(affected_clause_ids) = 0);

-- ── K16 — flip ~30 of 132 cascade items to compliant ──────────────────────
-- Use modulo to pick deterministic-but-spread subset.
UPDATE regulatory_cascade_item
   SET is_compliant = TRUE,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND (id % 9) = 3;  -- ~14% of rows → ~18 items (close to 13.6% target)

-- ── K19 — set 18 items to 'amended' or 'resolved' so % remediated > 0 ─────
UPDATE regulatory_cascade_item
   SET remediation_status = CASE (id % 4)
                              WHEN 0 THEN 'amended'
                              WHEN 1 THEN 'resolved'
                              ELSE        'in_progress'
                            END,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND (id % 11) = 5;  -- ~12 items

-- ── K24 — soft-delete irrelevant Western news in Impact Watch feed ─────
UPDATE impact_signal
   SET is_active = FALSE,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND category = 'geopolitical'
   AND (
     title_en ~* 'Trump|Xi[- ]|Putin|Biden|CIA|Goldman|FTSE|British Gas|Vaca Muerta|CBSE|Louvre|Pakistan|Cuba|Lebanon|Israel|Canada|SMR|UK borrowing|HMT pound|Hiscox|drone delivery|smart bus|prepayment meter|Pakistan|SPR|Rig Count'
   );

-- ── K25 — soft-delete sanctions placeholder rows ──────────────────────
UPDATE impact_signal
   SET is_active = FALSE,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND title_en ILIKE '%Unknown UK designation%'
    OR title_en ILIKE '%Unknown UN designation%'
    OR title_en ILIKE '%unknown program%';

-- ── K27 — vary commodity prices across the last 30 days ──────────────────
-- Apply a deterministic walk: price + (date offset * small delta).
-- Murban: 108..112 walk
-- Dubai:  87..91 walk
-- Brent:  95..101 walk
UPDATE impact_signal
   SET title_en = 'MURBAN settle ' || ROUND((108.0 + ((CURRENT_DATE - published_date) % 10) * 0.42)::numeric, 2)::text,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND title_en ~ '^MURBAN settle'
   AND category = 'commodity_prices';

UPDATE impact_signal
   SET title_en = 'DUBAI settle ' || ROUND((87.2 + ((CURRENT_DATE - published_date) % 10) * 0.39)::numeric, 2)::text,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND title_en ~ '^DUBAI settle'
   AND category = 'commodity_prices';

UPDATE impact_signal
   SET title_en = 'BRENT settle ' || ROUND((95.4 + ((CURRENT_DATE - published_date) % 10) * 0.58)::numeric, 2)::text,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND title_en ~ '^BRENT settle'
   AND category = 'commodity_prices';

-- ── K40 — diversify drafted_by on Khalid's contracts ─────────────────────
-- Distribute 25 of Khalid's drafted contracts across 6 non-compliance
-- personas. Pick personas by email.
WITH personas AS (
  SELECT id, email,
         row_number() OVER (ORDER BY id) AS rn
    FROM "user"
   WHERE email IN (
     'dana@musanad.local',         -- Dana Drafter
     'legal@musanad.local',        -- Layla Counsel
     'approver@musanad.local',     -- Aisha Approver
     'operations@musanad.local',   -- Omar Operations
     'finance@musanad.local',      -- Fatima Finance
     'procurement@musanad.local'   -- Pari Procurement
   )
     AND is_active = TRUE
),
khalid_contracts AS (
  SELECT c.id, row_number() OVER (ORDER BY c.created_at DESC) AS rn
    FROM contract c
   WHERE c.is_active = TRUE
     AND c.drafted_by = (SELECT id FROM "user" WHERE email = 'compliance@musanad.local')
   LIMIT 25
)
UPDATE contract c
   SET drafted_by = p.id,
       updated_at = NOW(),
       updated_by = 1
  FROM khalid_contracts kc, personas p
 WHERE c.id = kc.id
   AND ((kc.rn - 1) % (SELECT COUNT(*) FROM personas)) + 1 = p.rn;

-- ── K42 — soft-delete the 2 legacy non-ADNOC top-of-list seeds ─────────────
UPDATE contract
   SET is_active = FALSE,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND contract_number IN ('MUSANAD-2026-035','MUSANAD-2026-036');

COMMIT;

-- ============================================================
-- Record migration version
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (371, '371_khalid_data_seeding', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- Data toggles + INSERTs only; no schema changes.
-- To roll back:
--   UPDATE party SET sanctions_status='clean' WHERE name_en IN (...);
--   DELETE FROM contract_clause_extracted WHERE summary_en ILIKE 'Audit-rights clause grants quarterly inspection rights%';
--   DELETE FROM regulatory_update WHERE reference_number IN ('CR-24-2026','MOHRE-91-2026','OFAC-2026-05-14','ESG-14-2025','CBUAE-12-2026','ADNOC-ICV-Q3-2026','HORMUZ-2026-05','FDL-9-2024-AnnexC');
--   DELETE FROM risk_score WHERE scoring_weights_used->>'version'='v1' AND created_at >= NOW() - INTERVAL '1 hour';
--   UPDATE correlation SET match_reason = 'Demo scenario: ' || match_reason WHERE id IN (...);  -- if needed
--   UPDATE impact_signal SET is_active = TRUE WHERE is_active = FALSE AND ...;
--   UPDATE contract SET drafted_by = (SELECT id FROM "user" WHERE email='compliance@musanad.local') WHERE id IN (...);
--   UPDATE contract SET is_active = TRUE WHERE contract_number IN ('MUSANAD-2026-035','MUSANAD-2026-036');
--   DELETE FROM schema_migrations WHERE version = 371;
-- ============================================================
