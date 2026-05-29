# CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half) — Changelog

**Module impact:** Completes M21 Financial Intelligence. CR-N built the Cost/Budget-Burn half (mig 296..308); CR-O adds the Trade Margin half. Extends fn_dashboard_executive (additive 11th key `tradeMarginSummary`). Does not touch any CR-N artifact.
**Status:** Complete — shipped 2026-05-29
**Migrations:** 309..321 (12 planned 309–320 + migration 321 to fix NF-1 hardcoded delta)
**Schema version:** 321 (both `m0-foundation` dev and `test` Neon branches)
**Pipeline mode:** Autonomous end-to-end (change-request scope, `--no-walk`)
**S2-21 streak:** 21st consecutive clean module

---

## What changed

CR-O adds **oil-trade margin intelligence** — both sides of an ADNOC integrated-trader book. Finance and executive personas can evaluate seller and buyer positions, watch margin compression live when benchmark prices move, and see a portfolio-level rollup on the executive dashboard.

**Story 2a — Seller:** ADNOC Trading has a term contract selling 2M bbl/month Murban to a Korean refinery (Hanwha TotalEnergies), priced at monthly Murban OSP. When the OSP drops from $110.75 (May-26 basis) → $104.44 (Jun-26 basis), the three forward cargoes (Jun/Jul/Aug) recompute and the margin compression surfaces: per-bbl −$6.31 (106.15 → 99.84, −5.95%), total −$37.86M USD / AED −139.04M.

**Story 2b — Buyer:** ADNOC Global Trading evaluates a West-African spot crude purchase-and-refine deal. The platform computes buy-and-refine economics (crude at $96.20/bbl + transport + refining + storage vs downstream diesel/jet at $119.50/bbl) and derives a positive projected margin of **$9.00/bbl → recommendation: buy**.

The executive dashboard receives one additive key (`tradeMarginSummary`) preserving all 10 prior keys byte-for-byte (CR-N/CR-G lesson). A new `/app/financial/trade-margin` route handles finance_treasury/executive read and the OSP-drop recompute action.

**Counts:**
- 4 new tables: `price_benchmark`, `trade_position`, `trade_cost_component`, `margin_snapshot`
- 1 materialized view: `latest_margin` (DISTINCT ON per position, UNIQUE INDEX for CONCURRENTLY upgrade path)
- 11 new fn_'s: `fn_margin_compute`, `fn_margin_recompute_for_price_change`, `fn_margin_aggregate`, `fn_trade_position_list`, `fn_trade_position_get`, `fn_price_benchmark_list`, `fn_price_benchmark_record`, `fn_margin_snapshot_history`, `fn_price_benchmark_get_by_id` (internal), `fn_trade_position_get_by_id` (internal)
- 1 additive extension to `fn_dashboard_executive` (11th key `tradeMarginSummary`, mig 316; NF-1 fix in mig 321)
- 2 new permissions: `finance.margin.read`, `finance.trade.manage`
- 1 new pg_notify channel: `margin_recompute_requested`
- Seed: 7 `price_benchmark` rows (Murban OSP series May/Jun + Brent + Dubai + WAF + USD/AED FX), 2 `party` rows (Hanwha TotalEnergies, West Africa Crude Supplier), 3 sell positions + 1 buy position + 17 cost components + 4 bootstrap margin snapshots
- 5 BE files created / 3 modified; 7 FE files created / 3 modified
- 1 new worker: `margin-recompute.worker.ts` (LISTEN `margin_recompute_requested` + daily cron, `MARGIN_RECOMPUTE_WORKER_ENABLED=true` to activate)
- EN/AR i18n 7355→7551 (+196 keys: `financial.tradeMargin.*` + `financial.priceBenchmark.*` + `nav.financialTradeMargin`, full EN=AR parity 7551=7551)

---

## Persona access model

| Role | finance.margin.read | finance.trade.manage |
|---|---|---|
| finance_treasury | ✓ | ✓ |
| executive | ✓ | — |
| platform_admin | ✓ | ✓ |
| Super Admin | ✓ | ✓ |
| drafter / approver / legal_counsel / recipient / operations / procurement | — | — |

Finance reads margin surfaces and manages (record price benchmarks, trigger recompute). The executive dashboard shows the `tradeMarginSummary` tile without additional grants (executive has `finance.margin.read` via mig 318). Management roles (finance_treasury / platform_admin / Super Admin) can trigger the OSP-drop recompute action.

---

## Key decisions

All decisions auto-approved (autonomous build per user instruction 2026-05-29).

- **Decision 1 — price_benchmark typed table (not osint_signal):** A dedicated `price_benchmark` table with indexed `(benchmark_code, price_date)` uniqueness is required for numeric time-series joins in margin computation. `osint_signal` is an unstructured event feed tuned for correlation, not numeric lookups. The commodity adapter (CR-A future) can UPSERT into this table — additive, no redesign.
- **Decision 2 — margin_snapshot append-only + latest_margin MV:** The hero story depends on showing margin compression *over time* — both the $110.75 and $104.44 snapshots must exist to render the trend. Overwrite destroys the story. Mirrors `risk_score` / `latest_risk_score` from CR-F. DISTINCT ON + UNIQUE INDEX `(tenant_id, trade_position_id)` gives O(1) latest read and a one-line CONCURRENTLY upgrade path at pilot scale.
- **Decision 3 — USD/bbl economics + AED display:** Oil trades in USD/bbl (OSP is published in USD). The FX leg (USD/AED ≈ 3.6725) is part of the CFO story for a UAE finance persona. Per-bbl amounts in NUMERIC(12,4), totals in NUMERIC(18,2); both `total_margin_usd` and `total_margin_aed` persisted on each snapshot. AED totals serialised as `::text` in JSONB (CR-N/CR-F pattern — avoids JS float loss at 8-digit AED totals).
- **Decision 4 — Manual POST + env-gated worker:** Demo action is synchronous `POST /price-benchmarks/recompute` (deterministic, returns aggregate delta inline). The same fn emits `pg_notify`; `margin-recompute.worker.ts` LISTENs on `margin_recompute_requested` + optional daily cron, default off via `MARGIN_RECOMPUTE_WORKER_ENABLED`. Mirrors `score-recompute.worker.ts` pattern (CR-F).
- **Decision 5 — Single trade_position with side discriminator:** One unified `trade_position` shape with `side ∈ {sell,buy}` and per-position `trade_cost_component` rows covers both sides. Seller revenue = resolved benchmark OSP; buyer revenue = `downstream_sale` component (`is_revenue=TRUE`). Both sides use identical compute→snapshot→aggregate machinery — one engine, one UI, both stories.

---

## NF-1 — recentMarginChange hardcoded delta (FIXED, mig 321)

QA Stage 4 and the Integration Verifier (NF-1) found that `fn_dashboard_executive`'s `tradeMarginSummary.recentMarginChange.deltaAed` and `deltaUsd` were hardcoded string literals in mig 316 (`'-139040850.00'` / `'-37860000.00'`). The key shape was correct and the demo hero scenario matched these numbers exactly, so there was no crash or contract break, but the value would be stale after any subsequent recompute.

**Fix (migration 321):** `CREATE OR REPLACE fn_dashboard_executive` with a S2-24 split-aggregate CTE chain:
- `pc_ranked`: LAG window over all `triggered_by='price_change'` snapshots per position → prior_aed/usd per row.
- `latest_pc_per_pos`: DISTINCT ON per position → most-recent price_change snapshot with LAG-computed prior.
- `recent_window`: filters to positions with a price_change within 30 days; derives `delta_aed = new_aed - prior_aed`.
- `delta_totals`: sums deltas across in-window positions; picks `benchmark_code + asOf` from most-recent event.
- Returns `NULL` gracefully when no recent price_change snapshots exist (not a frozen literal).

**Verified:** BEFORE recompute → `deltaAed = -139040850.00` (computed from existing snapshots). AFTER recompute from $104.44 back to $110.75 → `deltaAed = +139040850.00`. No hardcoded literal in `pg_proc.prosrc`. All 11 executive keys confirmed present post-321.

---

## Margin formulas (canonical)

```
FX rate r = price_benchmark WHERE benchmark_code='usd_aed' AND unit='aed_per_usd'

SELLER (side='sell'):
  revenue_per_bbl = benchmark_price_used  (resolved Murban OSP for delivery_month)
  cost_per_bbl    = SUM(amount_usd_per_bbl) WHERE is_revenue=FALSE
                    lifting + transport_charter + insurance + hedge
  margin_per_bbl  = revenue_per_bbl - cost_per_bbl
  recommendation  = 'sell' if margin > 0 else 'review'

BUYER (side='buy'):
  revenue_per_bbl = SUM(amount_usd_per_bbl) WHERE is_revenue=TRUE  (downstream_sale)
  cost_per_bbl    = SUM(amount_usd_per_bbl) WHERE is_revenue=FALSE
                    crude_purchase + transport + refining + storage
  margin_per_bbl  = revenue_per_bbl - cost_per_bbl
  recommendation  = 'buy' if margin > 0 else 'hold'

BOTH:
  total_margin_usd = margin_per_bbl × volume_bbl
  total_margin_aed = total_margin_usd × r
```

**Seller demo (2a) at $110.75 OSP:** margin/bbl = $106.15; per cargo (2M bbl) = $212.3M / AED 779.7M; 3 cargoes = $636.9M / AED 2,339.0M.
**After OSP-drop to $104.44:** margin/bbl = $99.84; per cargo = $199.7M; 3 cargoes = $599.0M / AED 2,200.0M. Compression: −$6.31/bbl, −$37.86M total, AED −139.04M.
**Buyer demo (2b):** downstream_sale $119.50 − costs $110.50 = **$9.00/bbl** → recommendation: buy. Total: $9M / AED 33.05M.

---

## Tables introduced

| Table | Type | Description |
|---|---|---|
| `price_benchmark` | master/reference | Benchmark price observations (Murban OSP, Brent, Dubai, WTI, WAF, USD/AED FX). UNIQUE (tenant_id, benchmark_code, price_date). |
| `trade_position` | transactional master | A cargo or term-deal leg. Side ∈ {sell,buy}. Links to party (counterparty) and optionally contract. UNIQUE (tenant_id, position_ref). |
| `trade_cost_component` | transactional detail | Per-position cost/revenue inputs. component_type discriminates cost legs vs downstream_sale revenue. UNIQUE (tenant_id, trade_position_id, component_type). |
| `margin_snapshot` | append-only log | Computed margin per position per point in time. Mirrors risk_score. No updated_at/updated_by/is_active (append-only). |

**Materialized view:** `latest_margin` — DISTINCT ON (tenant_id, trade_position_id) ORDER BY computed_at DESC. UNIQUE INDEX `latest_margin_pk (tenant_id, trade_position_id)`.

All 4 tables: FORCE RLS, audit trigger, COMMENTs. NUMERIC money throughout (per-bbl NUMERIC(12,4), totals NUMERIC(18,2)). No FLOAT/DOUBLE.

---

## Functions introduced

| Function | Type | Security | Purpose |
|---|---|---|---|
| `fn_margin_compute` | VOLATILE | INVOKER | Compute margin for one position → INSERT margin_snapshot → REFRESH MV. Returns full breakdown. |
| `fn_margin_recompute_for_price_change` | VOLATILE | DEFINER | UPSERT price_benchmark + recompute all open forward positions on the benchmark. Returns aggregate delta. Emits pg_notify. |
| `fn_margin_aggregate` | STABLE | INVOKER | Portfolio rollup by counterparty / quarter / side. S2-24 split-aggregate. |
| `fn_trade_position_list` | STABLE | INVOKER | Paginated list with inline latest margin from MV. |
| `fn_trade_position_get` | STABLE | INVOKER | Full position detail incl. costComponents[] + latestMargin block. |
| `fn_price_benchmark_list` | STABLE | INVOKER | Paginated benchmark series. |
| `fn_price_benchmark_record` | VOLATILE | INVOKER | UPSERT price_benchmark row. |
| `fn_margin_snapshot_history` | STABLE | INVOKER | All snapshots for one position in ASC order (for trend chart). |
| `fn_price_benchmark_get_by_id` | STABLE | INVOKER | Internal helper — no external gate, RLS-scoped. |
| `fn_trade_position_get_by_id` | STABLE | INVOKER | Internal helper — no external gate, RLS-scoped. |
| `fn_dashboard_executive` (EXTEND) | VOLATILE | — | Additive `tradeMarginSummary` (11th key). Defensive BEGIN/EXCEPTION + COALESCE zero-shape. NF-1 delta computation fixed in mig 321. |

All 10 new fns + the exec EXTEND carry COMMENT + REVOKE PUBLIC EXECUTE + GRANT EXECUTE TO neondb_owner (S2-21). S2-21 CLEAN — 21st consecutive clean module.

---

## Endpoints

| Method | Path | Permission | DB Function |
|---|---|---|---|
| GET | /api/v1/financial/trade-margin | finance.margin.read | fn_trade_position_list |
| GET | /api/v1/financial/trade-margin/aggregate | finance.margin.read | fn_margin_aggregate |
| GET | /api/v1/financial/trade-margin/:positionId | finance.margin.read | fn_trade_position_get |
| GET | /api/v1/financial/trade-margin/:positionId/history | finance.margin.read | fn_margin_snapshot_history |
| GET | /api/v1/financial/price-benchmarks | finance.margin.read | fn_price_benchmark_list |
| POST | /api/v1/financial/price-benchmarks/recompute | finance.trade.manage | fn_margin_recompute_for_price_change |
| POST | /api/v1/financial/price-benchmarks | finance.trade.manage | fn_price_benchmark_record |

Static routes (`/aggregate`, `/recompute`) registered before parameterised routes (`:positionId`) in Express — prevents route-matching conflicts (CR-N lesson).

---

## Defects caught and fixed in-flight

| ID | Severity | Description | Fix |
|---|---|---|---|
| DEFECT-CRO-DB-01 | HIGH | `party` table has no `tenant_id` column — migration 319 party INSERTs used tenant-scoped idempotency pattern. Error 42703. | Removed `tenant_id` from party INSERT column lists; changed idempotency check to `WHERE name_en = '...'` (CR-M mig 285 pattern). |
| DEFECT-CRO-DB-02 | HIGH | Same root cause in migration 320 — party ID resolution queries also filtered on `tenant_id`. Error 42703. | Replaced all 4 party SELECT queries to remove `tenant_id` filter; added comment documenting `party` as a globally shared table. |
| DEFECT-CRO-DB-03 | MEDIUM | Migration 320 bootstrap block set `app.current_tenant_id` GUC but not `app.current_user_id`. `fn_margin_compute` permission check reads the user GUC → 42501 forbidden. | Added `PERFORM set_config('app.current_user_id', v_actor::text, TRUE)` immediately after tenant_id set_config. |
| NF-1 | WARN | `fn_dashboard_executive` `tradeMarginSummary.recentMarginChange.deltaAed/deltaUsd` were hardcoded literals (mig 316 L493–494). Demo-accurate but stale after any subsequent recompute. | Migration 321: S2-24 LAG-window CTE chain replacing hardcoded literals with dynamically computed delta from price_change snapshot history. |

---

## QA Stage 4 result

**SHIP-GO-WITH-WARNINGS** — 51/52 checks PASS, 1 WARN (NF-1 — fixed post-QA via mig 321), 0 FAIL.

- Section A (Architecture): 7/7
- Section B (Backend): 15/15
- Section C (Frontend): 13/14 (NF-1 WARN — resolved by mig 321)
- Section D (Accessibility): 7/7
- Section E (Integration): 6/6
- F4 E2E: N/A (`--no-walk`)

S2-21 CLEAN (21st consecutive). S2-24/25/26/27 CLEAN. NUMERIC money CLEAN. EN/AR i18n 6508=6508 flattened leaf key parity (7551=7551 raw `:` count).

---

## Tests

| Suite | Count | Result |
|---|---|---|
| `tests/db/CR-O-fns.test.ts` | 16 | 16/16 PASS |
| `tests/integration/financial-trade-margin-routes.test.ts` | 12 | 12/12 PASS |
| NF-1 integration (NF-1-int-01 — `deltaAed = recompute output ±$1`) | 1 (included in 12 above) | PASS |
| Full BE suite after CR-O | — | 0 CR-O regressions |

---

## Files affected

### Database migrations
- `309_cro_create_price_benchmark.sql`
- `310_cro_create_trade_position.sql`
- `311_cro_create_trade_cost_component.sql`
- `312_cro_create_margin_snapshot.sql`
- `313_cro_create_latest_margin_mv.sql`
- `314_cro_extend_audit_trigger_redact.sql`
- `315_cro_fn_trade_margin_functions.sql`
- `316_cro_extend_fn_dashboard_executive.sql`
- `317_cro_pg_notify_channel.sql`
- `318_cro_create_permissions.sql`
- `319_cro_seed_parties_and_benchmarks.sql`
- `320_cro_seed_positions_components_snapshots.sql`
- `321_nf1_fix_fn_dashboard_executive_computed_recent_margin_change.sql`

### Backend (created)
- `src/types/trade-margin.types.ts`
- `src/schemas/trade-margin.schemas.ts`
- `src/controllers/financial-trade-margin.controller.ts`
- `src/routes/v1/financial-trade-margin.routes.ts`
- `src/workers/margin-recompute.worker.ts`

### Backend (modified)
- `src/routes/v1/index.ts` — mounted tradeMarginRouter + priceBenchmarksRouter
- `src/server.ts` — wired startMarginRecomputeWorker / stopMarginRecomputeWorker
- `src/utils/logger.util.ts` — added 7 Pino redact paths for `breakdown` JSONB (mig 314 DB-side redact mirrors)

### Frontend (created)
- `src/types/entities/trade-margin.types.ts`
- `src/services/api/financial-trade-margin.service.ts`
- `src/routes/app/financial.trade-margin.tsx` (outlet shim)
- `src/routes/app/financial.trade-margin.index.tsx` (positions list + aggregate tab)
- `src/routes/app/financial.trade-margin.$positionId.tsx` (position detail + recompute panel)
- `src/features/dashboards/components/ExecutiveTradeMarginSection.tsx`
- i18n: `src/i18n/en.json` + `src/i18n/ar.json` (+196 keys each)

### Frontend (modified)
- `src/features/dashboards/components/ExecutiveDashboard.tsx` — imports + renders ExecutiveTradeMarginSection after BudgetBurnSection
- `src/config/sidebar.ts` — added financial.tradeMargin module + ROLE_MODULES grants
- i18n files (counted in created above)

---

## M21 Financial Intelligence — now COMPLETE

| Sub-area | CR | Migrations | Status |
|---|---|---|---|
| Cost / Budget Burn | CR-N | 296–308 | Complete — shipped 2026-05-29 |
| Trade Margin | CR-O | 309–321 | Complete — shipped 2026-05-29 |

M21 delivers integrated financial intelligence across both sides of ADNOC's operational picture: cost tracking for services contracts (CR-N) and trade margin for commodity trading positions (CR-O). Both surfaces feed the executive dashboard as additive keys (10th: `budgetBurnSummary`, 11th: `tradeMarginSummary`).

---

*Doc generated: 2026-05-29 | Agent 15 (Documentation Generator) — CR changelog mode*
