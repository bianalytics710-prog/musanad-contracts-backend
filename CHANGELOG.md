# Changelog — musanad-contracts-backend

Per-unit / per-module delivery log. Each entry summarises scope, surface area, defects caught in-flight, and key follow-ups. Full handoff docs live under `docs/handoff/` and `docs/modules/`.

For prior modules (M0..M15 + persona rounds + M16/M17/M18) the canonical narrative lives in:
- `docs/handoff/CR-H-handoff.md` (M16 / Unit 5)
- `docs/handoff/CR-I-J-handoff.md` (M17 + M18 / Unit 6)
- `docs/modules/M11-CR-D0.md`, `docs/modules/M14-CR-F.md`, `docs/modules/M15-CR-G.md`, `docs/modules/M10-CR-C.md`

---

## Unit 7 — M19 + M20 / CR-K + CR-L — Risk Cases + Reports & Briefings — 2026-05-15

**FINAL unit of v1.2 scope.**

### Scope

CR-K (Risk Cases — Mitigation Workflow): unified risk-case primitive — alert + workflow task + evidence + escalation lifecycle. 8-state machine (open / in_review / approved / rejected / escalated / accept_risk / snoozed / closed). 14 endpoints. Matrix-driven escalation + accept-risk; self-approval guard at FE + BE.

CR-L (Reports & Briefings): full reports library + asynchronous render worker (Puppeteer for PDF, ExcelJS for XLSX) + scheduler service + 24 ADNOC seed templates across 7 personas. 34 endpoints (3 user + 8 admin + 24 data-fn slugs behind a single dispatcher).

### Surface area

| Layer | Count |
|---|---|
| Migrations | 27 (251..277) |
| New tables | 5 (`risk_case`, `risk_case_event`, `risk_case_attachment`, `report_template`, `report_run`) |
| New fns | 47 (14 CR-K + 9 CR-L lifecycle + 24 CR-L data) |
| EXTEND fns | 2 (`fn_audit_trigger` redact, `system_setting.category` CHECK) |
| New permissions | 8 (4 CR-K + 4 CR-L); 47 distinct role-permission grants |
| BE endpoints | 48 |
| BE workers | 3 (escalation cron, auto-create LISTEN, report-run cron) + 1 service (report scheduler) |
| FE routes | 9 |
| FE components | 15 |
| FE services | 3 |
| FE types | 2 |
| i18n keys | +273 each locale (5905 → 6178 EN/AR parity) |

### Tests

154 / 154 PASS (90 DB + 45 integration + 19 Playwright E2E). Zero regressions. Module-scoped coverage >90% lines/functions.

### QA gates

- Stage 1: 6/6 PASS
- Stage 2: 19/19 PASS (4 patches applied: S2-RLS-1, S2-NUM-1, S2-NAME-1, S2-8)
- Stage 3: 14/14 PASS-WITH-WARNINGS (3 WARN, 0 FAIL)
- Stage 4: 52/52 PASS-WITH-WARNINGS (4 WARN, 0 FAIL, 0 BLOCKER)

**Verdict:** SHIP-GO-WITH-WARNINGS.

### Streak

**S2-21 18th consecutive clean module preserved** (47/47 net-new fns, 0 PUBLIC EXECUTE leaks).

### HITL decisions locked (9)

- CR-K-Q1: auto-create per-rule flag (high/critical ON, low OFF)
- CR-K-Q2: accept-risk approval via `system_setting.accept_risk_approval_matrix`
- CR-K-Q3: strict state machine (P0001 on invalid transition → 409)
- CR-K-Q4: evidence retention forever (soft delete only)
- CR-L-Q1: exec Mon 9am UTC + sanctions daily 6am UTC; rest manual
- CR-L-Q2: React → HTML → Puppeteer for PDF
- CR-L-Q3: report_run + outputs retained forever
- CR-L-Q4: ADNOC ships 24 templates; other tenants extend at pilot
- CR-L-Q5: basic parameter UI (dateRange + statusFilter)

See `docs/handoff/CR-K-L-handoff.md` § "HITL Decisions" for the full Q&A table.

### Defects caught + fixed in-flight (4)

| ID | Layer | Fix |
|---|---|---|
| DEFECT-CRKL-DB-INFLIGHT-1 | DB Impl | Mig 274 — `fn_risk_case_list` COUNT-CTE scoping fix |
| DEFECT-CRKL-INTV-1 | Integration Verifier | multer wiring on evidence upload + server-side fileUri derivation |
| DEFECT-CRKL-SMOKE-1 | Smoke Test | Mig 275 — DEFINER carve-out `fn_report_template_list_scheduled_only` for scheduler |
| DEFECT-CRKL-INT-1/2/3 | BE controller | 3 controller positional-arg-order fixes (no fn rewrites) |

### Known debt (non-blocking)

- DEBT-CRKL-ENV-1 (LOW) — Unit-7 controllers respond with raw JSON instead of `{success, data, requestId}` envelope; FE `unwrap()` is defensive. ~20-min polish task.
- DEBT-CRKL-INT-WRAPPER (LOW) — `db.callFunction` positional args; consider generating typed wrappers from `api-contracts.json` + `db-impl-report.json` in a future hardening sweep.
- DEFECT-CRKL-INFRA-1 (LOW, process-only) — test-branch migration step needs to be in DB Impl handoff for future units.

### Documentation

- Module handoff: `docs/handoff/CR-K-L-handoff.md`
- Data dictionary: `docs/database/M19-M20-CR-K-L-data-dictionary.md`
- OpenAPI spec: `docs/api/cr-k-l.yaml`
- Lovable handoff: `docs/M19-M20-lovable-handoff.md` (N/A — REGENERATE mode)

---

## Earlier deliveries

| Unit | Modules | CRs | Date | Reference |
|---|---|---|---|---|
| Unit 6 | M17 + M18 | CR-I + CR-J | 2026-05-14 | `docs/handoff/CR-I-J-handoff.md` |
| Unit 5 | M16 | CR-H | 2026-05-14 | `docs/handoff/CR-H-handoff.md` |
| Unit 4 | (procurement persona round R-PROC) | — | 2026-05-13 | `audit/procurement/GAP-REPORT-PROCUREMENT.md` |
| Unit 3 | (persona rounds R-OPS + R-FT + R-CES) | — | 2026-05-13 | `audit/{operations,finance-treasury,compliance-esg}/GAP-REPORT-*.md` |
| Unit 2B | M15 | CR-G | 2026-05-13 | `docs/modules/M15-CR-G.md` |
| Unit 2A | M14 | CR-F | 2026-05-13 | `docs/modules/M14-CR-F.md` |
| Unit 1 | M12 + M13 | CR-D + CR-E | 2026-05-12 | (see module handoffs in `docs/`) |
| — | M11 | CR-D0 | 2026-05-12 | `docs/modules/M11-CR-D0.md` |
| — | M10 | CR-C | 2026-05-10 | `docs/modules/M10-CR-C.md` |
| Pre-CRIP | M0..M9 + persona rounds | (M_parity, R-LC, R-DA, R-RC, R-EX, R-PA, R-PA7) | through 2026-05-09 | See `docs/` per-module handoffs |
