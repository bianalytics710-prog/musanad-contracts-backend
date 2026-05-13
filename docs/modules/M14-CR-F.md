# M14 / CR-F — 5-Dim Risk Scoring + MaR + AVaR

> **Module ID:** M14
> **Change Request:** CR-F
> **Status:** Complete — shipped 2026-05-13
> **Migrations:** 168..177 (10 files; 176 + 177 are in-flight defect-fix patches)
> **Schema version:** 177 (both `m0-foundation` and `test` Neon branches)
> **Pipeline mode:** Autonomous end-to-end (Unit 2A)

---

## Overview

CR-F delivers the 5-dimension risk scoring engine for the Musanad Contracts Hub CRIP Wave 2.
It builds a snapshot table (`risk_score` — append-only, FORCE RLS, audit-triggered), the
project's first materialized view (`latest_risk_score` — DISTINCT ON tenant_id + contract_id),
8 net-new fn_'s spanning compute / explain / history / AVaR-aggregate / recompute paths, a
score-recompute worker (PG LISTEN `correlation_inserted` + daily 00:30 UTC cron via node-cron),
and a complete FE surface (Risk tab on contract detail, AVaR section on executive dashboard,
/app/admin/scoring-weights admin page).

**Three major capability clusters:**

**Cluster 1 — Scoring engine + MaR formula (S1–S6):** `fn_risk_score_compute` DEFINER reads
active correlations, loads ADNOC scoring weights from `system_setting` (extended with new
`category='scoring'`), computes 5 dim scores (Probability × Impact, 0-100), composite Health
Score (weighted sum), MaR per correlation (`contract_value × exposure_fraction × probability
× impact_multiplier`), persists snapshot to `risk_score`, refreshes `latest_risk_score` MV.

**Cluster 2 — AVaR aggregation + admin weights tuning (S7–S12):** `fn_avar_aggregate`
uses the S2-24 split-aggregate pattern (inner per_bucket CTE with SUM + outer jsonb_agg).
`fn_scoring_weights_get/_set` admin pair with sum=1.0 ±0.001 tolerance, version auto-increment,
audit_log hash-chained via `fn_audit_log_record_v2`.

**Cluster 3 — FE Risk surface + worker (S13–S17):** Risk tab on `/app/contracts/$id` with SVG
gauge, 5-dim bars, MaR-per-correlation list, Recharts history chart, and client-side what-if
panel. AVaR top-tile on executive dashboard. `/app/admin/scoring-weights` page with 5 sliders,
sum meter, normalize button, and recompute-all CTA.

---

## Migrations

| # | File | Purpose | Status |
|---|---|---|---|
| 168 | `168_crf_extend_system_setting_category_scoring.sql` | Widen system_setting category CHECK 8→9 values (add 'scoring') + UPSERT 3 ADNOC scoring config rows | Applied |
| 169 | `169_crf_create_risk_score.sql` | CREATE TABLE risk_score (18 cols, append-only, BIGSERIAL PK, FORCE RLS, 3 policies, 5 indexes, audit trigger) | Applied |
| 170 | `170_crf_create_latest_risk_score_mv.sql` | CREATE MATERIALIZED VIEW latest_risk_score (DISTINCT ON tenant_id + contract_id ORDER BY calculated_at DESC; UNIQUE INDEX) | Applied |
| 171 | `171_crf_risk_score_functions.sql` | 8 net-new fn_'s: fn_risk_score_compute / explain / history / fn_avar_aggregate / fn_score_recompute_for_signal / fn_score_recompute_for_weight_change / fn_scoring_weights_get / fn_scoring_weights_set | Applied |
| 172 | `172_crf_extend_fn_rule_evaluate_notify.sql` | EXTEND fn_rule_evaluate — preserve M13 body byte-for-byte + add PERFORM pg_notify('correlation_inserted') on successful insert | Applied |
| 173 | `173_crf_extend_fn_audit_trigger_redact_43.sql` | EXTEND fn_audit_trigger — preserve M11 body byte-for-byte + v_redact_fields 41→43 (adds contributing_correlations + explanation) | Applied |
| 174 | `174_crf_pg_notify_channels.sql` | NOTIFY channel verification ping | Applied |
| 175 | `175_crf_permissions_grants_and_bootstrap.sql` | 3 net-new permissions (score.read / score.weights.manage / risk.acknowledge) + 9 role_permission grants + bootstrap DO block (fn_risk_score_compute for every active contract) | Applied |
| 176 | `176_crf_fix_fn_explain_signal_cols_and_numeric_casts.sql` | DEFECT-CR-F-1 fix: sig.signal_kind→sig.kind, sig.occurred_at→sig.event_date_v2 in fn_risk_score_explain; BIGINT/NUMERIC ::text casts on 4 fn_'s | Applied |
| 177 | `177_crf_fix_mv_id_column_and_scoring_weights_audit.sql` | DEFECT-DB-02 fix: DROP + CREATE latest_risk_score MV with `id` column; DEFECT-DB-01 fix: fn_scoring_weights_set now uses fn_audit_log_record_v2(NULL::bigint) helper | Applied |

---

## Database Objects

### Table: `risk_score`

Append-only snapshot table. One row per recompute per contract. No `updated_at`, `updated_by`, or `is_active` columns (mirrors M0 `audit_log` precedent). Immutability enforced by `risk_score_deny_direct_delete` RESTRICTIVE RLS policy.

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing row identifier. |
| tenant_id | UUID | NOT NULL, FK → tenant(id) | Tenant scoping. RLS uses `app.current_tenant_id` GUC. |
| contract_id | BIGINT | NOT NULL, FK → contract(id) ON DELETE RESTRICT | Contract being scored. |
| health_score | INTEGER | NOT NULL, CHECK 0..100 | Composite weighted risk score. Higher = more risk. |
| dim_legal | INTEGER | NOT NULL, CHECK 0..100 | Legal dimension (sanctions + regulatory rules). |
| dim_financial | INTEGER | NOT NULL, CHECK 0..100 | Financial dimension (market + disruption + counterparty). |
| dim_operational | INTEGER | NOT NULL, CHECK 0..100 | Operational dimension (geopolitical + cyber + disruption). |
| dim_reputational | INTEGER | NOT NULL, CHECK 0..100 | Reputational dimension (geopolitical + counterparty). |
| dim_compliance | INTEGER | NOT NULL, CHECK 0..100 | Compliance dimension (sanctions + regulatory + cyber). |
| mar_value | NUMERIC(18,2) | NULL, CHECK >= 0 | Money at Risk in AED. NULL for SOWs (HITL Q5). |
| mar_currency | CHAR(3) | NOT NULL DEFAULT 'AED' | Currency of mar_value. v1 AED-only. |
| contributing_correlations | JSONB | NOT NULL DEFAULT '[]' | SENSITIVE — correlation contribution array. Redacted in audit_log. |
| explanation | JSONB | NOT NULL DEFAULT '{}' | SENSITIVE — dimensions breakdown + marFormula + weightsAtCalculation. Redacted in audit_log. |
| weights_version | TEXT | NOT NULL | Scoring weights version at compute time. |
| calculated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Snapshot timestamp. Used for DISTINCT ON in MV. |
| triggered_by | TEXT | NOT NULL, CHECK enum-of-6 | signal / clause_change / weight_change / scheduled / manual / bootstrap. |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK enum-of-3 | demo / pilot / production. |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Row creation timestamp (append-only). |
| created_by | BIGINT | FK → user(id) ON DELETE SET NULL | NULL when triggered by system actor (worker / bootstrap; p_actor_id=0 → NULL per S2-20). |

**Indexes:**

| Index | Columns | Purpose |
|---|---|---|
| idx_risk_score_tenant_contract_calc | (tenant_id, contract_id, calculated_at DESC) | Primary read path: latest snapshot per contract + history queries |
| idx_risk_score_tenant_health | (tenant_id, health_score) | AVaR top-N high-risk contracts + executive sorting |
| idx_risk_score_tenant_calc | (tenant_id, calculated_at DESC) | AVaR time-series + admin recent recomputes |
| idx_risk_score_weight_change | (weights_version, calculated_at DESC) WHERE triggered_by = 'weight_change' | Bulk recompute audit (partial — ~5% of rows) |
| idx_risk_score_created_by | (created_by) WHERE created_by IS NOT NULL | FK audit queries (partial) |

**RLS policies:**

| Policy | Type | Condition |
|---|---|---|
| risk_score_tenant_select | PERMISSIVE SELECT | tenant_id = current_setting('app.current_tenant_id', true)::uuid |
| risk_score_tenant_modify | PERMISSIVE ALL | tenant_id = GUC (USING + WITH CHECK) |
| risk_score_deny_direct_delete | RESTRICTIVE DELETE | USING(FALSE) — append-only semantics |

**Audit trigger:** `audit_risk_score_changes` AFTER INSERT only (append-only; no UPDATE/DELETE triggers). Sensitive fields `contributing_correlations` and `explanation` are redacted to `"[REDACTED]"` by `fn_audit_trigger` (migration 173 extends redact list to 43 entries).

---

### Materialized View: `latest_risk_score`

**CRITICAL — PostgreSQL RLS does NOT apply to materialized views.** Every fn_ or query that reads `latest_risk_score` MUST include an explicit `WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid` filter. This invariant is documented in the MV COMMENT and enforced by QA Stage 2 S2-22.

```sql
CREATE MATERIALIZED VIEW latest_risk_score AS
  SELECT DISTINCT ON (tenant_id, contract_id) *
  FROM risk_score
  ORDER BY tenant_id, contract_id, calculated_at DESC;
```

UNIQUE INDEX `latest_risk_score_tenant_contract_unique` on `(tenant_id, contract_id)` enables future `REFRESH MATERIALIZED VIEW CONCURRENTLY`. Security: REVOKE ALL FROM PUBLIC + GRANT SELECT TO neondb_owner.

---

### Functions

| Function | Security | Type | Purpose |
|---|---|---|---|
| `fn_risk_score_compute(p_contract_id BIGINT, p_triggered_by TEXT, p_actor_id BIGINT)` | DEFINER | Write VOLATILE | Reads correlations, loads weights, computes 5 dims + Health Score + MaR, persists snapshot, refreshes MV. S2-20: v_actor=0→NULL coercion. |
| `fn_risk_score_explain(p_contract_id BIGINT, p_actor_id BIGINT)` | INVOKER | Read STABLE | Reads latest_risk_score + hydrates contributing correlations with signal/rule/clause details. |
| `fn_risk_score_history(p_contract_id BIGINT, p_window_days INTEGER, p_actor_id BIGINT)` | INVOKER | Read STABLE | Returns time-ordered snapshots for the contract within the window. windowDays validated (ERRCODE 22023 if not in {30,90,180}). |
| `fn_avar_aggregate(p_filters JSONB, p_window_days INTEGER, p_actor_id BIGINT)` | INVOKER | Read STABLE | Portfolio AVaR aggregation with breakdown by groupBy dimension. S2-24 split-CTE: inner per_bucket CTE + outer jsonb_agg. |
| `fn_scoring_weights_get(p_actor_id BIGINT)` | INVOKER | Read STABLE | Returns current weights + version history + ADNOC default exposure_fraction_defaults + impact_multipliers from system_setting. |
| `fn_scoring_weights_set(p_weights JSONB, p_actor_id BIGINT)` | INVOKER | Write VOLATILE | Updates scoring.weights in system_setting. sum=1.0±0.001 invariant. Version auto-incremented. Audit via fn_audit_log_record_v2(NULL::bigint) — system_setting has key PK not bigint id. |
| `fn_score_recompute_for_signal(p_signal_id BIGINT, p_actor_id BIGINT)` | DEFINER | Write VOLATILE | Finds correlations linked to signal → recomputes affected contracts. Called by score-recompute.worker.ts LISTEN handler. |
| `fn_score_recompute_for_weight_change(p_actor_id BIGINT)` | DEFINER | Write VOLATILE | Bulk-recomputes all active contracts after weight change. Per-contract BEGIN/EXCEPTION/END isolation. Returns failedContractIds. |

**Extended functions:**

| Function | Change |
|---|---|
| `fn_rule_evaluate` | +1 line: PERFORM pg_notify('correlation_inserted', json) on successful insert (gated IF v_inserted > 0). Body otherwise preserved byte-for-byte from M13 migration 153. |
| `fn_audit_trigger` | v_redact_fields 41→43 (adds `contributing_correlations` + `explanation`). Body otherwise preserved from M11 migration 157. |

---

## Routes

| Method | Path | Permission | DB Function | Notes |
|---|---|---|---|---|
| GET | /api/v1/contracts/:id/risk-score | score.read | fn_risk_score_explain | Hidden for contract_recipient |
| GET | /api/v1/contracts/:id/risk-score/history | score.read | fn_risk_score_history | windowDays ∈ {30,90,180} |
| GET | /api/v1/risk/avar | score.read | fn_avar_aggregate | 8 optional query params |
| GET | /api/v1/admin/scoring-weights | score.weights.manage | fn_scoring_weights_get | Admin-only |
| PATCH | /api/v1/admin/scoring-weights | score.weights.manage | fn_scoring_weights_set | Auto-normalises ±0.001 |
| POST | /api/v1/admin/scoring-weights/recompute-all | score.weights.manage | fn_score_recompute_for_weight_change | heavyExportRateLimiter 5/min/user |

---

## Permissions Seeded

| Permission Code | Granted To |
|---|---|
| score.read | Super Admin, platform_admin, executive, legal_counsel, contract_drafter, contract_approver |
| score.weights.manage | Super Admin, platform_admin |
| risk.acknowledge | Super Admin (placeholder; CR-G role expansion fills grants) |

---

## Worker: `score-recompute.worker.ts`

PG LISTEN on channel `correlation_inserted` (emitted by fn_rule_evaluate migration 172 on every successful correlation INSERT). On notification: extracts tenantId + signalId from payload JSON, calls fn_score_recompute_for_signal. Concurrency: p-limit(2) — at most 2 recomputes in flight simultaneously per worker instance.

Daily 00:30 UTC cron (node-cron) triggers fn_score_recompute_for_weight_change with actor_id=0 (system sentinel → NULL coercion) for time-decay updates.

`SCORE_RECOMPUTE_WORKER_ENABLED` env guard. Disabled by default in dev; must be explicitly set to `true` in production.

**Important (F-3):** production LISTEN connections MUST use the Neon **direct** endpoint, not `-pooler`.

---

## Decisions (HITL Gate 2)

| ID | Question | Locked | Rationale |
|---|---|---|---|
| CR-F-Q1 | MaR currency conversion timing | locked-at-correlation | Audit consistency outweighs live-FX flexibility at demo scale. Matches AED-base currency. |
| CR-F-Q2 | Score recompute granularity | per-correlation v1 | Demo immediacy. Batched window deferred to pilot when contract count grows. |
| CR-F-Q3 | Probability calculation method | weighted-by-source-reliability | Single-tenant + AED-base means source quality is the dominant variance. |
| CR-F-Q4 | Score history retention | all snapshots forever | v1 demo scale <100 contracts × <30 recomputes/year/contract = <3000 rows. |
| CR-F-Q5 | MaR for NULL contract_value (SOWs) | MaR=NULL + UI placeholder | Preserves data semantics. UI shows "No monetary value — operational risk only". |

---

## Defects Caught + Fixed In-Flight

| ID | Stage Caught | Description | Fix |
|---|---|---|---|
| DEFECT-3 | Agent 6 | contract table lacks tenant_id column (single-tenant v1) | 4 fn_ body adaptations + bootstrap guard in migration 175 |
| DEFECT-CR-F-1 | Smoke + Integration Verifier | fn_risk_score_explain refs sig.signal_kind + sig.occurred_at (non-existent columns; S2-22 miss); BIGINT-as-string ::text casts missing on 4 fn_'s | Migration 176 |
| DEFECT-DB-01 | Testing Agent | fn_scoring_weights_set manual audit_log INSERT missed prev_hash + this_hash NOT NULL from R-PA7 migration 128 | Migration 177: switched to fn_audit_log_record_v2(NULL::bigint) helper |
| DEFECT-DB-02 | Testing Agent | latest_risk_score MV column inconsistency: test branch had risk_score_id alias; m0-foundation had id (manually corrected during DEFECT-3 work) | Migration 177: DROP + CREATE uniformly with `id` on both branches |

---

## Test Coverage

| Test File | Tests | Result |
|---|---|---|
| tests/db/CR-F-fns.test.ts | 54 | PASS (all 8 fn_'s + 2 EXTEND) |
| tests/integration/score-recompute-roundtrip.test.ts | 5 | PASS (<30s NFR verified) |
| tests/integration/risk-score-routes.test.ts | 29 | PASS (all 6 BE routes) |
| **Total CR-F** | **88** | **88/88 PASS** |
| Full BE suite post-M14 | 1491 | 1487/1491 (3 pre-existing fails, 0 CR-F regressions) |

---

## Production Standards

- All 10 migrations include rollback blocks.
- **13th consecutive S2-21 clean module** — zero net-new PUBLIC EXECUTE grants. Live proacl verified at QA Stage 4 for all 10 fn_'s + 1 MV.
- First materialized view in the project — tenant-scoping invariant documented in MV COMMENT.
- i18n strict parity 5250/5250 (+96 keys for CR-F across risk.score.* / risk.mar.* / risk.avar.* / admin.scoring.* namespaces).
- INFRA-2: m0-foundation osint_signal storage cleanup (479k DELETE + VACUUM FULL) applied before bootstrap migration to clear 512MB Neon cap (same pattern as M11 INFRA-1).
- Codex review SKIPPED per Dexian decision 2026-05-04 (13th consecutive).

---

## Open Follow-Ups

| ID | Description |
|---|---|
| W1 (QA Stage 3) | PG NOTIFY payload `signalId` is JSON number not string. Acceptable v1 (counts << 2^53). Follow-up after pilot scale. |
| W5 (QA Stage 3) | ContractRiskTab.tsx Recharts color constants use hex literals `#8b5cf6` + `#06b6d4`. Follow-up CR — add purple + cyan to semantic-token palette. |
