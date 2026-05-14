# Data Dictionary — M17 + M18 / CR-I + CR-J
## Tier 2 Scenarios + Supporting Adapters AND Demo Harness

**Module:** M17 (CR-I) + M18 (CR-J) — Unit 6  
**Author:** Agent 15 (Documentation Generator)  
**Date:** 2026-05-14  
**Migration range applied:** 225..241 (17 of 20 planned)  
**DB head:** 242 (m0-foundation + test branches — mig 242 was in-flight defect fix)  
**Baseline before:** schema_migrations.version = 224

---

## 1. New Tables

### 1.1 `demo_seed_pack`

Versioned bundles of demo seed data referenced by `demo_scenario.seed_pack_ref`. Tenant-scoped. 8 rows seeded per tenant (one per scenario).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Row-level tenant isolation |
| `pack_id` | `TEXT` | NOT NULL, UNIQUE per tenant | Business key, e.g. `adnoc-cyclone-v1` |
| `version` | `INTEGER` | NOT NULL, DEFAULT 1 | Seed pack version; increment on content change |
| `description` | `TEXT` | nullable | Human-readable description |
| `fixture_path` | `TEXT` | nullable | Filesystem path under `seeds/adnoc-pack/scenarios/<scenario_id>/` |
| `payload` | `JSONB` | nullable | Inlined fallback payload when `fixture_path` is null |
| `is_active` | `BOOLEAN` | NOT NULL, DEFAULT true | Soft delete |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT now() | Audit |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT now() | Audit |
| `created_by` | `BIGINT` | FK → user(id) | Audit |
| `updated_by` | `BIGINT` | FK → user(id) | Audit |

**Indexes:** `idx_demo_seed_pack_tenant`, `idx_demo_seed_pack_pack_id`, `idx_demo_seed_pack_active` (partial, is_active=true)  
**RLS:** FORCE RLS, tenant isolation + Super Admin/platform_admin see-all  
**Audit trigger:** `audit_demo_seed_pack_changes` → `fn_audit_trigger()`  
**Delete strategy:** Soft (is_active=false). No hard deletes in normal operation.

---

### 1.2 `demo_scenario`

8 hero demo scenarios per tenant. Each row binds a seed pack reference, an event injection payload, and expected outcome baselines used for determinism assertion.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Row-level tenant isolation |
| `scenario_id` | `TEXT` | NOT NULL, UNIQUE per tenant, CHECK constraint | Closed set: `hormuz`, `ofac_sanctions`, `brent_review`, `epc_sla`, `renewal`, `cyclone`, `icv_shortfall`, `esg_subcontractor`. Extension via DDL. |
| `display_name_en` | `TEXT` | NOT NULL | English display name |
| `display_name_ar` | `TEXT` | NOT NULL | Arabic display name |
| `description` | `TEXT` | nullable | Scenario description |
| `tier` | `INTEGER` | NOT NULL, CHECK IN (1,2) | 1 = original CR-H Tier 1 scenarios; 2 = new CR-I scenarios |
| `seed_pack_ref` | `TEXT` | NOT NULL | Soft FK → demo_seed_pack.pack_id. Validated inside fn_demo_scenario_trigger via S2-23 pre-check. |
| `event_injection_payload` | `JSONB` | NOT NULL | Event injection spec (signals, correlations, drafts). **Sensitive — redacted from logs.** |
| `expected_outcomes` | `JSONB` | NOT NULL | Shape: `{ correlationCount, alertCount, advisoryDraftCount, signalCount }`. Baseline for determinism assertion. |
| `is_active` | `BOOLEAN` | NOT NULL, DEFAULT true | Soft delete; inactive scenarios cannot be triggered (409) |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT now() | Audit |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT now() | Audit |
| `created_by` | `BIGINT` | FK → user(id) | Audit |
| `updated_by` | `BIGINT` | FK → user(id) | Audit |

**Indexes:** `idx_demo_scenario_tenant`, `idx_demo_scenario_seed_pack_ref`, `idx_demo_scenario_tier`, `idx_demo_scenario_active` (partial)  
**RLS:** FORCE RLS, tenant isolation + admin see-all  
**Audit trigger:** `audit_demo_scenario_changes` → `fn_audit_trigger()`  
**Sensitive fields:** `event_injection_payload` — redacted by `fn_audit_trigger` redaction list (added in migration 230)  
**Design note:** CHECK constraint on `scenario_id` is intentional. Closed 8-value set is extendable via DDL by business-admin during pilot. No lookup table needed per dependency report §8.

---

### 1.3 `demo_scenario_run`

Append-only audit table. Records every scenario trigger event with outcome JSONB, elapsed_ms, and success flag. Never updated or deleted in normal operation.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Row-level tenant isolation |
| `demo_scenario_id` | `BIGINT` | NOT NULL, FK → demo_scenario(id) RESTRICT | Parent scenario |
| `triggered_by` | `BIGINT` | NOT NULL, FK → user(id) RESTRICT | Actor who triggered the run |
| `triggered_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT now() | Trigger timestamp |
| `outcome` | `JSONB` | nullable | Actual counts post-trigger: `{ correlationCount, alertCount, advisoryDraftCount, signalCount }`. Compared to expected_outcomes for determinism assertion. |
| `success` | `BOOLEAN` | NOT NULL | Whether the run completed without error |
| `elapsed_ms` | `INTEGER` | nullable | Wall-clock duration in milliseconds |
| `error_message` | `TEXT` | nullable | Error detail when success=false. **Sensitive — redacted from logs.** |
| `is_active` | `BOOLEAN` | NOT NULL, DEFAULT true | Retained for schema consistency; rows never soft-deleted in practice |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT now() | Audit |
| `created_by` | `BIGINT` | FK → user(id) | Audit |

**Indexes:** `idx_demo_scenario_run_tenant`, `idx_demo_scenario_run_demo_scenario`, `idx_demo_scenario_run_triggered_by`, `idx_demo_scenario_run_triggered_at DESC`, `idx_demo_scenario_run_success`  
**RLS:** FORCE RLS, tenant isolation + RESTRICTIVE deny-DELETE policy (`USING (false)`)  
**Audit strategy:** Strategy A — in-fn audit inside `fn_demo_scenario_trigger`. No default `fn_audit_trigger()` applied.  
**Sensitive fields:** `error_message` — redacted from logs (added in migration 230)  
**Delete strategy:** Effectively immutable. RESTRICTIVE RLS denies all DELETE attempts at row level. Hard-delete rationale: append-only log table; `is_active` retained for schema consistency only.

---

## 2. Extended Tables (seed-only, no schema change)

These tables received new seed rows in this module. No DDL changes.

| Table | Existing Owner | Change |
|---|---|---|
| `osint_source` | CR-A / M7 | +11 rows: 4 live adapters (openweather, ncm_uae, noaa_gfs, internal:icv_custom) + 6 RSS sub-feeds (rss_the_national, rss_meed, rss_energy_voice, rss_oil_gas_journal, rss_reuters_sanctions, rss_uae_gov) + 1 mocked (mock_social_x) |
| `correlation_rule` | CR-E / M13 | +1 row: `rule.weather.fm_eligible` (SLA 8h, alerts legal_counsel + operations, geography Persian Gulf/Oman) |
| `correlation_rule_fixture` | CR-E / M13 | +2 rows: positive fixture (critical severity + O&M contract → ≥1 correlation) + negative fixture (low severity → 0 correlations) |
| `advisory_template` | CR-H / M16 | +4 rows: `icv_rectification_notice_v1`, `weather_fm_notice_v1`, `esg_concern_memo_v1` (in_app only, no email per Annex C.8.3), `insurance_renewal_reminder_v1` |
| `permission` | M0 | +4 rows: demo.scenario.trigger, demo.reset, demo.time_freeze.manage, demo.health_check.read |
| `role_permission` | M0 | +8 rows: all 4 new permissions × 2 roles (platform_admin, Super Admin) |
| `demo_seed_pack` | (NEW this module) | +8 rows (one per scenario) |
| `demo_scenario` | (NEW this module) | +8 rows per tenant |
| `osint_signal` | CR-A / M7 | +30 synthetic ESG mocked rows (data_classification='demo') referencing seeded counterparties |

---

## 3. New fn_ Functions (17 net-new)

All fn_'s have the REVOKE/GRANT/COMMENT post-definition trio (S2-21 — 17th consecutive clean streak preserved).

### 3.1 Helper / Infrastructure

| fn_ | Signature | Volatility | Security | Purpose |
|---|---|---|---|---|
| `fn_demo_now` | `fn_demo_now() RETURNS TIMESTAMPTZ` | STABLE | INVOKER | Canonical "now" for time-sensitive business logic. Returns `coalesce(current_setting('app.demo.time_now', true)::timestamptz, now())`. Created first (migration 225) as the dependency foundation for the time-freeze feature. |
| `fn_demo_data_purge` | (EXTEND — existing CR-C signature preserved) | VOLATILE | DEFINER | Extended in migration 230 to 53-table topology. Adds 9 missing tables to purge order: `advisory_dispatch_log`, `advisory_draft`, `notification_dispatch_log`, `risk_score`, `correlation_evaluation_error`, `correlation`, `contract_clause_extracted`, `ingestion_review_queue`, `demo_scenario_run`. Also refreshes `latest_risk_score` MV post-purge. |

### 3.2 Seed Helpers (migration-internal only — no HTTP endpoints)

| fn_ | Purpose |
|---|---|
| `fn_demo_seed_load_sources` | Idempotent reload of osint_source seed rows. Called by fn_demo_reset. |
| `fn_demo_seed_load_rules` | Idempotent reload of correlation_rule + fixture seed rows. Called by fn_demo_reset. |
| `fn_demo_seed_load_templates` | Idempotent reload of advisory_template seed rows. Called by fn_demo_reset. |
| `fn_demo_seed_load_signals` | Idempotent reload of 30 mocked ESG osint_signal seed rows. Called by fn_demo_reset. |
| `fn_osint_source_seed_cri_batch` | Migration-only: inserts 11 CR-I osint_source rows via ON CONFLICT DO NOTHING. |
| `fn_correlation_rule_seed_weather_fm_eligible` | Migration-only: inserts rule.weather.fm_eligible + 2 fixtures; verifies existing ESG fixtures. |
| `fn_advisory_template_seed_cri_batch` | Migration-only: inserts 4 advisory_template rows with EN+AR Mustache bodies + parameter_schema. |

### 3.3 Demo Harness — Write Functions

| fn_ | Signature | Volatility | Security | Permission Gate |
|---|---|---|---|---|
| `fn_demo_scenario_trigger` | `(p_actor_id BIGINT, p_scenario_id TEXT) RETURNS JSONB` | VOLATILE | DEFINER | `demo.scenario.trigger` |
| `fn_demo_reset` | `(p_actor_id BIGINT, p_confirm_token TEXT) RETURNS JSONB` | VOLATILE | DEFINER | `demo.reset` |
| `fn_demo_time_freeze_set` | `(p_actor_id BIGINT, p_target_timestamp TIMESTAMPTZ) RETURNS JSONB` | VOLATILE | DEFINER | `demo.time_freeze.manage` |
| `fn_demo_time_unfreeze` | `(p_actor_id BIGINT) RETURNS JSONB` | VOLATILE | DEFINER | `demo.time_freeze.manage` |
| `fn_demo_time_freeze_current` | `(p_actor_id BIGINT) RETURNS JSONB` | VOLATILE | DEFINER | `demo.time_freeze.manage` |

**fn_demo_scenario_trigger key behaviors:**
- Acquires `pg_advisory_xact_lock(hashtextextended(tenant_id::text || ':' || p_scenario_id, 0))` — block-and-queue (never error) for concurrent same-(tenant, scenario) triggers (HITL CR-J-Q2).
- Idempotent event injection via `ON CONFLICT DO NOTHING` — re-trigger after reset yields identical outcomes (AC-S16).
- Outcome JSONB captured post-trigger via `created_at >= v_started_at` window snapshot.
- Records `demo_scenario_run` row with `success=false + error_message` on exception path (run committed even on failure).
- NULLIF(p_actor_id, 0) coercion in audit writes — SYSTEM_ACTOR_ID sentinel.

**fn_demo_reset key behaviors:**
- `SET LOCAL statement_timeout = '120s'` — handles 163K demo signal purge on live DB.
- Confirm token validated against `current_setting('app.demo.reset_token')` — single-use, session-scoped rolling UUID issued by controller (DN-4 in api-contracts.json).
- `slaWarn=true` when elapsed > 60s — `pg_notify('demo.reset.sla_warn')` emitted for monitoring. Operation does NOT fail (HITL CR-J-Q3).
- `fn_demo_time_freeze_set` truncates seconds/microseconds to minute granularity (HITL CR-J-Q1) via `date_trunc('minute', p_target_timestamp)`.

### 3.4 Demo Harness — Read Functions

| fn_ | Signature | Volatility | Security | Permission Gate |
|---|---|---|---|---|
| `fn_demo_scenario_list` | `(p_actor_id BIGINT, p_only_active BOOLEAN DEFAULT TRUE) RETURNS JSONB` | STABLE | INVOKER | `demo.scenario.trigger OR demo.reset` |
| `fn_demo_scenario_get` | `(p_actor_id BIGINT, p_id BIGINT) RETURNS JSONB` | STABLE | INVOKER | `demo.scenario.trigger` |
| `fn_demo_scenario_run_list` | `(p_actor_id BIGINT, p_page INT DEFAULT 1, p_limit INT DEFAULT 20, p_scenario_id TEXT DEFAULT NULL, p_success BOOLEAN DEFAULT NULL) RETURNS JSONB` | STABLE | INVOKER | `demo.scenario.trigger` |
| `fn_pre_demo_health_check` | `(p_actor_id BIGINT) RETURNS JSONB` | STABLE | INVOKER | `demo.health_check.read` |

**fn_pre_demo_health_check:** Probes 9 subsystems using S2-24 split-aggregate CTE pattern (inner per-subsystem CTEs → outer `jsonb_agg`). Returns DB-probeable subsystems (db, sources, rules, scoring, advisory, notification). BE controller merges real HTTP probes for storage, openai, smtp before responding. NFR: < 5s (AC-S15-03).

### 3.5 Rule Evaluation

| fn_ | Signature | Purpose |
|---|---|---|
| `fn_rule_evaluate_weather_fm_eligible` | `(p_signal_id BIGINT) RETURNS JSONB` | Evaluates rule.weather.fm_eligible: matches high-severity weather signal × O&M/drilling/charter_party contract with weather/FM/excusable_delay clause in Persian Gulf/Gulf of Oman bbox. Creates correlation rows via ON CONFLICT DO NOTHING. SLA 8h; alerts legal_counsel + operations. |

---

## 4. New Permissions

| Code | Description | Granted To |
|---|---|---|
| `demo.scenario.trigger` | Trigger demo scenarios via admin panel | platform_admin, Super Admin |
| `demo.reset` | Reset demo data + reload seed packs | platform_admin, Super Admin |
| `demo.time_freeze.manage` | Set/clear demo time freeze GUC | platform_admin, Super Admin |
| `demo.health_check.read` | Read pre-demo health check status | platform_admin, Super Admin |

All 4 new permissions are admin-only by design. No grants to legal_counsel, compliance_esg, procurement, or operations.

---

## 5. New BE Adapters (CR-I Tier 2)

5 new adapter classes under `src/adapters/`. The existing `RssAdapter` handles the 6 new RSS feeds via osint_source row configuration — no new per-RSS adapter class needed.

| File | Class | Cadence | Stub Mode |
|---|---|---|---|
| `src/adapters/open-weather.adapter.ts` | `OpenWeatherAdapter` | hourly | `WEATHER_API_KEY` not set → mock payload |
| `src/adapters/ncm-uae.adapter.ts` | `NcmUaeAdapter` | 30 min | Live RSS fetch fails → mock fixture |
| `src/adapters/open-meteo-noaa.adapter.ts` | `OpenMeteoNoaaAdapter` | 6h (00:00/06:00/12:00/18:00 UTC) | Live fetch fails → mock payload |
| `src/adapters/icv-custom.adapter.ts` | `IcvCustomAdapter` | on-trigger only (no cron — HITL CR-I-Q3) | Reads `tests/fixtures/osint/mock_icv/*.json` |
| `src/adapters/mock-social-x.adapter.ts` | `MockSocialXAdapter` | on-trigger only (no cron) | Reads `tests/fixtures/osint/mock_x/*.json` |

**Severity mappings:**
- OpenWeather: windspeed ≥ 20 m/s → high, ≥ 12 m/s → medium, else informational
- NCM UAE: Red Alert → critical, Orange → high, Yellow/Advisory → medium
- Open-Meteo: windspeed ≥ 50 km/h → high, ≥ 30 km/h → medium
- ICV Custom / Mock-X: severity from fixture field

**Geography constraint (noaa_gfs/open-meteo):** Persian Gulf + Gulf of Oman bounding box only.

---

## 6. Time-Freeze Refactor — Deferred Debt (DEBT-CRIJ-1)

**Status:** DEFERRED. Scheduled as follow-up CR or Unit 6 polish round.

The DB design planned 18 fn_ body rewrites (migrations 240–242) to replace business-logic `now()` calls with `fn_demo_now()` across legacy fn_'s. This was deferred during DB implementation due to the complexity of per-fn `pg_get_functiondef` inspection to distinguish business-arithmetic `now()` from audit-stamp `now()`.

**Impact:** The time-freeze GUC is correctly SET by `fn_demo_time_freeze_set`, but only the 17 newly-created CR-I+J fn_'s observe it. The legacy 18 fn_'s listed below still read raw `now()`:

| Migration | fn_'s | Category |
|---|---|---|
| mig 240 (deferred) | fn_dashboard_admin, fn_dashboard_approver, fn_dashboard_drafter, fn_dashboard_executive, fn_dashboard_legal_counsel, fn_dashboard_recipient, fn_dashboard_operations, fn_dashboard_finance_treasury, fn_dashboard_compliance_esg, fn_dashboard_procurement_supplier_risk | Dashboard |
| mig 241 (deferred) | fn_risk_score_compute, fn_risk_score_history, fn_avar_aggregate | Risk scoring |
| mig 242 (partially applied for defect fix) | fn_notification_send, fn_notification_dispatch_retry_due, fn_obligations_derive_from_clause, fn_source_health_record, fn_signature_invitation_expire_due | Notification / obligations |

**Consequence:** AC-CR-J-3 (run renewal scenario against frozen date) is PARTIAL — works for the newly-created demo-harness paths but not for legacy dashboard/risk calculations.

**S2-26 candidate:** Promote "time-freeze GUC propagation" check to mandatory Stage 2 check for future modules. Trigger condition: `now() + interval`, `now() - interval`, `< now()`, `> now()`, `age(now())`, `date_trunc(..., now())` in fn_ bodies.

---

## 7. Scenario Seed Packs (8 scenarios)

| scenario_id | pack_id | Tier | Description |
|---|---|---|---|
| `hormuz` | `adnoc-hormuz-v1` | 1 | Strait of Hormuz Disruption |
| `ofac_sanctions` | `adnoc-ofac-v1` | 1 | OFAC Sanctions Shock |
| `brent_review` | `adnoc-brent-v1` | 1 | Brent Crude Price Review |
| `epc_sla` | `adnoc-epc-sla-v1` | 1 | EPC SLA Breach |
| `renewal` | `adnoc-renewal-v1` | 1 | Contract Renewal Lookahead |
| `cyclone` | `adnoc-cyclone-v1` | 2 | Cyclone Force Majeure |
| `icv_shortfall` | `adnoc-icv-v1` | 2 | ICV Shortfall |
| `esg_subcontractor` | `adnoc-esg-subcon-v1` | 2 | ESG Sub-contractor Concern |

Seed pack directories: `seeds/adnoc-pack/scenarios/<scenario_id>/`

---

*Generated by Agent 15 (Documentation Generator) — Unit 6 / M17 + M18 / CR-I + CR-J — 2026-05-14*
