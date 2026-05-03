# M1a Test Coverage Gaps — Deferred ACs

> **Module:** M1a (Contracts: Core CRUD & Lifecycle).
> **Generated:** 2026-05-03.
> **Source:** `module-M1a-test-report.md` (Testing Agent v2.3) + QA Stage 4 Section F warnings + integration test bootstrap-admin scope.
> **Status:** Non-blocking — all 139/139 BE tests pass; coverage above the FAIL floors. This document tracks deferred ACs explicitly so they can be tackled in M1b or a QA Stage 4 follow-up sprint.

---

## Why these gaps exist

The M1a integration suite runs against the bootstrap admin (M0 `Super Admin` role). Super Admin is in the contract_select_role_aware "see-all" set defined in migration 003, so role-narrowing branches and many 403 / RLS-hidden-row branches are unreachable from a Super-Admin caller without seeding additional fixture users for each non-privileged M1a role.

Three classes of deferred ACs exist:

1. **Role-narrowing tests** — every "403 when caller lacks X permission" or "narrows to own/department" test that requires a `contract_drafter` / `contract_approver` / `contract_recipient` fixture user.
2. **Defensive paths unreachable from outside the DB** — e.g. AC-S10-08 versionNumber 409 retry which `SELECT FOR UPDATE` makes essentially impossible to provoke from a test client.
3. **Cross-module dependencies** — ACs that depend on M0 user soft-delete cycle behaviour (AC-S2-05, AC-S11-04) or Parties module wiring (true RLS-hidden-row 403 tests).

Coverage actuals at the time of M1a sign-off (against vitest gate floors):

| Metric | Actual | Gate (PASS) | Aspirational (CLAUDE.md §11) |
|---|---|---|---|
| Lines | 73.09% | 60 | 90 |
| Statements | 73.09% | 60 | 90 |
| Functions | 75.28% | 60 | 90 |
| Branches | 65.28% | 50 | 80 |

---

## Deferred ACs by story

### S1 — fn_contract_list

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S1-03 | Role-aware narrowing for `contract_recipient` (own scope) | Requires a `contract_recipient` fixture user; Super Admin sees-all. | M1b QA Stage 4 follow-up. |
| AC-S1-04 | Role-aware narrowing for `contract_drafter` (department scope, placeholder = drafted_by) | Same. | M1b QA Stage 4 follow-up. |
| AC-S1-06 | Tag filter exact-set assertions for non-privileged caller | Same. | M1b. |
| AC-S1-07 | Search filter narrows for non-privileged caller | Same. | M1b. |

### S2 — fn_contract_get_by_id

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S2-03 (negative) | True 403 when row exists but is hidden by RLS | Super Admin bypasses RLS; the `db.checkActiveRowExists` path is exercised on the visible-row branch only. | M1b — adds `contract_recipient` fixture user. |
| AC-S2-05 | `draftedBy`/`reviewedBy`/`approvedBy` enrich to NULL after underlying user soft-delete | Depends on M0 user soft-delete cycle; no M0 fn_user_delete was hit by these tests. | M0 follow-up suite OR Cross-module test (M2 timing). |

### S3 — fn_contract_create

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S3-10 | 403 when caller lacks `contract.draft` | Bootstrap admin holds `contract.draft` (granted by migration 006). Requires a fixture user without it. | M1b. |

### S4 — fn_contract_update

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S4-08 | 403 when `contract_drafter` not own contract | Requires a `contract_drafter` fixture user. | M1b. |

### S5 — fn_contract_delete

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S5-05 | 403 when caller is not `platform_admin` | Bootstrap admin holds `contract.delete` (granted by migration 006). Requires a non-platform-admin fixture user. | M1b. |

### S6 — fn_contract_status_update

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S6-06 | 403 when `contract_drafter` updating not-own contract | Requires a `contract_drafter` fixture user. | M1b. |

### S7 — fn_contract_get_tree

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S7-04 (negative) | Tree pruning when sibling/child is invisible to caller | Requires fixture user with constrained visibility. | M1b. |
| AC-S7-05 | Depth cap 20 + `truncated=true` flag | Constructing a 20-node ancestry chain on a shared test branch is expensive (40 inserts + sequential parent linking). | Dedicated test branch helper for M1b OR a unit test on `fn_contract_get_tree` directly with a synthetic 25-node chain. |
| AC-S7-07 | 403 on invisible root | Same root cause as AC-S2-03 negative. | M1b. |

### S8, S9, S10, S11 — per-role 403 paths

| AC | Description | Recommended owner |
|---|---|---|
| AC-S8-08 | 403 on `contract.tag.manage` denial | M1b fixture user. |
| AC-S9-06 | 403 on version list when caller lacks read permissions | M1b fixture user. |
| AC-S10-07 | 403 on version create when not own/not authorised | M1b fixture user. |
| AC-S11-06 | 403 on activity list when caller lacks read permissions | M1b fixture user. |
| AC-S11-04 | `actor` enriches to NULL after underlying user soft-delete | Depends on M0 user lifecycle; out of scope of HTTP-surface integration. |

### S10 — special: AC-S10-08 defensive UNIQUE retry

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S10-08 | `versionNumber` 409 CONFLICT retry on UNIQUE collision | After migration 008, `fn_contract_version_create` takes `SELECT FOR UPDATE` on the parent contract row before reading and incrementing `version_number`. The race window is closed at the database level — provoking the 409 from a multi-connection test client is essentially unreachable. | Defensive code path; document as "validated by DB lock semantics" rather than test-asserted. Promote to a stress-test only if Postgres advisory-lock semantics change. |

### S12 — system / triggers

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S12-03 | Dedicated `soft_deleted` / `restored` activityType assertion | Soft-delete is exercised in S5; the trigger-emitted activity is implicit. | Add a single assertion on `activity_type='soft_deleted'` in the S5 happy-path test. M1b housekeeping. |
| AC-S12-05 | Tagged activity metadata diff exact-match assertion | Tagged activity emission verified in S8-04; metadata diff structure tolerated rather than exact-asserted. | Tighten the assertion to exact `{added, removed}` structure. M1b housekeeping. |
| AC-S12-07 | Multi-row activity emission (e.g. mass status update) | Out of M1a HTTP scope; would require dedicated DB-direct tests. | Future system-test pass. |
| AC-S12-08 | `body_*` content redaction in activity metadata | Requires direct DB tests to verify the trigger never copies body content into `metadata`. | Future system-test pass. Reading the trigger source is currently the verification path. |

---

## QA Stage 4 Section F — coverage WARNs (3, all above FAIL floors)

| Metric | Actual | Aspirational target | FAIL floor | Verdict |
|---|---|---|---|---|
| Lines | 73.09% | ≥90% | 70% | WARN |
| Functions | 75.28% | ≥90% | 70% | WARN |
| Branches | 65.28% | ≥80% | 60% | WARN |

Branch-coverage gap concentrated in:

- Schema cross-field error paths (e.g. `endDate < startDate` boundary cases in `UpdateContractDtoSchema`).
- `AC-S2-03` 403 vs 404 controller branch (only 200 branch hit).
- `translatePgError` SQLSTATE variants (only the structured-RAISE format and 42501 are hit; 23xxx / 22xxx variants not exercised).
- `fn_contract_delete` GUC reset path (post-success cleanup branch).
- `fn_contract_set_tags` control-character rejection (covered by schema unit test but not by integration round-trip).

**Recommended action:** Testing Agent gap pass before M1b targeting these specific branches. Rationale per CLAUDE.md §11: "don't fight to hit 90 if the marginal tests are low-value" - but the four listed branches are reachable, security-relevant, and worth the cycles.

---

## Recommended fixture user pool (for M1b)

To unblock the role-narrowing tests above, M1b should add a small fixture user pool to `tests/helpers/`:

| Email | Role | Purpose |
|---|---|---|
| `drafter1@musanad.test` | `contract_drafter` | AC-S1-04, AC-S3-10, AC-S4-08, AC-S6-06, AC-S8-08 |
| `recipient1@musanad.test` | `contract_recipient` | AC-S1-03, AC-S2-03, AC-S7-04, AC-S7-07 |
| `approver1@musanad.test` | `contract_approver` | AC-S5-05, S6/S8 negative branches |
| `executive1@musanad.test` | `executive` | Read-all assertions disambiguating from platform_admin |

Provision via `m1a-helpers.ts` `seedFixtureUsers()` exported helper; cleanup via existing `cleanupContractsByIds` extended to clean fixture users by id range.

---

## Items NOT in this gap list (already PASSing)

For full transparency: 70 of the M1a ACs PASS in the integration / unit suite. The full breakdown is in `module-M1a-test-report.md` (Testing Agent output, retained in `.claude/workspace/current-module/`).

---

*Generated by Documentation Generator from module-M1a-test-report.md + qa-stage4-report.md.*
