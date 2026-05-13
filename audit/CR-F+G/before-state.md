# CR-F + CR-G (Unit 2 = M14 + M15) — Pre-Implementation Baseline

**Captured:** 2026-05-12
**Logged-in persona:** `executive@musanad.local` (id=8, role=executive)
**FE base URL:** http://localhost:5173
**BE base URL:** http://localhost:4000
**Schema versions (Neon):** m0-foundation=167, test=167 — Unit 2 starts at migration **168**

## Surfaces walked

| Route | Outcome | Screenshot |
|---|---|---|
| `/auth/login` | Renders dev quick-sign-in panel with 7 personas | n/a |
| `/app/dashboards/executive` | Renders R-EX foundation: 5-tile KPI strip + cycleTimeFunnel + 5 chart sections + 3 list sections + events14d + AI anomaly card. **No AVaR tile · No WhatChangedToday · No RecommendedActions · No ClausesTriggered.** | audit/CR-F+G/before-executive-dashboard.png |

## Net-new surfaces confirmed absent (grep-only, per autonomous-mode.md "skip pre-impl walk for purely net-new")

- ❌ `/app/dashboards/operations` — no `dashboards/operations` files in FE src
- ❌ `/app/dashboards/finance-treasury` — no `dashboards/finance` files in FE src
- ❌ `/app/dashboards/compliance-esg` — no `dashboards/compliance` files in FE src
- ❌ `/app/dashboards/procurement` — no `dashboards/procurement` files in FE src
- ❌ `/app/admin/scoring-weights` — no `scoring-weights` files in FE src
- ❌ `Risk` tab on `/app/contracts/$id` — no `RiskTab` / `RiskScore` components
- ❌ AI Risk Assistant panel — no `RiskAssistantPanel` / `risk-assistant.service` in FE src
- ❌ BE routes — no `risk-score` / `risk-assistant` / `scoring-weights` controllers/routes
- ❌ DB — no `risk_score` table; no `latest_risk_score` MV; no `fn_dashboard_operations` / `fn_dashboard_finance_treasury` / `fn_dashboard_compliance_esg` / `fn_dashboard_procurement_supplier_risk` / `fn_risk_score_compute` / `fn_avar_aggregate` etc.

Adjacent existing surfaces preserved (regression baseline):
- ✅ R-EX executive dashboard renders (5 KPI tiles + funnel + 5 charts + 3 lists + events14d + ExecutiveAnomaliesCard)
- ✅ M4 `ai_risk_score` column on `contract` already exists (single-number aggregate — distinct from CR-F's 5-dim snapshot table)
- ✅ Migration 167 = `167_fix_fn_correlation_list_group_by.sql` (last Unit-1 post-walk fix)

## Locked autonomous decisions (CR-F + CR-G briefs)

CR-F: (1) MaR currency locked-at-correlation · (2) Recompute per-correlation v1 · (3) Probability weighted-by-source-reliability · (4) Score history all-forever · (5) NULL contract_value → MaR=NULL + UI placeholder

CR-G: (1) Roles seed AND demo live-create · (2) AI Risk Assistant SSE streaming · (3) 60s polling · (4) Procurement dashboard-only (list view → R-PROC round) · (5) Separate per-persona prompts

## Pipeline scope summary

- ~12-15 migrations: 168..~182
- New tables: `risk_score`; materialized view: `latest_risk_score`
- New fn_'s (~12): `fn_risk_score_compute`, `fn_risk_score_explain`, `fn_avar_aggregate`, `fn_score_recompute_for_signal`, `fn_score_recompute_for_weight_change`, `fn_dashboard_operations`, `fn_dashboard_finance_treasury`, `fn_dashboard_compliance_esg`, `fn_dashboard_procurement_supplier_risk` + extend `fn_dashboard_executive`
- New permissions (~6): `score.read`, `score.weights.manage`, `risk.acknowledge`, `insights.operations`, `insights.finance_treasury`, `insights.compliance_esg`, `insights.procurement_supplier_risk`, `ai.invoke.risk_assistant`
- New roles (3): `operations`, `finance_treasury`, `compliance_esg` (seeded in CR-G migration)
- New BE routes (~8) + 1 SSE-streaming AI service + 1 worker (score-recompute)
- New FE routes (4) + Risk tab + executive dashboard extension + AI Risk Assistant panel
- ~55 tests + 16 ACs
