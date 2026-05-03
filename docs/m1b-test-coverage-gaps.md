# M1b Test Coverage Gaps — Deferred ACs

> **Module:** M1b (Compose Wizard, Payment Schedules & Exports).
> **Generated:** 2026-05-03.
> **Source:** `module-M1b-test-report.md` (Testing Agent v2.3) + `qa-stage4-report.md` Section F warnings.
> **Status:** Non-blocking — all 218/218 BE tests + 28/28 FE tests pass; coverage above the FAIL floors. This document tracks deferred ACs explicitly so they can be addressed in M1c or earlier.

---

## Why these gaps exist

Three classes of deferred ACs, mirroring the M1a gap profile:

1. **Role-narrowing tests** — every "403 when actor lacks `contract.edit` / `contract.export`" AC needs a fixture user without that permission. M1b's integration suite runs against the bootstrap admin (M0 Super Admin) which holds every M1a + M1b `contract.*` permission.
2. **Test-environment short-circuits** — `exportRateLimiter` middleware short-circuits when `NODE_ENV=test` (so the integration suite does not trip the per-user rate limit while writing 200+ contracts). 429 paths are unreachable in vitest without bypassing the short-circuit.
3. **Boundary-data construction expense** — the `X-Export-Truncated` header only emits when the result set exceeds `maxRows`; default `maxRows=10000`. Seeding 50,000 contracts on a shared test branch is prohibitively expensive.

Coverage actuals at M1b sign-off (against vitest gate floors):

| Metric | Actual | Gate (PASS) | Aspirational (CLAUDE.md §11) |
|---|---|---|---|
| Lines | 77.44% | 60 | 90 |
| Statements | 77.44% | 60 | 90 |
| Functions | 78.94% | 60 | 90 |
| Branches | 70.25% | 50 | 80 |

M1b-authored files alone are at 99–100% lines / 88–96% branches. Aggregate drag is M1a controller methods carried over.

---

## Deferred ACs by story

### S3 — fn_payment_schedule_create_bulk (PUT /payment-schedules)

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S3-03 | 403 when actor lacks `contract.edit` (and is not a drafter on own draft) | Bootstrap admin holds `contract.edit` (granted by M1a migration 006). Same gap pattern as M1a. | M1c — fixture user pool. |

### S4 — fn_contract_export_pdf (GET /export.pdf)

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S4-04 | 403 when actor lacks `contract.export` | Bootstrap admin holds `contract.export`; needs a fixture user without it. | M1c — fixture user pool. |
| AC-S4-09 | 429 when `exportRateLimiter` exceeded (30 req/min/user) | `exportRateLimiter` short-circuits when `NODE_ENV=test`. | Manual smoke or e2e — see "Manual smoke procedure" below. |

### S5 — fn_contract_export_xlsx (GET /export.xlsx)

| AC | Description | Why deferred | Recommended owner |
|---|---|---|---|
| AC-S5-03 | 403 when actor lacks `contract.export` | Same as AC-S4-04. | M1c — fixture user pool. |
| AC-S5-04 | Role-aware visibility (drafter sees own only, executive sees all) | Bootstrap admin sees all by default; needs `contract_drafter` and `executive` fixture users to disambiguate the visibility branches. | M1c — fixture user pool. |
| AC-S5-05 (HTTP-level) | `X-Export-Truncated: true` header emitted when result set exceeds `maxRows` | Renderer-level coverage IS in place (`tests/unit/contract-xlsx.service.test.ts` exercises the truncation branch with synthetic data). HTTP-level integration test would require seeding > 50,000 contracts on the shared test branch — prohibitive. | Renderer-unit coverage retained. Manual smoke for HTTP-level — see below. |
| AC-S5-10 | 429 when `exportRateLimiter` exceeded | Same as AC-S4-09. | Manual smoke or e2e. |

---

## Manual smoke procedures (cover the test-environment-shortcircuit ACs)

### 1. AC-S4-09 / AC-S5-10 — 429 rate-limit verification

In a development environment with `NODE_ENV=development` or `production` (NOT `test`), with `EXPORT_RATE_LIMIT_PER_MIN=3` for a quick verification:

```bash
# Login as bootstrap admin
curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@musanad.local","password":"ChangeMe@123"}' \
  | jq -r '.accessToken' > /tmp/at

# Issue 5 PDF exports back-to-back
for i in 1 2 3 4 5; do
  echo -n "Request $i: "
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer $(cat /tmp/at)" \
    "http://localhost:4000/api/v1/contracts/1/export.pdf?language=en"
done

# Expected (with EXPORT_RATE_LIMIT_PER_MIN=3): 200, 200, 200, 429, 429
```

After verification, restore `EXPORT_RATE_LIMIT_PER_MIN=30` (or whatever your environment's default is).

### 2. AC-S5-05 — X-Export-Truncated HTTP-level

Either seed > `maxRows` rows on a dev branch (one-time investment for an annual smoke), or call the endpoint with `?maxRows=1`:

```bash
# Force truncation at maxRows=1 against a small contracts set
curl -sv -H "Authorization: Bearer $(cat /tmp/at)" \
  'http://localhost:4000/api/v1/contracts/export.xlsx?maxRows=1' \
  -o /tmp/contracts.xlsx 2>&1 \
  | grep -i 'x-export-truncated'

# Expected: < x-export-truncated: true
```

This exercises the same code path as a 50,000-row truncation but with seeding cost of zero.

---

## Recommended fixture user pool (cross-module)

The M1a doc recommended a fixture user seed for M1b; M1b deferred it (the gaps shown above are the consequence). Recommend a **shared fixture-user seed migration** in M1c — one migration that seeds 4–5 fixture users across all `contract_*` roles, usable by every future module's integration suite.

| Email | Role | Purpose |
|---|---|---|
| `drafter1@musanad.test` | `contract_drafter` | M1a AC-S1-04 / AC-S3-10 / AC-S4-08 / AC-S6-06 / AC-S8-08 + M1b AC-S3-03, AC-S4-04, AC-S5-03 (drafter scope). |
| `recipient1@musanad.test` | `contract_recipient` | M1a AC-S1-03 / AC-S2-03 / AC-S7-04 / AC-S7-07 + M1b 403 paths. |
| `approver1@musanad.test` | `contract_approver` | M1a AC-S5-05 + M1b AC-S5-04 (department visibility branch). |
| `executive1@musanad.test` | `executive` | M1a read-all assertions + M1b AC-S5-04 (executive sees all). |
| `legal1@musanad.test` | `legal_counsel` | M1b export permission paths (legal_counsel holds `contract.export`). |

Provision via a `seedFixtureUsers()` helper exported from `tests/helpers/fixture-users.ts`; cleanup via `cleanupFixtureUsers()` keyed by id range. Fixture user IDs should sit in a reserved range (e.g. 1000..1099) so cleanup queries can filter by `id BETWEEN 1000 AND 1099`.

---

## Items NOT in this gap list (already PASSing)

For full transparency, M1b PASSes 218/218 BE tests + 28/28 FE tests. The full breakdown is in `module-M1b-test-report.md` (Testing Agent output, retained in `.claude/workspace/current-module/`).

In particular, all of these were verified in the integration / unit suite — NOT deferred:

- AC-S1-08 retry semantics (POST succeeds, first PUT fails, retry succeeds — locks DB-PATCH-1 + BE-PATCH-1).
- AC-S1-10 happy-path POST → PUT sequence.
- AC-S2-01..06 payment-schedule list (happy path, 404, 404-not-403 RLS layered defence, empty data, is_active filter, invalid status).
- AC-S3-01 + AC-S3-10 atomic replace + activity emission.
- AC-S3-02 / 04 / 05 / 06 / 07 / 08 / 09 / 11 (404, empty rows, missing label, negative amount, invalid status, invalid recurrence, > 100 rows, concurrent serialisation).
- AC-S4-01 / 02 / 03 / 05 / 06 / 07 / 08 / 10 (PDF: happy path + magic bytes, content assertions, 404, invalid language, activity emit, backend Puppeteer, body redaction in logs, includeAttachments accepted).
- AC-S5-01 / 02 / 06 / 07 / 08 / 09 (XLSX: happy path + ZIP magic, filter pass-through (locks migration 012 fix), maxRows out-of-range, empty workbook header-only, single audit_log row with EVENT discriminator, backend exceljs).

---

## Regression locks established by M1b

These are reverse-direction — tests that protect M1b patches from regressing.

### DB-PATCH-1 (migration 013 — fn_contract_activity_create whitelist extension)

Locked by AC-S3-01 + AC-S3-10 happy path + AC-S4-06 PDF emission test + AC-S1-10 sequence. If migration 013 regressed (whitelist reverts to 7 values), `fn_contract_activity_create` raises `activityType:Invalid activity type` and these tests fail with a 400.

### BE-PATCH-1 (`src/database/client.ts` array-of-objects serialiser)

Locked by `tests/unit/db-client-jsonb-array.test.ts` (3 tests directly assert `boundArgs` mapping for arrays of objects, primitives, and plain objects) plus every M1b integration `PUT /payment-schedules` round-trip. If regressed, `fn_payment_schedule_create_bulk` rejects the input with `invalid value type` and every PUT returns 400.

### Migration 012 (`fn_contract_export_xlsx` tag filter)

Locked by AC-S5-02 filter pass-through. If the `text[] <@ varchar[]` operator-resolution failure returned, the test would receive a 500 from the controller.

### Migration 014 (RLS WITH CHECK — Codex BE-M1b-006)

NOT directly asserted by an integration test, because the integration suite runs as Super Admin which is exempt from the WITH CHECK gate. Codex BE-M1b-006 verification is performed at code-review time + the manual smoke procedure in `ops-runbook.md` "Health check after deploy" §4.

### Migration 015 (PDF activity emit moved to controller — Codex BE-M1b-004)

Locked by AC-S4-06 PDF activity emission test, which is now agnostic to the source (function vs controller). If the controller fails to emit, the integration test fails immediately.

---

*Generated by Documentation Generator from module-M1b-test-report.md + qa-stage4-report.md + codex-be-patch-summary.md.*
