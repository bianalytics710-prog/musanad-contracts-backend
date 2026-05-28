# CR-M — Labor-Law Cascade + ADNOC-World Foundation — Changelog

**Module impact:** Extends M5 (regulatory / OSINT) + M16 (advisory drafter) + compliance_esg persona.
**Status:** Complete — shipped 2026-05-28
**Migrations:** 281..295 (14 files — 13 planned + 1 forward-fix 294 + 1 demo-data seed 295)
**Schema version:** 295 (both `m0-foundation` dev and `test` Neon branches)
**Pipeline mode:** Autonomous end-to-end (change-request scope)
**S2-21 streak:** 19th consecutive clean module

---

## What changed

CR-M demonstrates the **labor-law cascade**: a MOHRE Federal Decree-Law No.9/2024 regulatory signal
fans across ADNOC's contractor population (~40 seeded contractors), producing a per-contractor
remediation list that shows headcount-band Emiratisation exposure, affected employment clauses,
penalty-exposure AED range (AED 100k–1M statutory range), and ICV-certificate impact.
Legal Counsel can then draft amendment letters (via the existing CR-H advisory drafter) directly
from the cascade detail view. Compliance_esg runs the cascade and tracks remediation status;
legal_counsel generates the amendment drafts (separation of duties — DEBT-CRM-1 resolved).

The CR also lays the **ADNOC-world foundation**: 9 ADNOC group/subsidiary party rows,
~40 representative contractor parties with workforce attributes, party_relationship edges
(subsidiary + Offshore→Drilling contracting), and the MOHRE osint_source.

**Counts:**
- 3 new tables (`party_workforce`, `regulatory_cascade_run`, `regulatory_cascade_item`)
- 8 new fn_'s (`fn_party_workforce_set/get/list`, `fn_regulatory_cascade_run/list/get`,
  `fn_regulatory_cascade_item_set_status`, `fn_regulatory_cascade_item_link_draft`)
- 4 new permissions (`regulatory.cascade.read/run`, `party.workforce.read/manage`)
- 1 new role seeded (`procurement_supplier_risk` — closes DEFECT-CRH-DB-01)
- 1 new MOHRE osint_source + 1 Federal Decree-Law No.9/2024 osint_signal (via DEFINER upsert)
- 1 new advisory_template `labor_law_amendment_v1` (EN+AR Mustache, 5 placeholders)
- 9 ADNOC group/subsidiary party rows + ~40 contractor party + workforce rows
- 8 BE files created / 3 modified; 6 FE files created / 3 modified
- EN/AR i18n 6248→6254 (+76 keys: 70 cascade namespace + 6 column headers)

---

## Decisions locked during this CR

All decisions auto-approved (autonomous build per user instruction 2026-05-28).

- **CR-M-OD1:** Workforce attribute storage → **new `party_workforce` table** — `party` is single-tenant/shared by Stories 1-2; dedicated tenant-scoped FORCE-RLS table keeps party clean, allows future workforce history.
- **CR-M-OD2:** Cascade persistence → **persist `regulatory_cascade_run` + `regulatory_cascade_item`** — `impact_signal_contract` cannot hold per-contractor remediation state or advisory-draft links.
- **CR-M-OD3:** Penalty-exposure model → **min/max AED range + `penalty_basis` JSONB, config-driven via `system_setting`** — faithful to statutory AED 100k–1M; admin-tunable (Rule 8); demo-credible.
- **CR-M-Q1:** ICV model → **`icv_attachment_ids` via `contract_attachment.kind='icv_certificate'`** (keep AD-7 attachment model; first-class table deferred to pilot).
- **CR-M-Q2:** Employment-clause matching → **`clause_type_v2` in `{icv_in_country_value, strike_lockout, key_personnel}` + library fallback** — config-driven; existing taxonomy has no generic employment type.
- **CR-M-Q3:** `procurement_supplier_risk` role → **seed in migration 292** — needed by AC#7 read-gating and Stories 1/2; closes DEFECT-CRH-DB-01 (carried since CR-H).
- **CR-M-Q4:** `system_setting` category for penalty config → **add `regulatory` category** — DB Impl confirmed live constraint required it; low-risk additive change.
- **CR-M-Q5:** `advisory_template.draft_type` → **use `'custom'`** — avoid mid-CR DDL change to shared table; `'custom'` is already valid.
- **CR-M-Q6:** Remediation status write gate → **`regulatory.cascade.read`** — allows `legal_counsel` to mark items remediated after drafting; run-only gate would block natural remediation workflow.

---

## Files affected

### Backend — New (8)

- `src/types/regulatory-cascade.types.ts`
- `src/schemas/regulatory-cascade.schemas.ts`
- `src/adapters/mohre-labor.adapter.ts`
- `src/controllers/party-workforce.controller.ts`
- `src/controllers/regulatory-cascade.controller.ts`
- `src/services/regulatory-cascade-draft.service.ts`
- `src/routes/v1/party-workforce.routes.ts`
- `src/routes/v1/regulatory-cascade.routes.ts`

### Backend — Modified (3)

- `src/workers/source-fetch.worker.ts` — added `case 'mohre_labor'` to `buildAdapterForRow`
- `src/routes/v1/index.ts` — mounted workforce + cascade routers (literal-before-param ordering)
- `src/utils/logger.util.ts` — additive SENSITIVE_PATHS: `penaltyBasis` + `remediationNote` (camelCase + snake_case variants)

### Frontend — New (6)

- `src/types/entities/regulatory-cascade.types.ts`
- `src/services/api/regulatory-cascade.service.ts`
- `src/routes/app/compliance.regulatory-cascade.tsx` (parent outlet shim)
- `src/routes/app/compliance.regulatory-cascade.index.tsx` (list view)
- `src/routes/app/compliance.regulatory-cascade.$runId.tsx` (detail + remediation table)
- `src/features/compliance-esg/components/RegulatoryCascadeTile.tsx`

### Frontend — Modified (3)

- `src/features/dashboards/components/ComplianceEsgDashboard.tsx` — additive `RegulatoryCascadeTile`
- `src/config/sidebar.ts` — cascade route + `procurement_supplier_risk` AppRole + ROLE_MODULES entry
- `src/i18n/en.json` + `src/i18n/ar.json` — +76 keys (70 cascade + 6 columns)

### Database

| Migration | Purpose |
|---|---|
| 281 | Extend `fn_audit_trigger` redact list 58→60 (`penalty_basis`, `remediation_note`) |
| 282 | Create `party_workforce` — FORCE RLS, 3 policies, audit trigger, 7 indexes |
| 283 | Create `regulatory_cascade_run` (append-only header) — FORCE RLS, audit trigger |
| 284 | Create `regulatory_cascade_item` — FORCE RLS, 3 policies, audit trigger, 8 indexes |
| 285 | Seed ADNOC Group + 8 subsidiaries + 9 `party_relationship` edges |
| 286 | Seed ~40 contractor `party` rows + one `party_workforce` row each |
| 287 | Seed `system_setting` `regulatory.labor_cascade.penalty_bands` (AED 100k–1M range) |
| 288 | Seed `osint_source` `mohre_labor` + Federal Decree-Law No.9/2024 `osint_signal` (via DEFINER `fn_osint_signal_upsert`) |
| 289 | All 5 cascade fn_'s: `_run` (DEFINER), `_list/get` (STABLE), `_item_set_status`, `_item_link_draft` + tail trio each |
| 290 | 3 workforce fn_'s: `fn_party_workforce_set/get/list` + tail trio each |
| 291 | Seed `labor_law_amendment_v1` `advisory_template` (EN+AR Mustache, 5 contract placeholders, `assigned_approver_role='legal_counsel'`) |
| 292 | 4 new permissions + `procurement_supplier_risk` role + 18/19 `role_permission` grants |
| 293 | Defensive REVOKE/GRANT re-application on all 8 fn_'s (B14 belt-and-suspenders — 220 pattern) |
| 294 | DEFECT-289-1 forward-fix: penalty_max clamp formula corrected (`GREATEST(LEAST(...), floor)`) |
| 295 | Demo-data: 10 contractor contracts + 17 employment clauses + 5 ICV attachments (Defect-2 fix) |

---

## Tests

| Suite | Count | Result |
|---|---|---|
| `tests/db/CR-M-fns.test.ts` (unit) | **47 / 47** | PASS |
| `tests/integration/regulatory-cascade-routes.test.ts` | **34 / 34** | PASS (post-demo-fix; DEBT-CRM-1 resolved added 1 test) |
| Full BE suite | 29 fail / 2017+ pass | 0 new failures from CR-M |

**QA Stage 4:** SHIP-GO-WITH-WARNINGS — 48/48 applicable checks PASS, 0 FAIL, 3 non-blocking WARN.

---

## Defects caught and fixed

| ID | Severity | Description | Fix |
|---|---|---|---|
| DEFECT-286-1 | HIGH | `ON CONFLICT ON CONSTRAINT` doesn't apply to partial unique indexes | Rewrote migration 286 with `WHERE NOT EXISTS` pattern |
| DEFECT-289-1 | HIGH | `fn_regulatory_cascade_run` penalty_max formula could produce `max < min`, violating `reg_cascade_item_penalty_order` CHECK | Migration 294 forward-fix: `GREATEST(LEAST(perHead*gap, ceiling), floor)` |
| DEFECT-CRH-DB-01 | CARRY | `procurement_supplier_risk` role absent since CR-H | Seeded in migration 292 (closed) |
| DEFECT-CRM-ROUTES-1 | CRITICAL | `rlsMiddleware` missing from both new route files | Added to all 8 routes in both files |
| MISMATCH-1 | CRITICAL | FE service typed `ApiResponse<T>` double-unwrap vs BE bare JSONB convention | FE service retyped to bare domain types |
| MISMATCH-2 | HIGH | `GET /parties/workforce` shadowed by `partiesRouter.get('/:id')` (mount order) | Hoisted workforce routers before partiesRouter in `index.ts` |
| DEBT-CRM-1 | DESIGN | Draft-amendment gate included `regulatory.cascade.run` — `compliance_esg` could attempt draft (403 but dishonest UI) | Gate tightened to `advisory.draft.review` only (BE route + FE `canDraftAmend`) |
| Defect-1 (demo) | MEDIUM | 6 i18n column-header keys missing (`regulatory.cascade.columns.*`), rendered raw | Added 6 keys to EN + AR |
| Defect-2 (demo) | HIGH | No contracts seeded → all cascade items had empty `affectedContractIds` → Draft-amendment always disabled | Migration 295: 10 contracts + 17 clauses + 5 ICV attachments |

---

## Persona model

| Persona | Permissions | CR-M capabilities |
|---|---|---|
| `compliance_esg` | `regulatory.cascade.run` + `regulatory.cascade.read` + `party.workforce.read` | Run cascade, view remediation list, update remediation status, view ICV impact |
| `legal_counsel` | `regulatory.cascade.read` + `advisory.draft.review` | View cascade runs + items, draft amendment letters (labor_law_amendment_v1), update remediation status |
| `executive` | `regulatory.cascade.read` | View cascade dashboard tile + read-only list/detail |
| `procurement_supplier_risk` | `regulatory.cascade.read` + `party.workforce.read` | View cascade runs + workforce attributes (now seeded — DEFECT-CRH-DB-01 closed) |
| `platform_admin` / `Super Admin` | All 4 CR-M permissions | Full access + workforce manage |

---

## Git SHAs

See `delivery-report.md` in `project-artifacts/change-requests/CR-M-labor-cascade/` for commit SHAs.

---

*Agent 15 (Documentation Generator) — CR changelog mode. Appended 2026-05-28. No full module handoff regenerated.*
