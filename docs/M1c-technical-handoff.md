# M1c — Bulk & Manual Import — Technical Handoff

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M1c — Bulk & Manual Import (third sub-module of M1; M0 + M1a + M1b complete and shipped 2026-05-02 / 2026-05-02 / 2026-05-02 respectively).
> **Generated:** 2026-05-03.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Status:** Complete. 308/308 tests pass. QA Stage 4 PASS-WITH-WARNINGS (3 WARN-band coverage items, 0 FAIL, 0 blockers). Codex BE round-1 findings (1 CRITICAL + 1 HIGH + 1 MEDIUM) ALL FIXED in shipped code via migrations 021 / 022 + pino redact extension. Codex FE round-1 deferred to CRX-9 (quota exhausted; rerun from FE repo when quota resets ~2026-05-09).

This is the practical technical handoff for the developer extending M1c or picking it up across sessions. For database object detail see [`database/M1c-data-dictionary.md`](database/M1c-data-dictionary.md). For the OpenAPI specification see [`api/openapi.yaml`](api/openapi.yaml). For the FE-side handoff see the frontend repo's `docs/M1c-frontend.md`.

---

## 1. What this module builds

M1c lets users bulk-import contracts from PDF/DOCX files, route them by AI extraction confidence into auto-save / human review / manual-entry tracks, manage batch lifecycle (pause / resume / cancel), and lets admins drill into each batch to see counts and the resulting contracts. It also delivers a stub for the AI extraction endpoint with a frozen DTO that M4 will replace without consumer changes.

The module reuses M1a's contract domain wholesale — it adds NO new contract behaviour. Per-file save uses the existing `POST /api/v1/contracts` (M1a) with 4 new optional import-trace fields. Per-batch contract drill-down uses the existing `GET /api/v1/contracts` (M1a) with 3 new optional filter params + 3 new response fields. The new entity introduced in M1c is the `import_batch` session tracker.

---

## 2. Architecture

```
[ Frontend (TanStack Start) ]                     [ Supabase Storage 'contracts' bucket ]
        |                                                       ^
        | mammoth/pdfjs extract text in browser ───────────────/ (FE-direct upload — HQ1)
        |
        | apiClient.post('/api/v1/ai/extract-contract-bulk')   ← extractedText + filename
        v
[ AI controller (STUB — NO fn_, NO DB) ]
        |
        | returns deterministic mock { ...createDtoFields, importConfidence, importWarnings }
        v
[ FE routing logic — IMPORT_CONFIDENCE_THRESHOLDS ]
   |        |              |
   high     medium          low
   |        |              |
   v        v              v
auto-save  review queue   manual entry
   |        |              (link to existing M1a /app/contracts/new)
   |        |
   |        | apiClient.put('/api/v1/contracts/:id/status')   ← approve transition
   v        v
apiClient.post('/api/v1/contracts')  ← M1a fn_contract_create with 4 new optional fields
                                       (importBatchId / importFilename / importConfidence / importWarnings)
        |
        | apiClient.patch('/api/v1/import-batches/:id')   ← counter increment + status
        v
[ Express controllers (4 import-batch + 1 AI stub) ]
        |
        | db.callFunction('fn_import_batch_*')   ← thin pass-through
        v
[ PostgreSQL fn_import_batch_create / update / list / get_by_id ]
[ + cross-module: fn_contract_create (extended) / fn_contract_list (extended) / fn_contract_get_by_id (extended) ]
        |
        | RLS + trigger enforcement (FORCE ROW LEVEL SECURITY)
        v
[ Tables: import_batch (NEW M1c)  +  contract.import_batch_id FK (NEW in 016) ]
```

**Rules carried forward from M0/M1a/M1b:**

- Controllers do NOT contain business logic — they validate via Zod, call `db.callFunction()`, wrap the JSONB in the `ApiResponse<T>` envelope, and return.
- All business logic lives in `fn_*` functions. Naming: `fn_<entity>_<operation>`. Sole exception in M1c is the AI extract stub which is controller-only by design (HQ2; M4 will replace the body).
- No ORM. No stored procedures. Native `pg` + parameterized queries.
- `rls.middleware.ts` runs `SET LOCAL app.current_user_id = <jwt.sub>` inside a transaction before every authenticated `fn_` call. RLS policies read this GUC.
- JSONB output keys are camelCase and match the TypeScript interfaces in `src/types/import-batch.types.ts` and the M1c-extended `src/types/contracts.types.ts`.

**Backend file layout owned by M1c:**

```
src/
  types/
    import-batch.types.ts          (NEW — full M1c types)
    contracts.types.ts             (MODIFIED additively — 4 import fields on Contract / Create / List interfaces)
  schemas/
    import-batch.schemas.ts        (NEW — Zod schemas for S1/S2/S3/S4)
    contracts.schemas.ts           (MODIFIED additively — 4 fields on createContractSchema, 3 fields on contractListQuerySchema)
  controllers/
    import-batch.controller.ts     (NEW — 4 methods for S1/S2/S3/S4)
    ai/extract-contract-bulk.controller.ts (NEW — S8 stub controller)
    contracts.controller.ts        (MODIFIED — list method widened from 15 → 18 positional args)
  services/
    ai/extract-contract-bulk.service.ts (NEW — buildStubExtraction + computeStubConfidence)
  routes/
    v1/import-batches.routes.ts    (NEW)
    v1/ai.routes.ts                (NEW — first AI namespace endpoint; M4 will append more)
    v1/index.ts                    (MODIFIED — mounts the 2 new routers)
  database/
    client.ts                      (MODIFIED — translatePgError extended for 404:/permission:/status:Invalid status transition/fk_contract_import_batch_id 23503)
  utils/
    logger.util.ts                 (MODIFIED — Codex M1 extension: 53 → 275 redact paths covering 21 sensitive-field forms)

database/migrations/
  016_m1c_import_batch.sql                                          (original)
  017_m1c_import_functions.sql                                      (original)
  018_m1c_import_permissions_and_grants.sql                         (original)
  019_m1c_extend_fn_contract_create.sql                             (PATCH cycle 1)
  020_m1c_fix_concurrency_role_gate_and_warnings_default.sql        (PATCH cycle 2)
  021_m1c_fix_rls_anti_reassignment.sql                             (PATCH cycle 3 — Codex C1 CRITICAL)
  022_m1c_extend_fn_contract_get_by_id_projection.sql               (PATCH cycle 3 — Codex H1 HIGH)
```

---

## 3. API surface

### 5 new endpoints + 1 extended

| Method | Path | Story | DB function | Rate limit | Auth |
|---|---|---|---|---|---|
| POST | `/api/v1/import-batches` | S1 | `fn_import_batch_create` | authedWriteRateLimiter | `import.run` |
| PATCH | `/api/v1/import-batches/:id` | S2 | `fn_import_batch_update` | authedWriteRateLimiter | `anyOf(import.run, import.review)` + initiator-self in fn |
| GET | `/api/v1/import-batches` | S3 | `fn_import_batch_list` | authedReadRateLimiter | `anyOf(import.review, import.run)` |
| GET | `/api/v1/import-batches/:id` | S4 | `fn_import_batch_get_by_id` | authedReadRateLimiter | `anyOf(import.review, import.run)` |
| POST | `/api/v1/ai/extract-contract-bulk` | S8 | _none — controller-only stub_ | authedWriteRateLimiter | `import.run` |
| **GET** | **`/api/v1/contracts` (M1a) — EXTENDED** | extends M1a-S2 | `fn_contract_list` (15→18 params) | authedReadRateLimiter | unchanged |

The extended `GET /contracts` endpoint takes 3 new optional query params (`importBatchId`, `importConfidenceMin`, `importConfidenceMax`) and returns 3 new fields per row (`importBatchId`, `importConfidence`, `importWarnings`). Backward-compatible — existing 13-param callers unaffected; consumers ignoring unknown fields work as-is.

---

## 4. Migration history with the 4 patches explained

The 3 original migrations (016/017/018) shipped as designed. Three subsequent patch cycles added 4 more migrations driven by 2 Stage-2 escapes caught during testing and 2 Codex round-1 findings:

### Original (Phase 2 DB Implementation)

- **016 — `016_m1c_import_batch.sql`**
  CREATE TABLE `import_batch` (17 cols, 2 multi-col CHECKs); 7 indexes; 5 RLS policies; ENABLE + FORCE RLS; audit trigger binding; `ALTER TABLE contract ADD CONSTRAINT fk_contract_import_batch_id` (idempotent DO block). Closes the M1a forward-reference column.

- **017 — `017_m1c_import_functions.sql`**
  DROP+CREATE `fn_contract_list` (15→18 param signature, AE-1 cross-module REPLACE); CREATE OR REPLACE 4 new `fn_import_batch_*` functions (S1–S4).

- **018 — `018_m1c_import_permissions_and_grants.sql`**
  INSERT 2 permissions (`import.run`, `import.review`); INSERT 7 role_permission grants including pre-emptive Super Admin grants (avoids the M1a 006 follow-up cycle).

### PATCH cycle 1 — driven by Stage 2 escape #1 (TS/Zod-to-fn-body misalignment)

- **019 — `019_m1c_extend_fn_contract_create.sql`** (cycle 1, applied 2026-05-03 19:35Z)

  **Why:** Testing Agent cycle 0 surfaced 4 BE-test failures (AC-S5-08, AC-S4-05, AC-S6-01, AC-S9-05) all sharing one root cause. The M1c TS + Zod schemas extended `CreateContractDto` with 4 new optional fields but `fn_contract_create` (M1a migration 005) was never extended to read them from `p_data`. The BE controller's JSONB pass-through silently dropped them — bulk-imported contracts had NULL `import_batch_id` / `import_filename` / `import_confidence` / `import_warnings`.

  **Fix layer chosen — DB (fn_contract_create body) over BE controller-side UPDATE.** Reasons: (1) single source of truth for all M1a/M1b/M1c callers, (2) atomic INSERT (no INSERT-then-UPDATE race), (3) one audit-log 'created' event not two, (4) no read-between-writes race, (5) backward-compatible (NULL/`[]` defaults preserve M1a/M1b call sites unchanged).

  **What changed:** Signature unchanged (`(p_data JSONB, p_actor_id BIGINT)`) — used CREATE OR REPLACE. Added 4 declarations + 4 reads (`importBatchId`, `importFilename`, `importConfidence`, `importWarnings`); extended INSERT statement column + values lists. All M1a behaviours (validations, contract-number generator, tag loop, fn_contract_get_by_id return, outer EXCEPTION envelope) preserved verbatim.

  **Lesson logged for the Stage 2 checklist (proposed S2-16 — DTO-to-fn-body alignment):**
  > "For every cross-module DTO field extension on a Create/Update/List endpoint, verify the receiving fn_ either (a) explicitly reads the new key from p_data JSONB, or (b) is documented as ignoring the new field by design. No silent drops."

### PATCH cycle 2 — driven by Stage 2 escape #2 (concurrency primitive lost on rewrite) + 1 cycle-1 regression + 2 pre-existing role-gate gaps surfaced by cross-role tests

- **020 — `020_m1c_fix_concurrency_role_gate_and_warnings_default.sql`** (cycle 2, applied 2026-05-03 19:57Z)

  **Why (3 root causes in one migration):**

  1. **Concurrency regression.** Migration 019's CREATE OR REPLACE of `fn_contract_create` copied most of the M1a 005 body but reverted the parent existence check from `PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE FOR UPDATE` (M1a 008 hardening — Codex BE-001) back to the unlocked variant. Concurrent `fn_contract_delete(parent)` + `fn_contract_create(child)` no longer serialised through the parent row lock, allowing orphan children under soft-deleted parents.
  2. **`importWarnings` regression.** Migration 019 used a `COALESCE`-style default of `'[]'::JSONB` whenever the `importWarnings` key was missing or null. The cycle-1 integration test asserts that non-imported M1a contracts have NULL `import_warnings` (column-absent semantics), not empty array. The fix uses the JSONB key-exists operator (`?`) so missing key → NULL, while explicit empty array → `'[]'::jsonb` is preserved.
  3. **Pre-existing M1a `Super Admin` role-gate gap.** `fn_contract_list` computes `v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive')` — the M0 role `Super Admin` (literal name with space) was never added. `fn_import_batch_list` (017) DID include it, exposing the symmetry gap. M1a tests never failed because admin both creates AND lists, satisfying the user-narrowing predicate via `drafted_by`/`created_by`; M1c is the first cross-role create+list test (drafter creates, admin lists).

  **What changed:**

  1. Restored `PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE FOR UPDATE;` on the parent existence check in `fn_contract_create` (verbatim from migration 008 lines 126-130).
  2. Added a parallel `PERFORM 1 FROM import_batch WHERE id = v_import_batch_id AND is_active = TRUE FOR UPDATE; IF NOT FOUND THEN RAISE ...; END IF;` check when `importBatchId` is provided. Defense-in-depth; bad `importBatchId` now raises `fn_contract_create: importBatchId:Import batch not found` (was: SQLSTATE 23503 from FK at INSERT time). Both paths still result in a `fn_contract_create: %` prefixed exception, so the BE controller mapping is unchanged.
  3. Changed `importWarnings` missing-key default from `'[]'::JSONB` to NULL via JSONB key-exists operator.
  4. Added `'Super Admin'` (literal role.name with space) to `v_role_can_see_all` role list in `fn_contract_list`. Parity with `fn_import_batch_list`.

  **Lesson logged for the Stage 2 checklist (proposed S2-17 — concurrency-primitive preservation on function rewrite):**
  > "Any CREATE OR REPLACE / DROP+CREATE of an existing fn_ preserves SELECT FOR UPDATE / FOR SHARE / advisory locks / explicit transaction-isolation hints from the prior version. Diff the function body against the prior canonical source; flag any disappearing concurrency primitive." Critical-severity check given Codex BE-001 historical context.

### PATCH cycle 3 — driven by Codex BE round-1 findings (1 CRITICAL + 1 HIGH + 1 MEDIUM)

Codex BE round-1 review ran post-QA Stage 4 against the Phase 2 BE Implementation. 3 findings, all FIXED in shipped code. Regression PASS 308/308.

- **021 — `021_m1c_fix_rls_anti_reassignment.sql`** (cycle 3, applied 2026-05-04 04:05Z)

  **Codex finding C1 (CRITICAL — RLS self-reference recursion).** Migration 016 policies `import_batch_update_runner_or_admin` and `import_batch_deny_direct_is_active_update` embedded `(SELECT b.<col> FROM import_batch b WHERE b.id = import_batch.id)` inside USING/WITH CHECK to enforce immutability of `initiated_by` and `is_active`. Under FORCE ROW LEVEL SECURITY (set by 016), self-referencing SELECTs trigger RLS re-evaluation — either recursing or returning empty, blocking ALL UPDATEs. The inner `import_batch.id` is not guaranteed to resolve to the OLD row either — the planner can resolve against NEW. Same anti-pattern family as Codex BE-M1b-006; recurring under a new mechanism (anti-reassignment via subquery vs `WITH CHECK = TRUE`).

  **Fix:** Created BEFORE UPDATE trigger `trg_import_batch_immutable_fields` bound to function `fn_trg_import_batch_immutable_fields` that compares OLD vs NEW directly. RAISEs SQLSTATE `42501` (insufficient_privilege) when `initiated_by` or `is_active` changes — message includes both old and attempted values for forensics. BE `translatePgError` maps 42501 → 403 Forbidden, preserving the original UX intent. `SET search_path = public, pg_temp` on the fn (M0 hardening). Then DROP+CREATE `import_batch_update_runner_or_admin` to remove the self-ref WITH CHECK clause (kept the role + ownership filter); DROPped `import_batch_deny_direct_is_active_update` entirely (trigger fully replaces it). Hard-DELETE policy `import_batch_deny_direct_delete` unchanged.

  **Smoke probes (test branch):**

  | # | UPDATE | Expected | Actual | Result |
  |---|---|---|---|---|
  | 1A | `initiated_by = 8` | 42501 | 42501 | PASS |
  | 1B | `is_active = FALSE` | 42501 | 42501 | PASS |
  | 1C | `status = 'paused'` | ok | ok | PASS |
  | 1D | `review_queue + 1` | ok | ok | PASS |

- **022 — `022_m1c_extend_fn_contract_get_by_id_projection.sql`** (cycle 3, applied 2026-05-04 04:05Z)

  **Codex finding H1 (HIGH — get-by-id projection asymmetric to create + list).** `fn_contract_create` (post-019/020) persists 4 import-trace fields. `fn_contract_list` (017) projects 3 of them in list rows. `fn_contract_get_by_id` (last edited in M1a migration 005) was NOT extended — its JSONB projection still ended at `commentCount/createdAt/updatedAt` with no import fields. AC-S5-08 round-trip was therefore asymmetric: bulk-imported contract was visible in list but the 4 fields disappeared when fetched by id.

  **Fix:** CREATE OR REPLACE `fn_contract_get_by_id` (signature unchanged — `(BIGINT, BIGINT, TEXT)`). Append 4 camelCase keys before `createdAt`: `importBatchId`, `importFilename`, `importConfidence`, `importWarnings`. Keys are always present per the additive backward-compat contract — when the underlying column is NULL the JSONB key value is null (not omitted). BE-side type sync: `Contract` interface in `src/types/contracts.types.ts` extended with 4 optional import fields (additive, mirrors the `ContractListItem` M1c additive extension pattern). `npx tsc --noEmit` clean.

  **Note on `fn_contract_list` projection.** The list still keeps its lighter 3-field projection (no `importFilename`) — list rows are deliberately lightweight per AC-S1-08 sensitive-field handling.

- **`src/utils/logger.util.ts` — Codex M1 (MEDIUM, no migration — code-only)**

  **Codex finding M1.** Pino redact paths used wildcard-only paths (e.g. `*.contract_body`, `*.extractedText`). Pino redact wildcards match exactly one nesting level — top-level keys and direct-nested paths (`req.body.extractedText`) were NOT covered.

  **Fix:** For each sensitive field, added explicit complementary paths to the existing wildcard coverage (no existing path removed; no paths added for fields outside the project.config.json `sensitiveFields` allowlist). 7-path cover per field: top-level, `req.body.<key>`, `req.body.*.<key>`, `req.query.<key>`, `req.params.<key>`, `*.<key>`, `*.*.<key>`. Counts: 53 → 275 paths covering 21 sensitive-field forms. The exported `SENSITIVE_REDACT_PATHS: ReadonlyArray<string>` symbol surface is unchanged. tsc clean. M1c integration test `tests/integration/M1c-ai-extract-contract-bulk.test.ts` (AC-S8-06) exercises `extractedText` redaction via stdout capture.

---

## 5. Codex review summary

### Backend round 1 — fixed in shipped code

| Finding | Severity | File | Fix |
|---|---|---|---|
| C1 — RLS self-reference recursion in `import_batch` UPDATE policies | CRITICAL | `database/migrations/021_m1c_fix_rls_anti_reassignment.sql` | BEFORE UPDATE trigger replaces self-ref subquery; 1 policy DROP+CREATE, 1 policy DROPPED. |
| H1 — `fn_contract_get_by_id` projection missing 4 import fields | HIGH | `database/migrations/022_m1c_extend_fn_contract_get_by_id_projection.sql` | CREATE OR REPLACE — append 4 camelCase keys to JSONB projection, always-present per additive contract. |
| M1 — pino redact wildcard-only paths | MEDIUM | `src/utils/logger.util.ts` | 7-path cover per sensitive field (53 → 275 redact paths covering 21 field forms). |

Regression PASS — 308/308 tests green; tsc clean.

### Frontend round 1 — DEFERRED to CRX-9

Status: BLOCKED — Codex quota exhausted 2026-05-03 during BE round 1 follow-up patches. The FE Codex review is deferred as **CRX-9** to be run from the FE repo when quota resets (estimated ~2026-05-09).

**To run CRX-9 when quota resets:**

```bash
cd C:/Users/azureadmin/projects/musanad-contracts/musanad-contracts-frontend
# from inside the FE repo (Codex picks up CWD as the review scope):
/codex:adversarial-review
```

Pair every Codex review with a follow-up writer/patch agent — the Codex sandbox is read-only via `codex:codex-rescue` (it returns findings inline but cannot write review files; user feedback `feedback_codex_sandbox_readonly`).

The 5 FE Codex lessons already proactively embedded in the M1c FE code per the precedent from M1a / M1b reviews (F-FE-001 / F-FE-002 / F-FE-M1 / F-FE-M2 / FE-R2-001) — see [`musanad-contracts-frontend/docs/M1c-frontend.md`](../../musanad-contracts-frontend/docs/M1c-frontend.md). CRX-9 may surface incremental findings; none are blockers for the M1c shipping date since the lessons coverage is already strong.

---

## 6. Cross-module modifications (the most important section)

> Every artifact M1c modified outside its own ownership boundary, with backward-compatibility rationale.

### M0-owned (4 changes)

| Artifact | Change | Migration | Backward-compatible? | Rationale |
|---|---|---|---|---|
| `permission` table | INSERT 2 rows: `import.run`, `import.review` | 018 | YES | Pure additive; ON CONFLICT DO NOTHING idempotent. |
| `role_permission` table | INSERT 7 grants (incl. 2 pre-emptive Super Admin) | 018 | YES | Pure additive; ON CONFLICT DO NOTHING. The Super Admin grants close the M1a-006 follow-up cycle proactively. |
| `fn_audit_trigger` | NOT extended | n/a | YES | Design Note D1 — `import_filename` deliberately not redacted (forensics use case). |
| `src/utils/logger.util.ts` | Redact paths 53 → 275 | n/a | YES | Codex M1 fix; covers 21 sensitive-field forms across all M0/M1a/M1b/M1c sensitive fields. The exported `SENSITIVE_REDACT_PATHS` symbol shape is unchanged — only the array length grew. |

### M1a-owned (5 changes)

| Artifact | Change | Migration | Backward-compatible? | Rationale |
|---|---|---|---|---|
| `contract` table | `ALTER TABLE … ADD CONSTRAINT fk_contract_import_batch_id` (closes M1a forward-reference) | 016 | YES | Idempotent DO block (pg_constraint check). All existing rows have `import_batch_id IS NULL`, so no backfill needed. ON DELETE SET NULL preserves contract rows in test fixtures. |
| `fn_contract_list` | DROP+CREATE — signature widened 15 → 18 params; row JSONB shape +3 fields | 017, then 020 (Super Admin parity) | YES | All 15-positional-arg callers continue to work — new params 16-18 default NULL. New row fields are additive only. Migration 020 added `'Super Admin'` to `v_role_can_see_all` (closed pre-existing M1a gap). |
| `fn_contract_create` | Body extended — reads 4 new optional keys from `p_data`; SELECT FOR UPDATE on `import_batch_id` existence check | 019, then 020 (FOR UPDATE restored + importWarnings NULL-on-missing) | YES | Signature unchanged. 4 new keys are optional; missing-key semantics: NULL (importBatchId, importFilename, importConfidence) / NULL (importWarnings via JSONB `?`). Codex BE-001 lock preserved. |
| `fn_contract_get_by_id` | Body extended — JSONB projection +4 import fields (always present, null when column null) | 022 | YES | Signature unchanged (`(BIGINT, BIGINT, TEXT)`). Round-trip symmetry restored: create → list → get-by-id all expose the same 4 fields. |
| `ContractListItem` / `ContractListQuery` / `CreateContractDto` / `Contract` (TS types) | Each widened with M1c-specific optional fields | n/a | YES | Pure TS additive — existing M1a/M1b callers unaffected. tsc clean (0 errors). FE mirrors verbatim. |

> **Total artifacts touched outside M1c ownership: 4 M0 + 5 M1a + 0 M1b = 9.** All changes are additive and backward-compatible. Existing M1a/M1b integration tests pass without modification.

---

## 7. Test coverage status

### Final state — all-resolved

- **308/308 tests pass.** 23 test files passed in 87.79s (cycle 3 — Codex regression run). 90 new M1c tests across 6 new files; 218 M0/M1a/M1b tests carry over green.
- **3 fix cycles** ran during testing — all root-caused and remediated in shipped code. See §4 for the full migration history.
- **Coverage WARN-band, no FAIL-band:**

  | Metric | Actual | Target (PASS) | WARN band | Status |
  |---|---|---|---|---|
  | Lines | 79.96% | ≥90% | 70–89% | WARN |
  | Functions | 80.45% | ≥90% | 70–89% | WARN |
  | Branches | 72.72% | ≥80% | 60–79% | WARN |
  | Statements | 79.96% | — | — | (mirrors Lines) |

  Per QA Stage 4 Section F protocol, WARN does not block delivery. All three metrics are in the WARN band; none in FAIL. Hot spots: middleware/* (auth/CORS/rate-limit error paths not exercised by happy-path integration tests), utils/* (env-validation/error-translation edge cases), services/uae-pass/* (90.38%). Routes/schemas/services-export/services-ai are at or near 100%.

### Fixture user pool helper — closes the cumulative ~16 deferred role-narrowing test ACs

`tests/helpers/m1c-helpers.ts` was introduced in this module. It seeds and exposes a stable pool of fixture users — `drafter1`, `recipient1`, `approver1`, `approver2`, `executive1`, `legal_counsel1` — that the test suite uses to exercise role-narrowing ACs end-to-end. This closes a cumulative gap of ~16 deferred role-narrowing ACs across M1a + M1b (which previously could only run against the M0 bootstrap admin Super Admin).

One additional purpose: `setImportBatchActiveBypassTrigger(id, value)` helper wraps the test-ARRANGE `UPDATE import_batch SET is_active = ?` in `ALTER TABLE ... DISABLE TRIGGER trg_import_batch_immutable_fields` / `ENABLE TRIGGER` so AC-S3-08 (list excludes soft-deleted) and AC-S4-02 (get-by-id returns null for soft-deleted) tests can seed the soft-deleted state for ARRANGE without triggering Codex C1's intentional production-block. `ALTER TABLE DISABLE TRIGGER` requires only table ownership (which `neondb_owner` has on the test branch); `SET session_replication_role` would have needed SUPERUSER which Neon does not grant.

### Deferred follow-ups (non-blocking)

| ID | Topic | Owner | Severity |
|---|---|---|---|
| DF-1 | Coverage uplift to PASS thresholds (lines 79.96 → 90, branches 72.72 → 80) | Testing Agent next iteration + DB Impl test-branch role config | warn |
| DF-2 | `tests/helpers/setup.ts` should hard-throw on missing `TEST_DATABASE_URL` (currently falls back to `DATABASE_URL` silently) — M0/M1a inheritance, NOT M1c | Testing Agent (one-line) | warn |
| DF-3 | DB-side notifications for AC-S5-07 — toast-only in M1c per Q1 | Future Notifications module | info |
| DF-4 | Playwright / FE component tests for drag-drop UX, modal layout, form layouts | FE QA / Testing Agent next sprint | info |
| DF-5 | Real attachment integration — current Supabase storage upload is best-effort (HQ1) | Future Attachments module | info |
| DF-6 | Resume bulk import after refresh — File handles cannot persist (config preserved via TTL'd draft) | FE / UX (acceptable per FE-INFO-3) | info |
| CRX-9 | FE Codex round 1 — DEFERRED (quota exhausted 2026-05-03) | Run `/codex:adversarial-review` from FE repo when quota resets ~2026-05-09 | medium |

### AC traceability

64 ACs claimed across 9 stories (S1–S9, with S41-* aliases folded into S3+S4). All 9 stories have explicit AC-tagged test cases per `module-M1c-test-report.md`. Specific cycle-2/3 verifications: AC-S5-08, AC-S4-05, AC-S6-01, AC-S9-05, AC-S6-08-NoImport, Codex-BE-001-a, Codex-BE-001-d each ran final verification PASS. The remaining 86 of 90 new M1c ACs were green from cycle 0.

ACs deferred to FE component tests (covered indirectly via integration tests):
- AC-S5-01 (drag-drop UX details — drop-zone hover/animation)
- AC-S5-06 (pause/resume/cancel button visual states)
- AC-S6-05 (reject confirmation modal layout)
- AC-S7-01 (linear form scroll layout — delegates to M1a hardened form)

Fully deferred (DF-3): AC-S5-07 — DB notification rows.

---

## 8. Known limitations and design ratifications

### HITL Gate 2 ratifications (decisions baked into the implementation)

| ID | Decision | Where it lands |
|---|---|---|
| **HQ1** | Storage: FE-direct upload to Supabase 'contracts' bucket; no BE storage abstraction; no attachments table. | `src/features/imports/lib/upload-to-storage.ts` (FE). BE never sees file bytes — only extractedText + filename + size. |
| **HQ2** | AI stub DTO frozen for M4 drop-in. Union of CreateContractDto + `{ importConfidence, importWarnings, detectedDuplicateContractNumber? }`. | `ExtractContractBulkResponse` schema in `src/types/import-batch.types.ts` and `docs/api/openapi.yaml`. |
| **HQ3** | `fn_contract_list` backward-compat: DROP+CREATE; new params optional with DEFAULT NULL; new response fields always present. | `017_m1c_import_functions.sql` (DROP+CREATE 15→18 params). |
| **HQ4** | `contract_drafter` `import.review`: grant both, narrow via RLS + fn `v_role_can_see_all` gate. | `018_m1c_import_permissions_and_grants.sql` (grants both); `017` `fn_import_batch_list` `v_role_can_see_all` gate excludes contract_drafter from see-all. |

### Other limitations

- **Notifications are toast-only (per Q1 deferral).** AC-S5-07 'notifications fired at start/progress/complete' is satisfied via Sonner toasts only; DB-side `fn_notification_create_bulk` does not exist in M1c. A future Notifications module will add server-side notification rows.
- **AI is a deterministic mock (per HQ2).** `POST /api/v1/ai/extract-contract-bulk` is controller-only — no fn_, no DB persistence. M4 will replace the controller body with a real AI provider call WITHOUT changing route, auth, request DTO, or response DTO. Confidence formula: `round(min(95, max(20, extractedText.length / 100)))` — pure deterministic function.
- **`contract_drafter` own-narrowing happens at RLS not at permission level (per HQ4).** Both `import.run` AND `import.review` are granted to drafters; the see-all narrowing is enforced inside `fn_import_batch_list`'s `v_role_can_see_all` gate AND by the `import_batch_select_role_aware` PERMISSIVE SELECT policy (defense in depth).
- **RLS functional verification limited by `neondb_owner` bypassrls.** The migration-runner connection role has `rolbypassrls=TRUE`, so the RLS policies cannot be exercised end-to-end from this agent's verification step. Definitions were inspected and confirmed correct; in-fn defense-in-depth (`v_role_can_see_all` gate) was functionally validated; production enforcement happens via the BE app's per-request role switch (M1a/M1b precedent).

### Operational gotchas

- **The BEFORE UPDATE trigger blocks direct `is_active` toggles.** Test fixtures that need to flip `is_active` for setup MUST use `setImportBatchActiveBypassTrigger` helper (`tests/helpers/m1c-helpers.ts`) which wraps the UPDATE in `ALTER TABLE ... DISABLE TRIGGER trg_import_batch_immutable_fields ... ENABLE TRIGGER`. **Production code must NEVER attempt to flip `is_active` directly** — cancellation goes through `status='cancelled'` instead.
- **`initiated_by` is immutable.** Direct UPDATE of `import_batch.initiated_by` raises SQLSTATE 42501 → BE 403. There is no fn that supports operator reassignment; if a user is offboarded mid-batch, the batch should be cancelled (status='cancelled') and a new batch started by another operator.
- **Per-file save serialises against parent + batch.** `fn_contract_create` takes `SELECT FOR UPDATE` on both `parent_contract_id` (when set) AND `import_batch_id` (when set) before INSERT. Concurrent `fn_contract_delete(parent)` + `fn_contract_create(child)` is now correctly serialised (Codex BE-001 lock restored in 020). Concurrent admin soft-delete of a batch is also serialised against per-file inserts into that batch.

---

## 9. How to extend M1c

**To add a new field to `import_batch`:**
1. Create a new migration: `ALTER TABLE import_batch ADD COLUMN <col> <type>`. If sensitive, also extend `fn_audit_trigger` redact list AND `src/utils/logger.util.ts` `SENSITIVE_PATHS` (7-path cover per Codex M1).
2. Update `fn_import_batch_create` and `fn_import_batch_update` to read the new field. If counter-like, add to `chk_import_batch_counter_sum` and update overflow guard.
3. Update `fn_import_batch_get_by_id` JSONB projection. List rows: decide if it goes in the lighter `fn_import_batch_list` projection too (matching the contract list pattern).
4. Update `src/types/import-batch.types.ts` `ImportBatch` interface + `src/schemas/import-batch.schemas.ts` Zod.
5. Run `/state-update` to refresh the artifact store.

**To add a new AI endpoint (M4):**
1. Append a new route in `src/routes/v1/ai.routes.ts`.
2. Follow the M1c S8 stub conventions (documented in api-contracts.json `_aiNamespaceConvention`): JWT required, controller-level permission check (no fn for stubs), `authedWriteRateLimiter`, pino-redact `ai_prompt_payload` payloads, FROZEN request + response DTOs.
3. Extend `src/utils/logger.util.ts` `SENSITIVE_PATHS` if the new endpoint accepts a new sensitive payload class.
4. M4 will REPLACE the body of `extract-contract-bulk.controller.ts` without changing the route, auth, or DTO. Use the same pattern for new endpoints.

**To add a new transition rule on import_batch.status:**
1. Update `fn_import_batch_update` allowed-transition logic.
2. Update the AC-S2-02 documentation in `db-design.md` (workspace) and `M1c-data-dictionary.md` (this repo).
3. Update OpenAPI `ImportBatchStatus` schema description.
4. Add a regression test in `tests/db/M1c-import-batch-functions.test.ts`.

---

## 10. Pointers to upstream artifacts

- DB design: workspace `.claude/workspace/current-module/db-design.md` (Agent 4 v2.1 output).
- Requirements: workspace `.claude/workspace/current-module/requirements-analysis.json` (Agent 2 — 9 stories, 64 ACs, 2 epics).
- Collision report: workspace `.claude/workspace/current-module/collision-report.json` (Agent 3 — 32 new artifacts, 4 additive extensions, 14 reuse-confirmed).
- API contracts: workspace `.claude/workspace/current-module/api-contracts.json` (Agent 5 — 5 new endpoints, 1 extended).
- DB Implementation summary: workspace `.claude/workspace/current-module/db-impl-summary.json` (5 migrations applied across 3 cycles + 2 Codex patches).
- BE Implementation summary: workspace `.claude/workspace/current-module/be-implementation-summary.json` (7 created + 6 modified files).
- FE Implementation summary: workspace `.claude/workspace/current-module/fe-implementation-summary.json` (20 created + 5 modified; 5 components hardened + 1 regenerated).
- Test report (final): workspace `.claude/workspace/current-module/module-M1c-test-report.md` (308/308 PASS after 3 fix cycles).
- QA Stage 4 result: workspace `.claude/workspace/current-module/qa-stage4-result.json` (44 checks · 41 PASS · 3 WARN · 0 FAIL · PASS-WITH-WARNINGS).
- Codex BE patch summary: workspace `.claude/workspace/current-module/codex-be-patch-summary.md` (M1 + C1 + H1 fixed in shipped code).
- File manifest: workspace `.claude/workspace/current-module/module-M1c-file-manifest.json` (BE + FE file lists).

---

## 11. Files owned by this module

### Backend (created — 7)

```
src/types/import-batch.types.ts
src/schemas/import-batch.schemas.ts
src/controllers/import-batch.controller.ts
src/controllers/ai/extract-contract-bulk.controller.ts
src/services/ai/extract-contract-bulk.service.ts
src/routes/v1/import-batches.routes.ts
src/routes/v1/ai.routes.ts
```

### Backend (modified — 6)

```
src/types/contracts.types.ts            (additive M1c extensions on Contract / Create / List interfaces)
src/schemas/contracts.schemas.ts        (additive Zod extensions on createContractSchema + contractListQuerySchema)
src/controllers/contracts.controller.ts (fn_contract_list call site widened 15 → 18 args)
src/routes/v1/index.ts                  (mounts /api/v1/import-batches and /api/v1/ai routers)
src/database/client.ts                  (translatePgError extensions: 404:/permission:/status:Invalid status transition/fk_contract_import_batch_id 23503)
src/utils/logger.util.ts                (Codex M1: 53 → 275 redact paths covering 21 sensitive-field forms)
```

### Database (created — 7 migrations)

```
database/migrations/016_m1c_import_batch.sql                                           (original)
database/migrations/017_m1c_import_functions.sql                                       (original)
database/migrations/018_m1c_import_permissions_and_grants.sql                          (original)
database/migrations/019_m1c_extend_fn_contract_create.sql                              (PATCH cycle 1)
database/migrations/020_m1c_fix_concurrency_role_gate_and_warnings_default.sql         (PATCH cycle 2)
database/migrations/021_m1c_fix_rls_anti_reassignment.sql                              (PATCH cycle 3 — Codex C1 CRITICAL)
database/migrations/022_m1c_extend_fn_contract_get_by_id_projection.sql                (PATCH cycle 3 — Codex H1 HIGH)
```

### Tests (new files)

```
tests/db/M1c-import-batch-functions.test.ts
tests/db/M1c-forward-fk.test.ts
tests/db/M1c-cross-module-fn-contract-list.test.ts
tests/integration/M1c-import-batches.test.ts
tests/integration/M1c-ai-extract-contract-bulk.test.ts
tests/integration/M1c-cross-module-extension.test.ts
tests/helpers/m1c-helpers.ts                (fixture user pool — closes ~16 deferred role-narrowing ACs)
```

---

*M1c technical handoff v1.0 — Documentation Generator (Agent 15) v3.0. Pipeline status: complete. Ready for git commit.*
