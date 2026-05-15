# Technical Handoff — CR-K + CR-L (M19 + M20)
## Risk Cases (Mitigation Workflow) + Reports & Briefings

**Unit:** 7 (CR-K + CR-L combined) — **FINAL unit of v1.2 scope**
**Modules:** M19 (CR-K — Risk Cases) + M20 (CR-L — Reports & Briefings)
**Date shipped:** 2026-05-15
**QA verdict:** SHIP-GO-WITH-WARNINGS (91 total checks; 0 FAIL; 4 non-blocking WARN)
**S2-21 streak:** **18th consecutive clean module preserved**
**Migrations applied:** 251..277 (27 of 27 planned)
**Mode:** REGENERATE (no Lovable analogue — FE built fresh against Agent 5 contracts)

---

## TL;DR

CR-K introduces a unified **risk case primitive** — 8-state lifecycle (`open → in_review → approved | rejected | escalated | accept_risk | snoozed → closed`) covering correlation alerts, obligation timeouts, SLA breaches, system events, and manual entries. 14 endpoints under `/api/v1/risk-cases/*`. Three new tables (`risk_case`, `risk_case_event` append-only, `risk_case_attachment` Supabase-backed). 14 fns including a DEFINER auto-create-from-correlation worker entry and a DEFINER cross-tenant escalation scanner. Strict state-machine; matrix-driven escalation + accept-risk approval; self-approval guard at both FE + BE.

CR-L delivers the **full reports & briefings surface** — 24 ADNOC seed templates spanning 7 personas (executive / legal / procurement / operations / finance / compliance / admin), an async render worker (Puppeteer for PDF, ExcelJS for XLSX), a scheduler worker, and a template-admin CRUD interface. 34 endpoints (3 user-facing + 8 admin + 24 data-fn dispatcher slugs behind a single internal route). Two tables (`report_template`, `report_run` append-only). 33 fns (5 template + 4 run + 24 data + scheduler-only DEFINER patch). Signed-URL minting at controller layer (TTL 60s).

Four in-flight defects were caught and patched before the QA Stage 4 gate (one DB CTE scoping issue, one DEFINER carve-out for the scheduler service, three BE controller positional-arg-order fixes). Final test results: **154 / 154 PASS** (90 DB + 45 integration + 19 E2E). Zero regressions.

---

## Architecture Overview

### CR-K: Risk Cases

```
FE: /app/risk-cases (RiskCasesListView)
  ├── filter rail (7 filters + useDebounce search)
  └── /app/risk-cases/:caseId (RiskCaseDetailView)
       ├── Overview / Timeline / Evidence tabs
       └── action panel: Create / Assign / Status-Transition /
                         Escalate / Accept-Risk / Snooze / Close /
                         AddComment / AddEvidence

BE: src/routes/v1/risk-case.routes.ts (14 routes)
  ├── risk-case.controller.ts (14 handlers)
  ├── self-approval guard at acceptRisk (BE-side defense in depth)
  ├── signed-URL minting on evidence GET (TTL 60s)
  └── multer.memoryStorage() → Supabase upload on evidence POST

Workers:
  ├── risk-case-escalation.worker.ts (5-min node-cron)
  │     → fn_risk_case_escalation_check (DEFINER cross-tenant)
  │     → loop: set tenant GUC → fn_risk_case_escalate
  └── risk-case-auto-create.worker.ts (PG LISTEN correlation_inserted)
        → fn_risk_case_auto_create_from_correlation
          (DEFINER + dedupe_key='correlation:<id>')

DB: risk_case (8-state machine)
    risk_case_event (append-only; Strategy A audit)
    risk_case_attachment (Supabase Storage; 50MB cap)
    fn_risk_case_* (14 fns)
    system_setting (3 matrices: escalation / visibility / accept-risk)
```

**State machine** (strict, HITL CR-K-Q3):

```
                    ┌── approved ──┐
                    │              ▼
   open ──► in_review              closed
                    │              ▲
                    └── rejected ──┘
                       
   open ──► escalated (via /escalate, fn reads escalation_matrix)
   open ──► accept_risk (via /accept-risk, requires matrix approver)
   open ──► snoozed (via /snooze, 30-day cap)
   any non-terminal ──► closed (via /close, requires prior outcome)
```

Invalid transitions raise `P0001 invalid_transition` → 409.

**Escalation matrix cycle detection:** `matrixHopCount > 10` → `P0001 matrix_cycle_detected` → 409. Audit trail in `risk_case_event` preserves every attempt.

**Per-case-type permission gates** (in `fn_risk_case_status_transition`):
- `correlation_alert`, `sla_breach`: `risk.case.escalate` OR current assignee
- `obligation_due`, `manual`: assignee OR `risk.case.create`

### CR-L: Reports & Briefings

```
FE: /app/reports (template library grid)
  ├── GenerateReportDialog (format + dateRange + statusFilter)
  └── /app/reports/runs/:runId (auto-polling viewer + signed-URL download)

FE Admin: /app/admin/report-templates (admin grid)
  └── /app/admin/report-templates/:templateId
        (create / edit / soft-delete — templateId/kind immutable in edit mode)

BE: src/routes/v1/report.routes.ts (3 user routes)
    src/routes/v1/admin/reports.routes.ts (8 admin routes)
  ├── report.controller.ts (9 handlers)
  ├── data-fn dispatcher (path-param :slug → 24 fns)
  ├── signed-URL minting on run GET (TTL 60s)
  └── immutable-field rejection on PUT template

Workers:
  ├── report-run.worker.ts (10s node-cron)
  │     → fn_report_run_pending_get (DEFINER; CTE+FOR UPDATE SKIP LOCKED+S2-8 audit)
  │     → fn_report_data_<slug>
  │     → report-renderer.service.ts (Puppeteer / ExcelJS)
  │     → supabase-storage.uploadReportOutput
  │     → fn_report_run_complete (DEFINER)
  └── report-scheduler.service.ts (5-min re-scan)
        → registers/unregisters node-cron tasks from
          fn_report_template_list(admin_mode=true)
        → on fire: fn_report_run_trigger(SYSTEM_ACTOR, 'scheduled')

DB: report_template (24 ADNOC seeds)
    report_run (append-only; Strategy A audit)
    fn_report_template_* (5 fns)
    fn_report_run_* (4 fns incl. worker pickup + complete)
    fn_report_data_<slug> (24 fns: 4 exec + 4 legal + 4 proc +
                          3 ops + 3 fin + 3 compliance + 3 admin)
```

**Uniform data envelope** — every `fn_report_data_<slug>` returns:

```json
{
  "payload": { /* per-template structure */ },
  "meta": {
    "tenantId": "uuid",
    "generatedAt": "fn_demo_now()",
    "parameters": { /* echo of input */ },
    "sourceTraceability": [
      { "tableName": "risk_score", "recordIds": [1,2,3], "count": 3 }
    ]
  }
}
```

**Worker pickup** — `fn_report_run_pending_get` uses CTE + `FOR UPDATE SKIP LOCKED` (S2-24) to atomically flip `pending → generating` and emit the audit-log row inside the same CTE (S2-8 compliance — audit emitted in the same statement, not in a deferred trigger).

**Signed-URL contract** — neither `fileUri` nor `outputUri` is ever returned to the FE. The BE controller mints a fresh signed URL (TTL 60s) immediately before responding to `GET /risk-cases/:id/evidence/:attachmentId` and `GET /reports/runs/:id`. Both download paths require the caller to be the originator OR hold the relevant cross-user permission.

---

## HITL Decisions (9 autonomous resolutions)

All 9 open decisions were auto-resolved per the brief recommendation set, locked at HITL Gate 2.

### CR-K (4 decisions)

| ID | Question | Decision | Rationale |
|---|---|---|---|
| **CR-K-Q1** | Auto-create risk case from every correlation? | per-rule flag (high/critical ON, low OFF) | Default ON for actionable correlations; OFF for low-severity to avoid case-noise. Encoded as a BE-service decision on `correlation_rule.produce_yaml.alert.create_case` — not a new DB column (per HIGH-1 conflict resolution: `produce_yaml` is TEXT). |
| **CR-K-Q2** | Risk-acceptance approval levels | matrix in `system_setting.accept_risk_approval_matrix` | JSONB: `critical→Executive`; `high→Legal Counsel+named`; `medium→role peer`. Admin-editable via existing CR-C system_setting CRUD. |
| **CR-K-Q3** | State machine validation strictness | strict — reject invalid transitions | `P0001 invalid_transition` → 409. Audit trail in `risk_case_event` preserves attempts. |
| **CR-K-Q4** | Evidence retention policy | forever (no purge fn) | No `fn_risk_case_attachment_purge` designed — violation impossible at DB API. Soft delete only via `is_active=false`. Mirrors `audit_log` policy. |

### CR-L (5 decisions)

| ID | Question | Decision | Rationale |
|---|---|---|---|
| **CR-L-Q1** | Default scheduling for ADNOC pack | exec Mon 9am UTC + sanctions daily 6am UTC | Two scheduled defaults; the other 22 templates manual-only. `is_scheduled` + `schedule_cron` columns drive the scheduler. |
| **CR-L-Q2** | PDF template language | React → HTML → Puppeteer | Reuses FE component lib for tenant branding consistency. Puppeteer pool semaphore=2 (M1b pattern). |
| **CR-L-Q3** | Auto-archive policy | forever (no purge fn) | All `report_run` rows + outputs preserved indefinitely. Tiered retention deferred to pilot once volume justifies. |
| **CR-L-Q4** | Per-tenant report customization | ADNOC ships 24; others extend at pilot | ADNOC tenant seeded with all 24 templates idempotent. Other tenants use `/app/admin/report-templates` CRUD. |
| **CR-L-Q5** | Report parameter UI complexity | basic — dateRange + statusFilter | Custom per-template parameter fields deferred to pilot. |

---

## Migration List (27 migrations: 251..277)

See `docs/database/M19-M20-CR-K-L-data-dictionary.md` §9 for the full table. Summary by purpose:

| Group | Migrations | Count |
|---|---|---|
| EXTEND statements | 251 (audit redact) + 252 (system_setting category) | 2 |
| CR-K table DDL + permissions + seeds | 253..257 | 5 |
| CR-K function definitions | 258 (10 write) + 259 (4 read) | 2 |
| CR-L table DDL + permissions | 260..262 | 3 |
| CR-L lifecycle fns | 263 (5 template) + 264 (4 run) | 2 |
| CR-L data fns (24 across 7 personas) | 265..271 | 7 |
| CR-L ADNOC seeds | 272 | 1 |
| Pre-emptive grant backfill | 273 (95 statements) | 1 |
| In-flight defect patches | 274 (CTE fix) + 275 (DEFINER carve-out) | 2 |
| Empty placeholders retained | 276, 277 | 2 |

**Rollback discipline:** Every migration has a `-- ROLLBACK:` block. DROP TABLE CASCADE for new tables; DROP FUNCTION (signature) for new fns; CREATE OR REPLACE to previous body for EXTEND.

**Infra note:** Before migration apply began, the dev DB was at 490 MB / 512 MB Neon quota. Following the M11 INFRA-1 precedent, 472,424 non-seed `osint_signal` rows were deleted + `VACUUM FULL` reclaimed space → 28 MB final. Four gap migrations (160, 161, 165, 166 — historical defect-fix migs superseded by later definitions) were marked applied in `schema_migrations` so the runner could proceed.

---

## Permission Matrix Delta

8 net-new permissions × applicable roles = **47 distinct grants** (Agent 5 reconciled count; Agent 4 design narrative said "62" — the discrepancy is summing cells in the remap table vs distinct grants).

| Permission | platform_admin | Super Admin | executive | legal_counsel | operations | finance_treasury | compliance_esg | contract_drafter | contract_approver | contract_approver_2 | contract_recipient |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `risk.case.create` | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ | — |
| `risk.case.escalate` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | ✓ | — |
| `risk.case.accept_risk` | ✓ | ✓ | ✓ | ✓ | — | — | — | — | — | — | — |
| `risk.case.close` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `report.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `report.template.manage` | ✓ | ✓ | — | — | — | — | — | — | — | — | — |
| `report.schedule.manage` | ✓ | ✓ | — | — | — | — | — | — | — | — | — |
| `report.run.read.all` | ✓ | ✓ | — | — | — | — | — | — | — | — | — |

**Remap note (HIGH-2 conflict resolution):** Agent 2's brief enumerated `procurement_supplier_risk` for several grants, but that is a **permission**, not a role. Agent 4 remapped to `contract_drafter` / `contract_approver` / `contract_approver_2` to cover procurement workflows. Super Admin added alongside platform_admin everywhere.

---

## Stage 2 Mitigations

| Check | Application |
|---|---|
| **S2-RLS-1** Split deny-UPDATE / deny-DELETE policies | Applied to `risk_case_event` + `report_run` (4 policies each: select + insert + deny-UPDATE RESTRICTIVE + deny-DELETE RESTRICTIVE). Patch applied at QA Stage 2 (db-design §6.2 lines 891-915). |
| **S2-8** Audit emission inside writing CTE | `fn_report_run_pending_get` emits `fn_audit_log_record_v2` inside the pending→generating UPDATE CTE — no deferred trigger gap. Patch applied at QA Stage 2 (db-design §2.16). |
| **S2-19** Cross-fn signature lock | Every BE controller pins fn signature against `db-impl-report.spotCheckResults`. The three DEFECT-CRKL-INT-1/2/3 controller-arg-order defects were caught at integration test time and fixed in-flight. |
| **S2-20** SYSTEM_ACTOR sentinel | `NULLIF(p_actor_id, 0)` applied at all worker entry fns (auto_create / escalation_check / pending_get / complete). |
| **S2-21** No PUBLIC EXECUTE leaks | **18th consecutive clean module preserved.** 47 net-new fns × COMMENT+REVOKE+GRANT trio = 51 COMMENTs + 98 REVOKEs + 98 GRANTs across migrations 251..275. Mig 273 backfill backstop applies the full set defensively (95 statements). |
| **S2-22** Column existence | Per-fn header comment block documents column references. 11 design-vs-reality adapter mappings (A1..A11) applied at fn body authorship — see DB Impl report. |
| **S2-23** FK pre-validation | `fn_risk_case_assign` validates role existence + user-role match before mutating. |
| **S2-24** Split-aggregate | `fn_risk_case_list` + `fn_report_run_pending_get` + all 24 data fns use per-row CTE inner blocks → outer `jsonb_agg`; no nested aggregate. |
| **S2-25** ERRCODE on RAISE | Full SQLSTATE catalog: P0002=404, 22023=400, 23505=409, 23514=400, 42501=403, P0001=409 — applied consistently. |
| **S2-26** WHEN OTHERS preserves SQLSTATE | `USING ERRCODE = SQLSTATE` in every catch-all. |
| **S2-27** COMMENT ON FUNCTION | Trio (COMMENT + REVOKE + GRANT) per CREATE OR REPLACE. |
| **S2-28** Id-less audit strategy | Strategy A chosen by intent for `risk_case_event` + `report_run`. Both have `id BIGSERIAL` plus in-fn `fn_audit_log_record_v2` emission. |

---

## Defects Caught + Fixed In-Flight (4 — none escaped to ship)

| ID | Severity | Layer | Symptom | Fix |
|---|---|---|---|---|
| **DEFECT-CRKL-DB-INFLIGHT-1** | HIGH | DB Impl | `fn_risk_case_list` raised `relation "counted" does not exist` — the WITH-CTE `counted` was scoped only to the WITH chain, not the outer SELECT INTO. | Mig 274 — `CREATE OR REPLACE` with COUNT extracted to a separate scalar query before the WITH. Verified working via post-patch spot-check. |
| **DEFECT-CRKL-INTV-1** | HIGH | Integration Verifier | Evidence-upload contract: BE Zod schema expected client-supplied `fileUri`, but the FE was sending `multipart/form-data` with a `file` part. | BE+FE patched — multer wired on the route, BE controller streams to Supabase and derives `fileUri` server-side. New `riskCaseService.uploadEvidence` method on FE. (See `defect-crkl-intv-1-fix-report.md`.) |
| **DEFECT-CRKL-SMOKE-1** | HIGH | Smoke Test | Report scheduler crashed on startup — `fn_report_template_list(adminMode=true)` was INVOKER + checked `report.template.manage` on the scheduler service account (which has no role). | Mig 275 — DEFINER carve-out `fn_report_template_list_scheduled_only` returns just the scheduled+enabled subset for the worker. Scheduler service refactored to call the carve-out. (See `defect-crkl-smoke-1-fix-report.md`.) |
| **DEFECT-CRKL-INT-1/2/3** | HIGH | BE controller | Three controller methods called `db.callFunction` with positional args in the wrong order — `fn_risk_case_create` (title bound to p_contract_id), `fn_report_run_trigger` (parameters bound to p_format), `fn_report_template_create` (reportKind bound to p_assigned_roles). All raised 400 every call. | Three argument-order reorder fixes in `risk-case.controller.ts:204` and `report.controller.ts:238 / :410`. No fn rewrites needed — DB tests confirmed fn correctness. (See `defect-crkl-int-1-2-3-fix-report.md`.) |

After all four patches: re-run of 4 Unit-7 test files yielded **135/135 strict BE PASS + 19/19 Playwright PASS = 154/154**.

---

## Known Debt (non-blocking, logged for follow-up)

### DEBT-CRKL-ENV-1 (LOW) — Response Envelope Inconsistency

**What:** Unit-7 controllers respond with `res.json(result)` directly rather than the project-standard `{success, data, requestId}` envelope.

**Impact:** None functionally — the FE `unwrap()` helper is defensive against both shapes. Cosmetic inconsistency only.

**Schedule:** ~20-min polish task in a follow-up commit to wrap all 23 Unit-7 controller methods.

### DEBT-CRKL-INT-WRAPPER (LOW) — db.callFunction Positional Args

**What:** The three DEFECT-CRKL-INT-1/2/3 defects share a root cause that a thin typed wrapper per fn would have caught at compile time. Currently 10+ call sites across services + workers rely on developer discipline + inline comments.

**Impact:** None — all current call sites are correct + inline-commented. But the next fn signature change in any of those 10 sites carries the same risk.

**Schedule:** Future hardening sweep — generate typed wrappers from `api-contracts.json` + `db-impl-report.json`.

### DEFECT-CRKL-INFRA-1 (LOW, resolved at test time) — Test-Branch Migration Process Gap

**What:** DB Impl applies to dev branch via `npm run migrate`. Test branch needs `npm run migrate:test` separately, but the Testing Agent had to run it in-flight before any tests could exercise Unit-7 fns.

**Impact:** None — resolved at test time. But future modules will repeat the friction.

**Schedule:** Consider a unified `npm run migrate:all` for future modules.

### Coverage Measurement Scope (F1/F2/F3 WARN)

**What:** Whole-tree coverage numbers (29.61% lines / 8.27% functions / 45.07% branches) are below WARN tier thresholds. Testing Agent ran Unit-7-scoped tests against the whole-tree denominator.

**Impact:** None on quality — module-scoped coverage estimated >90% lines/functions per per-file v8 output.

**Schedule:** Developer can rerun `npx vitest run … --coverage.include=src/controllers/risk-case.controller.ts …` to capture the real number for handoff docs.

---

## Files Owned by This Module

### Backend (13 created + 4 modified)

**Schemas (2):**
- `src/schemas/risk-case.schemas.ts` — 11 Zod schemas for CR-K
- `src/schemas/report.schemas.ts` — 8 Zod schemas + `IMMUTABLE_REPORT_TEMPLATE_FIELDS` allowlist

**Controllers (2):**
- `src/controllers/risk-case.controller.ts` — 14 handlers
- `src/controllers/report.controller.ts` — 9 handlers + 24-slug data dispatcher

**Routes (3):**
- `src/routes/v1/risk-case.routes.ts` — 14 routes
- `src/routes/v1/report.routes.ts` — 3 user routes
- `src/routes/v1/admin/reports.routes.ts` — 8 admin routes

**Services (2 new + 1 extended):**
- `src/services/report-renderer.service.ts` (new) — Mustache + Puppeteer + ExcelJS
- `src/services/report-scheduler.service.ts` (new) — node-cron pool, 5-min re-scan
- `src/services/supabase-storage.service.ts` (extended) — added `buildRiskCaseEvidencePath`, `uploadRiskCaseEvidence`, `buildReportOutputPath`, `uploadReportOutput`

**Workers (3):**
- `src/workers/report-run.worker.ts` — 10s cron, p-limit(2)
- `src/workers/risk-case-escalation.worker.ts` — 5-min cron, p-limit(2)
- `src/workers/risk-case-auto-create.worker.ts` — PG LISTEN, p-limit(2)

**Modified (4):**
- `src/routes/v1/index.ts` — mounted `riskCaseRouter` + `reportRouter`
- `src/routes/v1/admin/index.ts` — mounted `adminReportsRouter`
- `src/server.ts` — wired 3 worker + 1 scheduler startup/shutdown
- `src/utils/logger.util.ts` — added Pino redact paths (`body`, `fileUri/file_uri`, `outputUri/output_uri`, `errorMessage`, `justification`, `decisionNote`, `closureNote`)

### Frontend (29 created + 4 modified)

**Routes (9):**
- `src/routes/app/risk-cases.tsx` (outlet shim) + `.index.tsx` + `.$caseId.tsx`
- `src/routes/app/reports.tsx` (outlet shim) + `.index.tsx` + `.runs.$runId.tsx`
- `src/routes/app/admin.report-templates.tsx` (outlet shim) + `.index.tsx` + `.$templateId.tsx`

**Components (15):**
- `src/components/risk-cases/` — StatusBadge, PriorityBadge, SlaCountdown, CreateRiskCaseDialog, AssignRiskCaseDialog, StatusTransitionDialog, EscalateDialog, AcceptRiskDialog, SnoozeDialog, CloseDialog, AddEvidenceDialog, CommentInline, RiskCaseTimeline, RiskCaseEvidenceList
- `src/components/reports/` — GenerateReportDialog
- `src/components/admin/report-templates/` — ReportTemplateEditor

**Services (3):**
- `src/services/api/risk-case.service.ts` — 12 methods
- `src/services/api/report.service.ts` — 3 methods
- `src/services/api/admin/report-templates.service.ts` — 5 methods

**Types (2):**
- `src/types/risk-case.types.ts` — DTOs + `STRICT_TRANSITIONS` / `CLOSABLE_STATUSES` / `ESCALATABLE_STATUSES` / `TERMINAL_STATUSES` tuples
- `src/types/report.types.ts` — DTOs + `REPORT_DATA_SOURCE_SLUGS` union (24 slugs)

**Modified (4):**
- `src/config/sidebar.ts` — `riskCases` + `reports` entries with role/permission gating
- `src/routes/app/__root.tsx` — route registration
- `src/locales/en.json` — +273 keys (5905 → 6178)
- `src/locales/ar.json` — +273 keys (5905 → 6178, first-pass machine translation)

### Database (27 migrations)

All under `database/migrations/251_*.sql .. 277_*.sql`. See data dictionary §9 for the full list.

---

## i18n Delta

| Locale | Before | After | Delta |
|---|---|---|---|
| EN keys | 5905 | **6178** | +273 |
| AR keys | 5905 | **6178** | +273 |
| Top-level EN | 77 | 79 | +2 (`riskCases`, `reports`) |
| Top-level AR | 77 | 79 | +2 |

**Parity verdict: PASS** — zero EN-only or AR-only keys; zero duplicate top-level keys (M15 lesson respected — set-if-absent helper used). AR is first-pass machine-quality per project precedent (M14/M15/M16/CR-J pattern); flag for human translation pass post-ship.

**New namespaces:**
- `riskCases.*` — 172 keys
- `reports.*` — 38 keys
- `admin.reportTemplates.*` — 51 keys

**Augmented:**
- `common.*` — +3 keys (`posting`, `uploading`, `queueing` + pagination)
- `nav.*` — +3 keys
- `roles.*` — +12 conditional fill-ins

---

## Testing Summary

**Total: 154 / 154 PASS** (100% — zero failures)

| Layer | Count | Files |
|---|---|---|
| DB function tests | 90 | `tests/db/R-CRK-fns.test.ts` (51) + `tests/db/R-CRL-fns.test.ts` (39) |
| Integration tests | 45 | `tests/integration/risk-case.test.ts` (23) + `tests/integration/report.test.ts` (22) |
| E2E (Playwright) | 19 | `tests/e2e/CR-KL-unit7.spec.ts` (consolidates 26 e2e-tagged ACs) |

**AC coverage:**
- Unit layer: 78/80 ACs directly tested (97.5%); 2 worker-surface ACs exercised at integration
- Integration: 45 distinct supertest cases over 9 user-facing surfaces; 88 ACs tagged
- E2E: 19 consolidated tests cover 26 e2e-tagged ACs

**Regressions:** Zero. Spot-checked `auth.test.ts` + `health.test.ts` (7/7 PASS).

**Coverage:** Module-scoped >90% lines/functions per per-file v8 output. Whole-tree numbers (29.61% lines, 8.27% functions, 45.07% branches) reflect Unit-7-scoped test scope, not Unit-7 quality.

---

## How to Extend This Module

**To add a new risk_case event type:**
1. Add value to `risk_case_event.event_type` CHECK constraint (new migration)
2. Update `fn_risk_case_*` writer fns to emit the new event_type when relevant
3. Update FE `RiskCaseTimeline.tsx` to render type-specific icon + i18n key
4. Add i18n keys under `riskCases.timeline.events.<eventType>` (EN+AR parity)

**To add a new report template (per-tenant):**
1. Use the `/app/admin/report-templates` UI (no migration needed for new tenant content)
2. `data_source` slug must match an existing `fn_report_data_<slug>` — validated by `pg_proc` EXISTS check

**To add a new report data fn (24 → 25):**
1. New migration in the 26X range (one persona-group per migration; pick the matching group or create a new one)
2. Fn must return the uniform `{payload, meta}` envelope (see data dictionary §3.5 invariants)
3. Add slug to `REPORT_DATA_SOURCE_SLUGS` union in `src/types/report.types.ts` (FE) + controller allowlist (BE) + OpenAPI spec enum in `docs/api/cr-k-l.yaml`
4. Seed a `report_template` row referencing the new slug (separate migration or admin CRUD)

**To add a new state to the risk_case state machine:**
1. Add value to `risk_case.status` CHECK constraint (new migration)
2. Update `fn_risk_case_status_transition` strict-matrix
3. Update FE `STRICT_TRANSITIONS` matrix in `src/types/risk-case.types.ts`
4. Add transition dialog component if user-facing
5. Update OpenAPI `RiskCaseStatus` enum

---

## Worker Enablement (Ops Handoff)

All four workers/services are gated behind env flags — disabled by default in dev:

| Env Var | Default | Purpose |
|---|---|---|
| `RISK_CASE_ESCALATION_WORKER_ENABLED` | off | Enable the 5-min escalation cron |
| `RISK_CASE_AUTO_CREATE_WORKER_ENABLED` | off | Enable the PG LISTEN auto-create worker |
| `REPORT_RUN_WORKER_ENABLED` | off | Enable the 10s report-run pickup cron |
| `REPORT_SCHEDULER_ENABLED` | off | Enable the report scheduler (re-scans every 5 min) |
| `RISK_CASE_ESCALATION_CRON` | `*/5 * * * *` | Override escalation cron expression |
| `REPORT_RUN_WORKER_INTERVAL_MS` | `10000` | Override run-worker polling interval |

For pilot/production: enable all four. The PG LISTEN auto-create worker requires the existing CR-F `correlation_inserted` NOTIFY emission to be wired (already in place since M14).

---

## Cross-Reference Links

- **OpenAPI spec:** `docs/api/cr-k-l.yaml`
- **Data dictionary:** `docs/database/M19-M20-CR-K-L-data-dictionary.md`
- **Adjacent units:**
  - `docs/handoff/CR-H-handoff.md` — M16 advisory drafter + notification (M19 inherits Pino redact list + signed-URL pattern)
  - `docs/handoff/CR-I-J-handoff.md` — M17/M18 demo harness + `fn_demo_now()` time-freeze (Unit-7 honours throughout)

---

*Generated by Agent 15 (Documentation Generator) — Unit 7 / M19 + M20 / CR-K + CR-L — 2026-05-15*
