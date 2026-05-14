# Technical Handoff — CR-I + CR-J (M17 + M18)
## Tier 2 Scenarios + Supporting Adapters AND Demo Harness

**Unit:** 6 (CR-I + CR-J combined)  
**Modules:** M17 (CR-I — Tier 2 Adapters + Rules + Templates) + M18 (CR-J — Demo Harness)  
**Date shipped:** 2026-05-14  
**QA verdict:** SHIP-GO-WITH-WARNINGS (91 checks, 89 pass, 2 warn, 0 fail)  
**S2-21 streak:** 17th consecutive clean  
**Migrations applied:** 225..241 (17 of 20 planned; 3 deferred as DEBT-CRIJ-1)

---

## TL;DR

CR-I adds 4 new weather/ESG/ICV OSINT adapters, 6 additional RSS feeds, 1 new correlation rule (`rule.weather.fm_eligible`), and 4 advisory templates (ICV Rectification, Weather FM Notice, ESG Concern Memo, Insurance Renewal Reminder). CR-J adds a production-grade demo harness: 8 hero scenario cards with one-click trigger, a <60s reset utility, a session-scoped time-freeze GUC, and a 9-subsystem pre-demo health check — all accessible at `/app/admin/demo` (platform_admin / Super Admin only). The harness is deterministic: trigger → reset → re-trigger yields identical outcome counts (AC-S16). One debt item is carried: the 18-fn time-freeze refactor of legacy dashboards/risk/notification fn_'s is deferred to a follow-up CR (DEBT-CRIJ-1).

---

## Architecture Overview

### CR-I: Tier 2 Adapters

The adapter layer lives in `src/adapters/`. Each adapter implements a standard interface (`pull(): Promise<OsintSignalDto[]>`) and is registered in the existing `AdapterRegistry` from CR-A. Cron scheduling is handled by the existing OSINT worker (`src/workers/osint.worker.ts`) via the adapter registry — no new cron entries needed.

- **openweather / ncm-uae / open-meteo-noaa**: Live HTTP adapters with stub-mode fallback when API keys are absent.
- **icv-custom / mock-social-x**: Harness-triggered only (no cron). Read from `tests/fixtures/osint/` directories.
- **6 RSS feeds**: Handled by existing `RssAdapter`; no new classes. The 6 new `osint_source` rows with `source_id = rss_*` are picked up automatically by the adapter registry at runtime.

### CR-J: Demo Harness

```
FE: /app/admin/demo (AdminDemoControlPanel)
  └── ScenarioCardsGrid + ScenarioCard (trigger)
  └── HealthCheckPanel + SubsystemTile
  └── TimeFreezePanel (datetime-local + freeze/unfreeze)
  └── ResetSection → ResetConfirmModal (destructive 2-step)
  └── ScenarioRunsFeed (paginated, debounced filters)

BE: src/routes/v1/admin/demo-harness.routes.ts
  └── demo-harness.controller.ts (9 methods)
  └── demo-harness.service.ts (wraps fn_ calls; health-check fans out HTTP probes)
  └── demo-time-freeze.middleware.ts (X-Demo-Time-Now header reader)

DB: fn_demo_scenario_trigger → pg_advisory_xact_lock → idempotent event injection
    fn_demo_reset → fn_demo_data_purge (53-table topology) → seed reload
    fn_demo_time_freeze_set → SET session app.demo.time_now GUC
    fn_demo_now → coalesce(GUC, now()) — consumed by all new time-sensitive fn_'s
```

**Concurrency model:** `pg_advisory_xact_lock(hashtextextended(tenant_id::text || ':' || p_scenario_id, 0))` — xact-scoped, auto-released on commit/rollback. Same-(tenant, scenario) triggers serialize (block-and-queue, never error). Cross-tenant and cross-scenario triggers proceed in parallel.

**Confirm token lifecycle (Reset):** Controller issues rolling UUID via `set_config('app.demo.reset_token', uuid, false)` on the same DB connection immediately before calling `fn_demo_reset`. The fn validates against `current_setting(...)` internally. Single-use, session-scoped. FE presents `RESET_DEMO_<YYYY-MM-DD>` — validated by Zod `.refine()`.

**Health check fan-out:** `fn_pre_demo_health_check` is STABLE — probes only DB-reachable subsystems (db, sources, rules, scoring, advisory, notification). BE controller fans out HTTP probes for storage, openai, smtp in parallel (`Promise.allSettled`, 3s timeout per probe) and merges the result before responding.

---

## HITL Decisions (7 autonomous resolutions)

| ID | Question | Decision | Rationale |
|---|---|---|---|
| CR-I-Q1 | NOAA data source: official NOAA API vs Open-Meteo proxy | Open-Meteo v1 (proxy) | NOAA GFS API requires EDL account + accepts ECMWF format; Open-Meteo provides equivalent Gulf grid data with no auth. Renamed `noaa_gfs` source_id kept for business naming continuity. |
| CR-I-Q2 | ESG rule regex: project default vs Annex C.8.3 | Annex C.8.3 default regex | `(?i)(labour\|labor\|forced\|child\|environmental\|pollution\|spill\|violation\|fine)` — standard across project. No custom signal-field extraction needed. |
| CR-I-Q3 | ICV adapter: periodic cron vs harness-trigger-only v1 | Harness-trigger-only v1 | No authoritative ICV API available in demo environment. Periodic poll would produce noise; trigger-on-demand is deterministic for demo purposes. |
| CR-J-Q1 | Time-freeze granularity: second vs minute | Minute-level | Renewal lookahead and SLA expiry operate on day/hour resolution; second-level freeze adds complexity without demo value. `date_trunc('minute', ...)` applied in `fn_demo_time_freeze_set`. |
| CR-J-Q2 | Concurrent trigger conflict: error vs block-and-queue | Block and queue | Demo context: concurrent admin users triggering same scenario should both succeed. `pg_advisory_xact_lock` serializes without surfacing errors to the UI. |
| CR-J-Q3 | Reset SLA breach handling: fail vs warn+log | Warn + log, do not fail | Demo must recover even if dataset grows; slaWarn=true + pg_notify for monitoring. Operation succeeds regardless. |
| CR-J-Q4 | Health check remediation: auto-remediate vs manual hints | Manual hints v1 | Auto-remediate (restart worker, flush cache) requires elevated privilege escalation paths not yet secured for pilot. Manual-only for v1; auto-remediate deferred to pilot phase. |

---

## Migration List (225..242)

| # | File | Contents | Status |
|---|---|---|---|
| 225 | `225_fn_demo_now_helper.sql` | fn_demo_now() STABLE INVOKER helper | Applied |
| 226 | `226_table_demo_seed_pack.sql` | demo_seed_pack table + RLS + audit trigger | Applied |
| 227 | `227_table_demo_scenario.sql` | demo_scenario table + RLS + CHECK constraint | Applied |
| 228 | `228_table_demo_scenario_run.sql` | demo_scenario_run append-only + RESTRICTIVE deny-DELETE | Applied |
| 229 | `229_demo_permissions.sql` | 4 new permissions + 8 role_permission grants | Applied |
| 230 | `230_extend_fn_demo_data_purge.sql` | EXTEND fn_demo_data_purge to 53-table topology; add redaction for event_injection_payload + error_message | Applied |
| 231 | `231_fn_demo_seed_helpers.sql` | 4 seed-loader helpers (load_sources/rules/templates/signals) | Applied |
| 232 | `232_fn_demo_time_freeze.sql` | fn_demo_time_freeze_set + fn_demo_time_unfreeze + fn_demo_time_freeze_current | Applied |
| 233 | `233_fn_pre_demo_health_check.sql` | fn_pre_demo_health_check STABLE — S2-24 split-aggregate 9-subsystem probe | Applied |
| 234 | `234_fn_demo_scenario_read.sql` | fn_demo_scenario_list + fn_demo_scenario_get + fn_demo_scenario_run_list | Applied |
| 235 | `235_fn_demo_scenario_trigger.sql` | fn_demo_scenario_trigger DEFINER — advisory lock + idempotent inject + outcome capture | Applied |
| 236 | `236_fn_demo_reset.sql` | fn_demo_reset DEFINER — 120s timeout + cascade purge + REFRESH MV + seed reload | Applied |
| 237 | `237_seed_osint_source_cri.sql` | 11 new osint_source rows via fn_osint_source_seed_cri_batch | Applied |
| 238 | `238_seed_correlation_rule_weather_fm.sql` | rule.weather.fm_eligible + 2 fixtures + fn_rule_evaluate_weather_fm_eligible | Applied |
| 239 | `239_seed_advisory_template_cri.sql` | 4 advisory_template rows (EN+AR Mustache + parameter_schema) | Applied |
| 240 | `240_seed_demo_scenario_packs.sql` | 8 demo_seed_pack + 8 demo_scenario rows per tenant (idempotent) | Applied (renumbered from plan; collapsed with 241) |
| 241 | `241_seed_mock_esg_signals.sql` | 30 mocked ESG osint_signal rows (data_classification='demo') | Applied |
| 242 | `242_demo_purge_permission_fixes.sql` | In-flight defect fix: fn_demo_data_purge permission gate widened (DEFECT-CRJ-1); contract.tenant_id column ref removed from weather-FM rule (DEFECT-CRJ-2) | Applied |

**Note (DEBT-CRIJ-2):** Migrations 240 and 241 were renumbered from Agent 4's planned 243 and 244 during implementation. Migration 242 was repurposed from the planned time-freeze refactor (third batch) to an in-flight defect fix. Numbering is cosmetically inconsistent with the db-design.md plan — functionally equivalent.

---

## Permission Matrix

| Permission | platform_admin | Super Admin | legal_counsel | compliance_esg | procurement | operations |
|---|---|---|---|---|---|---|
| `demo.scenario.trigger` | ✓ | ✓ | — | — | — | — |
| `demo.reset` | ✓ | ✓ | — | — | — | — |
| `demo.time_freeze.manage` | ✓ | ✓ | — | — | — | — |
| `demo.health_check.read` | ✓ | ✓ | — | — | — | — |

Demo harness is admin-only by design. All other personas access demo outcomes via their normal routes (advisory queue, risk dashboard, etc.) — they do not have visibility into the control panel.

---

## Stage 2 Mitigations

| Check | Application |
|---|---|
| **S2-17 Concurrency** | `pg_advisory_xact_lock` xact-scoped; cross-tenant parallel safe. |
| **S2-19 fn-to-fn signature** | 7 cross-fn signatures pinned in api-contracts.json `crossFnSignaturesPinned`. BE Impl verified p_actor_id first-arg convention before each `db.callFunction()`. |
| **S2-21 PUBLIC EXECUTE** | REVOKE/GRANT/COMMENT trio on all 17 net-new fn_'s. 17th consecutive clean streak preserved. |
| **S2-22 Column existence** | 12 DB-impl defects caught by report-don't-fix protocol; all column reference mismatches patched before apply. |
| **S2-22b JOIN-target tracing** | fn_demo_scenario_trigger uses GUC-based tenant_id scoping only — no contract.tenant_id direct column ref (DEFECT-CRJ-2 fixed). |
| **S2-23 FK pre-validation** | fn_demo_scenario_trigger validates seed_pack_ref via EXISTS check before proceeding (soft TEXT-FK enforcement). |
| **S2-24 Split-aggregate** | fn_pre_demo_health_check uses per-subsystem CTE inner blocks → outer jsonb_agg; no nested aggregate. |

**New S2-26 candidate (logged from this module):** "time-freeze GUC propagation" — any fn_ body containing `now() + interval`, `now() - interval`, `< now()`, `> now()`, or `date_trunc(..., now())` in business-logic context should be audited and either refactored to `fn_demo_now()` or explicitly documented as exempt (audit-stamp). Proposed for QA Validator update before next module with time-sensitive logic.

---

## Known Debt

### DEBT-CRIJ-1 (HIGH) — 18-fn Time-Freeze Refactor Deferred

**What:** The planned migrations 240–242 (Agent 4 plan) to replace business-logic `now()` with `fn_demo_now()` across 18 legacy fn_'s were not applied. Migration 242 was used for an in-flight defect fix instead.

**Impact:** The time-freeze GUC works correctly for the 17 new CR-I+J fn_'s. Legacy fn_'s (10 dashboards, 3 risk scoring, 2 notification, 3 obligation/source/signature-expiry) still read raw `now()`.

**AC affected:** AC-CR-J-3 (time-freeze allows running renewal scenario against frozen date) is PARTIAL — works for newly-generated demo-harness paths but not for legacy dashboard/risk computations.

**BE impact:** Scan of `src/` confirmed 0 `new Date()` usages in renewal/SLA/expiry logic — all date arithmetic is in DB fn_'s. BE-side renewal worker calls `SELECT fn_demo_now()` per design.

**Schedule:** Follow-up CR or Unit 6 polish round. Target: write migrations 243–260 (one per fn_ or grouped by domain) with the pattern: `WHERE captured_at >= fn_demo_now() - INTERVAL 'X'` replacing `WHERE captured_at >= now() - INTERVAL 'X'`. Audit-stamp `now()` (INSERT/UPDATE created_at/updated_at) is PRESERVED intentionally for forensic integrity.

**fn_'s requiring refactor:**

| Group | fn_'s |
|---|---|
| Dashboards (10) | fn_dashboard_admin, fn_dashboard_approver, fn_dashboard_drafter, fn_dashboard_executive, fn_dashboard_legal_counsel, fn_dashboard_recipient, fn_dashboard_operations, fn_dashboard_finance_treasury, fn_dashboard_compliance_esg, fn_dashboard_procurement_supplier_risk |
| Risk scoring (3) | fn_risk_score_compute, fn_risk_score_history, fn_avar_aggregate |
| Notification / obligations (5) | fn_notification_send, fn_notification_dispatch_retry_due, fn_obligations_derive_from_clause, fn_source_health_record, fn_signature_invitation_expire_due |

---

### DEBT-CRIJ-2 (LOW) — Migration Number Cosmetic Inconsistency

**What:** Agent 4 planned migrations 243/244 for scenario/ESG seed data; implementation renumbered them to 240/241 and repurposed 242 for the defect fix. The db-design.md plan shows 244 as the last migration; actual DB head is 242.

**Impact:** None functional. Migration history is contiguous and applied in order.

**Resolution:** Document the discrepancy (done here). No remediation required.

---

## Cross-Layer Defect Trail (all closed)

| ID | Layer | Symptom | Fix |
|---|---|---|---|
| CRIJ-DB-01..12 | DB Impl | 12 schema/syntax mismatches (permission columns, PL/pgSQL syntax, missing NOT NULL columns, wrong data_classification, dispatch_channels JSONB vs TEXT[], wrong ON CONFLICT target, missing advisory_template columns, JSONB column type mismatch, wrong osint_signal category) | Patched in migrations 229/231/237/238/239/241 via report-don't-fix protocol |
| INT-VER-CRIJ-1 | Integration Verifier | confirmToken regex mismatch — BE issued UUID, FE sent `RESET_DEMO_<date>` | BE schema relaxed to accept both formats |
| SMOKE-CRIJ-1 | Smoke Test | actorId missing as first arg + tenantId missing in callFunction opts across 7 fn calls | demo-harness.service.ts patched |
| DEFECT-CRJ-1 | Testing Agent | fn_demo_data_purge `super_admin_required` gate blocked fn_demo_reset for platform_admin | Permission gate widened in migration 242 |
| DEFECT-CRJ-2 | Testing Agent | `c.tenant_id does not exist` in weather-FM rule evaluator | Column ref removed — GUC-based scoping only; in migration 242 |

---

## i18n

- **Namespace:** `admin.demo.*` + `nav.adminDemo`
- **Keys added:** ~73 (EN/AR strict parity — 5902/5902 total leaf keys post-module)
- **AR coverage:** Full AR translation provided (no `[NEEDS TRANSLATION]` markers needed for UI keys; advisory template AR bodies use `[NEEDS TRANSLATION]` per project precedent)
- **Duplicate top-level key check:** 0 duplicates in en.json or ar.json (Unit 3 lesson applied)

---

## Testing

**Test report:** module-M17-M18-test-report.md — 40/40 PASS  
- 26 DB fn tests (fn_demo_now, fn_demo_scenario_list, fn_demo_scenario_trigger determinism, fn_demo_reset, tenant isolation, concurrent trigger serialization)  
- 13 integration tests (adapter stubs, scenario seed loader, health check probe fan-out, advisory template render)  
- 1 E2E scenario test: `tests/scenarios/cyclone-fm.test.ts` (cyclone signal → correlation → Weather FM Notice advisory draft)

---

*Generated by Agent 15 (Documentation Generator) — Unit 6 / M17 + M18 / CR-I + CR-J — 2026-05-14*
