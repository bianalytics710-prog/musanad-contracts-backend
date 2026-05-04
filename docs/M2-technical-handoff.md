# M2 — Approval Workflows — Technical Handoff

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M2 — Approval Workflows (fifth module; M0 + M1a + M1b + M1c shipped 2026-05-02 / 2026-05-02 / 2026-05-02 / 2026-05-03 respectively).
> **Generated:** 2026-05-04.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Status:** Complete. QA Stage 4 PASS-WITH-WARNINGS (84/84 effective PASS — 64 standard checks + 20 Codex-lesson checks; 3 acceptable WARN on coverage; 0 FAIL; 0 blockers). Codex adversarial review SKIPPED per developer decision; compensating Stage 2 + Stage 4 Codex-lesson scan covers L1–L20 with 20/20 PASS. 436/418 tests pass; 18 fail (1 M2 test-fixture flake + 17 pre-existing M1a/M1b/M1c expected-breaking failures from intentional AE-2 / ERRCODE materialization). Both Neon branches at `schema_migrations.version = 31`.

This is the practical handoff for the developer extending M2 or picking it up across sessions. For database object detail see [`database/M2-data-dictionary.md`](database/M2-data-dictionary.md). For the OpenAPI specification see [`api/openapi.yaml`](api/openapi.yaml). For the FE-side handoff see the frontend repo's `docs/M2-frontend.md`.

---

## 1. What this module builds

M2 introduces the approval engine. Drafters submit contracts into multi-step / parallel-group approval chains driven by an admin-configurable rules matrix; approvers act on individual steps (approve, reject, request resubmission); admins reassign stalled steps and monitor chains globally. The engine writes the contract.status state machine via a split function pair — `fn_contract_status_update_user` (drafter, INVOKER) for user-initiated transitions and a system-only `fn_contract_status_update_internal` (DEFINER, called only by `fn_approval_decide`) for terminal chain transitions. Escalation is automatic, driven by an in-process node-cron loop that calls `fn_approval_escalate`; there is no HTTP endpoint for escalation.

Two new namespaces are introduced: `/api/v1/approvals/*` (drafter / approver actions) and `/api/v1/admin/approval-*` (admin matrix + chain monitor + reassign). The `/admin/*` namespace is first introduced in M2.

---

## 2. Architecture

```
        [Frontend — TanStack Start + React 19]
                          │
                          │  apiClient → @/lib/api-client (axios; 401 refresh; X-Request-ID)
                          ▼
   ┌───────────────────────────────────────────────────────────────────────┐
   │  /approvals/*           /admin/approval-*       /contracts/:id/*       │
   │  S1 my-pending          S4 matrix list          S6 approval-chain/preview
   │  S2 decide              S5 matrix replace       S7 submit-for-approval
   │  S3 delegate            S8 reassign             S10 approval-chain (read)
   │                         S11 chains list          S12 status (PATCH)     │
   └──────────────────────────────────┬────────────────────────────────────┘
                                       │  thin Express controller → service → db.callFunction
                                       ▼
   ┌───────────────────────────────────────────────────────────────────────┐
   │  PostgreSQL (Neon, pg driver, RLS-enabled with FORCE ROW LEVEL SECURITY)
   │                                                                        │
   │  fn_approval_my_pending          fn_approval_decide      ──────────┐  │
   │  fn_approval_matrix_list         fn_approval_delegate              │  │
   │  fn_approval_route_init_preview  fn_approval_reassign              │  │
   │  fn_approval_chain_get / list    fn_approval_route_init            │  │
   │  fn_approval_matrix_set          fn_contract_status_update_user    │  │
   │                                  fn_contract_status_update_internal│  │
   │                                  ←── DEFINER, system-only ─────────┘  │
   │                                                                        │
   │  fn_approval_escalate (DEFINER, REVOKE FROM PUBLIC; node-cron only)    │
   └────────────────────────────────────┬───────────────────────────────────┘
                                         │  4 new tables  +  3 immutability triggers + 4 audit triggers
                                         ▼
                          approval_matrix / approval_chain / approval_step / approval_decision

        [BE process — node-cron driver]
        ┌────────────────────────────────────────────────────────────────┐
        │  approval-escalation.cron.service.ts                           │
        │   - registered at app.listen() callback                        │
        │   - APPROVAL_ESCALATION_INTERVAL_CRON env var (default */15)   │
        │   - disabled when NODE_ENV=test                                │
        │   - candidate scan via direct SQL (read-only sweep)            │
        │   - per-step calls fn_approval_escalate (idempotent, M2-NEW-3) │
        │   - gracefully stopped on SIGINT/SIGTERM (server.ts shutdown)  │
        └────────────────────────────────────────────────────────────────┘
```

DB-first state machine. Every wire endpoint is a thin pass-through. Business rules — including all transition gates, FOR UPDATE locks, idempotency checks, parallel-group resolution, and audit emission — live in the PL/pgSQL layer.

---

## 3. Entities Managed

| Entity | Table | Type | Description |
|---|---|---|---|
| Approval Matrix Rule | `approval_matrix` | master | Admin-configurable rule set keyed by (contract_type, value range, step_order, parallel_group, approver_role) |
| Approval Chain | `approval_chain` | transactional | Per-contract chain instance with frozen matrix_snapshot |
| Approval Step | `approval_step` | transactional | One row per approver in a chain (approver_user_id or approver_role) |
| Approval Decision | `approval_decision` | append-only | Per-step decision audit log (approve / reject / request_resubmission / delegate / reassign / escalate) |

---

## 4. API Endpoints (10 new + 1 extended)

| Method | Path | Story | Permission | DB Function |
|---|---|---|---|---|
| GET    | /api/v1/approvals/my-pending                  | S1  | implicit (RLS) | fn_approval_my_pending |
| POST   | /api/v1/approvals/:stepId/decide              | S2  | approval.act | fn_approval_decide |
| POST   | /api/v1/approvals/:stepId/delegate            | S3  | approval.act + approval.delegate | fn_approval_delegate |
| GET    | /api/v1/admin/approval-matrix                 | S4  | approval.matrix.read | fn_approval_matrix_list |
| PUT    | /api/v1/admin/approval-matrix                 | S5  | approval.matrix.write | fn_approval_matrix_set |
| POST   | /api/v1/contracts/:id/approval-chain/preview  | S6  | approval.matrix.read | fn_approval_route_init_preview |
| POST   | /api/v1/contracts/:id/submit-for-approval     | S7  | approval.submit_for_review | fn_approval_route_init |
| POST   | /api/v1/admin/approval-steps/:stepId/reassign | S8  | approval.reassign | fn_approval_reassign |
| GET    | /api/v1/contracts/:id/approval-chain          | S10 | anyOf(contract.read.{all,department,own}) | fn_approval_chain_get |
| GET    | /api/v1/admin/approval-chains                 | S11 | anyOf(approval.matrix.read, approval.reassign) | fn_approval_chain_list |
| PATCH  | /api/v1/contracts/:id/status (M1a, extended)   | S12 | per-transition (see [§ State machine](#7-state-machine)) | fn_contract_status_update_user |

**S9 has NO HTTP endpoint.** `fn_approval_escalate` is invoked exclusively by the node-cron driver inside the BE process. There is intentionally no `approval.escalate` permission.

Route ordering: `POST /contracts/:id/approval-chain/preview` MUST be registered before `GET /contracts/:id/approval-chain` to avoid the literal-segment shadow (mirrors M1b W1 lesson).

---

## 5. Migration History

8 migrations: 7 designed (023–029) + 1 design-error patch (030, caught at DB Impl functional probe) + 1 cycle-1 bug-fix patch (031, caught by Testing Agent integration tests).

| # | Purpose | Notes |
|---|---|---|
| 023 | AE-3 — extend contract.status CHECK 14→16 (`+in_approval`, `+cancelled`) | **CRITICAL FIRST migration.** Stable constraint name `contract_status_check`; dynamic pg_constraint lookup. |
| 024 | 4 tables + 25 indexes + 14 RLS + 4 audit triggers + 3 immutability triggers | M2-NEW-2 immutability triggers replace the RLS self-ref subquery anti-pattern (BE-M1c-C1) |
| 025 | 11 owned fn_approval_* + 3 trigger fn helpers | All SET search_path = public, pg_temp; SECURITY INVOKER except `fn_approval_escalate` (DEFINER, system-only) |
| 026 | AE-2 — DROP M1a `fn_contract_status_update` placeholder; CREATE `_user` (INVOKER) + `_internal` (DEFINER) | Wire signature preserved. Concurrency UPGRADE: `_user` adds SELECT FOR UPDATE on contract row (M1a placeholder had no lock). |
| 027 | AE-1 — extend `fn_contract_activity_create` whitelist 9→14 + table CHECK | S2-17 verbatim body preservation; namespace-prefixed activity types per OI-3 |
| 028 | AE-4 — 6 permissions + 21 grants | Pre-emptive Super Admin pattern (M1a 006 / M1c 018 lesson) |
| 029 | AE-Sensitive — extend `fn_audit_trigger` redact list with `decision_note` + `matrix_snapshot` | 19 → 21 redacted fields |
| **030** | **PATCH cycle 1** — fn_audit_log_record signature mismatch | See § 5.1 |
| **031** | **PATCH cycle 2** — NULL-safe equality + system-event actor sentinel | See § 5.2 |

Both Neon branches (`m0-foundation` / `br-snowy-brook-aje2ehtl` and `test` / `br-billowing-boat-ajq9m0g6`) advanced cleanly from `v22 → v31`. Per project memory `feedback_validate_runner_on_clean_db.md`, the runner was smoke-tested against `test` first.

### 5.1 Migration 030 — design error caught at DB Impl

**Root cause:** `db-design.md` Section 2 step 9 of `fn_approval_matrix_set` specified the audit call as `PERFORM fn_audit_log_record(p_actor_id, 'APPROVAL_MATRIX_SET', jsonb_build_object(...))` — three positional args. The canonical M1b 011 signature, however, is `(p_table_name TEXT, p_record_id BIGINT, p_action TEXT, p_new_values JSONB, p_actor_id BIGINT DEFAULT NULL)` with `p_action` constrained to `{INSERT, UPDATE, DELETE}`.

**Detection:** DB Implementation Agent's functional probe surfaced the deviation while exercising fn_approval_matrix_set against the test branch. Per project memory `feedback_db_impl_report_dont_fix.md`, the agent reported the deviation and wrote a follow-up patch rather than silently rewriting migration 025.

**Fix:** Migration 030 re-issued `fn_approval_matrix_set` via `CREATE OR REPLACE` with the corrected signature: `action='INSERT'` (the only enum value that fits — soft-delete + insert pattern) and `new_values.event='APPROVAL_MATRIX_SET'` discriminator (matches the M1b XLSX export precedent). Migration 025 was left immutable.

**Stage 4 escape lesson codified:** S2-19 — when a fn_ specification calls another fn_ (`PERFORM fn_other(...)`), Stage 2 must spot-check the call signature against the canonical signature in `project-artifacts/database/index.json`.

### 5.2 Migration 031 — two HIGH-severity bugs caught at testing fix loop

**Bug 1 — fn_approval_decide privilege escalation (AC-S2-04 db + be):**

The actor authorization check in `fn_approval_decide` was written as:
```
IF NOT (
    step.approver_user_id = p_actor_id
 OR step.delegated_to     = p_actor_id
 OR step.reassigned_to    = p_actor_id
) THEN RAISE 42501 ...
```
Under SQL three-valued logic, when `delegated_to` and `reassigned_to` are NULL (the common case — most steps are not delegated or reassigned), the OR chain evaluates to NULL. plpgsql `IF NULL THEN` is treated as FALSE, so the RAISE was BYPASSED. **Any authenticated user with `approval.act` could decide on any pending step.**

**Bug 2 — fn_approval_escalate cron actor=0 FK violation (AC-S9-01, S9-04, S9-08):**

`fn_approval_escalate` (SECURITY DEFINER, cron-invoked) calls `fn_contract_activity_create(... p_actor_id := NULL ...)`. fn_contract_activity_create's GUC fallback resolves NULL to `current_setting('app.current_user_id', true)`. The cron driver sets that GUC to `'0'` (the SYSTEM_ACTOR_ID sentinel). The resulting `INSERT INTO contract_activity (... actor_id) VALUES (... 0 ...)` violated `contract_activity_actor_id_fkey` because no user with `id=0` exists.

**Detection:** Testing Agent's integration tests caught both. The unit test for the cron driver mocked the DB and missed Bug 2 — a real-DB integration probe was required.

**Fix:** Migration 031 issued two `CREATE OR REPLACE` statements:
1. `fn_approval_decide` — actor check rewritten using `IS NOT DISTINCT FROM` (NULL-safe equality). Same pattern `fn_approval_delegate` already used (line 1030 of migration 025).
2. `fn_contract_activity_create` — added a 3-line block coercing `v_actor IN (NULL, 0) → NULL` just before INSERT, so the cron driver's sentinel produces a system-event row (`actor_id IS NULL`) instead of FK-violating. The column is already nullable on M1a (003 `REFERENCES "user"(id) ON DELETE SET NULL`); no ALTER TABLE was needed.

Both fixes preserved every other byte verbatim against migrations 025 / 027 (S2-17 fidelity). 5/5 smoke probes passed (drafter rejected, assigned approver succeeds, delegate succeeds, cron event writes actor_id IS NULL, real-user happy path preserved).

**Stage 4 escape lessons codified:**
- **S2-18** — every plpgsql equality check involving nullable columns MUST use `IS NOT DISTINCT FROM`. Pattern `column = p_arg OR column2 = p_arg` evaluates to NULL when one side is NULL → IF NULL → FALSE → RAISE bypassed → privilege escalation. Add to QA Stage 2 mandatory check list.
- **S2-20** — when introducing system-event fn_'s called by background workers, the actor-resolution logic MUST explicitly handle the system-actor sentinel (NULL or 0). Cron driver unit tests that mock the DB hide FK violations; a real-DB integration probe is required for any cron-driven fn_ chain.

Both new lessons are now mandatory at Stage 2 for every future module per memory `feedback_stage2_checks_s2_16_to_s2_20.md`.

---

## 6. Codex Adversarial Review Status

**SKIPPED** per developer decision 2026-05-04 (memory `feedback_skip_codex_review_dexian_decision.md`).

Compensating control: Stage 4 ran a cumulative Codex-lesson scan over L1–L20 — **20/20 PASS**. The lessons cover RLS WITH-CHECK mirroring (BE-M1b-006), no-self-ref-subquery (BE-M1c-C1), SECURITY INVOKER on public APIs, search_path pinning, fully-qualified DROP for signature changes, FOR UPDATE on every concurrent state mutation, status transitions returning 409 SQLSTATE class for invalid transitions, no-PostgreSQL-ENUM (CHECK only), redact list completeness, thin BE controllers, Zod ↔ fn_ key alignment (S2-16), Pino redaction coverage, ERRCODE → HTTP mapping completeness, JWT aud/iss/exp + permission gate ordering, FE no raw fetch, FE useDoubleSubmitLock on mutations, FE translateApiError funnel, FE three data states, FE i18n EN/AR parity, and **L20 NULL-safe equality (newly minted at this module)**.

Stage 4 also codified three new Stage-2 escape lessons (S2-18, S2-19, S2-20) — see § 5.

---

## 7. State Machine

### 7.1 Per-transition permission gates (fn_-side authoritative)

| From | To | fn | Permission |
|---|---|---|---|
| draft | in_review | fn_contract_status_update_user | approval.submit_for_review |
| in_review | draft | fn_contract_status_update_user | approval.submit_for_review (own) OR contract.delete |
| in_review | in_approval | fn_contract_status_update_user (atomically calls fn_approval_route_init) | approval.submit_for_review |
| in_approval | approved | fn_approval_decide → fn_contract_status_update_internal | implicit (assigned approver via 4 OR-arm) |
| in_approval | rejected | fn_approval_decide → fn_contract_status_update_internal | implicit |
| in_approval | draft (resubmission) | fn_approval_decide → fn_contract_status_update_internal | implicit |
| approved | active | fn_contract_status_update_user | contract.edit |
| any non-terminal | cancelled | fn_contract_status_update_user | contract.delete OR (contract.draft AND ownership) |

### 7.2 Direct override rejection (M2-NEW-1 / AC-S12-02)

`fn_contract_status_update_user` RAISES P0001 with `'Use fn_approval_decide for in_approval transitions'` when the caller targets approved / rejected / resubmission_requested directly while contract.status='in_approval'. BE `translatePgError` maps to HTTP 409 with the hint preserved in the error envelope.

### 7.3 Behaviour change (AC-S12-09)

Previously-permissive M1a transitions (e.g. `draft → approved` direct) now return 409. The 17 pre-existing M1a/M1b/M1c integration test failures are this intentional breaking change — to be migrated by their respective maintainers as test-fixture refresh, NOT routed through M2's fix loop.

---

## 8. Cross-Module Modifications Matrix

All five are backward-compatible at the wire level. Test-suite breaking changes are documented and acknowledged as M1a/M1b/M1c test debt.

| ID | Target | Change | Wire impact | Test-suite impact |
|---|---|---|---|---|
| AE-1 | fn_contract_activity_create whitelist + contract_activity_activity_type_check | 9→14 values; +5 namespace-prefixed approval activity types; system-event NULL-actor handling (031) | None (additive) | None |
| AE-2 | fn_contract_status_update | OWN-AND-SPLIT into `_user` (INVOKER) + `_internal` (DEFINER); concurrency UPGRADE (FOR UPDATE) | None on wire DTO field shape; **behaviour change** — previously-permissive transitions now 409 (M2-NEW-1 / AC-S12-09) | 12 M1a + 1 M1b + 4 M1c integration tests need updating |
| AE-3 | contract.status CHECK | 14→16 values (+`in_approval`, +`cancelled`) | None (additive enum) | None |
| AE-4 | permission + role_permission | 6 new permissions + 21 grants | None | None |
| AE-5 | fn_audit_trigger redact list | +decision_note +matrix_snapshot (19→21) | None | None |

---

## 9. Test Coverage Status

**Final state:** 436 tests / 418 pass / 18 fail. 95.87 % pass rate. Cycle-1 fix loop resolved 5 ACs (AC-S2-04 db + be, AC-S9-01, AC-S9-04, AC-S9-08).

**M2 surface:** 128 new M2 tests across 9 new test files. Per-file M2 coverage:

| File group | Lines | Branches |
|---|---|---|
| controllers/admin/* | 88.04 % | 63.15 % |
| services/approval-* | 87.61 % | 71.42 % |
| services/admin/* | 100 % | 45.45 % |
| routes/v1/approvals.routes.ts and admin routes | 100 % | 100 % |
| schemas/approval.schemas.ts | 96.15 % | 93.75 % |

**Aggregate coverage emit aborted** by failures (vitest v8 reporter blocks emission on any failure). M2-only-per-file figures meet or exceed 87 % lines / 63 % branches; QA Stage 4 accepted WARN per Section F policy.

### 9.1 Deferred follow-ups

1. **AC-S2-07 test-helper race** (LOW severity, no production impact). Test-only fix in `tests/db/M2-state-machine.test.ts:404`: replace `UPDATE approval_step SET approver_user_id WHERE approver_user_id IS NULL` with explicit per-stepId UPDATEs. Production code is correctly stricter post-031 — the old broken actor check masked the test-fixture race; the new correct check surfaces it. Schedule for next test-debt sweep.
2. **17 M1a/M1b/M1c expected-breaking tests.** Status-code expectations need updating (404 → 409, 400 → 409) to match the AE-2 OWN-AND-SPLIT + ERRCODE materialization. Schedule a clean-up sprint after M3.
3. **Coverage emit race.** Investigate vitest v8 coverage-from-passing-only mode or coverage-istanbul fallback to decouple coverage emit from test outcomes.

---

## 10. Known Limitations

1. **No notification table.** HQ1 / HQ7 ratified that approval events are surfaced via `contract_activity` rows only — no separate `notification` / `fn_notification_*` surface. FE polls via React Query (30 s `refetchInterval` on `/approvals/my-pending` and `/admin/approval-chains`). In-app inbox UX, push notifications, email digests are out of scope until M6+.
2. **Cron driver disabled in NODE_ENV=test.** `approval-escalation.cron.service.ts` short-circuits when `NODE_ENV=test`. Tests that exercise escalation must call `fn_approval_escalate` directly via the test helper.
3. **`contract.approval_chain_id` forward-FK column NOT introduced.** HQ4=B deferred. `fn_approval_chain_get(contract_id)` covers the lookup; FE caches via React Query. Optional projection extension to `fn_contract_get_by_id` is deferred follow-up M2-D5.
4. **Synthetic system user not introduced.** fn_approval_escalate uses `chain.initiated_by + metadata.systemEvent=true` for `approval_decision.decided_by` rather than a synthetic system user. Cron-emitted `contract_activity` rows have `actor_id IS NULL` (post-031 system-event coercion). Future cleanup: evaluate `actor_id BIGINT NULL` semantics consolidation.
5. **OI-5 `contract.status.update` permission disposition.** Kept (not deprecated). Repurposed as low-level admin override to avoid breaking M1a behaviour. Future cleanup if surface area allows.

---

## 11. HITL Gate 2 Ratifications

| Q | Topic | Resolution |
|---|---|---|
| HQ1 | Notification scope | C — contract_activity rows only; no notification table |
| HQ2 | fn_contract_status_update wrapper/replace/split | C — split into `_user` (INVOKER) + `_internal` (DEFINER) |
| HQ3 | contract_approver vs contract_approver_2 | A — keep both; identical approval.* grants |
| HQ4 | contract.approval_chain_id forward-FK column | B — defer; use fn_approval_chain_get |
| HQ5 | fn_approval_route_init dual-mode vs two fns | B — two fns (_preview STABLE + _commit VOLATILE) |
| HQ6 | fn_approval_escalate trigger mechanism | A — backend node-cron, default 15 min |
| HQ7 | Approval events: contract_activity vs separate notification table | A — contract_activity only |

---

## 12. Operational Gotchas

1. **Migration 023 is CRITICAL FIRST.** It extends the `contract.status` CHECK constraint. Every M2 fn that writes `contract.status` (route_init, status_update_user, status_update_internal, decide) fails until 023 lands. If you fork a migration sequence, 023 must come before any other M2 migration.
2. **`fn_contract_status_update_internal` is NEVER called by BE controllers.** It is SECURITY DEFINER, REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner, and is invoked only by `fn_approval_decide` for `in_approval → approved/rejected/draft`. If you find yourself wanting to call it from a controller, the right answer is to call `fn_approval_decide` instead (or extend the user wrapper).
3. **The cron driver requires `APPROVAL_ESCALATION_INTERVAL_CRON`.** Default `*/15 * * * *`. Missing → env-validation fails fast at startup. Set `NODE_ENV=test` to disable the driver in test runs.
4. **Cron driver actor sentinel.** The driver sets `app.current_user_id='0'`. fn_contract_activity_create coerces `v_actor IN (NULL, 0) → NULL` before INSERT (post-031). If you introduce another system-event fn_ called from cron, it MUST follow the same convention or violate `contract_activity_actor_id_fkey`. **Stage 2 lesson S2-20 is mandatory.**
5. **NULL-safe equality (S2-18) is mandatory** for any plpgsql equality check involving nullable columns. The pattern `column = p_arg OR ...` is forbidden when any operand can be NULL — use `IS NOT DISTINCT FROM`. Stage 4 codified S2-18 after the migration 031 privilege-escalation fix.
6. **fn-to-fn call signature spot-check (S2-19) is mandatory.** Whenever a fn_ specification calls another fn_ via `PERFORM`, Stage 2 must verify the call signature against the canonical signature in `project-artifacts/database/index.json`. The migration 030 patch was the result of skipping this check on `fn_audit_log_record`.
7. **Express route ordering.** `POST /contracts/:id/approval-chain/preview` MUST be registered before `GET /contracts/:id/approval-chain` to avoid the literal-segment shadow (mirrors M1b W1 lesson `/contracts/export.xlsx`).
8. **node-cron + @types/node-cron are new runtime deps.** Recorded in `package.json`. State Writer should reflect them in `registry.json deps.beAdded[]`. Graceful shutdown is wired via `stopApprovalEscalationCron()` first in the SIGINT/SIGTERM sequence in `src/server.ts`.
9. **GET /admin/approval-chains uses `authoriseAnyOf(approval.matrix.read, approval.reassign)`.** Non-admin `contract.read.*` callers will hit 403 at the route gate even though `fn_approval_chain_list` RLS would narrow them. INTENTIONAL — keeps the admin namespace permission boundary explicit. Drafters / approvers see chains via `GET /contracts/:id/approval-chain` instead.
10. **Sensitive fields.** `decisionNote` and `matrixSnapshot` are pino-redacted (14 paths each, top-level + req.body / req.query / req.params / nested + snake_case forms). `fn_audit_trigger` redacts both in `audit_log.old_values` / `new_values` JSONB. Don't log them in controllers.

---

## 13. How to Extend This Module

**To add a new step status (e.g. `paused`):**
1. Migration: `ALTER TABLE approval_step DROP CONSTRAINT approval_step_status_check;` then re-add with the new value. Update fn_approval_my_pending if the new state should be visible. Update TypeScript `ApprovalStepStatus` union in `src/types/approval.types.ts`.
2. Update i18n keys in `frontend/src/i18n/{en,ar}.json` under `approval.list.statusLabel.*` (FE T3).
3. Update `database/M2-data-dictionary.md` § 2.3 status enum.

**To add a new approval activity type (e.g. `approval_paused`):**
1. Migration: extend `contract_activity_activity_type_check` (DROP + ADD pattern from migration 027) AND extend the IN-list inside `fn_contract_activity_create` body via `CREATE OR REPLACE` with S2-17 fidelity.
2. Update `M2ActivityTypeExtension` union in `src/types/approval.types.ts`.
3. Update FE `ContractActivityLog.tsx` activity-type → label / icon mapping (T7 exhaustiveness).

**To wire a new admin oversight endpoint (e.g. forensic matrix-snapshot endpoint):**
1. Add a fn_ in a new migration (e.g. 032). Pattern: SECURITY INVOKER, SET search_path, FOR UPDATE if mutating, RAISE with ERRCODE for every non-happy path.
2. Add controller method under `src/controllers/admin/`.
3. Append route under `src/routes/v1/admin/`. Order literal-path routes before any `:id`-prefixed ones.
4. Add Zod schema mirroring the fn_ DTO (S2-16).
5. Update OpenAPI spec under `tag: M2 — Admin Approvals`.

**To add a new permission:**
1. INSERT into `permission` table (snake_case code per OI-9). Grant to roles via `role_permission`.
2. Update `M2_NEW_PERMISSIONS` array in `src/types/approval.types.ts`.
3. Add to `authorise([...])` middleware list at the route layer.
4. fn_ layer should re-check via `fn_current_user_has_permission` for defense-in-depth.

---

## 14. Files Owned by This Module

### Backend (13 new + 12 modified)

**Schemas / types:**
- `src/schemas/approval.schemas.ts`
- `src/types/approval.types.ts`

**Controllers:**
- `src/controllers/approval.controller.ts`
- `src/controllers/admin/approval-matrix.controller.ts`
- `src/controllers/admin/approval-chains.controller.ts`

**Services:**
- `src/services/approval.service.ts`
- `src/services/admin/approval-matrix.service.ts`
- `src/services/admin/approval-chains.service.ts`
- `src/services/approval-escalation.cron.service.ts`

**Routes:**
- `src/routes/v1/approvals.routes.ts`
- `src/routes/v1/admin/index.ts`
- `src/routes/v1/admin/approval-matrix.routes.ts`
- `src/routes/v1/admin/approval-chains.routes.ts`
- `src/routes/v1/admin/approval-steps.routes.ts`

**Modified:**
- `src/types/contracts.types.ts` (ContractStatus widened 14→16; ActivityType widened 9→14; UpdateContractStatusUserDto introduced)
- `src/schemas/contracts.schemas.ts`
- `src/controllers/contracts.controller.ts` (updateStatus → fn_contract_status_update_user)
- `src/routes/v1/contracts.routes.ts`
- `src/routes/v1/index.ts`
- `src/database/client.ts` (translatePgError extended for M2 ERRCODES)
- `src/utils/logger.util.ts` (decisionNote / matrixSnapshot redaction paths)
- `src/utils/env-validation.util.ts` (APPROVAL_ESCALATION_INTERVAL_CRON)
- `src/server.ts` (cron driver wiring + graceful shutdown)
- `.env.example`
- `package.json`, `package-lock.json` (node-cron@^3.0.3, @types/node-cron@^3.0.11)

### Database

- `database/migrations/023_m2_extend_contract_status_check.sql`
- `database/migrations/024_m2_approval_tables_rls_indexes.sql`
- `database/migrations/025_m2_approval_functions.sql`
- `database/migrations/026_m2_split_fn_contract_status_update.sql`
- `database/migrations/027_m2_extend_fn_contract_activity_create_whitelist.sql`
- `database/migrations/028_m2_approval_permissions_and_grants.sql`
- `database/migrations/029_m2_extend_audit_redact_list.sql`
- `database/migrations/030_m2_fix_fn_approval_matrix_set_audit_call.sql`
- `database/migrations/031_m2_fix_actor_check_and_cron_actor.sql`

### Frontend

See the FE-side handoff at the frontend repo's `docs/M2-frontend.md` for full file inventory, routes, components, and i18n key delta.

---

*Generated by Documentation Generator (Agent 15) post-QA Stage 4. Sources: requirements-analysis.json, db-design.md, db-design-summary.json, db-impl-summary.json, be-implementation-summary.json, fe-implementation-summary.json, module-M2-test-report.md, qa-stage4-result.json, module-M2-file-manifest.json. v1.0 — M2 ship.*
