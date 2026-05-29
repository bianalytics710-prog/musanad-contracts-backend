# CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half) — Changelog

**Module impact:** Establishes M21 Financial Intelligence (Cost Intelligence sub-area) as a net-new surface. Extends fn_dashboard_executive (additive 10th key). Reuses CR-H advisory-drafter + fn_advisory_draft_generate seam.
**Status:** Complete — shipped 2026-05-29
**Migrations:** 296..308 (13 files — 9 planned + 2 defect-fix + 1 DB-gate forward-fix + 1 dual-gate for cure-notice seam)
**Schema version:** 308 (both `m0-foundation` dev and `test` Neon branches)
**Pipeline mode:** Autonomous end-to-end (change-request scope)
**S2-21 streak:** 20th consecutive clean module

---

## What changed

CR-N adds **period-by-category budget allocation + actual-spend tracking** for multi-year ADNOC services contracts — the first "financial intelligence" surface in the platform. Finance and procurement personas can view quarterly budgets vs monthly ERP actuals, compute variance / burn / year-end-projection on demand, and see which contracts have breached the configurable 5% variance threshold.

The **hero contract** (ADNOC Offshore → ADNOC Drilling, Jack-Up Drilling Rigs + Manpower, AED 4.22B, 5-year term) has a concrete day-rate +8% overrun in month 4 (April 2026), which fires the variance breach, surfaces correlated `cure_period` (30-day notice) and `liquidated_damages` (AED 730k/rig/day, cap AED 63.3M) clauses, and enables a cure-notice draft via the existing CR-H advisory-drafter pattern. Legal Counsel drafts; finance/procurement read.

The executive dashboard receives one additive key (`budgetBurnSummary`) preserving all 9 prior keys byte-for-byte (R-EX/CR-G lesson). A new `/app/financial/budget-burn` route (portfolio view + contract-detail view) handles finance_treasury / procurement_supplier_risk / operations / executive read access.

**Counts:**
- 2 new tables (`contract_budget`, `contract_cost_actual`)
- 9 new fn_'s: 4 analytics reads (`fn_budget_burn_compute`, `fn_budget_variance_for_contract`, `fn_budget_year_end_projection`, `fn_budget_burn_portfolio`) + 2 entity reads (`fn_contract_budget_list`, `fn_contract_budget_get`) + 1 entity read (`fn_contract_cost_actual_list`) + 1 write (`fn_contract_cost_actual_record`) + 1 internal helper (`fn_contract_cost_actual_get_by_id`)
- 1 additive extension to `fn_dashboard_executive` (10th key `budgetBurnSummary`, mig 299)
- 2 new permissions (`finance.budget.read`, `finance.budget.manage`)
- 1 new advisory_template `budget_cure_notice_v1` (EN+AR Mustache, 11 parameter placeholders)
- 1 new system_setting `financial.budget.variance_threshold_pct = "5"` (configurable threshold)
- 52 `contract_budget` rows + 40 `contract_cost_actual` rows across 3 seeded hero contracts
- 2 extracted clauses on HERO-001 (`cure_period` + `liquidated_damages`)
- 5 BE files created / 1 modified; FE route + components + service created
- EN/AR i18n 6254→6346 (+92 keys: `financial.budgetBurn` namespace + `nav.financialBudgetBurn` key, full EN=AR parity 6346=6346)

---

## Persona access model

| Role | finance.budget.read | finance.budget.manage | advisory.draft.review (cure notice) |
|---|---|---|---|
| finance_treasury | ✓ | ✓ | — |
| executive | ✓ | — | — |
| procurement_supplier_risk | ✓ | — | — |
| operations | ✓ | — | — |
| platform_admin | ✓ | ✓ | ✓ |
| Super Admin | ✓ | ✓ | ✓ |
| legal_counsel | — | — | ✓ (cure-notice draft only) |
| drafter / approver | — | — | — |

Finance and procurement read the budget burn surface. Finance manages budget lines and records actuals. Legal Counsel drafts cure notices from the variance screen when a breach is present. The executive dashboard shows a 4-field budget burn summary tile without needing any additional grants.

---

## Key decisions

All decisions auto-approved (autonomous build per user instruction 2026-05-29).

- **Decision 1 — Budget/actual period grain:** Budget at quarter grain (`2026-Q2` labels) + actuals at month grain (`2026-04` labels). `fn_budget_burn_compute` owns the month→quarter rollup; FE never reconciles grains. The `byPeriod` array is quarter-level; `monthlyActuals` is month-level — both coexist in the response.
- **Decision 2 — Dashboard extension:** Standalone `fn_budget_burn_portfolio` powers the new `/app/financial/budget-burn` route. The executive dashboard receives ONE additive `budgetBurnSummary` key (inline CTE — not a call to the portfolio fn). `fn_dashboard_finance_treasury` is untouched this CR.
- **Decision 3 — Variance persistence:** Compute-on-read. No `budget_variance_alert` table. `fn_budget_variance_for_contract` reads threshold from `system_setting` key `financial.budget.variance_threshold_pct`; default 5 if row missing.
- **Decision 4 — Cure-notice template:** Dedicated `budget_cure_notice_v1` with budget-specific Mustache placeholders (`overrun_pct`, `breach_period`, `cost_category`, `ld_clause_ref`, `cure_period_days`, `cure_period_end_date`). Reuses `draft_type='cure_notice'` + `assigned_approver_role='legal_counsel'` + same 3-channel dispatch as `cure_notice_v1` (CR-H).
- **Cure-notice draft seam (S2-19):** DB does NOT call `fn_advisory_draft_generate`. `budget-cure-notice-draft.service.ts` owns the seam: calls variance fn → guards `cureNoticeEligible` → locates/creates `correlation` (signal-anchor pattern; rule_id `rule.budget.variance_overrun`) → renders Mustache → delegates to existing `advisory-drafter.service`. The 10-arg `fn_advisory_draft_generate` signature (mig 216) is used unchanged.
- **fn_budget_variance_for_contract dual permission gate (mig 308):** Gated on `finance.budget.read OR advisory.draft.review` so `legal_counsel` (who holds `advisory.draft.review` but not `finance.budget.read`) can reach the variance context when drafting a cure notice. Pattern mirrors `fn_regulatory_cascade_item_link_draft` (mig 289, CR-M).
- **Money-as-string convention:** All `*Aed` fields cast to `::text` at the fn_ boundary. TypeScript types declare them as `string`. FE parses with `parseFloat()` / `formatAedCompact()` before display. Follows CR-F (`marAed::text`) and CR-M (`totalPenaltyMinAed`) precedents.
- **`reference_no NOT NULL DEFAULT ''`:** The `contract_cost_actual` idempotency key requires a non-NULL value (Postgres treats NULLs as distinct in UNIQUE). BE Zod coalesces absent `referenceNo` to `''`; FE renders `referenceNo === ''` as a dash.

---

## Defects caught and fixed

| ID | Severity | Phase | Description | Fixed in |
|---|---|---|---|---|
| DEFECT-302-1 | HIGH | DB Impl (pre-apply) | `advisory_template` column names `name_en`/`name_ar` vs live `display_name_en`/`display_name_ar` | mig 302 rewritten |
| DEFECT-303-1 | HIGH | DB Impl (pre-apply) | `contract` table has no `tenant_id` column — removed from INSERT | mig 303 rewritten |
| DEFECT-303-2 | HIGH | DB Impl (during apply) | `contract_version` has no `is_current`/`updated_at`/`updated_by` columns | mig 303 re-written |
| DEFECT-301-1 | MEDIUM | DB Impl (pre-apply) | `system_setting.category` CHECK list differs from design assumption | mig 301 uses verified constraint text |
| DEFECT-298-1 | HIGH | Smoke test | `fn_budget_burn_compute` window function nested inside `jsonb_agg` — Postgres prohibits | mig 306 rewrites cumulative-burn CTE |
| DEFECT-298-2 | HIGH | Smoke test | `fn_budget_variance_for_contract` compared monthly actuals to full-quarter budget → breach hidden | mig 306 rewrites with pro-rated monthly budget (`quarterly/3`) |
| DEFECT-CRN-DB-01 | HIGH | Post-ship audit | 7 read fn_'s lacked DB-layer `finance.budget.read` gate; write fn was correctly gated | mig 307 adds gate to all 7 reads; mig 308 upgrades variance fn to OR-gate for legal_counsel |
| FAIL-CRN-FE-1 | HIGH | QA Stage 4 | FE reads `totalBudgetAed` + `pctBudgetConsumed`; fn returns `totalBudgetedAed` + `burnRatePct` → crash on detail page | FE type + component renamed; tsc clean confirmed |

---

## Files affected

### Backend — New (5)

- `src/types/budget-burn.types.ts`
- `src/schemas/budget-burn.schemas.ts`
- `src/controllers/financial-budget-burn.controller.ts`
- `src/routes/v1/financial-budget-burn.routes.ts`
- `src/services/budget-cure-notice-draft.service.ts`

### Backend — Modified (1)

- `src/routes/v1/index.ts` — added `financialBudgetBurnRouter` mount at `/financial/budget-burn`

### Database — Migrations

| Migration | Contents |
|---|---|
| 296 | CREATE TABLE `contract_budget` — FORCE RLS, 3 policies, audit trigger, 6 indexes |
| 297 | CREATE TABLE `contract_cost_actual` — `reference_no NOT NULL DEFAULT ''`, FORCE RLS, 3 policies, audit trigger, 6 indexes |
| 298 | All 9 CR-N fn_'s — analytics + entity reads + write (REVOKE/GRANT/COMMENT on each) |
| 299 | `fn_dashboard_executive` additive extension — `budgetBurnSummary` 10th key |
| 300 | `finance.budget.read` + `finance.budget.manage` permissions + role_permission grants |
| 301 | Widen `system_setting.category` CHECK + UPSERT `financial.budget.variance_threshold_pct="5"` |
| 302 | `budget_cure_notice_v1` advisory_template EN+AR Mustache |
| 303 | 3 hero contracts + contract_versions + `cure_period` + `liquidated_damages` extracted clauses |
| 304 | 52 `contract_budget` rows + 40 `contract_cost_actual` rows (month-4 day_rate +8% overrun) |
| 305 | Belt-and-suspenders REVOKE/GRANT re-application on 9 fn_'s + 1 dashboard fn + role_permissions |
| 306 | DEFECT-298-1 + DEFECT-298-2 fix: rewrite `fn_budget_burn_compute` (cumulative-burn CTE) + `fn_budget_variance_for_contract` (pro-rated monthly comparison) |
| 307 | DEFECT-CRN-DB-01 fix: add `finance.budget.read` DB-layer gate to 7 read fn_'s |
| 308 | Dual-gate `fn_budget_variance_for_contract`: `finance.budget.read OR advisory.draft.review` |

### Frontend — New (FE files; no existing components broken)

- `src/types/entities/budget-burn.types.ts`
- `src/services/api/financial-budget-burn.service.ts`
- `src/routes/financial.budget-burn.index.tsx` (portfolio view — finance/procurement/operations/executive)
- `src/routes/financial.budget-burn.$contractId.tsx` (contract-detail view — burn, variance, projection, clause refs, cure-notice button)
- `src/components/financial/ExecutiveBudgetBurnSection.tsx` (executive dashboard additive tile)
- i18n `en.json` / `ar.json` — `financial.budgetBurn` namespace 91 keys + `nav.financialBudgetBurn` key

---

## Test results

| Layer | Tests | Pass | Fail |
|---|---|---|---|
| DB function (`tests/db/CR-N-fns.test.ts`) | 45 | 45 | 0 |
| HTTP integration (`tests/integration/financial-budget-burn-routes.test.ts`) | 88 | 88 | 0 |
| **CR-N total** | **133** | **133** | **0** |

Full backend suite post-CR-N: 2,142 tests — 2,108 pass / 27 fail (pre-existing) / 7 skip. 0 CR-N regressions. S2-21 streak: **20th consecutive clean module**.

---

## Git SHAs

See delivery-report.md in `project-artifacts/change-requests/CR-N-budget-burn/` for committed SHAs.
