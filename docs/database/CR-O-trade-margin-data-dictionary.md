# CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half) — Database Data Dictionary

Generated: 2026-05-29
Module owner: CR-O (M21 Financial Intelligence — Trade Margin)
Schema version after CR-O: 321

---

## Tables

### price_benchmark

**Purpose:** Master/reference table for benchmark price observations — Murban OSP monthly series, Brent/Dubai/WTI/WAF spot, and the USD/AED FX rate used by margin computations.
**Owned by:** CR-O
**Used by:** fn_margin_compute (benchmark resolution), fn_margin_recompute_for_price_change (UPSERT), fn_price_benchmark_list, fn_price_benchmark_record, fn_margin_aggregate (indirect via fn_margin_compute), fn_dashboard_executive (tradeMarginSummary)

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT | Tenant scope |
| benchmark_code | TEXT | NOT NULL, CHECK ('murban_osp','brent','dubai','wti','west_african_x','usd_aed') | Price benchmark identifier. 'usd_aed' is the FX row (unit='aed_per_usd'); all others are crude benchmarks. |
| price_date | DATE | NOT NULL | Monthly OSP = first of month; daily market close = close date; spot = trade date |
| price_value | NUMERIC(12,4) | NOT NULL, CHECK (>= 0) | Price value in the unit specified. Never float. |
| unit | TEXT | NOT NULL DEFAULT 'usd_per_bbl', CHECK ('usd_per_bbl','aed_per_usd') | Unit of price_value. Crude benchmarks = usd_per_bbl; FX row = aed_per_usd. |
| period_grain | TEXT | NOT NULL DEFAULT 'monthly', CHECK ('monthly','daily','spot') | Time granularity of the observation |
| source | TEXT | NOT NULL DEFAULT 'mock', CHECK ('osp_official','market','mock') | Provenance. osp_official = published Murban OSP bulletin; market = exchange quote; mock = demo seed. |
| notes | TEXT | | Optional free-text annotation |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK ('demo','pilot','production') | Data maturity label |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation timestamp (UTC) |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last update timestamp (UTC) |
| created_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | User who created this record (sentinel 0 → NULL per S2-20) |
| updated_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | User who last updated this record |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Unique constraint:** `price_benchmark_idempotency_key (tenant_id, benchmark_code, price_date)` — one observation per (tenant, benchmark, date). Enables idempotent re-seed and ON CONFLICT UPSERT in recompute path.

**Indexes:**
| Index | Columns | Type | Purpose |
|---|---|---|---|
| idx_price_benchmark_tenant_id | tenant_id | BTREE | Tenant filter |
| idx_price_benchmark_code_date | tenant_id, benchmark_code, price_date DESC | BTREE | Primary read: latest/at-or-before observation for a benchmark code |
| idx_price_benchmark_created_by | created_by | BTREE (partial WHERE NOT NULL) | Audit JOIN |
| idx_price_benchmark_updated_by | updated_by | BTREE (partial WHERE NOT NULL) | Audit JOIN |
| idx_price_benchmark_active | id | BTREE (partial WHERE is_active=TRUE) | Active-only scans |

**RLS:** FORCE RLS. SELECT policy requires `finance.margin.read`; INSERT/UPDATE requires `finance.trade.manage` (defence-in-depth alongside fn-body gating).

---

### trade_position

**Purpose:** Transactional master for a cargo or term-deal leg — one row per distinct trade (e.g. ADNOC Trading sells 2M bbl Murban/month to Hanwha TotalEnergies for June delivery).
**Owned by:** CR-O
**Used by:** fn_trade_position_list, fn_trade_position_get, fn_margin_compute, fn_margin_recompute_for_price_change (bulk scan), fn_margin_snapshot_history, fn_margin_aggregate

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT | Tenant scope |
| position_ref | VARCHAR(60) | NOT NULL | Human-readable reference (e.g. 'TP-MURBAN-KR-JUN26'). Unique per tenant. |
| side | TEXT | NOT NULL, CHECK ('sell','buy') | Trade side. Seller = OSP-priced term contract; buyer = buy-and-refine spot economics. |
| grade | TEXT | NOT NULL, CHECK ('murban','west_african_x','brent','dubai','wti','other') | Crude grade |
| counterparty_id | BIGINT | NOT NULL REFERENCES party(id) ON DELETE RESTRICT | External counterparty (refinery buyer or crude seller). Name/country via JOIN — not stored here (column inheritance rule). |
| internal_entity_id | BIGINT | REFERENCES party(id) ON DELETE SET NULL | ADNOC internal entity on this leg (ADNOC Trading / ADNOC Global Trading). |
| volume_bbl | NUMERIC(18,2) | NOT NULL, CHECK (> 0) | Volume in barrels. Serialised as ::text in fn JSONB output. |
| pricing_basis | TEXT | NOT NULL, CHECK ('murban_osp','brent','dubai','wti','spot') | Benchmark that drives seller revenue resolution. 'spot' for buyer or bespoke spot. |
| delivery_month | DATE | NOT NULL | First of the delivery month (e.g. 2026-06-01 for June 2026) |
| term_or_spot | TEXT | NOT NULL DEFAULT 'term', CHECK ('term','spot') | Deal tenor |
| linked_contract_id | BIGINT | REFERENCES contract(id) ON DELETE SET NULL | Optional link to the underlying signed contract. Title/number via JOIN — not stored here. |
| status | TEXT | NOT NULL DEFAULT 'open', CHECK ('open','priced','closed') | Position lifecycle state |
| notes | TEXT | | Optional free-text |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK ('demo','pilot','production') | Data maturity label |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation timestamp (UTC) |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last update timestamp (UTC) |
| created_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | User who created this record |
| updated_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | User who last updated this record |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Unique constraint:** `trade_position_ref_key (tenant_id, position_ref)`.

**Indexes:**
| Index | Columns | Type | Purpose |
|---|---|---|---|
| idx_trade_position_tenant_id | tenant_id | BTREE | Tenant filter |
| idx_trade_position_counterparty_id | counterparty_id | BTREE | Counterparty lookup |
| idx_trade_position_internal_entity_id | internal_entity_id | BTREE (partial WHERE NOT NULL) | ADNOC entity lookup |
| idx_trade_position_linked_contract_id | linked_contract_id | BTREE (partial WHERE NOT NULL) | Contract JOIN |
| idx_trade_position_basis_status | tenant_id, pricing_basis, status | BTREE (partial WHERE is_active=TRUE) | Recompute scan: open positions on a given pricing_basis |
| idx_trade_position_side_delivery | tenant_id, side, delivery_month | BTREE (partial WHERE is_active=TRUE) | List sort/filter by side + delivery |

**RLS:** FORCE RLS. SELECT requires `finance.margin.read`; INSERT/UPDATE/DELETE requires `finance.trade.manage`.

---

### trade_cost_component

**Purpose:** Margin inputs — one row per cost/revenue component per position. Seller cost legs (lifting, transport_charter, insurance, hedge) and buyer cost legs (crude_purchase, refining, transport, storage) plus the buyer revenue leg (downstream_sale, `is_revenue=TRUE`). Seller OSP revenue is NOT stored here — it is resolved from price_benchmark at compute time.
**Owned by:** CR-O
**Used by:** fn_margin_compute (aggregates components), fn_trade_position_get (costComponents[] sub-query)

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT | Tenant scope |
| trade_position_id | BIGINT | NOT NULL REFERENCES trade_position(id) ON DELETE RESTRICT | Owning position |
| component_type | TEXT | NOT NULL, CHECK ('lifting','transport_charter','insurance','hedge','crude_purchase','refining','transport','storage','downstream_sale') | Type discriminator. Seller cost legs: lifting/transport_charter/insurance/hedge. Buyer cost legs: crude_purchase/refining/transport/storage. Buyer revenue leg: downstream_sale. |
| amount_usd_per_bbl | NUMERIC(12,4) | NOT NULL, CHECK (>= 0) | Per-barrel amount in USD. Never float. |
| is_revenue | BOOLEAN | NOT NULL DEFAULT FALSE | TRUE only for downstream_sale (buyer revenue leg). FALSE for all cost legs. |
| notes | TEXT | | Optional annotation |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK ('demo','pilot','production') | Data maturity label |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation timestamp (UTC) |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last update timestamp (UTC) |
| created_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | User who created this record |
| updated_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | User who last updated this record |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Unique constraint:** `trade_cost_component_key (tenant_id, trade_position_id, component_type)` — one row per component type per position.

**Indexes:**
| Index | Columns | Purpose |
|---|---|---|
| idx_trade_cost_component_tenant_id | tenant_id | Tenant filter |
| idx_trade_cost_component_position | trade_position_id | Position JOIN |

**RLS:** FORCE RLS. SELECT requires `finance.margin.read`; write requires `finance.trade.manage`.

---

### margin_snapshot

**Purpose:** Append-only computed-margin record per position per computation event. Mirrors the `risk_score` pattern from CR-F — every recompute inserts a new row; history is preserved for trend analysis. No `updated_at`, `updated_by`, or `is_active` columns (append-only table, same pattern as `audit_log`).
**Owned by:** CR-O
**Used by:** fn_margin_compute (INSERT), fn_margin_snapshot_history (ASC history reads), `latest_margin` MV (DISTINCT ON for latest per position)

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT | Tenant scope |
| trade_position_id | BIGINT | NOT NULL REFERENCES trade_position(id) ON DELETE RESTRICT | Owning position |
| side | TEXT | NOT NULL, CHECK ('sell','buy') | Denormalised side — point-in-time snapshot of position.side at compute time |
| benchmark_code_used | TEXT | | For seller: the benchmark_code resolved for this computation. NULL for buyer. |
| benchmark_price_used | NUMERIC(12,4) | | For seller: the OSP price applied (e.g. 110.7500). NULL for buyer. |
| revenue_per_bbl | NUMERIC(12,4) | NOT NULL | Per-barrel revenue. Seller = benchmark_price_used; buyer = downstream_sale amount. |
| cost_per_bbl | NUMERIC(12,4) | NOT NULL | Sum of all cost-leg amounts per barrel |
| margin_per_bbl | NUMERIC(12,4) | NOT NULL | revenue_per_bbl − cost_per_bbl. May be negative. |
| volume_bbl | NUMERIC(18,2) | NOT NULL | Denormalised volume at compute time (snapshot of position.volume_bbl) |
| total_margin_usd | NUMERIC(18,2) | NOT NULL | margin_per_bbl × volume_bbl in USD |
| usd_aed_rate | NUMERIC(12,4) | NOT NULL | FX rate used at compute time (frozen in snapshot, not re-derived) |
| total_margin_aed | NUMERIC(18,2) | NOT NULL | total_margin_usd × usd_aed_rate. Serialised as ::text in JSONB output. |
| recommendation | TEXT | CHECK (NULL OR 'buy','hold','sell','review') | Derived recommendation. Seller: sell/review. Buyer: buy/hold. |
| breakdown | JSONB | NOT NULL DEFAULT '{}' | Full revenue/cost waterfall — see breakdown shape below. Redacted in audit_log (mig 314). |
| computed_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | When this snapshot was computed (UTC) |
| triggered_by | TEXT | NOT NULL, CHECK ('manual','price_change','worker','bootstrap') | What triggered this computation |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK ('demo','pilot','production') | Data maturity label |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation timestamp (UTC) |
| created_by | BIGINT | REFERENCES "user"(id) ON DELETE SET NULL | Actor who triggered this computation |

**Note on denormalised columns:** `side`, `volume_bbl`, and `usd_aed_rate` are intentionally frozen in the snapshot — they are point-in-time facts of the computation, not derivable from the (mutable) current position or FX benchmark. This satisfies column inheritance rule #7's "derivable via FK join" test: these are *historical* values.

**breakdown JSONB shape:**
```jsonc
{
  "revenue": [ { "label": "Murban OSP", "type": "benchmark", "usdPerBbl": "110.7500" } ],
  "costs": [
    { "componentType": "lifting", "usdPerBbl": "1.2000" },
    { "componentType": "transport_charter", "usdPerBbl": "2.1000" }
  ],
  "totalCostPerBbl": "4.6000",
  "marginPerBbl": "106.1500",
  "fx": { "code": "usd_aed", "rate": "3.6725" }
}
```
Buyer `revenue[]` contains one `type:'component'` entry (downstream_sale). All numeric values serialised as `::text` strings.

**Indexes:**
| Index | Columns | Purpose |
|---|---|---|
| idx_margin_snapshot_tenant_position_computed | tenant_id, trade_position_id, computed_at DESC | History queries + DISTINCT ON for MV |
| idx_margin_snapshot_tenant_computed | tenant_id, computed_at DESC | Portfolio-level recent snapshot scans |
| idx_margin_snapshot_created_by | created_by | Audit JOIN (partial WHERE NOT NULL) |

**RLS:** FORCE RLS. SELECT requires `finance.margin.read`; audit trigger is AFTER INSERT only (append-only — no UPDATE/DELETE trigger needed). RESTRICTIVE deny-direct-delete policy (no deletes outside fn_ path).

---

## Materialized View

### latest_margin

**Purpose:** Exposes the most-recent `margin_snapshot` per (tenant_id, trade_position_id) as a fast O(1) lookup. Populated by `fn_margin_compute` via `REFRESH MATERIALIZED VIEW latest_margin` after each insert.
**Type:** MATERIALIZED VIEW
**Underlying table:** `margin_snapshot`
**Refresh strategy:** Non-concurrent inside `fn_margin_compute` (acceptable at demo scale < 20 positions, < 1s). UNIQUE INDEX `latest_margin_pk` enables a one-line `REFRESH ... CONCURRENTLY` upgrade at pilot scale.

**CRITICAL (A3 lesson):** RLS does NOT apply to MV rows. **Every fn that reads `latest_margin` MUST include `WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid`** — enforced in fn_margin_compute, fn_margin_recompute_for_price_change, fn_margin_aggregate, fn_trade_position_list, fn_trade_position_get, fn_dashboard_executive.

**Columns:** margin_snapshot_id, tenant_id, trade_position_id, side, benchmark_code_used, benchmark_price_used, revenue_per_bbl, cost_per_bbl, margin_per_bbl, volume_bbl, total_margin_usd, usd_aed_rate, total_margin_aed, recommendation, breakdown, computed_at, triggered_by.

**Indexes:**
| Index | Columns | Unique | Purpose |
|---|---|---|---|
| latest_margin_pk | tenant_id, trade_position_id | YES | Required for REFRESH CONCURRENTLY upgrade path. Primary lookup. |
| idx_latest_margin_tenant_side | tenant_id, side | NO | Side-filtered aggregate queries |
| idx_latest_margin_tenant_total | tenant_id, total_margin_aed DESC NULLS LAST | NO | Portfolio total sort |

**Access control:** `REVOKE ALL ON latest_margin FROM PUBLIC; GRANT SELECT ON latest_margin TO neondb_owner;`

---

## Functions

### fn_margin_compute
**Type:** Write (VOLATILE)
**Security:** INVOKER
**Purpose:** Compute margin for one trade position, insert a margin_snapshot row, refresh latest_margin MV, and return the full breakdown.
**Called via:** `SELECT fn_margin_compute(p_actor_id, p_trade_position_id, p_benchmark_price)`

**Parameters:**
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_actor_id | BIGINT | Yes | — | Calling user ID (0 = system sentinel) |
| p_trade_position_id | BIGINT | Yes | — | trade_position.id |
| p_benchmark_price | NUMERIC | No | NULL | Explicit benchmark price to use (seller). NULL = resolve from price_benchmark table. |

**Returns:** JSONB — MarginComputeResult shape. See db-design.md §D-1 for full key listing.

**Business rules:**
- Gates `finance.margin.read` in fn body (DEFECT-CRN-DB-01 lesson — from the start, not a follow-up fix)
- Resolves tenant via GUC `app.current_tenant_id`
- Resolves USD/AED rate from `price_benchmark WHERE benchmark_code='usd_aed'`
- Seller benchmark resolution: uses `p_benchmark_price` if supplied, else looks up `price_benchmark` at `delivery_month` (or latest at-or-before)
- Buyer: `benchmark_price_used = NULL`; revenue comes from `downstream_sale` component
- Split-aggregate CTE for cost/revenue components (S2-24 — no nested aggregate)
- `triggered_by = 'price_change'` when `p_benchmark_price IS NOT NULL`; `'manual'` otherwise
- Inserts `margin_snapshot` row; calls `REFRESH MATERIALIZED VIEW latest_margin`
- `recommendation`: seller → 'sell'/'review'; buyer → 'buy'/'hold'

**Error conditions:**
- `42501` — `finance.margin.read` not granted to calling user
- `P0002` — trade_position not found or inactive
- `22023` — `usd_aed benchmark not configured` (no FX row in price_benchmark)
- `22023` — no benchmark price resolvable for seller position

---

### fn_margin_recompute_for_price_change
**Type:** Write (VOLATILE)
**Security:** DEFINER
**Purpose:** UPSERT a new price_benchmark row, then recompute margin for all open positions priced on that benchmark with delivery on or after the new price date. Returns aggregate portfolio delta.
**Called via:** `SELECT fn_margin_recompute_for_price_change(p_actor_id, p_benchmark_code, p_new_price, p_price_date)`

**Parameters:**
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_actor_id | BIGINT | Yes | — | Calling user ID |
| p_benchmark_code | TEXT | Yes | — | Benchmark to update (e.g. 'murban_osp') |
| p_new_price | NUMERIC | Yes | — | New price (non-negative) |
| p_price_date | DATE | No | NULL | Effective date. Defaults to first of current month. |

**Returns:** JSONB — MarginRecomputeResult shape: `{ benchmarkCode, newPrice, priceDate, positionsRecomputed, deduplicatedCount, priorAggregateMarginAed, newAggregateMarginAed, deltaAed, deltaUsd, recomputedPositionIds[] }`

**Business rules:**
- Gates `finance.trade.manage` — DEFINER fn, caller-scoped
- Validates `p_benchmark_code` in enum; `p_new_price >= 0`
- UPSERT `price_benchmark` (ON CONFLICT tenant+code+date DO UPDATE)
- Captures `priorAggregateMarginAed` from `latest_margin` BEFORE recompute (A3 explicit tenant_id filter)
- Iterates open positions with matching `pricing_basis` AND `delivery_month >= p_price_date`; calls `fn_margin_compute` per position via SAVEPOINT (CR-F bulk-recompute isolation pattern)
- S2-19: 3-arg `fn_margin_compute(BIGINT, BIGINT, NUMERIC)` signature verified at design time
- Emits `pg_notify('margin_recompute_requested', ...)` after completion (consumed by margin-recompute.worker.ts)

**Error conditions:**
- `42501` — `finance.trade.manage` not granted
- `22023` — invalid benchmark_code or negative price

---

### fn_margin_aggregate
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** Portfolio rollup — total margin across all open positions, grouped by a chosen dimension (counterparty / quarter / side).
**Called via:** `SELECT fn_margin_aggregate(p_actor_id, p_filters)`

**Parameters:**
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_actor_id | BIGINT | Yes | — | Calling user ID |
| p_filters | JSONB | No | '{}' | `{ "groupBy": "counterparty" \| "quarter" \| "side" }` |

**Returns:** JSONB — `{ totalMarginAed, totalMarginUsd, currency:'AED', positionCount, groupBy, breakdown:[{key,label,marginAed,marginUsd,positionCount,pctOfTotal}] }`

**Business rules:**
- Gates `finance.margin.read`
- S2-24 split-aggregate: `filtered` CTE → `per_bucket` CTE → `totals` CTE → outer `jsonb_agg` (no nested aggregate inside jsonb_build_object)
- Reads `latest_margin` MV; explicit `WHERE tenant_id = ...` (A3)
- Quarter label via `to_char(delivery_month,'YYYY-"Q"Q')`. Counterparty bucket joins `party.name_en`.
- Never returns NULL — empty `breakdown: []` when no positions

---

### fn_trade_position_list
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** Paginated list of trade positions with inline latest margin from the MV.
**Called via:** `SELECT fn_trade_position_list(p_actor_id, p_side, p_grade, p_status, p_search, p_page, p_limit)`

**Returns:** JSONB — `{ data: TradePositionListItem[], pagination: PaginationMeta }`

**Business rules:**
- Gates `finance.margin.read`
- LEFT JOIN `latest_margin` for inline margin on each row
- `p_search` ILIKE on `position_ref` + `party.name_en`
- Never returns NULL — empty `data: []` when no matches

---

### fn_trade_position_get
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** Full position detail including cost components and latest margin block.
**Called via:** `SELECT fn_trade_position_get(p_actor_id, p_id)`

**Returns:** JSONB — `TradePosition` shape: id, positionRef, side, grade, counterparty, internalEntity, volumeBbl, pricingBasis, deliveryMonth, termOrSpot, linkedContract, status, notes, costComponents[], latestMargin, dataClassification, audit columns.

**Business rules:**
- Gates `finance.margin.read`
- `costComponents[]` from single `jsonb_agg` subquery on `trade_cost_component` (N+1 avoided)
- `latestMargin` is `NULL` before the first `fn_margin_compute` call; consumers must null-guard
- Returns `NULL` if position not found or inactive; controller maps to 404

---

### fn_price_benchmark_list
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** Paginated benchmark price series, optionally filtered by code and date range.
**Called via:** `SELECT fn_price_benchmark_list(p_actor_id, p_benchmark_code, p_from, p_to, p_page, p_limit)`

**Returns:** JSONB — `{ data: PriceBenchmarkListItem[], pagination: PaginationMeta }`. ORDER BY benchmark_code, price_date DESC.

**Business rules:**
- Gates `finance.margin.read`
- `priceValue` serialised as `::text` (NUMERIC(12,4) — CR-N/CR-F pattern)

---

### fn_price_benchmark_record
**Type:** Write (VOLATILE)
**Security:** INVOKER
**Purpose:** UPSERT a single price_benchmark observation (ad-hoc entry — not the bulk recompute path).
**Called via:** `SELECT fn_price_benchmark_record(p_actor_id, p_data)`

**Parameters:**
| Parameter | Type | Required | Description |
|---|---|---|
| p_actor_id | BIGINT | Yes | Calling user ID |
| p_data | JSONB | Yes | `{ benchmarkCode, priceDate, priceValue, unit, periodGrain?, source?, notes? }` |

**Returns:** JSONB — full PriceBenchmark entity row.

**Business rules:**
- Gates `finance.trade.manage`
- Validates required fields; enum checks
- UPSERT ON CONFLICT (tenant_id, benchmark_code, price_date) DO UPDATE

---

### fn_margin_snapshot_history
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** All margin snapshots for one position, in ascending computed_at order (for trend chart rendering left-to-right).
**Called via:** `SELECT fn_margin_snapshot_history(p_actor_id, p_trade_position_id, p_limit)`

**Returns:** JSONB — `{ tradePositionId, count, snapshots: MarginSnapshotHistoryItem[] }`. Returns `{ count: 0, snapshots: [] }` when position exists but has no snapshots.

**Business rules:**
- Gates `finance.margin.read`
- Reads `margin_snapshot` table directly (NOT the MV — the MV only has the latest row; history needs all rows)
- P0002 when position absent
- COALESCE empty array — never NULL

---

### fn_price_benchmark_get_by_id (internal)
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** Internal helper — returns one price_benchmark row by id. No external permission gate (called only by fn_price_benchmark_record return path); tenant-scoped by RLS.

---

### fn_trade_position_get_by_id (internal)
**Type:** Read (STABLE)
**Security:** INVOKER
**Purpose:** Internal helper — lightweight single-row trade_position fetch. No external gate; RLS-scoped. Used by future write fn return paths following the create→get_by_id convention.

---

### fn_dashboard_executive (EXTEND — additive key 11)
**Type:** See M6 / CR-G / CR-N for full spec. This entry documents the CR-O addition only.
**Purpose:** Additive `tradeMarginSummary` (11th top-level key) added to the executive dashboard JSONB. All 10 prior keys preserved byte-for-byte.

**tradeMarginSummary JSONB shape:**
```jsonc
{
  "openPositionCount": 4,
  "totalMarginAed": "2233026900.00",
  "totalMarginUsd": "608047500.00",
  "bySide": {
    "sell": { "positionCount": 3, "marginAed": "2199974400.00" },
    "buy":  { "positionCount": 1, "marginAed": "33052500.00" }
  },
  "recentMarginChange": {
    "benchmarkCode": "murban_osp",
    "deltaAed": "-139040850.00",
    "deltaUsd": "-37860000.00",
    "asOf": "2026-06-01"
  },
  "topPositionsByMargin3": [
    {
      "tradePositionId": 12, "positionRef": "TP-MURBAN-KR-JUN26",
      "side": "sell", "counterpartyName": "Hanwha TotalEnergies",
      "totalMarginAed": "733324800.00"
    }
  ]
}
```

`recentMarginChange` is computed dynamically (mig 321 — S2-24 LAG-window CTE chain reading `margin_snapshot WHERE triggered_by='price_change'`). Returns `null` when no price_change snapshots exist within the 30-day window.

**Defensive pattern:** `latest_margin` read wrapped in `BEGIN...EXCEPTION WHEN OTHERS THEN v_trade_margin_summary := NULL; END;` with COALESCE to a zero-shape fallback — a margin-data gap cannot break the executive dashboard.

**A3 compliance:** explicit `WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid` on all MV reads inside this key's computation.

---

## Audit Trigger Extension (migration 314)

`fn_audit_trigger` redact list extended to include `breakdown` column from `margin_snapshot`. Audit rows for margin_snapshot show `[REDACTED]` for the cost waterfall (commercially sensitive per-bbl cost data) while preserving headline margin columns (margin_per_bbl, total_margin_usd, total_margin_aed). BE Pino logger.util.ts mirrors with 7 redact paths covering `*.breakdown`.

---

## Migration sequence

| Migration | Description |
|---|---|
| 309 | price_benchmark table + FORCE RLS + audit trigger |
| 310 | trade_position table + FORCE RLS + audit trigger |
| 311 | trade_cost_component table + FORCE RLS + audit trigger |
| 312 | margin_snapshot append-only table + FORCE RLS + AFTER INSERT audit trigger |
| 313 | latest_margin MV + UNIQUE INDEX + REVOKE/GRANT |
| 314 | fn_audit_trigger redact extension: breakdown added (60 → 61 redacted fields) |
| 315 | All 10 CR-O fn_'s (D-1..D-10 per db-design.md) + COMMENT+REVOKE+GRANT trio per fn |
| 316 | fn_dashboard_executive EXTEND: additive tradeMarginSummary (11th key) |
| 317 | pg_notify channel documentation marker: margin_recompute_requested |
| 318 | 2 permissions + role grants (read→exec/finance/admin; manage→finance/admin) |
| 319 | Seed: Hanwha + WAF party rows + 7 price_benchmark rows (OSP series + context + FX) |
| 320 | Seed: 3 sell positions + 1 buy position + 17 cost components + bootstrap fn_margin_compute calls |
| 321 | NF-1 fix: fn_dashboard_executive tradeMarginSummary.recentMarginChange computed via S2-24 LAG-window CTE (replaces hardcoded literals from mig 316) |

---

*Data dictionary generated: 2026-05-29 | Agent 15 (Documentation Generator) — CR changelog mode | Covers CR-O only; prior modules documented in their own data dictionary files.*
