# CR-P — ADNOC Demo Wiring — Changelog

**CR-ID:** CR-P  
**Scope:** ADNOC demo registration + demo control panel wiring  
**Delivered:** 2026-05-29  
**Wave:** ADNOC Demo (v1.3) — finishing unit  
**Migrations:** 322 / 323 / 324  
**S2-21 status:** CLEAN — 21st consecutive (1 fn replaced, 2 REVOKE+GRANT)  
**Git SHAs:** BE — demo-harness only (no new BE routes); FE — no changes

---

## What changed

CR-P closes out the 3-story ADNOC demo build by registering the three new stories (labor cascade, budget burn, trade margin) in the existing demo control panel so a sales engineer can trigger, walk, and reset each scenario from `/app/admin/demo` without manual SQL.

---

## Migrations

### 322 — CHECK Constraint Extension
File: `database/migrations/322_crp_extend_demo_scenario_check.sql`

- Dropped `demo_scenario_scenario_id_chk` and recreated it as an 11-value closed set.
- Original 8 ids preserved byte-for-byte: `hormuz`, `ofac_sanctions`, `brent_review`, `epc_sla`, `renewal`, `cyclone`, `icv_shortfall`, `esg_subcontractor`.
- 3 new ids added: `labor_cascade`, `budget_burn`, `trade_margin`.
- `COMMENT ON TABLE demo_scenario` updated to document the 11-scenario closed set.

**Why DDL:** The original CHECK was a literal closed set; adding values requires a DROP + re-ADD. The audit trigger and FORCE RLS on the table were additive-only — no policy changes needed.

---

### 323 — Seed ADNOC Tier-2 Scenarios
File: `database/migrations/323_crp_seed_adnoc_demo_scenarios.sql`

**3 demo_seed_pack rows** (`pack.labor_cascade`, `pack.budget_burn`, `pack.trade_margin`) and **3 demo_scenario rows** (all `tier = 2`), scoped to the `adnoc` tenant via `WHERE t.slug = 'adnoc'`. Pattern matches migration 240 exactly — `ON CONFLICT DO NOTHING`, idempotent.

| scenario_id | display_name_en | tier | deepLink |
|---|---|---|---|
| `labor_cascade` | Labor Law Cascade | 2 | `/app/compliance/regulatory-cascade` |
| `budget_burn` | Budget Burn — Offshore Drilling | 2 | `/app/financial/budget-burn` |
| `trade_margin` | Oil Trade Margin | 2 | `/app/financial/trade-positions` |

**Verified expected_outcomes seeded in JSONB:**

| scenario_id | Key outcome data in seed |
|---|---|
| `labor_cascade` | `affectedContractors: 16`, penalty `AED 1.6M–1.7M`, `advisoryDraftCount >= 16` |
| `budget_burn` | day-rate `+8%` month-4, year-end `+1.3%` over budget, `cureNoticeEligible: true`, hero contract AED 4.22B |
| `trade_margin` | seller `$106.15→$99.84/bbl`, `−AED 139M` across 3 cargoes, buyer `+$9/bbl`, rec=buy |

No FE changes required: `fn_demo_scenario_list` returns all 11 rows dynamically; the admin panel's scenario cards render `displayNameEn/Ar`, `description`, `tier`, and `expectedOutcomes` from JSONB without a hardcoded `SCENARIO_IDS` filter.

---

### 324 — fn_demo_scenario_trigger Extension
File: `database/migrations/324_crp_extend_fn_demo_scenario_trigger.sql`

**Strategy: GRACEFUL CATALOG PATH.** A new `prepare` block runs before the existing signal-injection loop. The 3 new scenario_ids branch here; the existing 8 reach no matching branch and execute the original path byte-for-byte — zero regression risk.

| scenario_id | Prepare action | Reset behavior |
|---|---|---|
| `trade_margin` | Calls `fn_margin_recompute_for_price_change('murban_osp', 110.75)` — resets OSP benchmark to pre-drop state, recomputes all open sell positions, refreshes `latest_margin` MV. Graceful fallback if caller lacks `finance.trade.manage`. | Re-trigger resets to $110.75 so the operator can demo the drop again. |
| `labor_cascade` | `UPDATE osint_signal SET is_active = TRUE WHERE dedup_hash = <MOHRE decree signal>` (seeded by migration 288). Idempotent. | Re-trigger is always safe — signal stays active. |
| `budget_burn` | Static — data pre-seeded (migrations 303–304). No signal injection. Returns catalog result + deepLink. | No reset needed. |

**Return shape (all 3):** `{prepared: true, deepLink: '...', expectedOutcomes: {...}, note: '...'}` — no misleading zero-counts; `trade_margin` includes full `recomputeResult`.

**S2-21:** `REVOKE EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) FROM PUBLIC` + `GRANT EXECUTE ... TO neondb_owner` preserved verbatim (matches migration 235). 1 fn replaced, 2 explicit permission statements — streak maintained.

**ERRCODE:** explicit `42501` / `P0002` / `23000` on every RAISE; `WHEN OTHERS` preserves SQLSTATE. Failure run record written best-effort on exception.

---

## Frontend impact

**No FE code changes.** The demo control panel `/app/admin/demo` calls `fn_demo_scenario_list` at mount — with 11 rows now returned, all 3 ADNOC scenario cards appear automatically. The `SCENARIO_IDS` const in `admin.demo.index.tsx` is a local type alias, not a filter; it does not need updating for card rendering.

---

## Validation

| Check | Result |
|---|---|
| schema_migrations both branches | migrations 322/323/324 present — DEV + TEST identical |
| CHECK constraint (both branches) | 11-value array confirmed via `pg_get_constraintdef` |
| `fn_demo_scenario_list` total | 11 rows: 8 tier-1 + 3 tier-2 ADNOC |
| `trade_margin` trigger | `{prepared:true, recomputeResult:{benchmarkCode:'murban_osp', newPrice:'110.7500',...}}` — no 0-counts |
| `renewal` spot-check (existing scenario) | Original path untouched — returns standard outcome-count object |

---

## Files changed

### Database
- `database/migrations/322_crp_extend_demo_scenario_check.sql`
- `database/migrations/323_crp_seed_adnoc_demo_scenarios.sql`
- `database/migrations/324_crp_extend_fn_demo_scenario_trigger.sql`

### Backend
- No new routes or controllers.

### Frontend
- No changes.

---

## Decisions

No HITL questions raised for CR-P (fully autonomous / no-walk). Design approved without iteration.

---

*Agent 15 (Documentation Generator) — CR changelog mode. Incremental only — no full module regeneration. Generated 2026-05-29.*
