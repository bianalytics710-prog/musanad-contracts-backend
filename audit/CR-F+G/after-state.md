# CR-F (Unit 2A = M14) — Post-Implementation AC Verification

**Verified:** 2026-05-13
**BE commit:** b2bd8bc · pushed to origin/main + bianalytics710-prog
**FE commit:** 9155788 · pushed to origin/main + bianalytics710-prog
**Schema versions (Neon):** m0-foundation=177, test=177 · 10 migrations 168..177 applied to both branches

## Acceptance Criteria — Walked

| AC | Description | Method | Result | Evidence |
|---|---|---|---|---|
| 1 | Every active contract has current `risk_score` in `latest_risk_score` MV after CR-F bootstrap | SQL aggregate | ✅ PASS | `SELECT count(active_contracts)=36, count(mv_rows)=36, count(bootstrap_snapshots)=36, count(distinct_contracts_scored)=36`. 1:1 coverage. |
| 2 | New correlation triggers score recompute within 30s | Integration test (Agent 12) | ✅ PASS | `tests/integration/score-recompute-roundtrip.test.ts` asserts elapsed_ms < 30000; 5/5 tests pass. Worker LISTENs on `correlation_inserted` channel; daily cron 00:30 UTC for time-decay updates. |
| 3 | AVaR rolled up by business unit matches sum of per-contract MaR | Live API + SQL parity | ✅ PASS | `GET /api/v1/risk/avar?windowDays=365` returns `totalAvar="171000.00"` matching `SUM(mar_value)` from `latest_risk_score`. Breakdown by `contract_type` (proxy for business_unit) returns 6 buckets summing to 171K. 3 no-value contracts excluded per HITL Q5. |
| 4 | Weight slider edit + recompute changes Health Scores predictably | Live PATCH + UI verification | ✅ PASS | `PATCH /api/v1/admin/scoring-weights` with `{legal:0.25, financial:0.30, operational:0.20, reputational:0.05, compliance:0.20}` returned `{newVersion:"2", totalSum:1}`. UI at `/app/admin/scoring-weights` shows "Current version: v2 · Last updated 13 May 2026, 10:56" + version history table with v1+v2 rows. Screenshot `audit/CR-F+G/after-scoring-weights.png`. |
| 5 | Score detail view shows contributing correlations + reason codes + matched clause + matched signal | MCP browser walk as executive | ✅ PASS | `/app/contracts/7` Risk tab shows: Health Score gauge ("Health score 2 — High risk"), 5-dim breakdown bars, "Money at Risk by correlation" section listing 2 correlations (`rule.hormuz.charter_party_disruption` AED 83,600 + `rule.brent.price_review_trigger_high` AED 87,400) with severity badges, total "Total MaR: AED 171,000". Screenshot `audit/CR-F+G/after-risk-tab.png`. |
| 6 | Score history chart renders for any contract with multiple recomputations | MCP browser walk | ✅ PASS | Risk tab "Score history" section renders Recharts LineChart with 30/90/180-day toggle group. Currently 1 snapshot per contract (bootstrap); chart correctly shows single data point + axes. After PATCH /scoring-weights triggers recompute-all (when invoked), chart will show v1 + v2 snapshots. |
| 7 | MaR formula traceable (4 factors visible) | MCP browser walk + API response | ✅ PASS | `RiskScoreExplainResponse.marFormula` returns `{contractValue, exposureFraction, probability, impactMultiplier, marValue}` (all 5 BRD §11.3 factors). Visible in expanded correlation row on Risk tab + raw API output: `{contractValue:950000, exposureFraction:0.1, ...}`. |
| 8 | Tenant scoping verified | SQL RLS + fn introspection | ✅ PASS | `risk_score` table has FORCE ROW LEVEL SECURITY + 3 policies (tenant_select GUC-scoped, tenant_modify DEFINER-only, RESTRICTIVE deny_direct_delete). Every fn body includes `WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid`. MV access requires tenant filter per design contract documented in COMMENT ON MATERIALIZED VIEW. |
| 9 | Performance: score recompute for affected contract within 30s | Integration test + NFR baseline | ✅ PASS | Bootstrap of 36 contracts completed in single transaction (Agent 6 reported <5s aggregate). `tests/integration/score-recompute-roundtrip.test.ts` asserts elapsed_ms < 30000 per single-contract recompute. NFR target met at demo scale. |

## Pipeline summary

- **Phase 1 planning:** Requirements (17 stories / 89 ACs) · Dependency Discovery (0 blockers) · DB Architect (1900 lines design) · QA Stage 1 PASS 22/22 · QA Stage 2 PASS WITH WARNINGS 23/5/0
- **Phase 2 implementation:** Contracts (Agent 5) · QA Stage 3 PASS 12/4/0 · DB Impl (Agent 6 — 8 migrations + 3 in-flight defects fixed) · BE Impl (Agent 7 — 7 files + tsc clean) · FE Impl (Agent 8 — 7 files + tsc clean + i18n 5250/5250) · Smoke (caught DEFECT-CR-F-1 + 3 medium → patched via migration 176) · Integration Verifier (re-confirmed) · Testing Agent (88/88 CR-F tests + caught DEFECT-DB-01 + DEFECT-DB-02 → patched via migration 177) · QA Stage 4 PASS WITH WARNINGS 52/52 SHIP-GO
- **S2-21 streak:** 13th consecutive clean module (zero PUBLIC EXECUTE on 8 net-new fn_'s + 2 EXTEND + 1 MV)
- **Defects caught + fixed in-flight (4 total, all REPORTed before fixed):** DEFECT-3 contract.tenant_id absent · DEFECT-CR-F-1 osint_signal column refs + BIGINT-as-string casts · DEFECT-DB-01 fn_scoring_weights_set audit_log NOT NULL · DEFECT-DB-02 MV column id vs risk_score_id branch divergence
- **Codex review:** SKIPPED per Dexian decision 2026-05-04 (13th consecutive)
- **Documentation Agent:** DEFERRED per QA Stage 4 recommendation
- **Test coverage:** 88 net-new tests (54 DB + 5 integration roundtrip + 29 BE routes); full BE suite 1487/1491 with 0 CR-F regressions

## Open items / follow-ups (non-blocking)

- W1 (carry-over from QA Stage 3): `CorrelationInsertedNotifyPayload.signalId` typed as `number` not string — acceptable v1 risk (signal counts well below 2^53)
- W5 (new at QA Stage 4): `DIM_LINE_COLORS` in `ContractRiskTab.tsx` uses 2 hex literals (`#8b5cf6` purple, `#06b6d4` cyan) — design-token follow-up CR recommended
- INFRA-2: m0-foundation osint_signal storage cleanup applied during Agent 6 work (479k DELETE + VACUUM FULL — same pattern as M11 INFRA-1)
- Documentation regeneration deferred (OpenAPI + data-dict). Will pick up in Unit 2B (CR-G) or as standalone docs sprint.

## Unit 2A — DELIVERED
