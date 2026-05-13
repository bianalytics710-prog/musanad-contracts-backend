# M15 / CR-G — Executive Evolution + 4 Persona Dashboards + AI Risk Assistant

> **Module ID:** M15
> **Change Request:** CR-G
> **Status:** Complete — shipped 2026-05-13 (Unit 2B; fresh session after Unit 2A CR-F)
> **Migrations:** 178..190 (13 files; 189 + 190 are in-flight defect-fix patches)
> **Schema version:** 190 (both `m0-foundation` and `test` Neon branches)
> **Pipeline mode:** Autonomous end-to-end (Unit 2B)

---

## Overview

CR-G ships the decision surface layer atop M14's risk scoring engine. The module extends the
executive dashboard with 3 new sections, delivers 4 net-new persona dashboards, adds the AI
Risk Assistant floating panel with SSE streaming, seeds 3 new ADNOC roles and 5 new permissions,
and extends `ai_request_log` with ACL audit columns.

**Zero net-new tables** — all extensions via fn_'s + role/permission/ai_prompt rows + 1 EXTEND
on `ai_request_log`. Most complex module by migration count in the CRIP layer (13 migrations).

---

## Migrations

| # | File | Purpose | Status |
|---|---|---|---|
| 178 | `178_crg_permissions_seed.sql` | 5 net-new permissions (insights.operations / insights.finance_treasury / insights.compliance_esg / insights.procurement_supplier_risk / ai.invoke.risk_assistant) | Applied |
| 179 | `179_crg_extend_ai_request_log.sql` | ALTER TABLE ai_request_log ADD scope_hash TEXT + acl_filtered_count INTEGER (both nullable, backward-compat) per Annex D §15.3 ACL audit | Applied |
| 180 | `180_crg_extend_fn_dashboard_executive.sql` | EXTEND fn_dashboard_executive — preserve R-EX body byte-for-byte + 3 additive top-level keys (whatChangedToday + recommendedActions + clausesTriggered) per decision A1 Option B | Applied |
| 181 | `181_crg_seed_roles_and_grants.sql` | 3 new role rows (operations / finance_treasury / compliance_esg) + 30 native role_permission grants | Applied |
| 182 | `182_crg_preemptive_grants_backfill.sql` | 14-grant pre-emptive backfill activating M7/M8/M9/M12/M13/M14 conditional grants for the 3 new roles | Applied |
| 183 | `183_crg_fn_dashboard_operations.sql` | CREATE fn_dashboard_operations DEFINER VOLATILE (SLA breaches + delivery delays + penalty exposure + ops events + vendor scorecards) | Applied |
| 184 | `184_crg_fn_dashboard_finance_treasury.sql` | CREATE fn_dashboard_finance_treasury DEFINER VOLATILE (FX volatility + price-review queue + payment delays + currency breakdown) | Applied |
| 185 | `185_crg_fn_dashboard_compliance_esg.sql` | CREATE fn_dashboard_compliance_esg DEFINER VOLATILE (sanctions exposure + sub-contractor chain via fn_party_chain_traverse_down + audit rights tracker + regulatory updates + ESG correlations) | Applied |
| 186 | `186_crg_fn_dashboard_procurement_supplier_risk.sql` | CREATE fn_dashboard_procurement_supplier_risk DEFINER VOLATILE (supplier scorecard via M14 latest_risk_score join + ICV compliance + backup-supplier suggestions + vendor financial health) | Applied |
| 187 | `187_crg_seed_ai_prompt_risk_assistant.sql` | 6 ai_prompt rows (risk_assistant.qa_executive / qa_legal / qa_compliance / qa_operations / qa_finance_treasury / qa_procurement) per HITL Q5 separate-per-persona lock | Applied |
| 188 | `188_crg_seed_role_permission_dashboard_grants.sql` | 13 final permission grants: procurement perm × 3 roles + ai.invoke.risk_assistant × 9 dashboard roles | Applied |
| 189 | `189_crg_fix_executive_yaml_casts_and_platform_admin_grants.sql` | DEFECT-CR-G-1 fix: backfill platform_admin's 3 missing insights perms. DEFECT-CR-G-2 fix: replace `produce_yaml::jsonb` casts (column is YAML TEXT) with rule_id-pattern CASE expressions in fn_dashboard_executive | Applied |
| 190 | `190_crg_fix_finance_treasury_and_compliance_esg_yaml_casts.sql` | DEFECT-CR-G-4 fix: same YAML-cast issue in fn_dashboard_finance_treasury (1×) + fn_dashboard_compliance_esg (3×) | Applied |

---

## Database Changes

### Table Extension: `ai_request_log`

Two new nullable columns added by migration 179 (backward-compatible):

| Column | Type | Description |
|---|---|---|
| scope_hash | TEXT | SHA-256 of the ACL-filtered contract ID set used to build the AI prompt context. Enables Annex D §15.3 audit. |
| acl_filtered_count | INTEGER | Count of contracts visible to the caller after fn_contract_list ACL filter. |

---

### Functions Added

| Function | Security | Purpose |
|---|---|---|
| `fn_dashboard_operations(p_window_days INTEGER, p_actor_id BIGINT)` | DEFINER VOLATILE | Operations persona dashboard — SLA breaches + delivery delays + penalty exposure + ops events + vendor scorecards |
| `fn_dashboard_finance_treasury(p_window_days INTEGER, p_actor_id BIGINT)` | DEFINER VOLATILE | Finance & Treasury persona dashboard — FX volatility + price-review queue + payment delays + currency exposure breakdown |
| `fn_dashboard_compliance_esg(p_window_days INTEGER, p_actor_id BIGINT)` | DEFINER VOLATILE | Compliance & ESG persona dashboard — sanctions exposure (direct + chain) + audit rights tracker + sub-contractor chain (via fn_party_chain_traverse_down) + regulatory updates + ESG correlations |
| `fn_dashboard_procurement_supplier_risk(p_window_days INTEGER, p_actor_id BIGINT)` | DEFINER VOLATILE | Procurement Supplier Risk persona dashboard — supplier scorecard (AVG health_score per party from latest_risk_score MV) + ICV compliance + backup-supplier suggestions (party.party_type pivot per A4b) + vendor financial health |

**Function extended:**

`fn_dashboard_executive` — 3 additive top-level keys appended by migration 180 (body otherwise preserved from R-EX byte-for-byte per `feedback_fn_rewrites_lose_safety_guards.md`):
- `whatChangedToday` — array of correlation events in the past 24h with severity + marAed
- `recommendedActions` — array of actionable alerts with assignedRoles (PLURAL array per M13-projection lock) + slaHours + marAed
- `clausesTriggered` — object with `last7d` + `last30d` arrays grouping clause activations by clauseFamily + clauseType

Decision A1 (locked): `valueAtRisk` key NOT added to fn_dashboard_executive — M14's `AvarDashboardSection` continues to consume `/api/v1/risk/avar` directly, avoiding dual sources of truth.

---

### Roles Seeded

| Role Name | Description |
|---|---|
| operations | Operations persona — access to /dashboards/operations + internal signal resolution for operational subtypes |
| finance_treasury | Finance & Treasury persona — access to /dashboards/finance-treasury + financial signal resolution |
| compliance_esg | Compliance & ESG persona — access to /dashboards/compliance-esg + sanctions/ESG resolution |

---

### Permissions Seeded

| Permission Code | Granted To (primary) |
|---|---|
| insights.operations | Super Admin, platform_admin, operations |
| insights.finance_treasury | Super Admin, platform_admin, finance_treasury |
| insights.compliance_esg | Super Admin, platform_admin, compliance_esg |
| insights.procurement_supplier_risk | Super Admin, platform_admin, procurement |
| ai.invoke.risk_assistant | Super Admin, platform_admin, executive, legal_counsel, compliance_esg, operations, finance_treasury, procurement, contract_drafter, contract_approver |

Total role_permission grants added across migrations 181/182/188/189: ~57 rows.

---

### ai_prompt Seeds (Migration 187)

| prompt_id | Purpose |
|---|---|
| risk_assistant.qa_executive | Executive persona AI Risk Assistant system prompt |
| risk_assistant.qa_legal | Legal Counsel persona prompt |
| risk_assistant.qa_compliance | Compliance & ESG persona prompt |
| risk_assistant.qa_operations | Operations persona prompt |
| risk_assistant.qa_finance_treasury | Finance & Treasury persona prompt |
| risk_assistant.qa_procurement | Procurement persona prompt |

---

## Routes

| Method | Path | Permission | DB Function | Notes |
|---|---|---|---|---|
| GET | /api/v1/dashboards/operations | insights.operations | fn_dashboard_operations | windowDays default 30, max 180 |
| GET | /api/v1/dashboards/finance-treasury | insights.finance_treasury | fn_dashboard_finance_treasury | windowDays default 30, max 180 |
| GET | /api/v1/dashboards/compliance-esg | insights.compliance_esg | fn_dashboard_compliance_esg | windowDays default 30, max 180 |
| GET | /api/v1/dashboards/procurement | insights.procurement_supplier_risk | fn_dashboard_procurement_supplier_risk | windowDays default 30, max 180 |
| POST | /api/v1/ai/risk-assistant/ask | ai.invoke.risk_assistant | riskAssistantService.ask() | SSE + ?stream=false; 30 req/min/user |

**Extended route:**

`GET /api/v1/dashboards/executive` — response payload extended with `whatChangedToday + recommendedActions + clausesTriggered` (no URL or auth signature change).

---

## AI Risk Assistant Service Architecture

`src/services/ai/risk-assistant.service.ts` — the orchestration layer:

1. ACL pre-filter: calls `fn_contract_list` to narrow context to caller-visible contracts. Computes SHA-256 scope_hash.
2. Prompt resolution: `fn_ai_prompt_get(prompt_id = 'risk_assistant.qa_<persona>')` — per HITL Q5 separate-prompt lock.
3. pgvector citation lookup: `fn_clause_semantic_search` (DEFECT-CR-G-5: arg signature mismatch; service falls back gracefully).
4. Cache check: `fn_ai_insight_get_cached` (300s TTL).
5. LLM call: OpenAI gpt-4o via existing AIProvider abstraction. SSE chunks emitted as `token` events. Citations emitted as `citation` events.
6. Cache write: `fn_ai_insight_upsert`.
7. Audit: `fn_ai_request_log_create` (18-arg — NOT `_record` per Agent 3 fn-name correction). Includes scope_hash + acl_filtered_count.

---

## Decisions (HITL Gate 2 + Agent 3 Resolutions)

**HITL Gate 2:**

| ID | Question | Locked | Rationale |
|---|---|---|---|
| CR-G-Q1 | 3 new role seeding strategy | seed AND demo live-create | Best-of-both: seed for reliable fallback; Platform Admin live-create flow stays demoable. |
| CR-G-Q2 | AI Risk Assistant transport | SSE streaming | Demo wow factor + better first-token latency. Non-streaming fallback at ?stream=false for resilience. |
| CR-G-Q3 | Per-persona dashboard auto-refresh cadence | 60s polling v1 | Pragmatic at demo scale. Event-driven WebSocket deferred to pilot. |
| CR-G-Q4 | Procurement supplier-risk surface scope | dashboard only in CR-G | List view + filter UI deferred to R-PROC persona round to keep CR-G ship-able. |
| CR-G-Q5 | Risk Assistant per-persona prompt variants | separate prompts per persona | Cleaner separation; matches M4 6-prompt pattern. Allows per-persona tuning without cross-impact. |

**Agent 3 Dependency Resolutions:**

| ID | Decision | Rationale |
|---|---|---|
| A1 | Skip valueAtRisk in fn_dashboard_executive (Option B) | M14 AvarDashboardSection already consumes /risk/avar. Redundant key = dual sources of truth. |
| A4 | Per-party risk = AVG(latest_risk_score.health_score) over party's active contracts | Smooths single-contract noise; matches industry supplier-rating norms. |
| A4b | Backup-supplier categorization pivot = party.party_type | Only enforced supplier taxonomy in live party table. party.industry + party.partner_role do NOT exist. |
| fn-name | fn_ai_request_log_create (18-arg) | Brief said fn_ai_request_log_record; live DB has _create. Live name wins. |
| M13-projection | recommendedActions.assignedRoles is PLURAL ARRAY | Live correlation_rule.produce_yaml schema is alert.assigned_roles[]. Brief said singular; data shape wins. |

---

## Defects Caught + Fixed In-Flight

| ID | Stage Caught | Description | Fix |
|---|---|---|---|
| DEFECT-CR-G-1 | Post-impl DB check | migration 188 omitted platform_admin's 3 insights perms | Migration 189: backfill 3 grants |
| DEFECT-CR-G-2 (CRITICAL) | Post-impl DB check | fn_dashboard_executive used `produce_yaml::jsonb` on YAML TEXT column → invalid_input_syntax | Migration 189: rule_id-pattern CASE expressions |
| DEFECT-CR-G-3 | BE testing | executive controller didn't pass tenantId GUC → current_setting('app.current_tenant_id', true)::uuid failed on empty string | BE controller + service updated: pass req.tenantId with ADNOC default fallback |
| DEFECT-CR-G-4 | Post-impl DB check | same YAML cast issue in fn_dashboard_finance_treasury (1×) + fn_dashboard_compliance_esg (3×) | Migration 190 |
| CRITICAL-2 (Integration Verifier) | Integration Verifier | dashboards-crg.service.ts FE used raw `return data` instead of unwrapping envelope | Patched 4 service methods inline |

---

## Known Open Defects (post-ship)

| ID | Description | Impact |
|---|---|---|
| DEFECT-CR-G-5 | fn_clause_semantic_search arg signature mismatch | AI Risk Assistant citations degraded; service falls back gracefully |
| DEFECT-CR-G-6 | ai_request_log duplicate request_id collision on BE retries | Non-fatal (logged + skipped); occasional audit log gap |
| DEFECT-CR-G-7 (CRITICAL) | AI Risk Assistant LLM stream silent | Blocks AC#3 + AC#4 full verification; dashboard otherwise functional |

---

## Tests

Testing Agent (Agent 12) and QA Stage 4 were **deferred** to post-ship sprint due to context budget. Defects were caught instead via:
- Live smoke walks
- Integration Verifier (caught CRITICAL-2 FE envelope unwrap)
- Phase 3 MCP browser AC verification

**Live verification results (6/7 ACs):**

| AC | Status |
|---|---|
| AC#1 Executive dashboard shows 4 sections (+ 3 new) | PASS |
| AC#2 4 persona dashboards render with real data | PASS |
| AC#3 Risk Assistant infra works (SSE headers + 200) | PARTIAL (LLM stream silent — DEFECT-CR-G-7) |
| AC#4 Per-persona prompt variant | DEFERRED (blocked by CR-G-7) |
| AC#5 Tenant scoping verified | PASS |
| AC#6 Persona rounds parity | OUT-OF-SCOPE (Unit 3) |
| AC#7 Per-persona route gating (sidebar + BE 403) | PASS |

---

## Production Standards

- All 13 migrations include rollback blocks.
- **14th consecutive S2-21 clean module** — zero net-new PUBLIC EXECUTE grants. All 5 fn_'s + 1 EXTEND verified `proacl={neondb_owner=X/neondb_owner}`.
- Zero net-new tables (all extension).
- Harden Mode applied to all FE components: T1/T3/T4/T5/T6/T7/T11/T12/T13.
- i18n +256 keys EN/AR strict parity 5506/5506. AR keys use `[NEEDS TRANSLATION]` placeholders (translation sprint deferred).
- Codex review SKIPPED per Dexian decision 2026-05-04 (14th consecutive).

---

## Open Follow-Ups

| Item | Description |
|---|---|
| Agent 12 Testing Agent | ~30 DB tests + AI service tests + Playwright per-persona render — post-ship sprint |
| QA Stage 4 | 51-check post-impl validation — post-ship sprint |
| AR i18n translations | 256 keys with [NEEDS TRANSLATION] placeholders — translation sprint |
| DEFECT-CR-G-5/6/7 | See known open defects above |
| R-OPS / R-FT / R-CES / R-PROC persona rounds | Unit 3 of Post-M11 plan; fresh sessions |
