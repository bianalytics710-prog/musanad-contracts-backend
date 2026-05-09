-- ============================================================================
-- 108_m7_post_demo_hardening.sql
-- ============================================================================
-- Module:    M7 (CR-A) — post-demo hardening
-- Owner:     Direct work — surfaced during 2026-05-09 post-impl Playwright walk
-- Depends:   100..107 (CR-A) already applied
-- ----------------------------------------------------------------------------
-- Two demo-driven fixes:
--
-- (1) DROP TRIGGER audit_osint_signal_changes ON osint_signal
--     osint_signal is a write-only event-log table that ingests at high volume
--     (e.g. OFAC SDN ~178k entries/day). Auditing every insert overflows
--     audit_log past Neon free-tier 512MB project limit within one fetch
--     cycle. fn_osint_signal_upsert is the only writer in the data path; it
--     itself emits pg_notify('osint_signal_inserted') with actor_id from
--     app.current_user_id GUC, which serves as the canonical write trail.
--     Admin-driven UPDATE/DELETE through future fn_osint_signal_admin_*
--     should re-add a targeted trigger if needed.
--
-- (2) UPDATE 5 RSS source URLs to working free public feeds.
--     Original ADNOC pack URLs (Reuters Energy / S&P Platts / Argus Media /
--     Khaleej-with-querystring / GulfNews-business) all 401/403/404 against
--     unauthenticated GETs as of 2026-05-09. Replaced with working free
--     equivalents (BBC Business / OilPrice.com / Guardian Business / Khaleej
--     Times /rss/business / Gulf News /feed). source_id columns NOT renamed
--     — those are stable catalog identifiers and renaming would orphan prior
--     signals + history. Display names + URLs updated; metadata unchanged.
-- ----------------------------------------------------------------------------

BEGIN;

-- (1) Drop the audit trigger on osint_signal.
DROP TRIGGER IF EXISTS audit_osint_signal_changes ON osint_signal;

COMMENT ON TABLE osint_signal IS
  'M7 (CR-A 104) — OSINT signal store, renamed from impact_signal. Holds
   external normalised signals from OFAC/EU/UN/UK sanctions, RSS aggregator,
   commodity, GDELT, FX, plus R-LC manual_curated rows back-filled with
   signal_kind_subtype=manual_curated. Tenant-scoped via FORCE RLS using
   app.current_tenant_id GUC. Audit trigger DROPPED in 108 — write volume
   (~178k OFAC entries/sweep) blows Neon free-tier 512MB project limit. Use
   fn_osint_signal_upsert pg_notify trail + ai_request_log (M4) for audit.';

-- (2) Update RSS URLs to working free public feeds.
UPDATE osint_source SET
  url = 'https://feeds.bbci.co.uk/news/business/rss.xml',
  display_name = 'BBC Business RSS',
  display_name_ar = 'تغذية أخبار الأعمال — بي بي سي',
  updated_at = now()
 WHERE source_id = 'rss_reuters_energy';

UPDATE osint_source SET
  url = 'https://oilprice.com/rss/main',
  display_name = 'OilPrice.com Energy News',
  display_name_ar = 'أويل برايس — أخبار الطاقة',
  updated_at = now()
 WHERE source_id = 'rss_sp_platts';

UPDATE osint_source SET
  url = 'https://www.theguardian.com/uk/business/rss',
  display_name = 'Guardian Business RSS',
  display_name_ar = 'الغارديان — الأعمال',
  updated_at = now()
 WHERE source_id = 'rss_argus_oil';

UPDATE osint_source SET
  url = 'https://www.khaleejtimes.com/rss/business',
  updated_at = now()
 WHERE source_id = 'rss_khaleej_business';

UPDATE osint_source SET
  url = 'https://gulfnews.com/feed',
  updated_at = now()
 WHERE source_id = 'rss_gulf_business';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (108, 'm7_post_demo_hardening', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BLOCK (for /resume-debug visibility)
-- ============================================================================
-- BEGIN;
--   -- Restore the audit trigger
--   CREATE TRIGGER audit_osint_signal_changes
--     AFTER INSERT OR UPDATE OR DELETE ON osint_signal
--     FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();
--   -- Revert RSS URLs (back to original ADNOC pack — note: most return 4xx)
--   UPDATE osint_source SET url='https://www.reuters.com/business/energy/rss',
--     display_name='Reuters Energy RSS', display_name_ar='تغذية رويترز للطاقة'
--     WHERE source_id='rss_reuters_energy';
--   UPDATE osint_source SET url='https://www.spglobal.com/commodity-insights/en/rss-feed/oil',
--     display_name='S&P Global Platts Oil RSS', display_name_ar='تغذية بلاتس النفطية'
--     WHERE source_id='rss_sp_platts';
--   UPDATE osint_source SET url='https://www.argusmedia.com/en/rss/oil',
--     display_name='Argus Media Oil RSS', display_name_ar='تغذية أرغوس النفطية'
--     WHERE source_id='rss_argus_oil';
--   UPDATE osint_source SET url='https://www.khaleejtimes.com/rss?section=business'
--     WHERE source_id='rss_khaleej_business';
--   UPDATE osint_source SET url='https://gulfnews.com/rss/business'
--     WHERE source_id='rss_gulf_business';
--   DELETE FROM schema_migrations WHERE version=108;
-- COMMIT;
