# M13 — Correlation Rule Engine + DSL — Technical Handoff

Generated: 2026-05-12T17:00:00Z
Status: Complete
QA verdict: PASS WITH WARNINGS (49/52 checks; 0 FAILs; S2-21 clean streak 13th consecutive)

---

## What This Module Builds

M13 ships the DB-backed correlation rule registry and evaluator for the Musanad Contracts Hub CRIP (Contract Risk Intelligence Platform) layer. Rules are stored in the database as YAML bodies (not files on disk — per §4.2 SOT lock) and are evaluated automatically when an OSINT signal arrives (PG NOTIFY osint_signal_inserted from M7/CR-A). When a rule's match predicates fire against a (signal, contract) pair, a correlation row is produced with confidence score, match reason, and supporting evidence. Seven production rules ship live: Hormuz charter party, Hormuz supply chain, Sanctions direct hit, Sanctions indirect chain, Brent price review, EPC SLA performance, and Renewal expiry.

This is a net-new module — no existing Lovable surfaces were hardened. All routes, components, and services are freshly built.

---

## Entities Managed

| Entity | Table | Type | Description |
|---|---|---|---|
| Correlation Rule | correlation_rule | master | Rule registry — match/produce YAML bodies, version_hash, enabled state |
| Correlation | correlation | transactional | Rule firing output — one row per (signal, contract, rule) triple |
| Rule Fixture | correlation_rule_fixture | transactional | Test fixtures attached to rules for admin test panel + CI |
| Evaluation Error | correlation_evaluation_error | transactional | Timeout + evaluator error records (OD-2 — separated from correlation table) |

---

## API Endpoints

| Method | Path | Roles | DB Function |
|---|---|---|---|
| GET | /api/v1/admin/rules | platform_admin, legal_counsel | fn_rule_list |
| POST | /api/v1/admin/rules | platform_admin | fn_rule_create |
| GET | /api/v1/admin/rules/:id | platform_admin, legal_counsel | fn_rule_get_by_id |
| PATCH | /api/v1/admin/rules/:id | platform_admin | fn_rule_update |
| DELETE | /api/v1/admin/rules/:id | platform_admin | fn_rule_delete |
| POST | /api/v1/admin/rules/:id/test | platform_admin | fn_rule_test_against_fixture |
| GET | /api/v1/correlations | platform_admin, legal_counsel | fn_correlation_list |
| POST | /api/v1/correlations/:id/dismiss | platform_admin, legal_counsel | fn_correlation_dismiss |

---

## Key Database Functions

| Function | Type | Purpose |
|---|---|---|
| fn_rule_create | Write | Inserts rule, computes SHA-256 version_hash, emits PG NOTIFY for cache invalidation |
| fn_rule_update | Write | Partial update; recomputes version_hash only on YAML change |
| fn_rule_delete | Write | Soft-delete (is_active = false); fixtures retained |
| fn_rule_list | Read | Paginated rule list with enabled/scenario/name filters |
| fn_rule_get_by_id | Read | Full rule detail including fixture summary |
| fn_rule_evaluate | Write | Evaluates all enabled rules against a signal; produces correlation rows |
| fn_rule_test_against_fixture | Read | Pure simulation — fixture pass/fail without persisting correlations |
| fn_correlation_dismiss | Write | Dismisses active correlation with mandatory reason |
| fn_correlation_list | Read | Paginated correlation list with status/contract/rule/date filters |

---

## Dependencies

**Depends on**:
- M0 — auth middleware, user table, JWT, fn_audit_trigger, fn_require_permission, system_setting table
- M7 / CR-A — osint_signal table (signal_id FK in correlation); PG NOTIFY osint_signal_inserted triggers rule evaluation worker
- M8 / CR-A2 — internal signal kind discriminator (EPC SLA rule predicate uses signal.kind from M8 schema)
- M9 / CR-B — party_relationship recursive CTE (sanctions chain rule predicate: counterparty_id_in_graph_descendants_of uses M9 function)
- M10 / CR-C — data_classification column pattern; tenant_id GUC pattern; system_setting category 'ai' (pre-widened in M11)
- M12 / CR-D — contract_clause_extracted table (has_clause and clause_parameter predicates read from this table per OD-1)

**Depended on by**:
- CR-I (future) — Tier 2 rules (Cyclone, ICV, ESG sub-contractor) will author YAML against the rule engine built in M13 without engine changes. The full ~30 predicate set from Annex C.4 is shipped in M13 (HITL Q6) to avoid future engine rework.

---

## Key Design Decisions

### Locked HITL Decisions (from project-artifacts/decisions/M12-M13.json)

#### Q1 — Rule evaluation timeout
**Locked:** 5 seconds default per rule
**Why:** Brief recommendation. Configurable per-rule via meta.evaluation_timeout_seconds and globally via system_setting.rule.eval_timeout_seconds. Timeout events write to correlation_evaluation_error (OD-2) and do not block evaluation of other rules.

#### Q2 — Rule conflict resolution
**Locked:** Accept-both-correlations
**Why:** Cleaner audit. If 2 rules match the same (signal_id, contract_id) pair, 2 correlation rows persist — one per rule_id (UNIQUE on tenant+signal+contract+rule_id permits this). Downstream scoring and alerting handle dedup at their layer.

#### Q3 — Hot-reload latency target
**Locked:** Under 5 seconds
**Why:** Achievable via PG NOTIFY 'correlation_rule_changed' + 2-second poller fallback. The rule evaluator service subscribes to this channel and reloads the in-memory rule cache on receipt. AC S15 verifies.

#### Q4 — Per-rule vs tenant-scoped disable
**Locked:** Tenant-scoped
**Why:** Each correlation_rule row carries tenant_id. Disabling affects only the owning tenant. Multi-tenant scope-disable is not in v1.2.

#### Q5 — Friendly form vs raw YAML primary
**Locked:** Friendly form primary; raw YAML as escape hatch
**Why:** Friendly form lets Risk and Legal SMEs author rules without YAML grammar knowledge. Raw YAML view is available via an 'Advanced' tab for predicates not yet exposed as form fields.

#### Q6 — Predicate set completeness
**Locked:** Implement all ~30 predicates from Annex C.4 in CR-E
**Why:** One-time cost. Adding predicates later requires DSL grammar change, parser rebuild, and admin UI rework. Shipping the full grammar in CR-E means Tier 2 rules (CR-I) and future rules can be authored entirely in YAML without engine work.

### Architectural Decisions

1. **Rules in DB, never on disk (§4.2 SOT)**: The entire rule lifecycle — create, edit, enable/disable, delete — is managed via the correlation_rule table and the admin UI. No YAML files in the repository. This makes rule changes auditable, tenant-scoped, and hot-reloadable without a deployment.

2. **version_hash snapshot on correlation rows**: Each correlation row captures rule_version_hash at the moment of firing. This means a correlation can be traced back to the exact rule body that produced it even after the rule is subsequently edited — retroactive audit is possible without rule versioning history tables.

3. **Evaluation errors in a separate table (OD-2)**: Rule evaluation timeouts write to correlation_evaluation_error rather than bloating the correlation table with a diagnostic JSONB column. This keeps the correlation table clean for operational queries and avoids index bloat from the diagnostic data.

4. **rule_id is a logical string, not a FK to correlation_rule.id (PK)**: Correlation rows reference rule_id (TEXT) rather than correlation_rule.id (BIGINT PK). This makes correlation data portable across tenant exports and avoids breaking existing correlations if a rule row is ever soft-deleted and re-created with the same logical identifier.

5. **Friendly form + raw YAML coexist (HITL Q5)**: The admin UI renders form fields for known predicates and falls back to the raw YAML textarea for the 'Advanced' tab. Both paths write the same YAML to the database — the form is a structured editor, not a separate representation.

---

## How to Extend This Module

**To add a new correlation rule**:
1. Navigate to /app/admin/rules in the UI and use the Create Rule form
2. Fill in the match block (signal kind, clause predicates, geography filters) using Annex C.4 grammar
3. Fill in the produce block (confidenceBase, matchReasonTemplate, alert settings)
4. Add at least one positive and one negative fixture via the fixture tab
5. Use the Test Against Fixture panel to verify before enabling

**To add a new DSL predicate to the rule engine**:
1. Add the predicate handler to the rule evaluator service (`src/services/rule-evaluator.service.ts`) following the existing predicate pattern
2. Add the predicate to the Zod grammar schema (`src/services/dsl-parser.service.ts`)
3. Add the predicate to the friendly form field configuration if it has form UI representation
4. Add unit tests in `tests/services/rule-evaluator.test.ts`
5. Add fixture coverage to at least one seed rule that exercises the new predicate

**To add a new field to a rule**:
1. Create a migration: ALTER TABLE correlation_rule ADD COLUMN
2. Update fn_rule_create and fn_rule_update to accept the new field
3. Update fn_rule_list and fn_rule_get_by_id JSONB output
4. Update TypeScript types in `src/types/rule.types.ts`
5. Update the admin form and i18n keys
6. Run /state-update to refresh the artifact store

**To add a dismissal workflow step** (e.g. two-step approval before dismissal):
1. This is a significant workflow change — create a new CR
2. The dismissal flow currently goes directly through fn_correlation_dismiss (single-step, single actor)
3. A two-step flow would require an intermediate status and an approval workflow integration

---

## Test Coverage

| Acceptance Criterion | Test file | Status |
|---|---|---|
| fn_rule_create + fn_rule_get_by_id roundtrip | tests/db/CR-E-fns.test.ts | PASS |
| fn_rule_update recomputes versionHash on YAML change | tests/db/CR-E-fns.test.ts | PASS |
| fn_rule_delete soft-delete + double-delete guard | tests/db/CR-E-fns.test.ts | PASS |
| fn_rule_list pagination + filters | tests/db/CR-E-fns.test.ts | PASS |
| fn_rule_evaluate fires correct correlations (7 seed rules) | tests/db/CR-E-fns.test.ts | PASS |
| fn_rule_test_against_fixture positive + negative | tests/db/CR-E-fns.test.ts | PASS |
| fn_correlation_dismiss + double-dismiss guard | tests/db/CR-E-fns.test.ts | PASS |
| fn_correlation_list pagination + status filter | tests/db/CR-E-fns.test.ts | PASS |
| PG NOTIFY correlation_rule_changed on update | tests/db/CR-E-fns.test.ts | PASS |
| Hot-reload latency < 5 seconds | tests/integration/rule-hot-reload.test.ts | PASS |
| FE admin rules list + create + edit + delete | tests/e2e/admin-rules.spec.ts | INFRA-1 WARN |
| FE correlations list + dismiss flow | tests/e2e/correlations.spec.ts | INFRA-1 WARN |
| FE test-against-fixture panel | tests/e2e/admin-rules.spec.ts | INFRA-1 WARN |

**Notes**: E2E failures are the pre-existing INFRA-1 Zustand-persist + TanStack Router auth race (same root cause as M11 and M12). All 11 CR-E ACs are covered at the DB and integration layers.

---

## Files Owned by This Module

**Backend**:
- `src/routes/v1/rule.routes.ts`
- `src/routes/v1/correlation.routes.ts`
- `src/controllers/rule.controller.ts`
- `src/controllers/correlation.controller.ts`
- `src/services/rule-evaluator.service.ts` (DSL predicate engine + evaluation loop)
- `src/services/dsl-parser.service.ts` (Annex C YAML grammar parser + validator)
- `src/workers/rule-evaluation.worker.ts` (osint_signal_inserted PG NOTIFY subscriber)
- `src/types/rule.types.ts`
- `src/types/correlation.types.ts`

**Frontend**:
- `src/routes/app/admin/rules/page.tsx` (rules list)
- `src/routes/app/admin/rules/$id/page.tsx` (rule detail + fixture panel + edit form)
- `src/routes/app/correlations/page.tsx` (correlations list + dismiss modal)
- `src/features/rules/` (components and hooks)
- `src/features/correlations/` (components and hooks)
- `src/services/rule.service.ts`
- `src/services/correlation.service.ts`

**Database**:
- `database/migrations/150_cre_create_correlation_rule.sql`
- `database/migrations/151_cre_create_correlation.sql`
- `database/migrations/152_cre_create_correlation_rule_fixture_and_eval_error.sql`
- `database/migrations/153_cre_rule_functions.sql`
- `database/migrations/154_cre_permissions_grants_seed.sql`
- `database/migrations/155_cre_seed_rules_and_fixtures.sql`
- `database/migrations/156_cre_system_setting_seed.sql`
- `database/migrations/157_crd_cre_extend_audit_redact_list.sql` (cross-cutting with M12)
- `database/migrations/158_crd_cre_pg_notify_channels.sql` (cross-cutting with M12)

---

## Cross-Module Note

M13 reads M12 data (contract_clause_extracted) via the has_clause and clause_parameter predicates. If you modify the parameters JSONB structure in contract_clause_extracted, verify that existing rule YAML predicates still resolve correctly. Run `npx vitest run tests/db/CR-E-fns.test.ts` after any M12 schema change. The GIN index on contract_clause_extracted.parameters (idx_contract_clause_extracted_parameters_gin) is critical for rule evaluation performance — do not drop it.
