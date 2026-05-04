# M1c — Bulk & Manual Import — Data Dictionary

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M1c — Bulk & Manual Import
> **Generated:** 2026-05-03
> **Source migrations:**
> - `database/migrations/016_m1c_import_batch.sql`
> - `database/migrations/017_m1c_import_functions.sql`
> - `database/migrations/018_m1c_import_permissions_and_grants.sql`
> - `database/migrations/019_m1c_extend_fn_contract_create.sql` (PATCH cycle 1)
> - `database/migrations/020_m1c_fix_concurrency_role_gate_and_warnings_default.sql` (PATCH cycle 2)
> - `database/migrations/021_m1c_fix_rls_anti_reassignment.sql` (PATCH cycle 3 — Codex C1)
> - `database/migrations/022_m1c_extend_fn_contract_get_by_id_projection.sql` (PATCH cycle 3 — Codex H1)
> **Neon project:** `musanad-contracts` (id `patient-morning-04972561`)
> **Branches at v22:** `m0-foundation` (`br-snowy-brook-aje2ehtl`) + `test` (`br-billowing-boat-ajq9m0g6`).

This document is the canonical reference for every M1c database object: 1 new table (`import_batch`, 17 columns including 5 mutable counters), 4 owned `fn_` functions (S1–S4), 3 cross-module fn_ extensions on M1a (`fn_contract_create`, `fn_contract_list`, `fn_contract_get_by_id`), 1 BEFORE UPDATE trigger function, 1 audit trigger binding, 4 final-state RLS policies (5 created in 016, 1 dropped in 021), 7 indexes, 2 new permissions, and 7 role_permission grants.

The audit redact list is intentionally NOT extended for `import_filename` per Design Note D1 — filenames are useful audit forensics breadcrumbs, not classified PII in `project.config.json`. The AI-extraction stub treats `extractedText` as `ai_prompt_payload` (project.config.json sensitiveFields) — pino-redacted across 7 paths in `src/utils/logger.util.ts` (Codex M1 fix).

Cancellation is a status transition (`status='cancelled'`), NOT `is_active=false`. `is_active` is reserved for future administrative archive; the `trg_import_batch_immutable_fields` BEFORE UPDATE trigger blocks any direct flip of `is_active` or `initiated_by` (Codex C1 fix, migration 021).

---

## Migration history (M1c)

| # | Filename | Purpose | Cycle |
|---|---|---|---|
| 016 | `016_m1c_import_batch.sql` | NEW table `import_batch` (17 cols, 2 multi-col CHECKs); 7 indexes; 5 RLS policies; ENABLE + FORCE RLS; audit trigger binding; `ALTER TABLE contract ADD CONSTRAINT fk_contract_import_batch_id` (idempotent DO block — closes M1a forward-reference). | original |
| 017 | `017_m1c_import_functions.sql` | DROP+CREATE `fn_contract_list` (15→18 param signature, AE-1); CREATE OR REPLACE 4 new `fn_import_batch_*` functions (S1–S4). | original |
| 018 | `018_m1c_import_permissions_and_grants.sql` | INSERT 2 permissions (`import.run`, `import.review`); INSERT 7 role_permission grants including pre-emptive Super Admin grants (M1a 006 lesson). All ON CONFLICT DO NOTHING. | original |
| 019 | `019_m1c_extend_fn_contract_create.sql` | CREATE OR REPLACE `fn_contract_create` (signature unchanged) — body extended to read `importBatchId`, `importFilename`, `importConfidence`, `importWarnings` from `p_data` JSONB. Caught by Testing Agent cycle 0 (4 BE-test failures sharing one root cause: silent drop of M1c-extended Create DTO fields). | PATCH cycle 1 |
| 020 | `020_m1c_fix_concurrency_role_gate_and_warnings_default.sql` | CREATE OR REPLACE `fn_contract_create` — restored Codex BE-001 `SELECT 1 FROM contract WHERE id = v_parent_id ... FOR UPDATE` (lost in 019); changed `importWarnings` missing-key default `'[]'::jsonb` → NULL via JSONB `?` key-exists operator; added `SELECT 1 FROM import_batch WHERE id = v_import_batch_id ... FOR UPDATE` defense-in-depth. CREATE OR REPLACE `fn_contract_list` — added `'Super Admin'` literal to `v_role_can_see_all` role list (parity with `fn_import_batch_list`; closed pre-existing M1a gap). | PATCH cycle 2 |
| 021 | `021_m1c_fix_rls_anti_reassignment.sql` | NEW trigger fn `fn_trg_import_batch_immutable_fields` + BEFORE UPDATE binding `trg_import_batch_immutable_fields` (RAISEs SQLSTATE 42501 on `initiated_by` / `is_active` change). DROP+CREATE policy `import_batch_update_runner_or_admin` (removed self-referencing subquery anti-reassignment WITH CHECK clause — replaced by trigger). DROPped policy `import_batch_deny_direct_is_active_update` entirely (trigger replaces it). | PATCH cycle 3 (Codex C1, CRITICAL) |
| 022 | `022_m1c_extend_fn_contract_get_by_id_projection.sql` | CREATE OR REPLACE `fn_contract_get_by_id` (signature unchanged) — JSONB projection extended with 4 import-trace fields: `importBatchId`, `importFilename`, `importConfidence`, `importWarnings`. Always present in projection; NULL when underlying column NULL. Closes round-trip asymmetry between create / list / get-by-id. | PATCH cycle 3 (Codex H1, HIGH) |

Both Neon branches (m0-foundation + test) currently at `schema_migrations` version 22.

---

## Tables

### 1. `import_batch` (M1c-owned)

**Purpose.** One row per bulk-import session. Captures batch defaults (`config` JSONB), running counters (5 of them — `auto_saved` / `review_queue` / `manual_entry` / `duplicates_skipped` / `errored`), lifecycle status, and audit columns.
**Owned by:** M1c. **Audit columns:** full. **RLS:** enabled + forced. **Soft delete:** `is_active` (governed by trigger — see §6).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `initiated_by` | BIGINT | NOT NULL, FK → `"user"(id) ON DELETE RESTRICT` | Operator identity (system fact — RESTRICT prevents losing operator identity when batches exist). RLS WITH CHECK + trigger forbid reassignment (Codex BE-M1b-006 + C1). |
| `config` | JSONB | NOT NULL DEFAULT `'{}'::jsonb` | Batch defaults (camelCase keys): `{ contractType?: string, statusMode: 'active'|'draft'|'auto', defaultCounterpartyId?: number }`. Validated at fn entry, not a CHECK on the table (Design Note D6). |
| `total_files` | INTEGER | NOT NULL, CHECK (`>= 1`) | Up-front file count, set on create; immutable thereafter. |
| `auto_saved` | INTEGER | NOT NULL DEFAULT 0, CHECK (`>= 0`) | Counter — files routed to auto-save (high-confidence) track. |
| `review_queue` | INTEGER | NOT NULL DEFAULT 0, CHECK (`>= 0`) | Counter — files routed to human review queue (medium-confidence). |
| `manual_entry` | INTEGER | NOT NULL DEFAULT 0, CHECK (`>= 0`) | Counter — files routed to manual-entry track (low-confidence / extraction failed). |
| `duplicates_skipped` | INTEGER | NOT NULL DEFAULT 0, CHECK (`>= 0`) | Counter — files skipped because FE pre-check matched an existing contract (AC-S5-09). |
| `errored` | INTEGER | NOT NULL DEFAULT 0, CHECK (`>= 0`) | Counter — files that failed extraction or upload entirely (OI-6 / Design Note D3). Without this, batches with errors could never reach `status='completed'`. |
| `status` | VARCHAR(20) | NOT NULL DEFAULT `'in_progress'`, CHECK (in `('in_progress','paused','completed','cancelled')`) | 4-value lifecycle enum. Cancellation is a transition here, NOT `is_active=false`. |
| `started_at` | TIMESTAMPTZ | NOT NULL DEFAULT `CURRENT_TIMESTAMP` | Set at row creation. |
| `completed_at` | TIMESTAMPTZ | nullable | Set by `fn_import_batch_update` when status transitions to terminal (completed | cancelled). Declaratively enforced by `chk_import_batch_completed_at_status`. |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT `CURRENT_TIMESTAMP` | Audit. |
| `updated_at` | TIMESTAMPTZ | NOT NULL DEFAULT `CURRENT_TIMESTAMP` | Audit. |
| `created_by` | BIGINT | nullable, FK → `"user"(id) ON DELETE SET NULL` | Audit. |
| `updated_by` | BIGINT | nullable, FK → `"user"(id) ON DELETE SET NULL` | Audit. |
| `is_active` | BOOLEAN | NOT NULL DEFAULT `TRUE` | Soft-delete flag. **Locked** by `trg_import_batch_immutable_fields` — direct flips raise SQLSTATE 42501 (BE 403). Reserved for future administrative archive. |

**Multi-column CHECK constraints:**

| Name | Predicate | Purpose |
|---|---|---|
| `chk_import_batch_counter_sum` | `auto_saved + review_queue + manual_entry + duplicates_skipped + errored <= total_files` | AC-S2-05 overflow guard, declarative defense-in-depth (Design Note D3). |
| `chk_import_batch_completed_at_status` | `(status IN ('completed','cancelled') AND completed_at IS NOT NULL) OR (status IN ('in_progress','paused') AND completed_at IS NULL)` | Lifecycle invariant (Design Note D2). |

**Indexes (7):**

| Index | Columns | Type | Predicate | Purpose |
|---|---|---|---|---|
| `idx_import_batch_active` | `(id)` | BTREE | `WHERE is_active = TRUE` | Soft-delete partial index — every table with `is_active` gets one. |
| `idx_import_batch_initiated_by` | `(initiated_by)` | BTREE | `WHERE is_active = TRUE` | FK index + role-narrowing predicate `initiated_by = current_user_id`. |
| `idx_import_batch_started_at_desc` | `(started_at DESC, id DESC)` | BTREE | `WHERE is_active = TRUE` | Powers `fn_import_batch_list` ORDER BY (AC-S3-01). |
| `idx_import_batch_status` | `(status)` | BTREE | `WHERE is_active = TRUE` | Status filter on AdminImports list (AC-S3-03). |
| `idx_import_batch_status_live` | `(id)` | BTREE | `WHERE status IN ('in_progress','paused') AND is_active = TRUE` | Live-batches dashboard / partial index for live states. |
| `idx_import_batch_created_by` | `(created_by)` | BTREE | `WHERE created_by IS NOT NULL` | Audit. |
| `idx_import_batch_updated_by` | `(updated_by)` | BTREE | `WHERE updated_by IS NOT NULL` | Audit. |

**Foreign keys:**

| Column | References | On Delete |
|---|---|---|
| `initiated_by` | `"user"(id)` | RESTRICT |
| `created_by` | `"user"(id)` | SET NULL |
| `updated_by` | `"user"(id)` | SET NULL |

**Triggers:**

- `audit_import_batch_changes` — `AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger()`. M0-owned audit logger; redacts sensitive field names per the M0 SENSITIVE_FIELD_NAMES array (extended by M1a 004 for `body_en`/`body_ar`; M1c does NOT extend — Design Note D1).
- `trg_import_batch_immutable_fields` — `BEFORE UPDATE FOR EACH ROW EXECUTE FUNCTION fn_trg_import_batch_immutable_fields()`. Codex C1 fix (migration 021) — RAISEs SQLSTATE 42501 on any direct change to `initiated_by` or `is_active`.

---

### 2. `contract` (M1a-owned, M1c-extended)

M1c does NOT add columns to `contract` — all four columns (`import_batch_id`, `import_filename`, `import_confidence`, `import_warnings`) already shipped in M1a. M1c adds the FK constraint that was deferred:

```sql
ALTER TABLE contract
  ADD CONSTRAINT fk_contract_import_batch_id
  FOREIGN KEY (import_batch_id) REFERENCES import_batch(id) ON DELETE SET NULL;
```

Idempotent — wrapped in a `DO $$ ... $$;` block that checks `pg_constraint`.

The existing partial index `idx_contract_import_batch_id` (M1a, `WHERE import_batch_id IS NOT NULL`) supports this FK without performance regression. ON DELETE SET NULL preserves `contract` rows when a batch is hard-deleted (test fixtures only — production hard-delete blocked by RLS).

| Column (M1a-owned, M1c-FK closes) | Type | Constraints | Description |
|---|---|---|---|
| `import_batch_id` | BIGINT | nullable, FK → `import_batch(id) ON DELETE SET NULL` (NEW in 016) | Bulk-import session this contract belongs to. NULL for non-imported contracts. |
| `import_filename` | VARCHAR(500) | nullable | Original uploaded filename. Persists unredacted (Design Note D1). |
| `import_confidence` | INTEGER | nullable, CHECK (`0..100`) | AI extraction confidence. |
| `import_warnings` | JSONB | nullable | Array of human-readable AI warnings. Key-exists semantics post-020 (missing → NULL; explicit `[]` → preserved). |

---

## Functions

### M1c-owned (4)

#### `fn_import_batch_create(p_data JSONB, p_actor_id BIGINT) RETURNS JSONB`
**Type:** Write.
**Security:** INVOKER. **Volatility:** VOLATILE (default). **search_path:** `public, pg_temp`.

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `p_data` | JSONB | Yes | — | Request payload (camelCase keys: `totalFiles`, `config?`). |
| `p_actor_id` | BIGINT | Yes | — | Caller user id (drives audit + `initiated_by`). |

**Returns:** Full `ImportBatch` JSONB (delegates to `fn_import_batch_get_by_id(v_id, p_actor_id)`).

**Business rules:**
- AC-S1-04 — Validates caller has `import.run` via `fn_current_user_has_permission` (RAISEs `permission:Forbidden` → 403).
- AC-S1-02 — `totalFiles >= 1` (RAISEs `totalFiles:totalFiles must be at least 1` → 400).
- AC-S1-03 — `config.statusMode` ∈ `(active|draft|auto)` when present.
- `config.contractType` ∈ M1a 8-value list (`service|employment|vendor|partnership|lease|license|nda|other`) when present — hardcoded in fn body with cross-ref comment to M1a migration 003.
- AC-S1-05 — `initiated_by = p_actor_id` (NOT a body field; RLS WITH CHECK forbids impersonation).

**Error conditions:** All RAISEs follow `fn_import_batch_create: <field>:<message>` pattern; BE error mapper splits `:` to produce `{field, message}` envelope.

#### `fn_import_batch_update(p_id BIGINT, p_actor_id BIGINT, p_status TEXT DEFAULT NULL, p_auto_saved_delta INTEGER DEFAULT 0, p_review_queue_delta INTEGER DEFAULT 0, p_manual_entry_delta INTEGER DEFAULT 0, p_duplicates_skipped_delta INTEGER DEFAULT 0, p_errored_delta INTEGER DEFAULT 0) RETURNS JSONB`
**Type:** Write.
**Security:** INVOKER. **search_path:** `public, pg_temp`.

**Returns:** Full `ImportBatch` JSONB (delegates to `fn_import_batch_get_by_id`).

**Business rules:**
- Step 1 — `SELECT * FROM import_batch WHERE id = p_id AND is_active = TRUE FOR UPDATE` (Codex BE-001 lock; Design Note D8). NOT FOUND → RAISE `404:Import batch not found` → BE 404.
- AC-S2-07 — Defense-in-depth permission check: caller must have `import.run` OR `initiated_by = p_actor_id`. RAISEs `permission:Forbidden` → 403.
- Counter math is run for ALL deltas (no short-circuit) so the failing field is reported correctly:
  - AC-S2-04 underflow guard — per-counter `< 0` raises `<counterName>:Counter underflow` (e.g. `autoSaved:Counter underflow`) → 400.
  - AC-S2-05 overflow guard — sum of 5 new counters `> total_files` raises `counters:Counter overflow vs totalFiles` → 400. Backed by `chk_import_batch_counter_sum` declarative CHECK.
- AC-S2-02 — Status transition validation: only `in_progress↔paused` and either to `completed`/`cancelled` are permitted; terminal states have no outgoing transitions (AC-S2-08). Otherwise RAISEs `status:Invalid status transition` → BE 409.
- AC-S2-03 — On transition to `completed`/`cancelled`, `completed_at = CURRENT_TIMESTAMP` set in same transaction. Backed by `chk_import_batch_completed_at_status` declarative CHECK.

#### `fn_import_batch_list(p_page INTEGER DEFAULT 1, p_limit INTEGER DEFAULT 20, p_status TEXT DEFAULT NULL, p_initiated_by BIGINT DEFAULT NULL, p_actor_id BIGINT DEFAULT NULL, p_actor_role TEXT DEFAULT NULL) RETURNS JSONB`
**Type:** Read. **STABLE.**
**Security:** INVOKER. **search_path:** `public, pg_temp`.

**Returns:** `{ data: ImportBatchListItem[], pagination: { total, page, limit, totalPages } }`.

**Business rules:**
- AC-S3-05 — Pagination clamped to `[1, 100]`; `page >= 1`.
- AC-S3-01 — `ORDER BY started_at DESC, id DESC`.
- AC-S3-02 — Empty result returns `data: []` + `totalPages = 0` (NOT an error; M1a 007 patch precedent).
- AC-S3-07 — Role narrowing: `v_role_can_see_all := p_actor_role IN ('platform_admin','legal_counsel','executive','Super Admin')`. Non-admin callers see only `initiated_by = p_actor_id`. Defense-in-depth via RLS (`import_batch_select_role_aware`) below.
- AC-S3-08 — `is_active = FALSE` rows universally excluded.
- Permission gate is upstream (controller checks `anyOf(import.review, import.run)`); fn enforces row visibility.

#### `fn_import_batch_get_by_id(p_id BIGINT, p_actor_id BIGINT DEFAULT NULL) RETURNS JSONB`
**Type:** Read. **STABLE.**
**Security:** INVOKER. **search_path:** `public, pg_temp`.

**Returns:** Full `ImportBatch` JSONB or NULL.

**Business rules:**
- Returns NULL when row not found OR `is_active=FALSE` OR not visible per RLS (Design Note D7 — matches M1a `fn_contract_get_by_id` pattern). BE controller maps NULL → 404 with `Import batch not found`. Avoids leaking existence to unauthorised callers.
- AC-S4-04 — `initiatedBy` hydrated as `UserRef { id, firstName, lastName }` via M0 `fn_user_get_by_id`.

### M1a-owned, M1c-extended (3)

#### `fn_contract_list` — signature widened 15→18 params (migration 017; further amended in 020)
DROP+CREATE pattern (Postgres CREATE OR REPLACE cannot change parameter list — Design Note D5). Three new optional params appended; row JSONB shape gains 3 new fields. All M1a/M1b 15-positional-arg callers continue to work — new params 16–18 default to NULL.

**New parameters:**

| Parameter | Type | Default | Used by | Description |
|---|---|---|---|---|
| `p_import_batch_id` | BIGINT | NULL | S4 admin drill-down | AC-S4-05 — filter to a single batch. |
| `p_import_confidence_min` | INTEGER | NULL | S6 review queue | AC-S6-01 — lower bound 0..100. |
| `p_import_confidence_max` | INTEGER | NULL | S6 review queue | AC-S6-01 — upper bound 0..100. |

**New row fields (always present, null when underlying column null):** `importBatchId`, `importConfidence`, `importWarnings`.

**Migration 020 amendment:** added `'Super Admin'` to the `v_role_can_see_all` role list — closes a pre-existing M1a gap surfaced by the M1c cross-role tests (admin lists drafter-created contracts). Parity with `fn_import_batch_list`.

#### `fn_contract_create` — body extended (migrations 019 + 020)
Signature unchanged (`(p_data JSONB, p_actor_id BIGINT)`). Body reads 4 new optional keys from `p_data`:

| Read key | Persists to | Notes |
|---|---|---|
| `importBatchId` | `contract.import_batch_id` (BIGINT) | Migration 020 also adds `SELECT 1 FROM import_batch WHERE id = v_import_batch_id AND is_active = TRUE FOR UPDATE` defense-in-depth; bad id raises `importBatchId:Import batch not found` (was: SQLSTATE 23503 from FK at INSERT time). Both error paths surface as 400. |
| `importFilename` | `contract.import_filename` (TEXT) | Persists unredacted (Design Note D1). |
| `importConfidence` | `contract.import_confidence` (INTEGER 0..100) | In-fn range guard fires before column CHECK so error envelope is structured (`importConfidence:Confidence must be between 0 and 100`). |
| `importWarnings` | `contract.import_warnings` (JSONB) | Migration 020 changed missing-key default from `'[]'::jsonb` to NULL via JSONB `?` operator: missing → NULL, explicit `[]` → `'[]'::jsonb`, populated → preserved. |

**Migration 020 also restored** the `SELECT 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE FOR UPDATE` Codex BE-001 lock (lost when 019 used CREATE OR REPLACE without preserving the M1a 008 hardening). Backed by `tests/integration/M1a-contracts-concurrency.test.ts` regression coverage.

#### `fn_contract_get_by_id` — projection extended (migration 022)
Signature unchanged (`(p_id BIGINT, p_actor_id BIGINT, p_actor_role TEXT)`). JSONB projection extends with 4 camelCase keys before `createdAt`: `importBatchId`, `importFilename`, `importConfidence`, `importWarnings`. Always present in projection — null when underlying column null. Closes the round-trip asymmetry between create / list / get-by-id (Codex H1 finding).

### Trigger function (1)

#### `fn_trg_import_batch_immutable_fields() RETURNS TRIGGER`
**Type:** Trigger.
**Security:** INVOKER. **search_path:** `public, pg_temp`.

Compares OLD vs NEW directly. RAISEs SQLSTATE `42501` (insufficient_privilege) when:
- `OLD.initiated_by IS DISTINCT FROM NEW.initiated_by` — message includes both old and attempted values for forensics.
- `OLD.is_active IS DISTINCT FROM NEW.is_active` — message: `is_active cannot be toggled directly (use status=cancelled)`.

BE `translatePgError` maps SQLSTATE 42501 → 403 Forbidden, preserving the original UX intent.

Replaces the prior self-referencing-subquery WITH CHECK clauses on `import_batch_update_runner_or_admin` and the entirely-dropped `import_batch_deny_direct_is_active_update` policy (Codex C1 fix — same anti-pattern family as Codex BE-M1b-006).

---

## RLS policies (final state — 4 policies after migration 021)

### `import_batch` — Row Level Security

`ALTER TABLE import_batch ENABLE ROW LEVEL SECURITY;`
`ALTER TABLE import_batch FORCE ROW LEVEL SECURITY;` — defense-in-depth (M1a precedent). `FORCE` makes RLS apply even to the table owner.

| # | Policy name | Op | Type | USING / WITH CHECK |
|---|---|---|---|---|
| 1 | `import_batch_select_role_aware` | SELECT | PERMISSIVE | USING: `is_active=TRUE AND (role ∈ {platform_admin, legal_counsel, executive, Super Admin} OR initiated_by = current_user_id)` |
| 2 | `import_batch_insert_runner` | INSERT | PERMISSIVE | WITH CHECK: `fn_current_user_has_permission('import.run') AND initiated_by = current_user_id` |
| 3 | `import_batch_update_runner_or_admin` | UPDATE | PERMISSIVE | USING + WITH CHECK: `is_active=TRUE AND (role ∈ {platform_admin, legal_counsel, Super Admin} OR initiated_by = current_user_id)`. Anti-reassignment is now enforced by `trg_import_batch_immutable_fields` BEFORE UPDATE trigger — the prior self-referencing subquery clause was REMOVED in migration 021 (Codex C1 fix). |
| 4 | `import_batch_deny_direct_delete` | DELETE | RESTRICTIVE | USING: `FALSE` — hard-delete forbidden universally. |

**Dropped in migration 021:** `import_batch_deny_direct_is_active_update` (RESTRICTIVE UPDATE) — replaced by the BEFORE UPDATE trigger which enforces `is_active` immutability cleanly without RLS self-reference.

**Why platform_admin / legal_counsel / Super Admin / executive AND NOT contract_drafter in the see-all SELECT list?** A `contract_drafter` with `import.review` is naturally narrowed to own batches per HQ4. The fn ALSO enforces this (defense-in-depth) via `v_role_can_see_all` in `fn_import_batch_list`.

> **Operational gotcha.** Production fn calls switch to a non-bypass-RLS role per request via `SET LOCAL app.current_user_id` middleware. The migration runner connection (`neondb_owner`) has `rolbypassrls=TRUE`, so RLS does not apply during functional verification — same constraint as M1a/M1b RLS-enforcement pattern. Test fixtures that need to flip `is_active` for setup MUST use `setImportBatchActiveBypassTrigger` helper (`tests/helpers/m1c-helpers.ts`) which wraps the UPDATE in `ALTER TABLE ... DISABLE TRIGGER trg_import_batch_immutable_fields ... ENABLE TRIGGER`. `SET session_replication_role` would need SUPERUSER which Neon does not grant.

---

## Permissions and grants (M1c-introduced)

### New permissions (2)

| Code | Module | Action | Description |
|---|---|---|---|
| `import.run` | `import` | `run` | Initiate and operate an import batch (create, update counters, pause/resume/cancel). |
| `import.review` | `import` | `review` | View import batches across users (admin oversight). Required for the Admin Imports list and per-batch drill-down. |

### New role_permission grants (7)

| Role | Permission | Notes |
|---|---|---|
| `platform_admin` | `import.run` | Run + review oversight. |
| `platform_admin` | `import.review` | Run + review oversight. |
| `legal_counsel` | `import.review` | Review-only — does not initiate batches. |
| `contract_drafter` | `import.run` | Own-narrowed via RLS + fn `v_role_can_see_all` gate (HQ4). |
| `contract_drafter` | `import.review` | Own-narrowed via RLS + fn `v_role_can_see_all` gate (HQ4). |
| `Super Admin` | `import.run` | **Pre-emptive M0 grant per M1a 006 lesson** — bootstrap admin gets every new permission so no follow-up patch is required. |
| `Super Admin` | `import.review` | Pre-emptive M0 grant per M1a 006 lesson. |

`INSERT ... ON CONFLICT DO NOTHING` makes the migration idempotent.

---

## ER diagram fragment — `import_batch` ↔ `contract`

```
                     ┌──────────────────────────────────┐
                     │            import_batch          │
                     │ ───────────────────────────────  │
                     │ id              BIGSERIAL PK     │
                     │ initiated_by    BIGINT NN FK ───┐│
                     │ config          JSONB NN        ││
                     │ total_files     INTEGER NN >=1  ││
                     │ auto_saved      INTEGER NN >=0  ││
                     │ review_queue    INTEGER NN >=0  ││
                     │ manual_entry    INTEGER NN >=0  ││
                     │ duplicates_skipped INTEGER NN   ││
                     │ errored         INTEGER NN >=0  ││
                     │ status          VARCHAR(20) NN  ││
                     │ started_at      TIMESTAMPTZ NN  ││
                     │ completed_at    TIMESTAMPTZ NULL││
                     │ created_at … is_active (audit)  ││
                     └──────────────┬───────────────────┘│
                                    │                    │
                          (1)       │                    │
                                    │ ON DELETE SET NULL │
                                    │ (FK added in 016)  │
                                    │                    │
                                    │ (0..N)             │
                                    ▼                    │
              ┌────────────────────────────────────┐    │
              │              contract              │    │
              │ ───────────────────────────────────│    │
              │ id              BIGSERIAL PK       │    │
              │ ...                                │    │
              │ import_batch_id BIGINT NULL FK ──> │    │
              │ import_filename VARCHAR(500) NULL  │    │
              │ import_confidence INTEGER NULL     │    │
              │ import_warnings JSONB NULL         │    │
              │ ...                                │    │
              └────────────────────────────────────┘    │
                                                        │
                                                        │
              ┌────────────────────────────────────┐    │
              │               "user"               │    │
              │ ───────────────────────────────────│    │
              │ id              BIGSERIAL PK       │    │
              │ ...                              <─┼────┘  ON DELETE RESTRICT
              └────────────────────────────────────┘
```

`import_batch.initiated_by` → `"user".id` ON DELETE RESTRICT (operator deletion forbidden while owned batches exist; Design Note D4 — diverges from M1a `contract.drafted_by` ON DELETE SET NULL because operator identity is a hard fact, not a soft attribution).

`contract.import_batch_id` → `import_batch.id` ON DELETE SET NULL — closes the M1a forward-reference. Existing M1a contracts have `import_batch_id IS NULL`; FK enforcement begins with M1c-issued INSERTs.

---

## fn_import_batch_get_by_id — JSONB output (sample)

```json
{
  "id": 42,
  "initiatedBy": { "id": 7, "firstName": "Aisha", "lastName": "Al-Mansouri" },
  "config": {
    "contractType": "service",
    "statusMode": "active",
    "defaultCounterpartyId": 12
  },
  "totalFiles": 50,
  "autoSaved": 30,
  "reviewQueue": 15,
  "manualEntry": 3,
  "duplicatesSkipped": 1,
  "errored": 1,
  "status": "completed",
  "startedAt": "2026-05-03T12:00:00.000Z",
  "completedAt": "2026-05-03T12:48:33.000Z",
  "createdAt": "2026-05-03T12:00:00.000Z",
  "updatedAt": "2026-05-03T12:48:33.000Z"
}
```

---

## fn_import_batch_list — JSONB output (sample)

```json
{
  "data": [
    {
      "id": 42,
      "initiatedBy": 7,
      "totalFiles": 50,
      "autoSaved": 30,
      "reviewQueue": 15,
      "manualEntry": 3,
      "duplicatesSkipped": 1,
      "errored": 1,
      "status": "completed",
      "config": { "contractType": "service", "statusMode": "active" },
      "startedAt": "2026-05-03T12:00:00.000Z",
      "completedAt": "2026-05-03T12:48:33.000Z"
    }
  ],
  "pagination": { "total": 1, "page": 1, "limit": 20, "totalPages": 1 }
}
```

`initiatedBy` is the raw bigint user id in list rows (lighter payload — drill-down to the hydrated UserRef happens via `GET /api/v1/import-batches/:id`).

---

## Notes on Design Decisions (Section 12 of db-design.md, condensed)

- **D1.** `import_filename` deliberately NOT in audit redact list — useful audit forensics; not classified PII.
- **D2.** `chk_import_batch_completed_at_status` enforces lifecycle invariant declaratively (defense-in-depth on top of fn logic).
- **D3.** `chk_import_batch_counter_sum` enforces AC-S2-05 5-counter sum bound declaratively.
- **D4.** `initiated_by` is ON DELETE RESTRICT (NOT SET NULL) — operator identity is a hard fact for the lifetime of the batch.
- **D5.** DROP+CREATE for `fn_contract_list` — Postgres CREATE OR REPLACE cannot change parameter list.
- **D6.** No CHECK on JSONB shape — validation happens at fn entry + Zod layer (Postgres CHECK on JSONB is brittle).
- **D7.** `fn_import_batch_get_by_id` returns NULL on row-invisible (not-found OR not-authorised); BE returns 404 in both cases — good security practice.
- **D8.** Codex BE-001 SELECT FOR UPDATE applied verbatim in `fn_import_batch_update`.
- **D10.** All M1c fns use `SET search_path = public, pg_temp` (M0 002 hardening / CRX-1 lesson).
- **D11.** All M1c public-API fns are SECURITY INVOKER — no DEFINER privilege escalation. RLS enforces row visibility.
- **D12.** Read fns (`fn_import_batch_list`, `fn_import_batch_get_by_id`) marked STABLE.
- **D15.** Field-prefixed exception messages (`fn_<name>: <field>:<message>`) for clean BE error mapping.
- **D16.** Migration rollback blocks materialised in-file by DB Implementation Agent.

---

*M1c data dictionary v1.0 (final state at v22 — incl. patches 019 / 020 / 021 / 022).*
