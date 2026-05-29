# CR-N — Budget Burn (M21 Financial Intelligence, Cost half) — Database Data Dictionary

Generated: 2026-05-29T00:00:00Z
Module owner: M21 / CR-N
Migrations: 296–308

---

## Tables

### contract_budget

**Purpose:** Period-by-category budget allocation (the PLAN) per contract. Quarter grain by default (finance plans quarterly). Variance is computed on-read against `contract_cost_actual`.
**Owned by:** CR-N (M21)
**Used by:** `fn_budget_burn_compute`, `fn_budget_variance_for_contract`, `fn_budget_year_end_projection`, `fn_budget_burn_portfolio`, `fn_contract_budget_list`, `fn_contract_budget_get`, `fn_dashboard_executive` (additive key)

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK → tenant(id) ON DELETE RESTRICT | Tenant scope — all RLS policies gate on this |
| contract_id | BIGINT | NOT NULL, FK → contract(id) ON DELETE RESTRICT | Contract this budget line belongs to |
| period_type | TEXT | NOT NULL DEFAULT 'quarter', CHECK IN ('month','quarter','year') | Grain of this budget line |
| period_label | VARCHAR(20) | NOT NULL | Human/sortable label: 'YYYY-Qn' for quarter, 'YYYY-MM' for month, 'YYYY' for year |
| fiscal_year | INTEGER | NOT NULL, CHECK BETWEEN 2000 AND 2100 | Calendar year (ADNOC FY = calendar year) |
| cost_category | TEXT | NOT NULL, CHECK IN ('day_rate','manpower','equipment','milestone','other') | Fixed ADNOC accounting taxonomy — not user-extensible in this CR |
| allocated_amount_aed | NUMERIC(18,2) | NOT NULL, CHECK >= 0 | Planned spend for this period + category. Never float. Returned as ::text in JSONB. |
| currency | CHAR(3) | NOT NULL DEFAULT 'AED' | Budget-line currency. AED-only for CR-N. Property of the line, not inherited from contract. |
| notes | TEXT | nullable | Optional note for this budget line |
| source | TEXT | NOT NULL DEFAULT 'demo_seed', CHECK IN ('manual','demo_seed','import') | Provenance of the budget entry |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK IN ('demo','pilot','production') | Data maturity classification |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation timestamp (UTC) |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last update timestamp (UTC) |
| created_by | BIGINT | FK → "user"(id) ON DELETE SET NULL | User who created this record |
| updated_by | BIGINT | FK → "user"(id) ON DELETE SET NULL | User who last updated this record |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Unique constraint:**
`contract_budget_idempotency_key` — UNIQUE (tenant_id, contract_id, period_label, cost_category). One active budget line per (tenant, contract, period, category).

**Indexes:**

| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_contract_budget_tenant_id | tenant_id | BTREE | Tenant isolation |
| idx_contract_budget_contract_id | contract_id | BTREE | FK join |
| idx_contract_budget_created_by | created_by WHERE NOT NULL | BTREE | Audit join |
| idx_contract_budget_updated_by | updated_by WHERE NOT NULL | BTREE | Audit join |
| idx_contract_budget_active | id WHERE is_active=TRUE | BTREE | Active-record filter |
| idx_contract_budget_contract_fy_cat | (contract_id, fiscal_year, cost_category) WHERE is_active=TRUE | BTREE | Burn/variance scan — primary query pattern |

**RLS policies (FORCE RLS):**

| Policy | Command | Condition |
|---|---|---|
| contract_budget_tenant_select | SELECT | tenant_id = GUC AND fn_current_user_has_permission('finance.budget.read') |
| contract_budget_tenant_modify | ALL (INSERT/UPDATE) | tenant_id = GUC AND fn_current_user_has_permission('finance.budget.manage') — WITH CHECK same |
| contract_budget_deny_direct_delete | DELETE (RESTRICTIVE) | USING (FALSE) — soft delete only |

**Audit trigger:** `audit_contract_budget_changes` — AFTER INSERT OR UPDATE OR DELETE, calls `fn_audit_trigger()`. No sensitive-field redaction (money figures are operational, not secret).

---

### contract_cost_actual

**Purpose:** Actual-spend line items (mock ERP feed). Month grain. Rolled up to budget quarter by burn/variance fn_'s. No real ERP integration in CR-N.
**Owned by:** CR-N (M21)
**Used by:** `fn_budget_burn_compute`, `fn_budget_variance_for_contract`, `fn_budget_year_end_projection`, `fn_budget_burn_portfolio`, `fn_contract_cost_actual_list`, `fn_contract_cost_actual_record`

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK → tenant(id) ON DELETE RESTRICT | Tenant scope |
| contract_id | BIGINT | NOT NULL, FK → contract(id) ON DELETE RESTRICT | Contract this actual-spend line belongs to |
| period_type | TEXT | NOT NULL DEFAULT 'month', CHECK IN ('month','quarter','year') | Grain — month by default for ERP feed |
| period_label | VARCHAR(20) | NOT NULL | Month label e.g. '2026-04'; quarter '2026-Q2'; year '2026' |
| fiscal_year | INTEGER | NOT NULL, CHECK BETWEEN 2000 AND 2100 | Calendar year |
| cost_category | TEXT | NOT NULL, CHECK IN ('day_rate','manpower','equipment','milestone','other') | Fixed accounting taxonomy |
| actual_amount_aed | NUMERIC(18,2) | NOT NULL, CHECK >= 0 | Actual spend for this line. Never float. Returned as ::text in JSONB. |
| currency | CHAR(3) | NOT NULL DEFAULT 'AED' | AED-only for CR-N |
| source | TEXT | NOT NULL DEFAULT 'erp_feed', CHECK IN ('erp_feed','manual') | 'erp_feed' = mock finance feed; 'manual' = via fn_contract_cost_actual_record |
| reference_no | VARCHAR(100) | NOT NULL DEFAULT '' | ERP voucher/invoice reference. NOT NULL DEFAULT '' (not nullable) — required for reliable idempotency key. FE renders '' as dash. |
| recorded_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | When this actual was posted / recorded |
| notes | TEXT | nullable | Optional note |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK IN ('demo','pilot','production') | Data maturity |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Record creation timestamp (UTC) |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Last update timestamp (UTC) |
| created_by | BIGINT | FK → "user"(id) ON DELETE SET NULL | User who created this record |
| updated_by | BIGINT | FK → "user"(id) ON DELETE SET NULL | User who last updated this record |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Unique constraint:**
`contract_cost_actual_idempotency_key` — UNIQUE (tenant_id, contract_id, period_label, cost_category, reference_no). One active actual per (tenant, contract, period, category, ERP reference). `reference_no NOT NULL DEFAULT ''` makes the key reliable — Postgres treats NULLs as distinct in UNIQUE.

**Indexes:**

| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_contract_cost_actual_tenant_id | tenant_id | BTREE | Tenant isolation |
| idx_contract_cost_actual_contract_id | contract_id | BTREE | FK join |
| idx_contract_cost_actual_created_by | created_by WHERE NOT NULL | BTREE | Audit join |
| idx_contract_cost_actual_updated_by | updated_by WHERE NOT NULL | BTREE | Audit join |
| idx_contract_cost_actual_active | id WHERE is_active=TRUE | BTREE | Active-record filter |
| idx_contract_cost_actual_contract_fy_cat_period | (contract_id, fiscal_year, cost_category, period_label) WHERE is_active=TRUE | BTREE | Burn/projection scan — primary query pattern including sort order |

**RLS policies (FORCE RLS):**

| Policy | Command | Condition |
|---|---|---|
| contract_cost_actual_tenant_select | SELECT | tenant_id = GUC AND fn_current_user_has_permission('finance.budget.read') |
| contract_cost_actual_tenant_modify | ALL (INSERT/UPDATE) | tenant_id = GUC AND fn_current_user_has_permission('finance.budget.manage') — WITH CHECK same |
| contract_cost_actual_deny_direct_delete | DELETE (RESTRICTIVE) | USING (FALSE) — soft delete only |

**Audit trigger:** `audit_contract_cost_actual_changes` — AFTER INSERT OR UPDATE OR DELETE, calls `fn_audit_trigger()`. No sensitive-field redaction.

---

## Functions

All 9 fn_'s are defined in migrations 298, 306, 307, 308. All return JSONB with camelCase keys. All money fields returned as `::text` (NUMERIC → string). All follow COMMENT + REVOKE PUBLIC EXECUTE + GRANT neondb_owner tail. S2-21 verified: `proacl = {neondb_owner=X/neondb_owner}` on all 9.

---

### fn_budget_burn_compute

**Type:** Read — STABLE INVOKER
**Migration:** 298 (original), 306 (window-in-aggregate fix — rewrites cumulative-burn CTE), 307 (adds finance.budget.read DB-layer gate)
**Purpose:** Per-period × category budget-vs-actual, variance amount + %, cumulative burn, % of total budget consumed, remaining budget — for one contract.
**Called via:** `SELECT fn_budget_burn_compute(p_actor_id, p_contract_id)`

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_actor_id | BIGINT | Yes | Calling user id (0 → NULL coerced — S2-20) |
| p_contract_id | BIGINT | Yes | contract.id to compute burn for (22023 if NULL) |

**S2-24 CTE structure:** `budget_q` (SUM allocated by quarter+category) → `actual_m` (SUM actual by month+category) → `actual_roll` (month labels mapped to owning quarter via CASE; SUM to quarter grain) → `joined` (FULL JOIN) → `cum_burn` (pre-computes window-function running sums on plain column references — avoids window-in-aggregate) → final jsonb_build_object.

**Returns:** JSONB — NULL if contract not found (controller → 404)

```json
{
  "contractId": "number",
  "contractNumber": "string",
  "titleEn": "string",
  "titleAr": "string | null",
  "currency": "AED",
  "totalBudgetedAed": "string",
  "totalActualAed": "string",
  "totalVarianceAed": "string",
  "totalVariancePct": "number",
  "burnRatePct": "number",
  "remainingBudgetAed": "string",
  "byPeriod": [
    {
      "periodLabel": "2026-Q1",
      "fiscalYear": 2026,
      "budgetAed": "string",
      "actualAed": "string",
      "varianceAed": "string",
      "variancePct": "number | null",
      "byCategory": [
        { "costCategory": "day_rate", "budgetAed": "string", "actualAed": "string",
          "varianceAed": "string", "variancePct": "number | null", "overThreshold": "boolean" }
      ]
    }
  ],
  "monthlyActuals": [
    { "periodLabel": "2026-04", "costCategory": "day_rate", "actualAed": "string" }
  ],
  "cumulativeBurn": [
    { "periodLabel": "2026-Q1", "cumulativeActualAed": "string", "cumulativeBudgetAed": "string" }
  ]
}
```

**Note on key names:** The deployed fn returns `totalBudgetedAed` (not `totalBudgetAed`) and `burnRatePct` (not `pctBudgetConsumed`). FE types and components align to the fn output names after FAIL-CRN-FE-1 patch.

**Business rules:**
- RLS + explicit `finance.budget.read` DB-layer permission check (mig 307) — 42501 if absent
- Month actuals rolled up to quarter for variance join (`YYYY-MM` → `YYYY-Qn` via CASE expression; fn-internal — no stored mapping table)
- `byPeriod` uses quarter labels; `monthlyActuals` uses month labels — both arrays coexist; FE must not align them by label

**Error conditions:**
- `fn_budget_burn_compute: p_contract_id is required` (ERRCODE 22023) — NULL contract_id
- `fn_budget_burn_compute: contract not found` (ERRCODE P0002) — contract_id absent or inactive
- `fn_budget_burn_compute: insufficient permission` (ERRCODE 42501) — caller lacks finance.budget.read
- WHEN OTHERS → preserves SQLSTATE

---

### fn_budget_variance_for_contract

**Type:** Read — STABLE INVOKER
**Migration:** 298 (original), 306 (pro-rated monthly comparison fix), 307 (finance.budget.read DB gate), 308 (dual-gate: finance.budget.read OR advisory.draft.review — for legal_counsel cure-notice seam)
**Purpose:** List (period, category) pairs breaching the variance threshold + correlate to the contract's `cure_period` and `liquidated_damages` extracted-clause refs.
**Called via:** `SELECT fn_budget_variance_for_contract(p_actor_id, p_contract_id, p_threshold_pct)`

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_actor_id | BIGINT | Yes | — | Calling user id |
| p_contract_id | BIGINT | Yes | — | Target contract (22023 if NULL) |
| p_threshold_pct | NUMERIC | No | NULL → system_setting → 5 | Override threshold %. NULL reads system_setting 'financial.budget.variance_threshold_pct'; defaults to 5 if row missing. |

**Key logic:** Compares month actuals to pro-rated monthly budget (`quarterly_budget / 3.0`) — not to full quarter total. This allows a single-month spike (e.g., April +8%) to fire as a breach even when the quarter budget is not yet fully consumed.

**Returns:** JSONB — NULL if contract not found (controller → 404)

```json
{
  "contractId": "number",
  "thresholdPct": "number",
  "thresholdSource": "param | system_setting | default",
  "breaches": [
    {
      "periodLabel": "2026-04",
      "costCategory": "day_rate",
      "fiscalYear": 2026,
      "budgetAed": "string",
      "actualAed": "string",
      "varianceAed": "string",
      "variancePct": "number",
      "severity": "warning | breach"
    }
  ],
  "breachCount": "number",
  "maxVariancePct": "number",
  "correlatedClauses": {
    "curePeriod": [
      { "clauseId": "number", "clauseType": "cure_period", "curePeriodDays": "number | null", "pageNo": "number" }
    ],
    "liquidatedDamages": [
      { "clauseId": "number", "clauseType": "liquidated_damages", "ldRate": "string | null", "ldCap": "string | null", "pageNo": "number" }
    ]
  },
  "cureNoticeEligible": "boolean"
}
```

**Business rules:**
- Dual permission gate (mig 308): `finance.budget.read OR advisory.draft.review` — allows legal_counsel to reach variance context for cure-notice drafting
- `cureNoticeEligible = true` when `breachCount > 0` AND at least one `cure_period` clause is present
- Clause refs read from `contract_clause_extracted` WHERE `clause_type_v2 IN ('cure_period', 'liquidated_damages')` and tenant GUC matches

---

### fn_budget_year_end_projection

**Type:** Read — STABLE INVOKER
**Migration:** 298, 307 (finance.budget.read gate added)
**Purpose:** Run-rate extrapolation → projected fiscal-year-end spend vs allocated, projected over/under, confidence note.
**Called via:** `SELECT fn_budget_year_end_projection(p_actor_id, p_contract_id, p_as_of_period)`

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_actor_id | BIGINT | Yes | — | Calling user id |
| p_contract_id | BIGINT | Yes | — | Target contract |
| p_as_of_period | VARCHAR | No | NULL → latest period with actuals | 'YYYY-MM' label for as-of cutoff |

**Projection logic:**
- `monthsElapsed` = count of distinct month period_labels with actuals up to `as_of`
- `runRatePerMonth` = `actualToDate / monthsElapsed`
- `projectedYearEnd` = `actualToDate + runRatePerMonth × monthsRemaining`
- `confidenceNote`: 'high' if `monthsElapsed >= 6`, 'medium' if 3–5, 'low' if < 3, 'insufficient_data' if 0 (no division — no raise)
- Fiscal year = calendar year (ADNOC-aligned). 12-month constant.

**Returns:** JSONB — NULL if contract not found. Returns projection fields as null + `confidenceNote='insufficient_data'` when no actuals exist (200, not 404).

```json
{
  "contractId": "number",
  "fiscalYear": 2026,
  "asOfPeriod": "2026-04",
  "monthsElapsed": "number",
  "monthsRemaining": "number",
  "actualToDateAed": "string | null",
  "runRatePerMonthAed": "string | null",
  "projectedYearEndAed": "string | null",
  "allocatedFyAed": "string",
  "projectedOverUnderAed": "string | null",
  "projectedOverUnderPct": "number | null",
  "isProjectedOverBudget": "boolean | null",
  "confidenceNote": "high | medium | low | insufficient_data"
}
```

---

### fn_budget_burn_portfolio

**Type:** Read — STABLE INVOKER
**Migration:** 298, 307 (finance.budget.read gate added)
**Purpose:** Portfolio rollup across all budgeted contracts (finance + executive); top over-budget contracts; paginated.
**Called via:** `SELECT fn_budget_burn_portfolio(p_actor_id, p_filters)`

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_actor_id | BIGINT | Yes | Calling user id |
| p_filters | JSONB | No (default '{}') | Optional: fiscalYear, minVariancePct, costCategory, page (default 1), limit (default 20, max 100) |

**S2-24 CTE structure:** `budget_by_contract` (SUM allocated GROUP BY contract_id) → `actual_by_contract` (SUM actual GROUP BY contract_id) → `joined` (LEFT JOIN + variance scalar math) → outer `jsonb_agg` consumes `joined` rows only. No nested aggregates.

**Returns:** JSONB — never NULL; returns zeros/empty arrays when no budgeted contracts.

```json
{
  "summary": {
    "contractsWithBudget": "number",
    "totalBudgetAed": "string",
    "totalActualAed": "string",
    "totalVarianceAed": "string",
    "overBudgetCount": "number",
    "totalProjectedOverrunAed": "string"
  },
  "topOverBudget": [
    { "contractId": "number", "contractNumber": "string", "titleEn": "string",
      "variancePct": "number", "varianceAed": "string" }
  ],
  "data": [
    { "contractId": "number", "contractNumber": "string", "titleEn": "string", "titleAr": "string | null",
      "counterpartyName": "string | null", "counterpartyNameAr": "string | null",
      "budgetAed": "string", "actualAed": "string", "varianceAed": "string",
      "variancePct": "number", "pctConsumed": "number",
      "projectedOverUnderAed": "string", "varianceFlag": "boolean" }
  ],
  "pagination": { "total": "number", "page": "number", "limit": "number", "totalPages": "number" }
}
```

**Note:** `counterpartyName` / `counterpartyNameAr` are embedded in the fn output (party LEFT JOIN) so executive (who lacks `party.read`) can still see counterparty names — same CR-FIX1 mig 278 precedent.

---

### fn_contract_budget_list

**Type:** Read — STABLE INVOKER
**Migration:** 298, 307 (finance.budget.read gate)
**Purpose:** Paginated list of budget lines with optional filters.
**Called via:** `SELECT fn_contract_budget_list(p_actor_id, p_contract_id, p_fiscal_year, p_cost_category, p_page, p_limit)`

**Parameters:** p_contract_id, p_fiscal_year, p_cost_category (all optional; filter when provided); p_page (default 1); p_limit (default 50, clamped 1–100).

**Returns:** `{ "data": [ContractBudgetListItem], "pagination": PaginationMeta }` — never NULL; data=[] when no rows.

---

### fn_contract_budget_get

**Type:** Read — STABLE INVOKER
**Migration:** 298, 307 (finance.budget.read gate)
**Purpose:** Single budget line by id with embedded contract summary.
**Called via:** `SELECT fn_contract_budget_get(p_actor_id, p_id)`

**Returns:** Full `ContractBudget` JSONB (including embedded `contract: { id, contractNumber, titleEn, titleAr }`) — NULL if not found (controller → 404).

---

### fn_contract_cost_actual_list

**Type:** Read — STABLE INVOKER
**Migration:** 298, 307 (finance.budget.read gate)
**Purpose:** Paginated list of actual-spend lines with optional filters.
**Called via:** `SELECT fn_contract_cost_actual_list(p_actor_id, p_contract_id, p_fiscal_year, p_cost_category, p_period_label, p_page, p_limit)`

**Parameters:** p_contract_id, p_fiscal_year, p_cost_category, p_period_label (all optional); p_page (default 1); p_limit (default 50, clamped 1–100).

**Returns:** `{ "data": [ContractCostActualListItem], "pagination": PaginationMeta }` — never NULL.

---

### fn_contract_cost_actual_record

**Type:** Write — VOLATILE INVOKER
**Migration:** 298
**Purpose:** Record a single actual-spend line (manual entry; mirrors ERP-feed shape). Upsert semantics via idempotency key.
**Called via:** `SELECT fn_contract_cost_actual_record(p_actor_id, p_contract_id, p_data)`

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_actor_id | BIGINT | Yes | Calling user id |
| p_contract_id | BIGINT | Yes | Target contract |
| p_data | JSONB | Yes | Keys: periodLabel (req), fiscalYear (req), costCategory (req), actualAmountAed (req), source? ('manual'), referenceNo? (coerced to '' if absent), periodType? ('month'), notes? |

**Business rules:**
- Explicit `finance.budget.manage` permission check at top (defence-in-depth + RLS WITH CHECK) — 42501 if absent
- `v_actor := NULLIF(p_actor_id, 0)` (S2-20 coercion)
- `tenant_id := current_setting('app.current_tenant_id', true)::uuid`
- INSERT … ON CONFLICT ON CONSTRAINT `contract_cost_actual_idempotency_key` DO UPDATE (upsert — idempotent ERP re-post)
- Validates: required fields present (22023), actualAmountAed >= 0 (22023), costCategory in enum (23514), contract exists and is_active (P0002)

**Returns:** Upserted row JSONB (full `ContractCostActual` shape).

---

### fn_contract_cost_actual_get_by_id (internal helper)

**Type:** Read — STABLE INVOKER (internal)
**Migration:** 298
**Purpose:** Internal helper used by `fn_contract_cost_actual_record` to return the upserted row in a consistent full-entity shape. Not directly exposed via API.

---

## Additive extension: fn_dashboard_executive — budgetBurnSummary key

**Migration:** 299 (additive; signature `(integer)` unchanged; all 9 prior keys preserved byte-for-byte)
**Change:** Adds `budgetBurnSummary` as the 10th top-level key in the fn output. All 9 existing keys (`kpis`, `kpiPrev`, `trends`, `charts`, `lists`, `events14d`, `whatChangedToday`, `recommendedActions`, `clausesTriggered`) are unchanged.

**Implementation:** An inline `WITH` block (split-aggregate CTEs: `budget_by_contract` / `actual_by_contract` / `joined`) appended to the final `jsonb_build_object(...)`. Does not call `fn_budget_burn_portfolio` — inlined 4-field CTE is lighter and keeps the fn self-contained.

**Requires:** executive role holds `finance.budget.read` (granted in mig 300) — RLS on `contract_budget` and `contract_cost_actual` permits the GUC-scoped sub-SELECT.

**JSONB shape of budgetBurnSummary:**

```json
{
  "budgetBurnSummary": {
    "contractsWithBudget": "number",
    "overBudgetCount": "number",
    "totalProjectedOverrunAed": "string",
    "topOverBudget3": [
      {
        "contractId": "number",
        "contractNumber": "string",
        "titleEn": "string",
        "variancePct": "number",
        "varianceAed": "string"
      }
    ]
  }
}
```

**QA B-key regression guard:** All 10 top-level keys verified present post-mig-299 (test-report + QA Stage 4 Section E confirmation). 0 prior key regressions.

---

## Permissions (mig 300 + backfill 305)

| Permission code | Module | Action | Description |
|---|---|---|---|
| finance.budget.read | finance | budget.read | View contract budget allocation, actual spend, burn, variance, and year-end projection |
| finance.budget.manage | finance | budget.manage | Create/update contract budget lines and record cost actuals |

Role grants: see §F of db-design.md and "Persona access model" in the module changelog.

---

## Seed data (migrations 303, 304)

### Hero contracts (mig 303)

| contract_number | title_en | value_aed | status | party A | party B |
|---|---|---|---|---|---|
| CRN-296-HERO-001 | ADNOC Offshore — Jack-Up Drilling Rigs + Manpower (2 rigs) | 4,220,000,000.00 | active | ADNOC Offshore | ADNOC Drilling |
| CRN-296-HERO-002 | ADNOC Offshore — Subsea Fracturing & Stimulation Services | 180,000,000.00 | active | ADNOC Offshore | ADNOC Drilling |
| CRN-296-HERO-003 | ADNOC Onshore — Integrated Well Manpower Services | 95,000,000.00 | active | ADNOC Onshore | ADNOC Drilling |

### Extracted clauses on HERO-001 (mig 303)

| clause_type_v2 | parameters | page_no |
|---|---|---|
| cure_period | `{"cure_period_days": 30, "notice_requirement": true}` | 22 |
| liquidated_damages | `{"ld_basis": "per_day_delay", "ld_rate": 730000, "ld_cap": 63300000}` | 24 |

### Budget allocations (mig 304)

- HERO-001: AED 845,000,000/year FY2026 across 4 categories × 4 quarters = 16 rows; plus 4 rows for FY2025-Q4
- HERO-002: AED 36,000,000/year FY2026 × 4 quarters = 16 rows
- HERO-003: AED 19,000,000/year FY2026 × 4 quarters = 16 rows
- Total: **52 contract_budget rows**

### Actual spend (mig 304)

- HERO-001: 4 months × 4 categories = 16 rows; month-4 day_rate = AED 47,880,000 (+8% over plan of AED 44,333,333/month = 133M/3)
- HERO-002 + HERO-003: 3–4 months on-plan actuals each
- Total: **40 contract_cost_actual rows**

### System setting (mig 301)

- `key = 'financial.budget.variance_threshold_pct'`, `category = 'financial'`, `value = '"5"'::jsonb`, `description = 'Variance % threshold above which a (period,category) budget breach is flagged and a cure notice becomes eligible.'`

### Advisory template (mig 302)

- `template_id = 'budget_cure_notice_v1'`, `display_name_en = 'Budget Variance Cure Notice'`, `draft_type = 'cure_notice'`, `assigned_approver_role = 'legal_counsel'`, `dispatch_channels = ["email","teams_capture","slack_capture"]`, `version = 1`, EN+AR Mustache bodies with 11 parameter placeholders (notice_date, contract_id, addressee, counterparty_name, breach_period, cost_category, overrun_pct, budgeted_amount_aed, actual_amount_aed, ld_clause_ref, cure_period_days, cure_period_end_date, cure_address)

---

*Data dictionary version: CR-N | Generated for Musanad Contracts Hub M21 Financial Intelligence (Cost half)*
