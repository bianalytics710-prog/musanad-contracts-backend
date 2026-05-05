# M0 Foundation - Data Dictionary

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M0 - Foundation
> **Generated:** 2026-05-02
> **Source:** `database/migrations/001_foundation.sql` + `database/migrations/002_security_hardening.sql`
> **Neon project:** `musanad-contracts` (id `patient-morning-04972561`), branch `m0-foundation` (`br-snowy-brook-aje2ehtl`)

This document is the canonical reference for every M0 database object: 7 tables, 19 indexes, 14 fn_-prefixed functions (13 from spec + 1 RLS helper), 3 audit triggers, and 16 RLS policies.

All sensitive columns are tagged **[SENSITIVE]** - they must never appear in `fn_` output JSONB, API responses, or log lines. The redaction pipeline runs in three places: (1) `fn_audit_trigger` rewrites VALUES to `"[REDACTED]"` before INSERT into `audit_log`, (2) Pino redacts request/response paths in BE logs, (3) the auth controller strips `passwordHash` from the login response before returning.

**Per CRX-4 (Codex review fix):** every `fn_` function declared in M0 - SECURITY DEFINER and SECURITY INVOKER alike - has `SET search_path = public, pg_temp` pinned. Migration `002_security_hardening.sql` applied this defense-in-depth pragma.

---

## Tables

### 1. `schema_migrations`

**Purpose.** System table tracking applied migrations. One row per applied migration file.
**Owned by:** M0. **Audit columns:** none. **RLS:** enabled, deny-all (only the privileged migration runner writes).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `version` | INTEGER | PRIMARY KEY | Migration sequence number (`1` = `001_foundation.sql`). |
| `description` | TEXT | NOT NULL | Migration description (e.g. `001_foundation`). |
| `applied_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | When the migration was applied. |

**Indexes:** primary key only.
**Audit trigger:** none. The migration runner is the only writer.
**Current rows:** 2 (`001_foundation`, `002_security_hardening`).

---

### 2. `audit_log`

**Purpose.** Append-only audit trail. `fn_audit_trigger` writes one row per INSERT/UPDATE/DELETE on every business table. Sensitive field VALUES are rewritten to `"[REDACTED]"` inside the trigger before insertion.
**Owned by:** M0. **Audit columns:** none (this IS the audit). **RLS:** enabled, capability-gated read, append-only.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `table_name` | TEXT | NOT NULL | Source table name. |
| `record_id` | BIGINT | nullable | Affected row id (NULL for ops that don't have a single id). |
| `action` | TEXT | NOT NULL, CHECK IN ('INSERT','UPDATE','DELETE') | Trigger op. |
| `old_values` | JSONB | nullable | OLD row snapshot. **Sensitive values redacted** before insertion. |
| `new_values` | JSONB | nullable | NEW row snapshot. **Sensitive values redacted** before insertion. |
| `changed_by` | BIGINT | nullable | `app.current_user_id` GUC at time of write. |
| `changed_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | Server clock. |

**Indexes:**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| `idx_audit_log_table_record` | `(table_name, record_id)` | BTREE | "All changes for record X in table Y". |
| `idx_audit_log_changed_by` | `(changed_by)` | BTREE | "Everything user X did". |
| `idx_audit_log_changed_at` | `(changed_at DESC)` | BTREE | Recent activity feed; retention/cleanup jobs. |

**Audit trigger:** none (would recurse on itself).

---

### 3. `role`

**Purpose.** Application roles (`Super Admin`, `Admin`, `User` seeded; feature modules add domain roles).
**Owned by:** M0. **Audit columns:** full. **RLS:** enabled. **Soft delete:** `is_active`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `name` | TEXT | NOT NULL UNIQUE | Display name. |
| `description` | TEXT | nullable | Free-text description. |
| `created_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `updated_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable | Set by trigger to `app.current_user_id`. NOT FK'd because bootstrap admin is seeded before any user exists. |
| `updated_by` | BIGINT | nullable | Same caveat. |
| `is_active` | BOOLEAN | NOT NULL DEFAULT true | Soft delete flag. |

**Indexes:** `idx_role_active(id) WHERE is_active = true` (partial - powers `fn_role_list`).
**Audit trigger:** `audit_role_changes` fires AFTER INSERT/UPDATE/DELETE.

---

### 4. `permission`

**Purpose.** Permission catalog. Canonical identifier is `code` (NOT `name`). Used by `fn_current_user_has_permission` for RLS capability checks and by the BE `authorise()` middleware.
**Owned by:** M0. **Audit columns:** partial (only `created_at`, `is_active`) - the catalog is install-time defined and effectively read-only at runtime (S2-6 closed-as-accepted). **RLS:** enabled.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Stable IDs (1-4 in M0 seed). |
| `code` | TEXT | NOT NULL UNIQUE | Canonical identifier in dot-notation (`user.read.all`, `user.manage`, `role.manage`, `audit.read`). |
| `module` | TEXT | NOT NULL | Logical module (`user`, `role`, `audit`). |
| `action` | TEXT | NOT NULL | Action verb (`read.all`, `manage`, `read`). |
| `description` | TEXT | nullable | Human-readable description. |
| `created_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT true | |

**Indexes:**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| `idx_permission_code` | `(code)` | BTREE | RLS capability lookup hot path. |
| `idx_permission_module` | `(module)` | BTREE | `fn_permission_list` grouping. |
| `idx_permission_active` | `(id) WHERE is_active = true` | BTREE partial | Active filter. |

**Audit trigger:** none (catalog is install-time; no audit needed).
**Seed:** 4 rows - `user.read.all`, `user.manage`, `role.manage`, `audit.read`.

---

### 5. `role_permission`

**Purpose.** Junction mapping roles to permissions.
**Owned by:** M0. **Audit columns:** partial (`created_at`, `created_by`, `is_active` - junction rows are immutable except for soft-revoke). **RLS:** enabled.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `role_id` | BIGINT | NOT NULL, FK -> `role(id)` ON DELETE CASCADE | |
| `permission_id` | BIGINT | NOT NULL, FK -> `permission(id)` ON DELETE CASCADE | |
| `created_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT true | Soft-revoke flag. |
| - | - | UNIQUE (`role_id`, `permission_id`) | Prevents duplicate grants. |

**Indexes:** `idx_role_permission_role_id`, `idx_role_permission_permission_id`, `idx_role_permission_active(id) WHERE is_active = true`.
**Audit trigger:** `audit_role_permission_changes` fires AFTER INSERT/UPDATE/DELETE.
**Seed:** 7 rows - Super Admin gets all 4 permissions; Admin gets 3 (no `role.manage`); User gets 0.

---

### 6. `"user"` (quoted - `user` is a SQL reserved word)

**Purpose.** Base user entity. `password_hash` is bcrypt(12) - never returned by any `fn_` other than `fn_auth_get_user_for_login`, which is restricted to the login flow. Lockout enforced via `login_attempts` (>= 5) + `locked_until`.
**Owned by:** M0. **Audit columns:** full. **RLS:** enabled. **Soft delete:** `is_active`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `email` | TEXT | NOT NULL UNIQUE | Lookup is case-insensitive (`LOWER(email)`). |
| `password_hash` | TEXT | NOT NULL | **[SENSITIVE]** bcrypt(12). NEVER returned in any `fn_` output other than `fn_auth_get_user_for_login`. Pino-redacted. |
| `first_name` | TEXT | NOT NULL | |
| `last_name` | TEXT | NOT NULL | |
| `role_id` | BIGINT | NOT NULL, FK -> `role(id)` | |
| `login_attempts` | INTEGER | NOT NULL DEFAULT 0 | Reset to 0 on success; locks at 5. |
| `locked_until` | TIMESTAMPTZ | nullable | NULL when not locked. |
| `last_login_at` | TIMESTAMPTZ | nullable | Set by `fn_auth_record_login_success`. |
| `created_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `updated_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable, FK -> `"user"(id)` (self-ref) | |
| `updated_by` | BIGINT | nullable, FK -> `"user"(id)` (self-ref) | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT true | Soft delete flag. |

**Indexes:**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| `idx_user_email` | `(email)` | BTREE | `fn_auth_get_user_for_login` lookup. |
| `idx_user_role_id` | `(role_id)` | BTREE | `fn_user_list` role filter; RLS joins. |
| `idx_user_active` | `(id) WHERE is_active = true` | BTREE partial | Most authenticated queries scope to active. |
| `idx_user_created_by` | `(created_by) WHERE created_by IS NOT NULL` | BTREE partial | Back-reference scans (S2-7 closed). |
| `idx_user_updated_by` | `(updated_by) WHERE updated_by IS NOT NULL` | BTREE partial | Same. |

**Audit trigger:** `audit_user_changes` fires AFTER INSERT/UPDATE/DELETE.
**Seed:** 1 row - bootstrap admin (`id=1`, `admin@musanad.local`, password `ChangeMe@123` hashed at migration time with bcrypt(12); plaintext is NEVER committed).

---

### 7. `token_blacklist`

**Purpose.** Append-only refresh-token invalidation log. Stores SHA-256 hex of the refresh token (never the token itself). Direct table access denied; SECURITY DEFINER `fn_auth_*` are the only access path.
**Owned by:** M0. **Audit columns:** none (this IS the revocation audit). **RLS:** enabled, deny-all-direct.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `token_hash` | TEXT | NOT NULL UNIQUE | **[SENSITIVE]** SHA-256 hex digest of refresh JWT. Never logged or returned. |
| `user_id` | BIGINT | NOT NULL, FK -> `"user"(id)` | |
| `blacklisted_at` | TIMESTAMPTZ | DEFAULT CURRENT_TIMESTAMP | |
| `expires_at` | TIMESTAMPTZ | NOT NULL | Refresh JWT expiry; cleanup job deletes rows past this. |

**Indexes:** `idx_token_blacklist_hash`, `idx_token_blacklist_user_id`, `idx_token_blacklist_expires_at`.
**Audit trigger:** none (logout/revocation events ARE the audit).

---

## Functions

All functions live in the `public` schema. Per CRX-4 fix, every function declares `SET search_path = public, pg_temp` to mitigate schema-shadow privilege escalation, regardless of SECURITY mode.

### Auth functions (5 + 1 atomic helper from 002)

#### `fn_auth_get_user_for_login(p_email TEXT) RETURNS JSONB`
- **Type:** read. **Security:** DEFINER. **Sets `app.current_user_id`:** no.
- **Purpose:** Returns user with `passwordHash` + lockout state for the login controller. NULL if not found/inactive.
- **Sensitive:** This is the ONLY `fn_` that returns `passwordHash`. The login controller is the sole caller; the response object is in Pino's redaction list.
- **Returns:** `{id, email, passwordHash, firstName, lastName, loginAttempts, lockedUntil, isActive, role:{id,name}}` or NULL.

#### `fn_auth_record_login_failure(p_user_id BIGINT, p_max_attempts INTEGER, p_lockout_minutes INTEGER) RETURNS JSONB`
- **Type:** write. **Security:** DEFINER. **Sets `app.current_user_id`:** no.
- **Purpose:** Increments `login_attempts`; sets `locked_until` when threshold hit.
- **Returns:** `{loginAttempts, lockedUntil, isLocked}`.

#### `fn_auth_record_login_success(p_user_id BIGINT) RETURNS JSONB`
- **Type:** write. **Security:** DEFINER. **Sets `app.current_user_id`:** no.
- **Purpose:** Resets attempts/lockout, sets `last_login_at`.
- **Returns:** `{success: true, lastLoginAt}`.

#### `fn_auth_blacklist_token(p_token_hash TEXT, p_user_id BIGINT, p_expires_at TIMESTAMPTZ) RETURNS JSONB`
- **Type:** write. **Security:** DEFINER. **Sets `app.current_user_id`:** no.
- **Purpose:** Idempotent insert into `token_blacklist` (`ON CONFLICT (token_hash) DO NOTHING`). Used by logout.
- **Returns:** `{success: true}`.

#### `fn_auth_check_token_blacklist(p_token_hash TEXT) RETURNS JSONB`
- **Type:** read. **Security:** DEFINER. **Sets `app.current_user_id`:** no.
- **Purpose:** Single-row existence check.
- **Returns:** `{isBlacklisted: boolean}`.

#### `fn_auth_blacklist_if_absent(p_token_hash TEXT, p_user_id BIGINT, p_expires_at TIMESTAMPTZ) RETURNS JSONB` *(added in 002)*
- **Type:** write. **Security:** DEFINER. **Sets `app.current_user_id`:** no.
- **Purpose:** **Atomic** check-and-insert via `INSERT ... ON CONFLICT DO NOTHING RETURNING xmax = 0`. Closes the refresh-rotation TOCTOU race (CRX-1 fix). Used by `/auth/refresh`.
- **Returns:** `{inserted: boolean}` - `true` only when this call inserted the row; `false` if another process won the race.

### User CRUD functions

#### `fn_user_create(p_data JSONB, p_actor_id BIGINT) RETURNS JSONB`
- **Type:** write. **Security:** INVOKER. **Sets `app.current_user_id`:** caller responsible (BE middleware via `SET LOCAL`).
- **Purpose:** Creates a user. Controller pre-hashes plaintext with bcrypt(12) into `passwordHash`. Returns via `fn_user_get_by_id`.
- **Calls:** `fn_user_get_by_id`.
- **Returns:** Full `User` JSONB (no `passwordHash`).
- **Errors:** `EMAIL_IN_USE`, `INVALID_ROLE`.

#### `fn_user_update(p_id BIGINT, p_data JSONB, p_actor_id BIGINT) RETURNS JSONB`
- **Type:** write. **Security:** INVOKER. **Sets `app.current_user_id`:** caller.
- **Purpose:** Partial update via COALESCE on `email`, `first_name`, `last_name`, `role_id`. Password updates NOT handled here.
- **Calls:** `fn_user_get_by_id`.
- **Returns:** Full `User` JSONB.

#### `fn_user_delete(p_id BIGINT, p_actor_id BIGINT) RETURNS JSONB`
- **Type:** write. **Security:** INVOKER. **Sets `app.current_user_id`:** caller.
- **Purpose:** Soft delete (`is_active = false`). Self-protection: cannot deactivate self.
- **Returns:** `{success: true, message: "User deactivated"}`.

#### `fn_user_get_by_id(p_id BIGINT) RETURNS JSONB`
- **Type:** read. **Security:** INVOKER. **Sets `app.current_user_id`:** caller.
- **Purpose:** Full user with role and `permissions[]` (codes). NEVER returns `passwordHash`.
- **Returns:** `User` JSONB or NULL.

#### `fn_user_list(p_page INT DEFAULT 1, p_limit INT DEFAULT 20, p_search TEXT DEFAULT NULL, p_role_id BIGINT DEFAULT NULL) RETURNS JSONB`
- **Type:** read. **Security:** INVOKER. **Sets `app.current_user_id`:** caller.
- **Purpose:** Paginated list with role filter and search across email/firstName/lastName.
- **Returns:** `{data: UserListItem[], pagination: {page, limit, total, totalPages}}`.

### Catalog functions

#### `fn_role_list(p_page INT DEFAULT 1, p_limit INT DEFAULT 50) RETURNS JSONB`
- **Type:** read. **Security:** INVOKER. **Sets `app.current_user_id`:** caller.
- **Purpose:** Paginated active roles with `permissionCount`. Bounds: `p_page >= 1`, `1 <= p_limit <= 200`.
- **Returns:** `{data: Role[], pagination}`.

#### `fn_permission_list(p_page INT DEFAULT 1, p_limit INT DEFAULT 50, p_role_id BIGINT DEFAULT NULL) RETURNS JSONB`
- **Type:** read. **Security:** INVOKER. **Sets `app.current_user_id`:** caller.
- **Purpose:** Paginated permission catalog; if `p_role_id` provided, only that role's permissions. Same bounds as above.
- **Returns:** `{data: Permission[], pagination}`.

### RLS helper

#### `fn_current_user_has_permission(p_code TEXT) RETURNS BOOLEAN`
- **Type:** read (STABLE). **Security:** DEFINER.
- **Purpose:** Used by every capability-based RLS policy. Reads `app.current_user_id` GUC and joins through `role_permission` + `permission`. Returns true iff the session user has the permission code.

### Trigger function

#### `fn_audit_trigger() RETURNS TRIGGER`
- **Security:** DEFINER.
- **Purpose:** Generic audit trigger attached to `user`, `role`, `role_permission`. Captures OLD/NEW as JSONB; rewrites the values of 17 redacted field names to `"[REDACTED]"` before INSERT into `audit_log`. Reads `app.current_user_id` GUC for `changed_by`.
- **Redacted field set (17):** `password_hash`, `password`, `token_hash`, `refresh_token`, `access_token`, `openai_api_key`, `anthropic_api_key`, `smtp_password`, `uae_pass_client_secret`, `supabase_service_role_key`, `jwt_secret`, `signature_image`, `emirates_id`, `signer_email`, `signer_phone`, `ai_prompt_payload`, `contract_body`. (Project-wide superset; some fields appear only in feature-module tables.)

---

## Triggers

| Trigger | Table | Events | Function |
|---|---|---|---|
| `audit_user_changes` | `"user"` | AFTER INSERT, UPDATE, DELETE | `fn_audit_trigger` |
| `audit_role_changes` | `role` | AFTER INSERT, UPDATE, DELETE | `fn_audit_trigger` |
| `audit_role_permission_changes` | `role_permission` | AFTER INSERT, UPDATE, DELETE | `fn_audit_trigger` |

`permission` has no audit trigger (intentional - install-time catalog). `audit_log` has no audit trigger (would recurse). `token_blacklist` has no audit trigger (the inserts ARE the audit).

---

## RLS Policies (16 total across 7 tables)

All policies use the production-grade approach: per-tenant + per-role + per-ownership filtering via `app.current_user_id` GUC + `fn_current_user_has_permission(code)`. **No `USING(true)` policies anywhere.** (Per decisions.md G5.)

### `"user"` (4 policies)

| Policy | Command | Approach |
|---|---|---|
| `user_select_self_or_admin` | SELECT | `id = current_user_id() OR fn_current_user_has_permission('user.read.all')` |
| `user_insert_admin` | INSERT | `fn_current_user_has_permission('user.manage')` |
| `user_update_self_or_admin` | UPDATE | self OR `user.manage` |
| `user_delete_admin` | DELETE | `user.manage` |

### `role` (2 policies)

| Policy | Command | Approach |
|---|---|---|
| `role_select_authenticated` | SELECT | session user is set (authenticated) |
| `role_modify_admin` | ALL | `role.manage` |

### `permission` (2 policies)

| Policy | Command | Approach |
|---|---|---|
| `permission_select_authenticated` | SELECT | authenticated |
| `permission_modify_admin` | ALL | `role.manage` |

### `role_permission` (2 policies)

| Policy | Command | Approach |
|---|---|---|
| `role_permission_select_authenticated` | SELECT | authenticated |
| `role_permission_modify_admin` | ALL | `role.manage` |

### `token_blacklist` (1 policy)

| Policy | Command | Approach |
|---|---|---|
| `token_blacklist_deny_direct` | ALL | deny-all - SECURITY DEFINER `fn_auth_*` are the only access path |

### `audit_log` (4 policies)

| Policy | Command | Approach |
|---|---|---|
| `audit_log_select_audit_read` | SELECT | `fn_current_user_has_permission('audit.read')` |
| `audit_log_deny_direct_insert` | INSERT | deny - only `fn_audit_trigger` (SECURITY DEFINER) inserts |
| `audit_log_deny_update` | UPDATE | deny (append-only) |
| `audit_log_deny_delete` | DELETE | deny (append-only) |

### `schema_migrations` (1 policy)

| Policy | Command | Approach |
|---|---|---|
| `schema_migrations_deny_all` | ALL | deny - system table |

---

## Sensitive columns (consolidated)

| Table | Column | Why sensitive | Where redacted |
|---|---|---|---|
| `"user"` | `password_hash` | Bcrypt hash of plaintext password | `fn_audit_trigger`; never returned by `fn_user_*`; auth controller strips before login response; Pino redact path. |
| `token_blacklist` | `token_hash` | SHA-256 of refresh token (high-value target) | `fn_audit_trigger`; never returned by any `fn_`; Pino redact path. |

The full project-wide sensitive list (17 names) is in `project.config.json` -> `sensitiveFields` and is mirrored in `src/types/api.types.ts` -> `SENSITIVE_FIELD_NAMES`. Feature modules adding sensitive columns must extend that list.

---

## Seed data summary

| Table | Rows | Notes |
|---|---|---|
| `permission` | 4 | Stable IDs 1-4. Codes: `user.read.all`, `user.manage`, `role.manage`, `audit.read`. |
| `role` | 3 | Stable IDs 1-3. Names: `Super Admin`, `Admin`, `User`. |
| `role_permission` | 7 | Super Admin -> all 4; Admin -> 3 (no `role.manage`); User -> 0. |
| `"user"` | 1 | Bootstrap admin `admin@musanad.local`. Password `ChangeMe@123` hashed at migration time with bcrypt(12). **Must be rotated on first login.** |

---

*Generated by Documentation Generator from db-design.md v1.1, db-design-summary.json, and applied migrations 001 + 002.*

---
---

# M1a — Contracts: Core CRUD & Lifecycle

> **Module:** M1a (first sub-module of split M1).
> **Generated:** 2026-05-03.
> **Source:** `database/migrations/003_m1a_contracts.sql` + `004_m1a_extend_sensitive_fields.sql` + `005_m1a_contract_functions.sql` + patches `006_m1a_grant_super_admin_contract_permissions.sql`, `007_m1a_fix_total_pages_zero.sql`, `008_m1a_concurrency_fixes.sql`.
> **Neon project:** `musanad-contracts` (`patient-morning-04972561`), dev branch `m0-foundation` (`br-snowy-brook-aje2ehtl`), test branch `test` (`br-billowing-boat-ajq9m0g6`).

This section documents the 4 tables, 12 fn_ functions, 2 activity-emit trigger functions, 12 RLS policies (3 RESTRICTIVE), 7 new roles, 9 new permissions, and 20 role-permission grants introduced by M1a. M0 sensitive-field redaction is extended in migration 004 to cover `body_en` / `body_ar`.

`fn_audit_trigger` is **bound** to `contract`, `contract_version`, `contract_tag` (3 of 4 M1a tables). It is **not** bound to `contract_activity` - that table IS the activity-style audit; double-binding would amplify `audit_log` volume.

---

## Tables

### `contract` — core entity

**Purpose.** Core contract record. Bilingual title/body, 14-state status workflow, party linkage, value, governing law, parent/child relationships, version pointer, AI fields (read-only in M1a; populated by M4), import provenance fields (read-only in M1a; populated by M1c).
**Owned by:** M1a. **Audit columns:** full. **Audit trigger:** `audit_contract_changes`. **RLS:** enabled (5 policies; 2 RESTRICTIVE). **Soft delete:** `is_active` - centrally controlled by `fn_contract_delete` (Codex G2 TOCTOU defense).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `contract_number` | VARCHAR(50) | NOT NULL UNIQUE | Auto-generated server-side: `CT-YYYY-NNNNNN`. Controller retries up to 3 times on collision. |
| `title_en` | VARCHAR(500) | NOT NULL | Title (English). |
| `title_ar` | VARCHAR(500) | nullable | Title (Arabic). |
| `contract_type` | VARCHAR(50) | NOT NULL | e.g. `employment`, `services`, `MSA`, `NDA`, `lease`. |
| `template_id` | BIGINT | nullable, FK deferred | Forward reference to `contract_template` (Templates module / M1b). FK ALTER added by that module. |
| `status` | VARCHAR(50) | NOT NULL DEFAULT 'draft', CHECK enum | 14 values: `draft`, `in_review`, `approved`, `awaiting_signature_employer`, `awaiting_signature_counterparty`, `fully_signed`, `active`, `expiring_soon`, `expired`, `amended`, `renewed`, `terminated`, `rejected`, `resubmission_requested`. |
| `language` | VARCHAR(20) | NOT NULL DEFAULT 'en', CHECK enum | `en`, `ar`, `bilingual`. |
| `our_party_id` | BIGINT | nullable, FK deferred | Forward reference to `party` (Parties module). FK ON DELETE RESTRICT added by that module. |
| `counterparty_id` | BIGINT | nullable, FK deferred | Forward reference to `party` (Parties module). |
| `value_aed` | NUMERIC(15,2) | CHECK >= 0 OR NULL | Contract value in AED (or `currency`). |
| `currency` | CHAR(3) | NOT NULL DEFAULT 'AED' | ISO-4217 alpha-3. |
| `start_date` | DATE | nullable | |
| `end_date` | DATE | nullable, CHECK end >= start | Row-level constraint `chk_contract_dates`. |
| `signed_at` | TIMESTAMPTZ | nullable | Set by signing flow (M3). |
| `expiry_notice_days` | INTEGER | DEFAULT 30 | |
| `emirate` | VARCHAR(50) | nullable | UAE emirate code. |
| `governing_law` | VARCHAR(50) | CHECK enum OR NULL | `uae_federal`, `dubai`, `abu_dhabi`, `sharjah`, `difc`, `adgm`, `english`, `other`. |
| `jurisdiction_court` | VARCHAR(255) | nullable | |
| `parent_contract_id` | BIGINT | nullable, FK contract(id) ON DELETE RESTRICT, CHECK <> id | Self-referencing - amendment / renewal / extension / SOW tree. |
| `relationship_type` | VARCHAR(30) | CHECK enum OR NULL | `amendment`, `renewal`, `extension`, `superseded`, `sow_under_msa`. |
| `body_en` | TEXT | nullable | **[SENSITIVE]** Pino-redacted in logs; redacted in `audit_log` JSONB by `fn_audit_trigger` (after migration 004). NEVER returned by `fn_contract_list`. |
| `body_ar` | TEXT | nullable | **[SENSITIVE]** Same handling as `body_en`. |
| `current_version` | INTEGER | NOT NULL DEFAULT 1 | Pointer to the latest `contract_version`. Bumped by `fn_contract_version_create`. |
| `drafted_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | Used by role-aware RLS as a placeholder for party-membership / approval-pending until Parties module + M2 land. |
| `reviewed_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | Same. |
| `approved_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | Same. |
| `ai_risk_score` | INTEGER | CHECK 0..100 OR NULL | Populated by M4. M1a never writes. |
| `ai_summary_en` | TEXT | nullable | Populated by M4. |
| `ai_summary_ar` | TEXT | nullable | Populated by M4. |
| `import_batch_id` | BIGINT | nullable, FK deferred | Forward reference to `import_batch` (M1c). |
| `import_confidence` | INTEGER | CHECK 0..100 OR NULL | Populated by M1c. |
| `import_filename` | TEXT | nullable | Populated by M1c. |
| `import_warnings` | JSONB | nullable | Populated by M1c. |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `updated_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable, FK "user"(id) | |
| `updated_by` | BIGINT | nullable, FK "user"(id) | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag. **Direct UPDATE that touches `is_active` is denied by RLS** (`contract_deny_direct_is_active_update`); only `fn_contract_delete` (SECURITY DEFINER, sets `app.fn_contract_delete='true'` GUC) may flip it. |

**Indexes (17):** `idx_contract_active` (partial WHERE is_active), `idx_contract_status`, `idx_contract_contract_type`, `idx_contract_counterparty_id`, `idx_contract_our_party_id`, `idx_contract_drafted_by`, `idx_contract_reviewed_by`, `idx_contract_approved_by`, `idx_contract_template_id`, `idx_contract_parent_contract_id` (recursive CTE for tree), `idx_contract_import_batch_id`, `idx_contract_created_at_desc` (default list sort), `idx_contract_end_date`, `idx_contract_start_date`, `idx_contract_created_by`, `idx_contract_updated_by`, `idx_contract_search_trgm` (GIN with `pg_trgm` extension - powers ILIKE search across `contract_number / title_en / title_ar`).

**Audit trigger:** `audit_contract_changes` (AFTER INSERT/UPDATE/DELETE -> `fn_audit_trigger`).

**Activity-emit trigger:** `trg_contract_activity_emit_iu` (AFTER INSERT OR UPDATE OF status, is_active -> `fn_trg_contract_activity_emit`). Emits `created` / `status_changed` / `soft_deleted` / `restored` activity rows. De-dupes with explicit emissions inside `fn_contract_status_update`.

---

### `contract_tag` — junction (chosen over TEXT[]+GIN)

**Purpose.** Junction table normalising the contract's tag set. Free-form text per row; UNIQUE per (contract_id, tag) WHERE active.
**Owned by:** M1a. **Audit columns:** partial (no `updated_at`/`updated_by` - tags are immutable; lifecycle is insert + soft-delete). **Audit trigger:** `audit_contract_tag_changes`. **RLS:** enabled (3 policies). **Soft delete:** `is_active`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `contract_id` | BIGINT | NOT NULL, FK contract(id) ON DELETE CASCADE | |
| `tag` | VARCHAR(64) | NOT NULL, CHECK length 1..64, CHECK no-control-char | Trimmed by `fn_contract_set_tags` before storage. |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT TRUE | |

**Indexes (4):** `uq_contract_tag_active` UNIQUE(contract_id, tag) WHERE is_active=true (allows tag reactivation), `idx_contract_tag_contract_id`, `idx_contract_tag_tag` WHERE active, `idx_contract_tag_active`, `idx_contract_tag_created_by`.

**Audit trigger:** `audit_contract_tag_changes`.

---

### `contract_version` — append-only version history

**Purpose.** Immutable version snapshots. `fn_contract_version_create` is the only writer. UPDATE/DELETE forbidden by RLS (implicit deny).
**Owned by:** M1a. **Audit columns:** partial (no `updated_at`/`updated_by` - append-only). **Audit trigger:** `audit_contract_version_changes`. **RLS:** enabled (2 policies; UPDATE/DELETE implicit-deny).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `contract_id` | BIGINT | NOT NULL, FK contract(id) ON DELETE CASCADE | |
| `version_number` | INTEGER | NOT NULL | UNIQUE(contract_id, version_number). |
| `body_en` | TEXT | nullable | **[SENSITIVE]** Pino + audit redacted. |
| `body_ar` | TEXT | nullable | **[SENSITIVE]** Pino + audit redacted. |
| `diff_summary` | TEXT | nullable | Free-text in M1a; AI-generated path is M4. |
| `change_note` | VARCHAR(500) | nullable | Required at the API layer (Zod). |
| `changed_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT TRUE | |

**Constraints:** UNIQUE(contract_id, version_number); CHECK body_en IS NOT NULL OR body_ar IS NOT NULL.

**Indexes (5):** `idx_contract_version_contract_id`, `idx_contract_version_active`, `idx_contract_version_changed_by`, `idx_contract_version_created_by`, `idx_contract_version_contract_vnum` (contract_id, version_number DESC).

**Audit trigger:** `audit_contract_version_changes`.

**Activity-emit trigger:** `trg_contract_version_activity_emit` (AFTER INSERT -> emits `version_created` activity with `metadata.versionNumber`).

---

### `contract_activity` — append-only timeline (NO updated_at, NO audit-trigger binding)

**Purpose.** Append-only contract activity timeline. Auto-emitted by triggers on `contract` and `contract_version` changes. Read-only via API (no POST endpoint).
**Owned by:** M1a. **Audit columns:** minimal (no `updated_at`, no `created_by` - `actor_id` IS the creator). **Audit trigger:** none (intentional - W3 / Agent 3 ND-2). **RLS:** enabled (2 policies including 1 RESTRICTIVE deny-direct-INSERT).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `contract_id` | BIGINT | NOT NULL, FK contract(id) ON DELETE CASCADE | |
| `activity_type` | VARCHAR(50) | NOT NULL, CHECK enum | `created`, `updated`, `status_changed`, `version_created`, `tagged`, `soft_deleted`, `restored`. M2/M3/M5 may extend the CHECK via ALTER. |
| `actor_id` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | Read from `app.current_user_id` GUC inside the trigger. NULL after user soft-delete. |
| `description_en` | VARCHAR(1000) | nullable | |
| `description_ar` | VARCHAR(1000) | nullable | |
| `metadata` | JSONB | nullable | Free-form. status_changed: `{ fromStatus, toStatus, reason? }`; version_created: `{ versionNumber }`; tagged: `{ added, removed }`. **Body content is FORBIDDEN** - sensitive-body changes record only `fieldsChanged`. |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT TRUE | |

**Indexes (5):** `idx_contract_activity_contract_id`, `idx_contract_activity_active`, `idx_contract_activity_actor_id`, `idx_contract_activity_created_at_desc` (contract_id, created_at DESC) - powers list-newest-first per contract, `idx_contract_activity_type`.

**Audit trigger:** none (intentional). **Direct INSERT denied** by RESTRICTIVE policy `contract_activity_deny_direct_insert WITH CHECK (FALSE)`. Only `fn_contract_activity_create` (SECURITY DEFINER) may write.

---

## Functions (12)

All functions are `LANGUAGE plpgsql` with `SET search_path = public, pg_temp`. Security mode (INVOKER vs DEFINER) is called out per function.

| Function | Type | Security | Purpose | AC mapping |
|---|---|---|---|---|
| `fn_contract_create(p_data JSONB, p_actor_id BIGINT)` | Write | INVOKER | Create draft contract; auto-numbered `CT-YYYY-NNNNNN`; `current_version=1`. Triggers emit `created` activity. Migration 008: locks parent (FOR UPDATE) when `parentContractId` set. | AC-S3-* |
| `fn_contract_update(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)` | Write | INVOKER | Partial COALESCE update; cycle detection on `parentContractId`; body change auto-creates `contract_version` row. Migration 008: locks self + parent FOR UPDATE before reading `v_existing` (Codex BE-002). | AC-S4-* |
| `fn_contract_delete(p_id BIGINT, p_actor_id BIGINT)` | Write | **DEFINER** | Soft-delete via `is_active=false`. Sets `app.fn_contract_delete='true'` GUC (transaction-local). Takes FOR UPDATE on the row, checks `child IS active` inside the lock, then flips. Codex G2 TOCTOU defense. | AC-S5-* |
| `fn_contract_status_update(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)` | Write | INVOKER | Update `contract.status`. M1a placeholder: validates enum membership only (no transition logic). Auto-emits `status_changed` activity with `metadata.{ fromStatus, toStatus, reason? }`. M2 replaces with state-machine-aware variant. | AC-S6-* |
| `fn_contract_set_tags(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)` | Write | INVOKER | Atomic replace of the tag set; idempotent. Emits `tagged` with `{ added, removed }`. Migration 008: locks parent FOR UPDATE before reading current tags (Codex BE-003). | AC-S8-* |
| `fn_contract_version_create(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)` | Write | INVOKER | Append a new `contract_version`; SELECT FOR UPDATE on parent for atomic `version_number` increment. Updates `contract.body_*` and bumps `current_version`. | AC-S10-* |
| `fn_contract_activity_create(p_contract_id, p_activity_type, p_actor_id, p_description_en, p_description_ar, p_metadata)` | Write | **DEFINER** | INTERNAL HELPER. The only writer to `contract_activity`. Called from `fn_trg_contract_activity_emit`, `fn_trg_contract_version_activity_emit`, and `fn_contract_status_update` / `fn_contract_set_tags`. Never exposed via HTTP. | AC-S12-* |
| `fn_contract_list(p_page, p_limit, p_status, p_contract_type, p_counterparty_id, p_drafted_by, p_approved_by, p_start_date_*, p_end_date_*, p_tags TEXT[], p_search, p_actor_id, p_actor_role)` | Read | INVOKER | Paginated, role-aware list. body_en/body_ar EXCLUDED from response (AC-S1-08). Tag filter uses AND-semantics. Sort: created_at DESC, end_date ASC. Patch 007: `totalPages=0` when `total=0`. | AC-S1-* |
| `fn_contract_get_by_id(p_id, p_actor_id, p_actor_role)` | Read | INVOKER | Full contract payload + drafter/reviewer/approver enrichment + attachmentCount + commentCount. Returns NULL when row not visible (RLS) or absent; controller distinguishes 403 vs 404 via `db.checkActiveRowExists` (AC-S2-03). | AC-S2-* |
| `fn_contract_get_tree(p_id, p_actor_id, p_actor_role)` | Read | INVOKER | Recursive CTE in both directions; depth cap 20 (`truncated=true` flag). Role-aware filter omits invisible nodes. | AC-S7-* |
| `fn_contract_version_list(p_id, p_page, p_limit, p_actor_id, p_actor_role)` | Read | INVOKER | Paginated version list newest-first. Patch 007: `totalPages=0` when `total=0`. | AC-S9-* |
| `fn_contract_activity_list(p_id, p_page, p_limit, p_activity_type, p_actor_id, p_actor_role)` | Read | INVOKER | Paginated activity timeline newest-first. Optional `activityType` filter. Patch 007: `totalPages=0` when `total=0`. | AC-S11-* |

**RAISE EXCEPTION format:** `fn_<name>: <field>:<message>`. Backend `translatePgError` parses field prefix and routes:

- `id` / `contractId` -> 404 NOT_FOUND
- `children` -> 409 CONFLICT
- `contractNumber` / `versionNumber` -> 409 CONFLICT
- any other field -> 400 VALIDATION_ERROR
- SQLSTATE `42501` (RLS denial) -> 403 FORBIDDEN (no table or policy name leaked)

### Trigger functions (2)

| Function | Bound trigger | Purpose |
|---|---|---|
| `fn_trg_contract_activity_emit()` | `trg_contract_activity_emit_iu` AFTER INSERT OR UPDATE OF status, is_active ON contract | Emits `created` (INSERT), `status_changed` (with de-dupe vs explicit emit from `fn_contract_status_update`), `soft_deleted`, `restored`. |
| `fn_trg_contract_version_activity_emit()` | `trg_contract_version_activity_emit` AFTER INSERT ON contract_version | Emits `version_created` with `metadata.versionNumber`. |

There is **no row-level activity-emit trigger on `contract_tag`** - `fn_contract_set_tags` emits the `tagged` activity directly with full `{ added, removed }` metadata (a row-level trigger cannot compute the diff across a multi-row tag swap).

---

## RLS Policies (12 total; 3 RESTRICTIVE)

### `contract` (5 policies; 2 RESTRICTIVE)

| Policy | Command | Approach |
|---|---|---|
| `contract_select_role_aware` | SELECT | Privileged roles (`platform_admin`, `legal_counsel`, `executive`, `Super Admin`) see all; otherwise caller must be `drafted_by` / `reviewed_by` / `approved_by` / `created_by`. M1a placeholder until Parties module + M2 approvals join. |
| `contract_insert_drafter_or_admin` | INSERT | `fn_current_user_has_permission('contract.draft')` AND role IN platform_admin / legal_counsel / contract_drafter / Super Admin. |
| `contract_update_owner_or_admin` | UPDATE | Privileged role OR (contract_drafter AND `drafted_by = current_user` AND status IN draft / resubmission_requested). |
| `contract_deny_direct_is_active_update` | UPDATE (RESTRICTIVE) | Allows the UPDATE only if `app.fn_contract_delete='true'` GUC is set OR `is_active` is unchanged. Codex G2 TOCTOU companion to `fn_contract_delete`. |
| `contract_deny_direct_delete` | DELETE (RESTRICTIVE) | `USING (FALSE)` - direct DELETE forbidden. Soft-delete only. |

### `contract_tag` (3 policies)

| Policy | Command | Approach |
|---|---|---|
| `contract_tag_select_parent_aware` | SELECT | `is_active` AND parent contract visible. |
| `contract_tag_insert_parent_writable` | INSERT | `contract.tag.manage` AND parent active. |
| `contract_tag_update_parent_writable` | UPDATE | `contract.tag.manage` AND parent active. |

DELETE on `contract_tag` is implicit-deny (no policy); `fn_contract_set_tags` soft-deletes via UPDATE.

### `contract_version` (2 policies; UPDATE/DELETE implicit-deny)

| Policy | Command | Approach |
|---|---|---|
| `contract_version_select_parent_aware` | SELECT | `is_active` AND parent contract visible. |
| `contract_version_insert_edit` | INSERT | `contract.edit` AND parent active. |

UPDATE/DELETE implicit-deny (append-only).

### `contract_activity` (2 policies; 1 RESTRICTIVE; UPDATE/DELETE implicit-deny)

| Policy | Command | Approach |
|---|---|---|
| `contract_activity_select_parent_aware` | SELECT | `is_active` AND parent contract visible. |
| `contract_activity_deny_direct_insert` | INSERT (RESTRICTIVE) | `WITH CHECK (FALSE)` - only `fn_contract_activity_create` (SECURITY DEFINER) may write. |

UPDATE/DELETE implicit-deny.

---

## Roles seeded (7, alongside existing M0 Super Admin / Admin / User)

| Role name | Purpose |
|---|---|
| `platform_admin` | System-scope contracts admin. Coexists with M0 Super Admin pending consolidation. |
| `legal_counsel` | Read-all + edit / export / tag / status across contracts. |
| `contract_drafter` | Department-scope drafting + edit-own-while-draft. |
| `contract_approver` | Department-scope read for approval queue (M2 will refine). |
| `contract_approver_2` | Second-stage approval read scope. |
| `contract_recipient` | Own-scope read (placeholder for party-membership; refined by Parties module). |
| `executive` | Read-all access to contracts. |

Migration 006 (smoke-test patch): grants the M0 `Super Admin` role all 9 contract.* permissions so the bootstrap admin can use the new endpoints.

## Permissions seeded (9)

| Code | Action | Description |
|---|---|---|
| `contract.read.all` | read.all | Read all contracts across the organisation. |
| `contract.read.department` | read.department | Read contracts within own department. |
| `contract.read.own` | read.own | Read only contracts the caller is a party to or drafted. |
| `contract.draft` | draft | Create new contract drafts. |
| `contract.edit` | edit | Update contract fields and create new versions. |
| `contract.delete` | delete | Soft-delete contracts (system-scope only). |
| `contract.export` | export | Export contracts to PDF/XLSX (defined in M1a; used by M1b). |
| `contract.tag.manage` | tag.manage | Add/remove tags on contracts. |
| `contract.status.update` | status.update | Change contract status (placeholder; replaced by approval engine in M2). |

## Role-permission grants (20)

| Role | Grants | Permissions |
|---|---|---|
| `platform_admin` | 7 | read.all, draft, edit, delete, export, tag.manage, status.update |
| `legal_counsel` | 5 | read.all, edit, export, tag.manage, status.update |
| `contract_drafter` | 4 | read.department, draft, edit, tag.manage |
| `contract_approver` | 1 | read.department |
| `contract_approver_2` | 1 | read.department |
| `contract_recipient` | 1 | read.own |
| `executive` | 1 | read.all |

Migration 006 adds 9 grants for M0 `Super Admin` -> all 9 contract.* permissions (idempotent via `ON CONFLICT DO NOTHING`).

---

## M1a sensitive-field redaction extensions (migration 004)

Migration 004 rebuilds `fn_audit_trigger` (M0 SECURITY DEFINER trigger) appending `body_en`, `body_ar` to its redact array (now 19 names total: M0's 17 + M1a's 2). Verified by inserting CT-TEST-AUDIT-001 with `body_en='SECRET ENGLISH BODY'` / `body_ar='SECRET ARABIC BODY'` and asserting `audit_log.{old_values,new_values}->>'body_*' = '[REDACTED]'`.

Pino redact paths (added by BE Implementation Agent in `src/utils/logger.util.ts`): `*.bodyEn`, `*.body_en`, `*.bodyAr`, `*.body_ar` (defence-in-depth across camelCase and snake_case).

---

## Migrations applied (8 total - 003..008)

| # | File | Description |
|---|---|---|
| 003 | `003_m1a_contracts.sql` | Tables, indexes, RLS (12 policies inc. 3 RESTRICTIVE), audit-trigger bindings (3 of 4 tables - NOT contract_activity), 7 roles + 9 permissions + 20 grants. |
| 004 | `004_m1a_extend_sensitive_fields.sql` | Rebuilds `fn_audit_trigger` redact array adding `body_en`, `body_ar` (W2 honoured). |
| 005 | `005_m1a_contract_functions.sql` | All 12 fn_ functions + 2 activity-emit trigger functions + their bindings. |
| 006 | `006_m1a_grant_super_admin_contract_permissions.sql` | Patch: grants M0 Super Admin all 9 contract.* permissions (smoke-test follow-up so bootstrap admin can hit the new endpoints). |
| 007 | `007_m1a_fix_total_pages_zero.sql` | Patch: removes `GREATEST(1, ...)` clamp from `totalPages` in the three list fn_'s; empty list now reports `totalPages=0`. |
| 008 | `008_m1a_concurrency_fixes.sql` | Codex BE-001/002/003 patch: SELECT FOR UPDATE on parent contract before parent validation (`fn_contract_create`, `fn_contract_update`); SELECT FOR UPDATE on self before reading `v_existing` (`fn_contract_update`); SELECT FOR UPDATE on parent before reading current tags (`fn_contract_set_tags`). |

All 8 migrations applied to dev branch `m0-foundation` AND test branch `test`. Idempotency verified: a second `npm run migrate` reports "No pending migrations" on both branches.

---

## Sensitive columns (M1a additions)

| Table | Column | Why sensitive | Where redacted |
|---|---|---|---|
| `contract` | `body_en` | English contract body content | `fn_audit_trigger` (post-004); pino `req.body.bodyEn` / `res.body.data.bodyEn` / list-shape paths; never returned by `fn_contract_list`. |
| `contract` | `body_ar` | Arabic contract body content | Same as `body_en`. |
| `contract_version` | `body_en` | Snapshot of body_en at version time | Same. |
| `contract_version` | `body_ar` | Snapshot of body_ar at version time | Same. |

The project-wide sensitive list now totals 19 names (M0 17 + M1a 2). Mirrored in `fn_audit_trigger` (DB), `SENSITIVE_FIELD_NAMES` ∪ `M1A_SENSITIVE_FIELD_EXTENSIONS` (TypeScript), and pino redact paths (logger config).

---

*Generated by Documentation Generator from db-design.md, db-implementation-summary.json, and applied migrations 003..008.*

---

# M1b — Compose Wizard, Payment Schedules & Exports

> **Module:** M1b (second sub-module of split M1).
> **Generated:** 2026-05-03.
> **Source:** `database/migrations/009_m1b_payment_schedule.sql` + `010_m1b_extend_m1a.sql` + `011_m1b_export_and_payment_functions.sql` + 4 patches (012..015).
> **Status:** Verified on dev (`m0-foundation`) and test (`test`) Neon branches; head version = 15.

M1b creates ONE new table (`payment_schedule`), FIVE new fn_ functions (4 user-facing + 1 SECURITY DEFINER audit helper), ONE new audit-trigger binding, FOUR new RLS policies (3 PERMISSIVE + 1 RESTRICTIVE), and consolidates two cross-module writes (CMW-1 enum extension, CMW-2 drafter export grant). Seven migrations applied total (009..015).

---

## Tables

### `payment_schedule` — owned entity

**Purpose.** Per-contract milestone payment schedule. Reconstituted from the Lovable types.ts + ALTER chain per HITL Gate 1 G1. `fn_payment_schedule_create_bulk` is the canonical bulk writer (replace-existing); inserts via the wizard submit flow. CASCADE-deletes from parent contract. RLS inherits visibility from parent contract (parent-aware pattern).
**Owned by:** M1b. **Audit columns:** full. **Audit trigger:** `audit_payment_schedule_changes` (binds M0 `fn_audit_trigger`). **RLS:** enabled (4 policies; 1 RESTRICTIVE). **Soft delete:** `is_active`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `contract_id` | BIGINT | NOT NULL, FK contract(id) ON DELETE CASCADE | Parent contract. Milestones live and die with the contract. |
| `milestone_label_en` | VARCHAR(255) | NOT NULL | Short display tag (e.g. "Milestone 1", "Phase 2 Payment"). Required. Retained alongside `milestone_name_en` per Q6 — label = short tag for quick scan, name = descriptive title for full context. |
| `milestone_label_ar` | VARCHAR(255) | nullable | Arabic counterpart of `milestone_label_en`. |
| `milestone_name_en` | VARCHAR(500) | nullable | Descriptive title for the milestone, longer than the label. Retained alongside `milestone_label_en` per Q6 — distinct UX roles. Do not consolidate. |
| `milestone_name_ar` | VARCHAR(500) | nullable | Arabic counterpart of `milestone_name_en`. |
| `amount_aed` | NUMERIC(15,2) | NOT NULL CHECK (>= 0) | Milestone payment amount in AED. Zero allowed for waived/cancelled milestones. NOT flagged sensitive. |
| `due_date` | DATE | nullable | |
| `paid_at` | TIMESTAMPTZ | nullable | Set when status flips to `paid`. |
| `status` | VARCHAR(20) | NOT NULL DEFAULT 'pending', CHECK enum | 6 values: `pending`, `due`, `paid`, `overdue`, `waived`, `cancelled`. |
| `recurrence` | VARCHAR(20) | CHECK enum OR NULL | NULL = single. 4 values: `once`, `monthly`, `quarterly`, `annually`. |
| `invoice_ref` | VARCHAR(100) | nullable | Free-text external invoice reference. Carried through to PDF export. |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `updated_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | |
| `created_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | |
| `updated_by` | BIGINT | nullable, FK "user"(id) ON DELETE SET NULL | |
| `is_active` | BOOLEAN | NOT NULL DEFAULT TRUE | Soft-delete flag. Flipped to FALSE only by `fn_payment_schedule_create_bulk` replace path or via parent contract CASCADE. **Direct DELETE is denied** by `payment_schedule_deny_direct_delete` RESTRICTIVE policy. |

**Row-level constraints:**

| Constraint | Definition | Purpose |
|---|---|---|
| `chk_payment_schedule_paid_at_status` | CHECK (paid_at IS NULL OR status = 'paid') | Sanity: only milestones in `paid` status may carry a `paid_at` timestamp. Transitional invariant; not strict on inserts. |

**Indexes (8 total: PK + 7 created):**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| (PK) | `(id)` | BTREE | Primary key. |
| `idx_payment_schedule_contract_id` | `(contract_id)` | BTREE | FK index. Powers `fn_payment_schedule_list` parent lookup and ON DELETE CASCADE traversal. |
| `idx_payment_schedule_active` | `(id) WHERE is_active = TRUE` | BTREE partial | Soft-delete-aware reads. |
| `idx_payment_schedule_due_date` | `(due_date) WHERE is_active = TRUE AND due_date IS NOT NULL` | BTREE partial | Upcoming/overdue milestone queries. |
| `idx_payment_schedule_status` | `(status) WHERE is_active = TRUE` | BTREE partial | Optional status filter on `fn_payment_schedule_list`. |
| `uq_payment_schedule_contract_label_active` | `(contract_id, milestone_label_en) WHERE is_active = TRUE` | BTREE UNIQUE partial | Prevents duplicate active milestone label within a contract. Trivially satisfied by the replace path. |
| `idx_payment_schedule_created_by` | `(created_by) WHERE created_by IS NOT NULL` | BTREE partial | Audit FK. |
| `idx_payment_schedule_updated_by` | `(updated_by) WHERE updated_by IS NOT NULL` | BTREE partial | Audit FK. |

**Audit trigger:** `audit_payment_schedule_changes` (AFTER INSERT/UPDATE/DELETE → M0 `fn_audit_trigger`).

**`is_seed` Lovable column dropped per Agent 3 recommendation:** v2.6 seed mechanism is migration-based; no functional consumer in M1b application code. If FE reconstitution needs it, re-add via additive migration.

### `contract_activity` — EXTEND (CMW-1)

`activity_type` CHECK enum extended from 7 to 9 values via migration 010. Migration uses a `DO $$` block + `pg_constraint` lookup to find M1a's anonymous CHECK constraint name (W3) before issuing a stable-named replacement: `contract_activity_activity_type_check`. New values added: `payment_schedule_replaced` (emitted by `fn_payment_schedule_create_bulk` replace path), `exported` (emitted by the BE controller after a successful PDF render, post-migration 015).

Migration 013 (smoke patch) extends `fn_contract_activity_create`'s server-side activity-type whitelist to accept the same 9 values — without 013, the function rejects the new types with `RAISE EXCEPTION 'activityType:Invalid activity type'` even though the table CHECK accepts them.

| Enum value | Owner | Emitter | Notes |
|---|---|---|---|
| `created` | M1a | trigger `trg_contract_activity_emit_iu` | |
| `updated` | M1a | `fn_contract_update` direct emit | |
| `status_changed` | M1a | `fn_contract_status_update` + trigger | De-duped. |
| `version_created` | M1a | trigger `trg_contract_version_activity_emit` | |
| `tagged` | M1a | `fn_contract_set_tags` direct emit | |
| `soft_deleted` | M1a | trigger | |
| `restored` | M1a | trigger | |
| `payment_schedule_replaced` | **M1b** | `fn_payment_schedule_create_bulk` replace path (AC-S3-10) | Metadata: `{insertedCount, softDeletedCount}`. |
| `exported` | **M1b** | BE controller after `renderContractPdf` (AC-S4-06; post-015 emission moved off the fn_) | Metadata: `{format, language, includeAttachments}`. PDF only — XLSX uses `audit_log` (AC-S5-08). |

### `role_permission` — extend (CMW-2)

Pure-data INSERT in migration 010. Adds one row granting `contract.export` permission to the `contract_drafter` role (idempotent via `ON CONFLICT (role_id, permission_id) DO NOTHING`). Pre-existing grants on `contract.export` (legal_counsel, platform_admin, Super Admin) remain unchanged.

---

## Functions (5 new)

### `fn_payment_schedule_create_bulk(p_contract_id BIGINT, p_rows JSONB, p_replace_existing BOOLEAN DEFAULT FALSE, p_actor_id BIGINT) RETURNS JSONB`

**Type:** Write. **Security:** INVOKER. **search_path:** `public, pg_temp` (pinned).
**Purpose.** Atomic bulk insert (or replace) of milestone rows for a given contract. Used by both the standalone PUT `/payment-schedules` endpoint AND the Compose Wizard submit flow. Concurrency-safe via `SELECT FOR UPDATE` on the parent contract head row (Codex BE-001 hardening, AC-S3-11).

**Business rules:**
- `jsonb_array_length(p_rows) >= 1` and `<= 100`; else `RAISE` with field `rows`.
- TOCTOU defence: `SELECT id, is_active FROM contract WHERE id = p_contract_id FOR UPDATE` BEFORE any per-row read/write. Parent must be active or `RAISE 'id:Contract not found'`.
- Per-row validation loop (after parent lock acquired): `milestoneLabelEn` 1..255 chars; `amountAed >= 0`; `status` in 6-value enum; `recurrence` in 4-value enum (or NULL).
- Replace path (`p_replace_existing = TRUE`): UPDATE `is_active = FALSE` on existing active rows for the contract, then INSERT new rows.
- ONE `contract_activity('payment_schedule_replaced')` emission per replace-path invocation (AC-S3-10) via `fn_contract_activity_create` with metadata `{insertedCount, softDeletedCount}`. Append path (`p_replace_existing = FALSE`) does NOT emit (AC-S3-10 — append is per-row data write, not a "replaced" event).
- All errors RAISE atomically — txn rollback covers the lock + soft-delete + inserts + activity emit.

**Return JSONB:** `{contractId, inserted, softDeleted, rows: PaymentSchedule[]}`.

**RAISE list (field:message → HTTP):**
- `rows:rows must be a non-empty array` → 400
- `rows:Maximum 100 milestones per batch` → 400
- `id:Contract not found` → 404
- `rows[<i>].milestoneLabelEn:Milestone label is required` → 400
- `rows[<i>].amountAed:Amount must be greater than or equal to zero` → 400
- `rows[<i>].status:Invalid status value` → 400
- `rows[<i>].recurrence:Invalid recurrence value` → 400

### `fn_payment_schedule_list(p_contract_id BIGINT, p_actor_id BIGINT, p_actor_role TEXT DEFAULT NULL, p_status TEXT DEFAULT NULL) RETURNS JSONB`

**Type:** Read. **Security:** INVOKER STABLE. **search_path:** `public, pg_temp` (pinned).
**Purpose.** Returns the active payment milestone list for a contract, ordered by `due_date ASC NULLS LAST` then `id ASC`. NOT paginated.

**Business rules:**
- Parent visibility check: `SELECT id, is_active FROM contract WHERE id = p_contract_id`. If not found / inactive → return NULL (controller maps to 404 — AC-S2-02 / AC-S2-03 layered defence).
- Optional status filter validated against the 6-value enum; else `RAISE 'status:Invalid status value'`.
- Empty `data` array (NOT NULL) when contract exists + visible but has zero milestones (AC-S2-04).
- Only `is_active = TRUE` rows returned (AC-S2-05).

**Return JSONB:** `{data: [{id, contractId, milestoneLabelEn, milestoneLabelAr, milestoneNameEn, milestoneNameAr, amountAed, dueDate, paidAt, status, recurrence, invoiceRef, createdAt, updatedAt}, ...]}`.

**RAISE list:**
- `status:Invalid status value` → 400.

### `fn_contract_export_pdf(p_contract_id BIGINT, p_actor_id BIGINT, p_actor_role TEXT DEFAULT NULL, p_language TEXT DEFAULT 'bilingual', p_include_attachments BOOLEAN DEFAULT FALSE) RETURNS JSONB`

**Type:** Read (data prep for renderer). **Security:** INVOKER **STABLE** (post-migration 015 — see below). **search_path:** `public, pg_temp` (pinned).
**Purpose.** Returns a denormalised, RLS-respecting JSONB payload shaped for the BE Puppeteer renderer. Single-contract export. Body in the requested language(s); tags + payment schedule aggregated inline.

**Migration 015 change (Codex BE-M1b-004):** the original spec emitted a `contract_activity('exported')` row inside the function. Migration 015 strips that emission so the function is a pure data-prep STABLE read; the BE controller now emits the `exported` activity row AFTER `renderContractPdf` resolves and BEFORE `res.send`. If the render throws, the activity row is never written.

**Business rules:**
- Validate `p_language IN ('en','ar','bilingual')`; else `RAISE 'language:Invalid language value'`.
- SELECT contract head WHERE `id = p_contract_id AND is_active = TRUE`. If not found → return NULL (controller → 404).
- Enrich `draftedBy` / `reviewedBy` / `approvedBy` as `UserRef` (mirrors `fn_contract_get_by_id`).
- Aggregate tags via `jsonb_agg(...) FROM contract_tag WHERE is_active = TRUE`.
- Aggregate `paymentSchedule` inline using the same row shape as `fn_payment_schedule_list`.
- `ourParty` / `counterparty` / `attachments` → return `null` with TODO marker per Q1 deferral.
- Body sourced from `contract.body_en` / `contract.body_ar` at the head pointer (current_version) — no join to `contract_version` per Q5.

**Return JSONB:** `{contract: {…head…, bodyEn, bodyAr, draftedBy, reviewedBy, approvedBy, …}, tags: [...], paymentSchedule: [...], ourParty: null, counterparty: null, attachments: null, exportLanguage, generatedAt}`.

**RAISE list:**
- `language:Invalid language value` → 400.
- (Returns NULL — does NOT raise — for not-found / unauthorized; controller maps to 404.)

### `fn_contract_export_xlsx(p_actor_id BIGINT, p_actor_role TEXT DEFAULT NULL, p_status TEXT DEFAULT NULL, p_contract_type VARCHAR DEFAULT NULL, p_counterparty_id BIGINT DEFAULT NULL, p_drafted_by BIGINT DEFAULT NULL, p_approved_by BIGINT DEFAULT NULL, p_start_date_from DATE DEFAULT NULL, p_start_date_to DATE DEFAULT NULL, p_end_date_from DATE DEFAULT NULL, p_end_date_to DATE DEFAULT NULL, p_tags TEXT[] DEFAULT NULL, p_search TEXT DEFAULT NULL, p_max_rows INTEGER DEFAULT 10000) RETURNS JSONB`

**Type:** Read (data prep for exceljs WorkbookWriter). **Security:** INVOKER STABLE. **search_path:** `public, pg_temp` (pinned).
**Purpose.** List-level XLSX export. Mirrors `fn_contract_list` filter set + role-aware visibility. body_en/body_ar EXCLUDED (AC-S5-02).

**Migration 012 fix:** the original spec used `p_tags <@ array_agg(t.tag)` where `p_tags` is `TEXT[]` and `t.tag` is `VARCHAR`. The `<@` operator has no resolution between `text[]` and `varchar[]`, aborting at plan time. Fix: `array_agg(t.tag::TEXT)` inside the EXISTS subquery so the comparison is text[] vs text[].

**Business rules:**
- Clamp `p_max_rows` to 1..50000; else `RAISE 'maxRows:maxRows must be between 1 and 50000'` (AC-S5-06).
- Returns `truncated = TRUE` flag when result count exceeds `p_max_rows`; controller emits `X-Export-Truncated: true` header + appends a translated "Result truncated…" footer row to the workbook (AC-S5-05).
- Empty result → `{rows: [], truncated: false}` — controller emits a header-only workbook (AC-S5-07).
- NO activity emission inside the function. The BE controller invokes `fn_audit_log_record` AFTER the workbook stream completes, with `new_values.event = 'EXPORT'` (per Q4 / W4 — `audit_log.action` stays in the M0 enum INSERT|UPDATE|DELETE; the EVENT discriminator distinguishes the row).

**Return JSONB:** `{rows: ContractExportXlsxRow[], totalRows, truncated, filterApplied}`.

**RAISE list:**
- `maxRows:maxRows must be between 1 and 50000` → 400.

### `fn_audit_log_record(p_table_name TEXT, p_record_id BIGINT, p_action TEXT, p_new_values JSONB, p_actor_id BIGINT) RETURNS JSONB`

**Type:** Write (audit helper). **Security:** **DEFINER**. **search_path:** `public, pg_temp` (pinned).
**Hardening (per `_securityNotes.fnAuditLogRecordHardening`):**
- `REVOKE EXECUTE FROM PUBLIC`.
- `GRANT EXECUTE TO neondb_owner` only (the BE service-role connection).
- App-role connections (the per-request RLS-bound role) cannot EXECUTE.
- Caller surface: ONLY the BE XLSX export controller.

**Purpose.** Single insertion point for `audit_log` rows from application controllers (used by the XLSX export to emit ONE audit row after a successful workbook stream). Validates `p_action IN ('INSERT','UPDATE','DELETE')` to keep the M0 enum stable; the EVENT discriminator inside `new_values.event` (`'EXPORT'` for M1b XLSX) distinguishes the row.

---

## RLS policies (4 new on `payment_schedule`)

| Policy name | Command | Type | Condition (USING / WITH CHECK) |
|---|---|---|---|
| `payment_schedule_select_parent_visible` | SELECT | PERMISSIVE | EXISTS subquery on parent `contract` row visible per `contract_select_role_aware` (parent-aware). |
| `payment_schedule_insert_parent_writable` | INSERT | PERMISSIVE | WITH CHECK: parent contract is editable by the actor (mirrors `contract_update_owner_or_admin` predicate). |
| `payment_schedule_update_parent_writable` | UPDATE | PERMISSIVE | USING + **WITH CHECK** (post-migration 014 — Codex BE-M1b-006 hardening). Both clauses gate on parent contract editability. WITH CHECK prevents privilege escalation by reassigning `contract_id` in the post-image. |
| `payment_schedule_deny_direct_delete` | DELETE | **RESTRICTIVE** | USING (FALSE). Direct DELETE always denied; rows lifecycle through `is_active` flip OR parent ON DELETE CASCADE. |

**Migration 014 (Codex BE-M1b-006):** drops the original UPDATE policy that omitted `WITH CHECK` and recreates it with explicit `WITH CHECK` mirroring USING (excluding `is_active = TRUE` so soft-delete-style updates remain feasible). Closes a privilege-escalation path where a draft-permission user could repoint their schedule rows to another user's contract via UPDATE.

---

## Roles & permissions (extensions)

| What | Where | Notes |
|---|---|---|
| Drafter export grant | `role_permission` (CMW-2 in migration 010) | INSERT one row: `contract_drafter` × `contract.export`. Idempotent. |
| New permissions | none | M1b adds zero permissions; reuses `contract.export` (defined in M1a) and the M1a `contract.read.*` family. |
| New roles | none | M1b adds zero roles. |

---

## Migrations applied (7 total — 009..015)

| # | File | Contents |
|---|---|---|
| 009 | `009_m1b_payment_schedule.sql` | `CREATE TABLE payment_schedule` (17 cols: 13 Lovable after dropping `is_seed` + 4 audit/soft-delete) + COMMENTs (esp. milestone_label_* and milestone_name_* per Q6) + 7 indexes + audit trigger binding + ENABLE RLS + 4 RLS policies (3 PERMISSIVE + 1 RESTRICTIVE deny-direct-DELETE). |
| 010 | `010_m1b_extend_m1a.sql` | **CMW-1**: dynamic `pg_constraint` lookup for M1a's anonymous activity_type CHECK (W3) + DROP + ADD `contract_activity_activity_type_check` (stable name, 9 values). **CMW-2**: INSERT `role_permission` granting `contract.export` to `contract_drafter` (idempotent ON CONFLICT). |
| 011 | `011_m1b_export_and_payment_functions.sql` | 5 fn_ bodies: `fn_audit_log_record` (DEFINER + REVOKE PUBLIC + GRANT neondb_owner), `fn_payment_schedule_list` (INVOKER STABLE), `fn_payment_schedule_create_bulk` (INVOKER + SELECT FOR UPDATE), `fn_contract_export_pdf` (INVOKER STABLE — post-015), `fn_contract_export_xlsx` (INVOKER STABLE). |
| 012 | `012_m1b_fix_export_xlsx_tags.sql` | DB Implementation patch: fix `text[] <@ varchar[]` operator-resolution failure in `fn_contract_export_xlsx`. Casts `array_agg(t.tag::TEXT)`. AC-S5-02 regression-locked. |
| 013 | `013_m1b_extend_activity_create_whitelist.sql` | Smoke patch: extends `fn_contract_activity_create`'s in-function activity-type whitelist to 9 values matching the table CHECK. AC-S3-10 + AC-S4-06 + AC-S1-10 regression-locked. |
| 014 | `014_m1b_fix_payment_schedule_rls_with_check.sql` | Codex BE-M1b-006: DROP + recreate `payment_schedule_update_parent_writable` with WITH CHECK mirroring USING (excluding `is_active=TRUE`). Closes privilege-escalation via `contract_id` reassignment. |
| 015 | `015_m1b_export_pdf_strip_activity_emit.sql` | Codex BE-M1b-004: `CREATE OR REPLACE` `fn_contract_export_pdf` minus the activity emit. Function is now STABLE; BE controller is the sole emitter (AFTER successful render, BEFORE response). |

All 7 migrations applied to dev branch (`m0-foundation`) AND test branch (`test`). Idempotency verified.

---

## Cross-module writes (CMW)

| ID | Target | Operation | Backward-compatible | Rollback guarded |
|---|---|---|---|---|
| **CMW-1** | `contract_activity.activity_type` CHECK enum (M1a-owned) | Migration 010 dynamic-name DROP + ADD with stable name, 7→9 values. | Yes — additive. | Yes — DO block restores anonymous CHECK with the original 7 values. |
| **CMW-2** | `role_permission` junction (M0-owned) | Migration 010 INSERT one row (contract_drafter × contract.export), `ON CONFLICT DO NOTHING`. | Yes — additive. | Rollback DELETE matches both columns. |

**Precondition for CMW-2:** the M1a registry note states "`contract.export` Required by M1b but defined in M1a so role seeds reference it." Migration 003 already created the permission; migration 010 only inserts the junction.

---

## Codex review — security findings & resolutions (M1b)

| ID | Severity | Finding | Resolution | Migration / file |
|---|---|---|---|---|
| **BE-M1b-001** | HIGH | XLSX audit row emitted before workbook renders → if render throws, audit is committed without delivery. | Reordered controller: render first, then `fn_audit_log_record` (with its own try/catch — non-fatal warn on failure), then `res.send(buffer)`. | `src/controllers/contracts.controller.ts` L867-933. |
| **BE-M1b-002** | HIGH | Formula injection in XLSX cells (`=HYPERLINK(...)`, `+SUM(...)`, etc.). | Added `sanitizeCellValue` helper in `contract-xlsx.service.ts` — prefixes `\t` to dynamic string cells whose first non-whitespace char is `= + - @`. Numbers/dates/booleans pass through unchanged. | `src/services/export/contract-xlsx.service.ts` L19-73. |
| **BE-M1b-003** | HIGH | Per-request Puppeteer browser launch — DoS surface (~50–100 MB Chromium spin-up per request). | New singleton browser pool (`puppeteer-pool.service.ts`) with `withPage()` helper and `p-limit(PUPPETEER_MAX_CONCURRENT)` semaphore (default 2, hard cap 16). Graceful shutdown awaits `closePuppeteerBrowser()`. | New `src/services/export/puppeteer-pool.service.ts`; `contract-pdf.service.ts` rewritten to use pool. |
| **BE-M1b-004** | MEDIUM | `fn_contract_export_pdf` was NOT marked STABLE because it emitted a `contract_activity('exported')` row inline → audit emission ordering inconsistent with XLSX. | Migration 015 strips activity emission from the fn_; fn_ is now STABLE. Controller emits `contract_activity('exported')` AFTER `renderContractPdf` resolves, BEFORE `res.send`. | Migration 015 + `src/controllers/contracts.controller.ts` `exportPdf`. |
| **BE-M1b-005** | MEDIUM | pg SQLSTATE 23514 (check_violation) unmapped in `translatePgError` — leaked raw constraint name to clients. | `case '23514' → ValidationError('Data violates database constraint', { check: 'invalid' })`. Generic message; raw constraint name logged but not surfaced. | `src/database/client.ts` `translatePgError`. |
| **BE-M1b-006** | MEDIUM (DB) | RLS `payment_schedule_update_parent_writable` had `WITH CHECK (TRUE)` — privilege escalation by repointing `contract_id` to a contract the actor cannot edit. | Migration 014 DROP + CREATE with `WITH CHECK` mirroring USING (excluding is_active). | Migration 014. |
| **F-FE-001** | HIGH (FE) | Export service used direct `fetch` — bypassed Axios 401-refresh interceptor → exports failed for users with expiring access tokens. | Rewrote `contract-export.service.ts` to use `apiClient.get<Blob>` with `responseType: 'blob'`. Now goes through 401 → refresh → retry pipeline. | FE `src/services/api/contract-export.service.ts`. |
| **F-FE-002** | HIGH (FE) | Compose Wizard double-submit created duplicate contracts (POST repeated). | Added `submittingRef = useRef(false)` synchronous guard on `submit()` and `retryStep2()` in `useComposeSubmit.ts`. Lock held across full POST→PUT sequence. | FE `src/features/contracts/wizard/useComposeSubmit.ts`. |
| **F-FE-M1** | MEDIUM (FE) | Compose draft localStorage retained sensitive body indefinitely. | `_savedAt` envelope + 24h TTL eviction on read; backwards-compat with legacy drafts (round-2 follow-up FE-R2-001 addressed legacy-draft re-leak). | FE `src/features/contracts/wizard/useComposeDraft.ts`. |
| **F-FE-M2** | MEDIUM (FE) | Export error toasts indistinguishable across 401/403/429. | `translateApiError` per-namespace lookup + RATE_LIMITED / TOO_MANY_REQUESTS → CODE_TO_KEY; export entry points pass `errors.export.failed` fallback. en/ar parity preserved. | FE `src/lib/translate-api-error.ts` + i18n. |
| **F-FE-M3** | MEDIUM (FE) | Blob downloads accepted any 200 Content-Type. | Optional `expectedContentType` parameter on `downloadBlobWithHeaders` + `BlobContentTypeMismatchError` typed throw. PDF/XLSX call sites pass expected MIME. | FE `src/lib/format-blob-download.ts`. |

Codex round-2 verdict: **APPROVED** (BE) and **APPROVED** (FE). All 11 findings resolved.

---

## Sensitive columns (M1b additions)

M1b introduces no new sensitive fields. `body_en` / `body_ar` (M1a-defined) are surfaced into `ContractExportPdfHead` for PDF rendering; pino-redact paths added for the export controller request lifecycle: `contract.bodyEn`, `contract.bodyAr`, `rows[*].bodyEn`, `rows[*].bodyAr` (Q5 decision).

The project-wide sensitive list remains 19 names (M0 17 + M1a 2). Mirrored in `fn_audit_trigger`, TypeScript constants, and pino redact paths.

---

*Generated by Documentation Generator from db-design.md, db-implementation-summary.json, codex-be-patch-summary.md, codex-fe-patch-summary.md, and applied migrations 009..015.*

---
---

# M3 — Signatures + Signer Q&A AI

> **Module:** M3 (Signatures + Signer Q&A AI — sixth module).
> **Generated:** 2026-05-04.
> **Migration window:** 032..039 (6 design migrations + 2 mid-flight patches).
> **DB head version:** 39 on both `test` and `m0-foundation` Neon branches.
> **Detailed module dictionary:** [`database/M3-data-dictionary.md`](database/M3-data-dictionary.md) (per-module dictionary file pending; this section is the canonical M3 data-dictionary append).

M3 introduces the signature ceremony + signer Q&A AI surface. **6 new tables** (4 transactional + 2 reference), **11 new fn_ functions** (2 read + 9 write — including 2 cron-only and 5 SECURITY DEFINER PUBLIC), **3 extended fn_'s** owned by M0/M1a/M2 (CC-1, AE-1, CC-2), **35 indexes**, **20 RLS policies**, **4 audit triggers** (vs 6 designed — see DB Impl I-1), **2 immutability triggers** (denormalised-FK consistency on signature_invitation + signature_event), **1 append-only deny-update trigger** on signature_event, **3 new permissions**, **20 seed rows** (3 signer sides + 4 signature methods + 3 permissions + 10 role-permission grants).

**Key novel pattern: 5 PUBLIC EXECUTE grants.** This is the first module to use SECURITY DEFINER + GRANT EXECUTE TO PUBLIC for token-bearer authentication. The 5 public fn_'s authenticate via SHA-256 hash-and-match of the `invitation_token` (and `session_token` where applicable) inside the fn body. CC-4 Option A locked at HITL Gate 2.

---

## Tables (6 new — 4 transactional + 2 reference)

### `signature_party_side` — reference / lookup

**Purpose:** Bilingual lookup for `signature_party.signer_side` enum (replaces a CHECK constraint per Agent 4 Rule 8 — lookup table for dropdown values).
**Owned by:** M3. **Audit columns:** standard 4 (created_at, updated_at, created_by, updated_by, is_active). **RLS:** enabled + FORCE; 2 policies (authenticated SELECT + admin modify). **Audit trigger:** none — see DB Impl I-1 (canonical fn_audit_trigger references NEW.id; this code-PK table dropped its trigger in migration 035 mid-flight).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `code` | VARCHAR(20) | PRIMARY KEY | Stable enum code (`employer`, `counterparty`, `witness`). |
| `label_en` | VARCHAR(80) | NOT NULL | English display label. |
| `label_ar` | VARCHAR(80) | NOT NULL | Arabic display label. |
| `sort_order` | INTEGER | NOT NULL DEFAULT 0 | Sort hint for UI. |

**Seeded rows (migration 035 §7.1):** 3 — `employer`, `counterparty`, `witness`.

---

### `signature_method` — reference / lookup

**Purpose:** Bilingual lookup for the 4 signature methods. `is_enabled` allows runtime feature-flag of a method without dropping rows (AC-S4-12 surfaces `is_enabled=FALSE` as `invalid_method`).
**Owned by:** M3. **Audit columns:** standard 4. **RLS:** enabled + FORCE; 2 policies (PUBLIC-readable SELECT — required by unauthenticated signer page + admin modify). **Audit trigger:** none (DB Impl I-1).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `code` | VARCHAR(20) | PRIMARY KEY | `uae_pass`, `ds_otp`, `drawn`, `typed`. |
| `label_en` | VARCHAR(80) | NOT NULL | English display label. |
| `label_ar` | VARCHAR(80) | NOT NULL | Arabic display label. |
| `verification_strength` | INTEGER | NOT NULL CHECK 1..4 | 1=lowest (typed), 4=highest (uae_pass). UX hint + sort. |
| `is_enabled` | BOOLEAN | NOT NULL DEFAULT TRUE | Runtime feature flag. |

**Seeded rows (migration 035 §7.2):** 4 — `uae_pass(4)`, `ds_otp(3)`, `drawn(2)`, `typed(1)` — all `is_enabled=TRUE`.

---

### `signature_party` — per-contract signer roster (transactional)

**Purpose:** Per-contract roster of who signs (employer / counterparty / witness). One row per signer per contract. `signer_user_id` MAY be NULL for external counterparty signers without a user account. `signer_party_id` is a forward-reference to a future Parties module — no FK constraint in M3 (mirrors M1a `contract.our_party_id` forward-FK pattern).
**Owned by:** M3. **Audit columns:** standard 4. **RLS:** 4 policies (role-aware SELECT + 3 RESTRICTIVE deny-direct-INSERT/UPDATE/DELETE). **Audit trigger:** `audit_signature_party_changes` (AFTER INSERT/UPDATE/DELETE).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `contract_id` | BIGINT | NOT NULL FK contract(id) RESTRICT | Parent contract. |
| `signer_side` | VARCHAR(20) | NOT NULL FK signature_party_side(code) | `employer` / `counterparty` / `witness`. |
| `signer_user_id` | BIGINT | nullable, FK "user"(id) | NULL for external counterparty signers without an account. |
| `signer_name_en` | VARCHAR(200) | NOT NULL, btrim length > 0 | Display name (EN). |
| `signer_name_ar` | VARCHAR(200) | nullable | Display name (AR). |
| `signer_email` | VARCHAR(255) | nullable, regex format | **[SENSITIVE]** Already in M2 029 redact list. |
| `signer_phone` | VARCHAR(40) | nullable | **[SENSITIVE]** Already in M2 029 redact list; never returned by any read path. |
| `signer_party_id` | BIGINT | nullable, NO FK | Forward-reference to future party(id). |
| `step_order` | INTEGER | NOT NULL CHECK >= 1 | 1..N — determines signature order. |
| `is_required` | BOOLEAN | NOT NULL DEFAULT TRUE | Required vs witness/optional. |
| `created_at` / `updated_at` / `created_by` / `updated_by` / `is_active` | — | standard | — |

**Indexes (7):** `idx_signature_party_contract_id`, `idx_signature_party_signer_user_id` (partial), `idx_signature_party_signer_side`, `idx_signature_party_step_order` (composite), `idx_signature_party_active`, `idx_signature_party_created_by`, `idx_signature_party_updated_by`. Plus `uq_signature_party_active_per_step_email` (UNIQUE partial — supplies AC-S1-08 idempotency).

---

### `signature_invitation` — per-signer invitation lifecycle (transactional)

**Purpose:** Per-signer invitation token + lifecycle. One ACTIVE invitation per signature_party (UNIQUE partial). `invitation_token_hash` stores SHA-256 hash of the plaintext token; plaintext is returned ONCE on creation via JSONB and **never** persisted. Resending creates a new active row + soft-deactivates the prior. **CC-5 storage shape**: column is `*_hash`, not plaintext, mirrors M0 `token_blacklist`.
**Owned by:** M3. **Audit columns:** standard 4. **RLS:** 4 policies (role-aware SELECT + 3 RESTRICTIVE deny-direct-write). **Audit trigger:** `audit_signature_invitation_changes`. **Immutability trigger:** `trg_signature_invitation_contract_id_consistent` (BEFORE INSERT/UPDATE OF contract_id, signature_party_id — enforces denormalised-FK invariant).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `signature_party_id` | BIGINT | NOT NULL FK signature_party(id) RESTRICT | — |
| `contract_id` | BIGINT | NOT NULL FK contract(id) RESTRICT | Denormalised for RLS performance; trigger-enforced equality with parent signature_party.contract_id. |
| `invitation_token_hash` | TEXT | NOT NULL UNIQUE | **[SENSITIVE]** SHA-256 hex hash of plaintext token (`encode(digest($1, 'sha256'), 'hex')`). Plaintext NEVER persisted. Added to fn_audit_trigger redact list in M3 034. |
| `status` | VARCHAR(20) | NOT NULL DEFAULT 'pending', CHECK enum | `pending` / `viewed` / `signed` / `declined` / `expired` / `cancelled`. |
| `invitation_sent_at` | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | When the invitation was issued. |
| `invitation_expires_at` | TIMESTAMPTZ | NOT NULL, CHECK > sent_at | Default sent_at + 14 days. |
| `first_viewed_at` | TIMESTAMPTZ | nullable | First time the signer hit the public landing page. Gate for idempotent 'viewed' event emission (AC-S3-03). |
| `last_viewed_at` | TIMESTAMPTZ | nullable | Latest view. |
| `view_count` | INTEGER | NOT NULL DEFAULT 0 | Total view count. |
| `ip_address` | INET | nullable | Last viewer IP. |
| `user_agent` | TEXT | nullable | Last viewer UA. |
| `language` | VARCHAR(8) | NOT NULL DEFAULT 'en' CHECK ('en','ar') | Language for the public signer page. |
| standard audit columns | — | — | — |

**Indexes (7+):** UNIQUE `uq_signature_invitation_one_active_per_party` (partial — exactly one active row per party), UNIQUE `uq_signature_invitation_token_hash` (the hottest read path), `idx_signature_invitation_due` (cron expiry SKIP LOCKED scan), `idx_signature_invitation_contract_id`, `idx_signature_invitation_party_id`, `idx_signature_invitation_status`, `idx_signature_invitation_active`, plus created_by / updated_by.

---

### `signature_event` — append-only event log (transactional)

**Purpose:** Append-only event log. One row per signed/declined/expired/cancelled/viewed/resent action. Mirrors M2 `approval_decision` append-only pattern. **UPDATE/DELETE blocked** by `trg_signature_event_deny_update` (BEFORE UPDATE — RAISE 42501) **plus** RLS deny-update policy (defense-in-depth).
**Owned by:** M3. **Audit columns:** `created_at` + `is_active` only (no `updated_*`). **RLS:** 4 policies (parent-aware SELECT via EXISTS contract + 3 RESTRICTIVE deny-write). **Audit trigger:** `audit_signature_event_changes` (AFTER INSERT only). **Immutability trigger:** `trg_signature_event_contract_id_consistent` (BEFORE INSERT — denormalised-FK invariant).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | — |
| `signature_invitation_id` | BIGINT | NOT NULL FK signature_invitation(id) RESTRICT | — |
| `contract_id` | BIGINT | NOT NULL FK contract(id) RESTRICT | Denormalised; trigger-enforced equality with parent invitation.contract_id. |
| `event_type` | VARCHAR(30) | NOT NULL, CHECK enum | `viewed` / `signed` / `declined` / `expired` / `cancelled` / `resent`. |
| `signature_method` | VARCHAR(20) | nullable, FK signature_method(code) | Required when event_type='signed'. |
| `uae_pass_verification_level` | VARCHAR(20) | nullable, CHECK ('basic','verified','premium') | Required when signature_method='uae_pass'. |
| `signature_image_url` | TEXT | nullable | **[SENSITIVE]** Net-new in M3 034 redact list. NEVER returned by any read path. |
| `signature_data` | TEXT | nullable | **[SENSITIVE]** Verbatim signature payload. Net-new in M3 034 redact list. |
| `decline_reason` | TEXT | nullable, length 5..2000 when set | Required when event_type='declined'. |
| `ip_address` | INET | nullable | — |
| `user_agent` | TEXT | nullable | — |
| `actor_user_id` | BIGINT | nullable, FK "user"(id) | NULL for external-signer events (AN-9); NULL via system-actor sentinel for cron-driven events. |
| `metadata` | JSONB | nullable | Event-specific payload (e.g. `{ otpReceipt }`, `{ newInvitationId, reason }` for resent, `{ autoExpiredAt }`). |

**Method-gating CHECK constraints (db-design.md §1.5):** `chk_signature_event_signed_has_method`, `chk_signature_event_declined_has_reason`, `chk_signature_event_uae_pass_level_required`, `chk_signature_event_decline_reason_length`.

---

### `signer_qa_session` — per-invitation chat session (transactional)

**Purpose:** Per-invitation Q&A chat session. **Stores ONLY metadata** — counters + last-activity + rate-limit window — **NO chat transcript persisted** (AN-2 transcriptStorage / DN-11). One row per invitation_token + browser session; up to 5 active sessions per invitation (AN-12 sliding-window soft-deactivate-oldest).
**Owned by:** M3. **Audit columns:** standard 4. **RLS:** 4 policies (admin-only SELECT — token-bearer reads go via DEFINER fn_ + 3 RESTRICTIVE deny-write). **Audit trigger:** `audit_signer_qa_session_changes`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | — |
| `signature_invitation_id` | BIGINT | NOT NULL FK signature_invitation(id) RESTRICT | — |
| `session_token_hash` | TEXT | NOT NULL UNIQUE | **[SENSITIVE]** SHA-256 hex hash of plaintext session_token. Plaintext returned ONCE. Net-new in M3 034 redact list. |
| `message_count` | INTEGER | NOT NULL DEFAULT 0 | Cumulative messages (post-COMMIT mode). |
| `tokens_consumed` | INTEGER | NOT NULL DEFAULT 0 | Cumulative tokens. |
| `last_activity_at` | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Sliding-window oldest sentinel. |
| `rate_limit_window_start` | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Rolling 1-hour rate window start. |
| `rate_limit_count` | INTEGER | NOT NULL DEFAULT 0 | Slots consumed in current window. |
| `language` | VARCHAR(8) | NOT NULL DEFAULT 'en' CHECK ('en','ar') | Locked at session start (AN-2 languageLock; AC-S11-05). |

---

## Functions (11 new + 3 extended)

| Function | Type | SECURITY | GRANT | Purpose |
|---|---|---|---|---|
| `fn_signature_party_create_bulk` | Write | INVOKER | neondb_owner | S1 — bulk-create signer roster. ON CONFLICT idempotent (AC-S1-08). FOR UPDATE on contract head. |
| `fn_signature_send_for_signature` | Write | INVOKER | neondb_owner | S2 — issue invitation tokens for lowest-step_order signers; transition contract.status approved → awaiting_signature_employer. |
| `fn_signature_invitation_resend` | Write | INVOKER | neondb_owner | S7 — soft-deactivate prior + create fresh invitation with extended expiry. Emits 'resent' event on OLD invitation. |
| `fn_signature_invitation_cancel` | Write | INVOKER | neondb_owner | S8 — cancel invitation; conditionally roll contract back to 'approved' when last active at current step. |
| `fn_signature_sign` | Write | **DEFINER** | **PUBLIC** | S4 — record a signature. Step-completion advances contract.status awaiting_signature_employer → awaiting_signature_counterparty → fully_signed. |
| `fn_signature_decline` | Write | **DEFINER** | **PUBLIC** | S5 — record a decline; required-signer halts contract (→ rejected); witness records event without status transition. |
| `fn_signature_invitation_expire_due` | Write | DEFINER | neondb_owner only (REVOKE PUBLIC) | S9 — cron-driven invitation expiry. NO HTTP exposure. SKIP LOCKED batch loop. |
| `fn_signer_qa_session_start` | Write | **DEFINER** | **PUBLIC** | S11 — open Q&A session. Returns sessionTokenPlaintext ONCE. Sliding-window soft-deactivate-oldest at 5+. |
| `fn_signer_qa_session_record_message` | Write | **DEFINER** | **PUBLIC** | S12 — two-call rate-limit pattern (GATE/COMMIT) for Q&A messages. |
| `fn_signature_get_by_invitation_token` | Read (VOLATILE) | **DEFINER** | **PUBLIC** | S3 — public landing page. Hashes plaintext + lookup + viewed-event ONCE + signer-safe excerpt. |
| `fn_signature_list_for_contract` | Read (STABLE) | INVOKER | neondb_owner | S6 — per-contract signature progress + role-aware email mask. Migration 038 added `currentInvitationId`; 039 fixed step-4 nested-aggregate latent bug. |

**Extended functions (byte-for-byte preserved except cited diff):**

| Function | Owner | Migration | Diff |
|---|---|---|---|
| `fn_contract_activity_create` | M1a | 032 | activity_type whitelist 14 → 20 values (+6: `sent_for_signature`, `signer_viewed`, `signer_signed`, `signer_declined`, `fully_executed`, `signature_invalidated`). Body byte-for-byte vs M2 031. |
| `fn_contract_status_update_internal` | M2 | 033 | Allowed-transitions IF condition extended with 9 signature-driven transitions. Signature `(BIGINT, TEXT, BIGINT, TEXT DEFAULT NULL) RETURNS jsonb` preserved. |
| `fn_audit_trigger` | M0 | 034 | `v_redact_fields` literal extended +4: `invitation_token_hash`, `session_token_hash`, `signature_data`, `signature_image_url`. Final size 25. |

**fn-trigger helpers (3):**

| Function | Trigger | Purpose |
|---|---|---|
| `fn_trg_signature_event_deny_update` | BEFORE UPDATE on signature_event | Append-only enforcement — RAISE 42501. |
| `fn_trg_signature_invitation_contract_id_consistent` | BEFORE INSERT/UPDATE OF (contract_id, signature_party_id) on signature_invitation | Denormalised-FK invariant. |
| `fn_trg_signature_event_contract_id_consistent` | BEFORE INSERT on signature_event | Denormalised-FK invariant. |

---

## Audit triggers — 4 applied (vs 6 designed)

**DB Impl Issue I-1:** the canonical `fn_audit_trigger` references `NEW.id` to populate `audit_log.record_id`. The two reference tables (`signature_party_side`, `signature_method`) use a **code-PK** (`code VARCHAR(20)`) and have no `id` column — attaching the audit trigger raised `42703 column NEW.id does not exist` on every INSERT/UPDATE/DELETE. Mid-flight fix during the test-branch run: drop the audit trigger from the two reference tables. Reference tables are admin-modify-only and rarely change; the loss of audit coverage is acceptable for the v1 ship.

**Recommended remediation as M3 follow-up:** either (a) add an `id BIGSERIAL UNIQUE` column to the two reference tables and re-add the audit trigger, or (b) add a permanent QA Stage 2 check that audit triggers are only attached to tables with an `id` column (DB Impl F-1).

| Trigger | Table | Events |
|---|---|---|
| `audit_signature_party_changes` | signature_party | INSERT, UPDATE, DELETE |
| `audit_signature_invitation_changes` | signature_invitation | INSERT, UPDATE, DELETE |
| `audit_signature_event_changes` | signature_event | INSERT only (UPDATE/DELETE blocked by trg_signature_event_deny_update + RLS) |
| `audit_signer_qa_session_changes` | signer_qa_session | INSERT, UPDATE, DELETE |
| (DROPPED) `audit_signature_party_side_changes` | signature_party_side | — — see I-1 |
| (DROPPED) `audit_signature_method_changes` | signature_method | — — see I-1 |

---

## RLS policies — 20 across 6 tables

Pattern mandate per `feedback_db_impl_report_dont_fix.md`: **no self-ref subqueries in WITH CHECK; immutability via BEFORE UPDATE triggers, not RLS RESTRICTIVE deny-direct-update.** ENABLE + FORCE on all 6 tables.

| Table | Policies | Notes |
|---|---|---|
| `signature_party` | 4 (1 SELECT role-aware + 3 RESTRICTIVE deny INSERT/UPDATE/DELETE) | Mirrors M1a `contract_select_role_aware`. Self-row visibility for the signer (`signer_user_id = current_user`). |
| `signature_invitation` | 4 | Token-bearer PUBLIC reads bypass RLS via DEFINER fn_. |
| `signature_event` | 4 | Parent-aware SELECT. Append-only deny-update is defense-in-depth alongside `trg_signature_event_deny_update`. |
| `signer_qa_session` | 4 | Admin-only SELECT (legal_counsel / platform_admin / Super Admin). |
| `signature_party_side` | 2 (authenticated SELECT + admin modify) | Reference table — global lookup. |
| `signature_method` | 2 | **PUBLIC-readable SELECT** — required by unauthenticated signer page. The ONLY M3 RLS-public table; preferred over a DEFINER bypass because the data is non-sensitive (4 enum rows). |

---

## PUBLIC EXECUTE grants (5 — novel pattern in this project)

CC-4 Option A locked at HITL Gate 2 (gate2-decisions.md). The 5 fn_'s below are the ONLY ones in the project with `EXECUTE GRANT TO PUBLIC`:

| Function | Auth model | Notes |
|---|---|---|
| `fn_signature_get_by_invitation_token` | invitation_token plaintext in URL path; SHA-256 hash-and-match | RETURNS NULL when token is unknown / expired / cancelled (controller maps 410 with single generic message — AC-S3-04). |
| `fn_signature_sign` | invitation_token | Method-gating + step-completion advance. |
| `fn_signature_decline` | invitation_token | Required-signer halt logic. |
| `fn_signer_qa_session_start` | invitation_token | Sliding-window soft-deactivate-oldest at 5+ (AN-12). |
| `fn_signer_qa_session_record_message` | invitation_token (URL) + session_token (X-Session-Token header); both SHA-256 hash-and-match | GATE/COMMIT two-call rate-limit pattern. |

**Stage 4 enumeration check (S2-21 candidate):** verified live via `pg_proc.proacl` query that exactly these 5 fn_'s carry `=X/neondb_owner` ACL and no others. Pattern stable through M3 ship; Dexian decision to formally codify as S2-21 is pending the next module's Stage 2 cycle.

---

## Sensitive-field redaction (M3 additions)

`fn_audit_trigger` `v_redact_fields` array final list = **25 names** (M2 029 had 21):

| Name | Origin | Notes |
|---|---|---|
| `invitation_token_hash` | M3 034 net-new | Belt-and-suspenders — the column is `*_hash` so the plaintext key never appears in JSONB diffs. Added per CC-2 / DN-4. |
| `session_token_hash` | M3 034 net-new | Same rationale. |
| `signature_data` | M3 034 net-new | Verbatim signature payload (typed/drawn). |
| `signature_image_url` | M3 034 net-new | Storage URL of canvas-rendered PNG. |

Already in M2 029: `signer_email`, `signer_phone`, `signature_image` (M3 does NOT redeclare — S2-19 byte-for-byte mandate; the M3 034 body diffs ONLY in the array literal vs M2 029).

**Plaintext token lifecycle** (`*_tokenPlaintext`):
- Generated server-side via `encode(gen_random_bytes(32), 'base64')` (pgcrypto).
- Hashed via `encode(digest($1, 'sha256'), 'hex')` and persisted as `*_token_hash`.
- Returned ONCE in the JSONB response on creation (`SignatureSendInvitationItem.invitationTokenPlaintext`, `ResendInvitationData.invitationTokenPlaintext`, `SignerQaSessionStartData.sessionTokenPlaintext`).
- Pino-redacted on egress logs (~12 sensitive-field name groups; ~80 path entries — `invitationToken`, `invitation_token`, `invitationTokenPlaintext`, `sessionToken`, `session_token`, `sessionTokenPlaintext`, `req.headers.x-session-token`, `req.params.invitationToken`).
- NEVER re-derivable. The fn_'s accept plaintext and compute the hash internally — mirrors M0 `fn_auth_check_token_blacklist`.

---

## ActivityType extension (AE-1 — cross-module additive)

`contract_activity.activity_type` CHECK enum widened M2 14 → M3 20 values (+6) in migration 032. The 6 net-new values are emitted by M3 fn_'s:

| Activity type | Emitted by |
|---|---|
| `sent_for_signature` | fn_signature_send_for_signature (S2) |
| `signer_viewed` | fn_signature_get_by_invitation_token (S3, ONCE per invitation per first view, AC-S10-04) |
| `signer_signed` | fn_signature_sign (S4) |
| `signer_declined` | fn_signature_decline (S5) |
| `fully_executed` | fn_signature_sign at fully_signed (S4) |
| `signature_invalidated` | reserved for cancel-rollback / mid-contract amendment flows (S8 + future) |

S2-19 byte-for-byte mandate: migration 032 body diffs from M2 031 ONLY in the `IF p_activity_type NOT IN (...)` literal.

---

## Permissions added (3) + role grants (10)

| Permission | Description | Roles granted (10 row inserts in migration 037) |
|---|---|---|
| `signature.send` | Create signer roster, send-for-signature, resend invitation | Super Admin (pre-emptive), platform_admin, legal_counsel, contract_drafter (own scope) |
| `signature.cancel` | Cancel invitation; drafter explicitly NOT granted (AC-S8-03) | Super Admin, platform_admin, legal_counsel |
| `signature.read.all` | Cross-contract signature read (executive scope) | Super Admin, platform_admin, executive |

Pre-emptive Super Admin grants per ND-6 (M1c 018 / M2 028 precedent — avoids post-smoke patch cycle).

---

## Migrations applied (8 total — 032..039)

| # | File | Contents |
|---|---|---|
| 032 | `032_m3_extend_contract_activity_check_and_whitelist.sql` | (a) DROP + ADD `contract_activity_activity_type_check` (14 → 20 values). (b) `CREATE OR REPLACE fn_contract_activity_create` extending whitelist. Atomic per M1b 010/013 split-cycle precedent. |
| 033 | `033_m3_extend_fn_contract_status_update_internal_for_signatures.sql` | `CREATE OR REPLACE fn_contract_status_update_internal` extending allowed-transitions IF condition by 9 signature-driven transitions. Body byte-for-byte vs M2 026 except the IF NOT (...) literal. |
| 034 | `034_m3_extend_audit_redact_list.sql` | `CREATE OR REPLACE fn_audit_trigger` extending `v_redact_fields` +4 (final 25). Body byte-for-byte vs M2 029 except the array literal. |
| 035 | `035_m3_signature_tables.sql` | All 6 tables + indexes + RLS + audit triggers + immutability triggers + reference seeds. **Mid-flight fix:** dropped audit triggers on signature_party_side + signature_method (DB Impl I-1). **Mid-flight fix:** added `CREATE EXTENSION IF NOT EXISTS pgcrypto` at the top (DB Impl I-2). |
| 036 | `036_m3_signature_functions.sql` | All 11 new fn_ + GRANT EXECUTE matrix (5 PUBLIC + 5 neondb_owner-only + 1 cron-only neondb_owner-only-with-explicit-REVOKE-PUBLIC). |
| 037 | `037_m3_signature_permissions_and_grants.sql` | 3 permission rows + 10 role_permission rows. Pre-emptive Super Admin grants. |
| 038 | `038_m3_extend_fn_signature_list_for_contract_with_invitation_id.sql` | Integration verifier R1 patch — added `currentInvitationId` projection to fn_signature_list_for_contract so the FE Signatures tab can target POST /signature-invitations/:id/cancel directly. |
| 039 | `039_m3_fix_fn_signature_list_for_contract_step4_nested_sum.sql` | Latent step-4 nested-aggregate bug surfaced by the 038 functional probe. CTE refactor; signature unchanged. |

All 8 migrations applied to `test` (`br-billowing-boat-ajq9m0g6`) AND `m0-foundation` (`br-snowy-brook-aje2ehtl`). Idempotency verified.

---

## Cross-module writes (CMW)

| ID | Target | Operation | Backward-compatible | Migration |
|---|---|---|---|---|
| **CC-1** | M2-owned `fn_contract_status_update_internal` allowed-transitions | Migration 033 — `CREATE OR REPLACE` extending IF condition by 9 signature transitions. | Yes — additive. Signature preserved. | 033 |
| **AE-1** | M1a-owned `contract_activity.activity_type` CHECK + `fn_contract_activity_create` whitelist | Migration 032 — DROP + ADD CHECK + `CREATE OR REPLACE` fn_. | Yes — additive (14 → 20 values). | 032 |
| **CC-2** | M0-owned `fn_audit_trigger` redact list | Migration 034 — `CREATE OR REPLACE` extending `v_redact_fields` +4. | Yes — additive (21 → 25). | 034 |

---

## Key DB Impl issues + outcomes

| ID | Severity | Topic | Outcome |
|---|---|---|---|
| **I-1** | HIGH | `fn_audit_trigger` requires id-PK on audited tables — ref tables use code-PK. | Audit triggers dropped from the 2 reference tables (4 of 6 designed). Recommend M3 follow-up: add `id` column or codify Stage 2 check. |
| **I-2** | HIGH | `pgcrypto` extension not present on either Neon branch. | Added `CREATE EXTENSION IF NOT EXISTS pgcrypto;` as the first statement of migration 035. |
| **I-3** | LOW | `fn_current_user_has_permission` canonical signature is 1-arg, not 2-arg as design narrative implied. | All M3 fn_'s implemented with the 1-arg form `fn_current_user_has_permission('signature.send')`. |
| **I-4** | INFO | Step-2+ invitation issuance delegated to BE (no DB-side auto-issue path). | DB-by-design. BE controller logs `signPublic.sign.next_step_required` when stepCompleted=true; drafter manually re-invokes POST /api/v1/contracts/:id/send-for-signature. |

---

## Concurrency primitive verification (S2-17)

| Function | Lock primitive |
|---|---|
| `fn_signature_party_create_bulk` | `SELECT FOR UPDATE` on contract head + per-party `FOR UPDATE` in loop. |
| `fn_signature_send_for_signature` | `FOR UPDATE` on contract head + per-party `FOR UPDATE` in loop. |
| `fn_signature_invitation_resend` | `FOR UPDATE` on signature_party + signature_invitation. |
| `fn_signature_invitation_cancel` | `FOR UPDATE` on contract + invitation + signature_party. |
| `fn_signature_sign` | `FOR UPDATE OF inv` (via JOIN) → `FOR UPDATE` on contract → `FOR UPDATE` on signature_party. Lock order documented in fn_ comments. |
| `fn_signature_decline` | `FOR UPDATE` on invitation (via JOIN) → contract → signature_party. |
| `fn_signature_invitation_expire_due` | `FOR UPDATE OF inv SKIP LOCKED` — cron-callable; live signers hold their row; cron skips. |
| `fn_signer_qa_session_record_message` | `FOR UPDATE` on signer_qa_session. |

---

## NULL-safe equality (S2-18)

`IS NOT DISTINCT FROM` used at:
- `fn_signature_sign` step-completion check — `sp.step_order IS NOT DISTINCT FROM v_current_step` (with LEFT JOIN + COUNT FILTER for nullable step_order).
- `fn_signature_invitation_expire_due` step-exhaustion check — `sp2.step_order IS NOT DISTINCT FROM v_inv.step_order`.

---

## System-actor sentinel (S2-20)

- Cron driver MUST execute `SET app.current_user_id = '0'` before invoking `fn_signature_invitation_expire_due` (AC-S9-04).
- `fn_contract_activity_create` coerces `v_actor IN (NULL, 0) → NULL` — preserved verbatim from M2 031 in M3 032 (S2-19 byte-for-byte mandate).
- External-signer events reach `actor_user_id = NULL` directly (no sentinel — invitation_token-authenticated path). Verified live via Testing Agent `M3-cron-and-system-actor.test.ts`: `signer_signed` / `fully_executed` / `signer_declined` activity rows confirmed `actor_id = null`.

---

*Generated by Documentation Generator from M3 db-design.md, db-implementation-summary.json, integration-verifier-report-r2.md, qa-stage4-report.md, and applied migrations 032..039.*

---

# M4 — AI Features

> **Module:** M4 — AI Features
> **Generated:** 2026-05-04
> **Module owner:** M4
> **Predecessor:** M3 (complete; M4 introduces 3 new AI-subsystem tables + 12 new fn_'s + extends fn_contract_activity_create + fn_audit_trigger).
> **Schema migration window:** 040 → 045 (5 designed + 1 DEFECT-1 patch).
> **Codex review:** SKIPPED per Dexian decision 2026-05-04. Stage 2 + Stage 4 absorbed safety net (S2-16..S2-20 + S2-21 PROMOTED + S2-22 codification recommended).

This dictionary documents the database surface introduced by M4: 3 new tables (`ai_prompt`, `ai_insight`, `ai_request_log`), 12 new fn objects + 1 trigger fn helper, 17 explicit M4 indexes (+2 PK auto + 1 UNIQUE auto = 20 physical), 4 RLS policies, 1 BEFORE-UPDATE deny-update trigger + 2 audit triggers, 4 new permissions / 12 distinct role grants, 6 ai_prompt seed rows, and 2 cross-module fn body extensions (no DDL changes on existing tables). For the wire surface see `api/openapi.yaml` (paths under `/api/v1/ai/*` and `/api/v1/admin/ai/*`).

---

## Tables

### 1. `ai_prompt` (reference, code-PK)

**Purpose.** Reference table holding per-prompt configuration: default model, temperature, max tokens, TTL, streaming/tool-call/public flags, rate limits, and the canonical prompt-file path on disk. The 6 seed rows mirror the 6 canonical M4 prompts (G7 — verbatim files in `[backend]/prompts/`).
**Owned by:** M4. **Audit columns:** standard 5 (created_at, updated_at, created_by, updated_by, is_active). **Audit trigger:** **OMITTED** (DB-IMPL-I-1 — code-PK incompatible with `fn_audit_trigger NEW.id`). Same precedent as M3 `signature_party_side` / `signature_method`. **RLS:** enabled.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `prompt_id` | VARCHAR(60) | PRIMARY KEY | Code-PK; matches the canonical prompt slug (e.g. `ai-contract-insights`). |
| `description_en` | TEXT | NOT NULL | English description for admin UIs. |
| `description_ar` | TEXT | NOT NULL | Arabic description. |
| `default_model` | VARCHAR(80) | NOT NULL | OpenAI model id (e.g. `gpt-4o`, `gpt-4o-mini`). |
| `default_temperature` | NUMERIC(3,2) | NOT NULL, CHECK 0..2 | Default sampling temperature. |
| `default_max_tokens` | INTEGER | NOT NULL, CHECK > 0 | Hard cap per AI call. |
| `default_ttl_seconds` | INTEGER | NOT NULL, CHECK >= 0 | ai_insight cache TTL; 0 = no caching (currently only ai-drafting-assistant). |
| `supports_streaming` | BOOLEAN | NOT NULL | Whether the prompt streams SSE. |
| `supports_tool_call` | BOOLEAN | NOT NULL | Whether the prompt uses OpenAI tool-call. |
| `public_endpoint` | BOOLEAN | NOT NULL DEFAULT FALSE | TRUE only for `ai-regulatory-impact-summary` (S5 signed-PDF-token path). |
| `prompt_file_path` | VARCHAR(255) | NOT NULL | Relative path to the verbatim prompt file in `[backend]/prompts/`. |
| `rate_limit_per_user_per_hour` | INTEGER | NOT NULL, CHECK > 0 | Per-user hourly cap. |
| `rate_limit_per_user_per_day` | INTEGER | NOT NULL, CHECK > 0 | Per-user daily cap. |
| `created_at` | TIMESTAMPTZ | DEFAULT NOW | Record creation. |
| `updated_at` | TIMESTAMPTZ | DEFAULT NOW | Last update. |
| `created_by` | BIGINT | FK → user.id ON DELETE SET NULL | |
| `updated_by` | BIGINT | FK → user.id ON DELETE SET NULL | |
| `is_active` | BOOLEAN | DEFAULT TRUE | Soft-delete. |

**Indexes (3):** `idx_ai_prompt_created_by` (BTREE on `created_by`), `idx_ai_prompt_updated_by` (BTREE on `updated_by`), `idx_ai_prompt_active` (BTREE on `prompt_id` WHERE `is_active=TRUE`).
**Audit trigger:** **OMITTED** (intentional; mirrors M3 signature reference tables).
**Seed rows (6):** `ai-contract-insights`, `ai-drafting-assistant`, `ai-executive-anomalies`, `ai-regulatory-impact`, `ai-regulatory-impact-summary`, `ai-version-diff-summary`.

---

### 2. `ai_insight` (transactional — polymorphic AI cache)

**Purpose.** AI insight cache. One active row per `(entity_type, entity_id, insight_type, language)`. Polymorphic — `entity_type` references `contract`, `contract_version`, `regulatory_update`, `regulatory_update_summary`, or `executive_dashboard` without a real FK (mirrors M0 `audit_log.table_name + record_id`). Read via `fn_ai_insight_get_cached`; written ONLY via `fn_ai_insight_upsert` (DEFINER) and soft-deactivated by `fn_ai_insight_evict_expired` (cron, DEFINER).
**Owned by:** M4. **Audit columns:** standard 5. **Audit trigger:** **STANDARD** (`audit_ai_insight_changes` — AFTER INSERT OR UPDATE OR DELETE). **RLS:** enabled.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `entity_type` | VARCHAR(40) | NOT NULL | Polymorphic discriminator. **Open-set** (no CHECK constraint, no lookup table). |
| `entity_id` | BIGINT | nullable | NULL allowed for cross-contract rows (executive_dashboard). |
| `insight_type` | VARCHAR(60) | NOT NULL | Open-set free-text (e.g. `contract_summary`, `executive_anomalies`, `version_diff_summary`). |
| `language` | VARCHAR(8) | NOT NULL, CHECK IN ('en','ar','bilingual') | |
| `payload_hash` | VARCHAR(64) | NOT NULL | SHA-256 of canonicalised inputs (entity content + prompt_id + language). |
| `prompt_id` | VARCHAR(60) | NOT NULL, FK → ai_prompt.prompt_id ON DELETE RESTRICT | |
| `provider` | VARCHAR(40) | NOT NULL, CHECK IN ('openai','anthropic') | |
| `model_used` | VARCHAR(80) | NOT NULL | |
| `payload` | JSONB | NOT NULL | **[SENSITIVE]** AI output payload (response, NOT prompt). Discriminated union by `insight_type`. Redacted in `fn_audit_trigger v_redact_fields` post-migration 041. |
| `tokens_input` | INTEGER | nullable | |
| `tokens_output` | INTEGER | nullable | |
| `cost_usd_micros` | BIGINT | nullable | Micro-dollars to avoid float. |
| `expires_at` | TIMESTAMPTZ | NOT NULL | TTL boundary; `fn_ai_insight_get_cached` treats `expires_at <= now()` as miss. |
| `created_at` | TIMESTAMPTZ | DEFAULT NOW | |
| `updated_at` | TIMESTAMPTZ | DEFAULT NOW | |
| `created_by` | BIGINT | FK → user.id ON DELETE SET NULL | |
| `updated_by` | BIGINT | FK → user.id ON DELETE SET NULL | |
| `is_active` | BOOLEAN | DEFAULT TRUE | Soft-delete (cron + upsert flip). |

**Indexes (8):**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| `idx_ai_insight_unique_active` | `(entity_type, COALESCE(entity_id,0::BIGINT), insight_type, language)` WHERE `is_active=TRUE` | UNIQUE BTREE (partial) | One active cache row per cache key. `COALESCE` enforces uniqueness across NULL entity_ids (DN-2). |
| `idx_ai_insight_payload_hash_active` | `(payload_hash)` WHERE `is_active=TRUE` | BTREE (partial) | S5 30-day content-addressed cache lookup. |
| `idx_ai_insight_expiry_sweep` | `(expires_at)` WHERE `expires_at IS NOT NULL AND is_active=TRUE` | BTREE (partial) | Cron eviction sweep (`fn_ai_insight_evict_expired`). |
| `idx_ai_insight_prompt_id` | `(prompt_id)` | BTREE | FK index. |
| `idx_ai_insight_created_by` | `(created_by)` | BTREE | FK index (audit join). |
| `idx_ai_insight_updated_by` | `(updated_by)` | BTREE | FK index (audit join). |
| `idx_ai_insight_active` | `(id)` WHERE `is_active=TRUE` | BTREE (partial) | Soft-delete partial. |
| `idx_ai_insight_by_entity` | `(entity_type, entity_id, created_at DESC)` WHERE `is_active=TRUE` | BTREE (partial) | Per-entity history (admin observability + entity-page sidebar). |

**Audit trigger:** `audit_ai_insight_changes` — AFTER INSERT OR UPDATE OR DELETE → `fn_audit_trigger`.
**Write-path restriction:** RLS deny-direct on INSERT/UPDATE/DELETE; only `fn_ai_insight_upsert` (DEFINER) and `fn_ai_insight_evict_expired` (DEFINER, cron-only) can write.

---

### 3. `ai_request_log` (append-only telemetry)

**Purpose.** Append-only telemetry log of every AI invocation attempt — success / error / timeout / rate_limited / cancelled, including cache_hit. One row per controller `finally{}` block. Drives admin observability (S11) + cost report (S12) + per-user rate-limit pre-flight (`fn_ai_request_log_check_rate_limit`).
**Owned by:** M4. **Audit columns:** `created_at` + `is_active` (no `updated_*`; append-only). **Audit trigger:** **STANDARD INSERT-only** (mirrors M3 `audit_signature_event_changes`). **RLS:** enabled.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | |
| `request_id` | UUID | NOT NULL, UNIQUE, DEFAULT gen_random_uuid() | Mirrored to `X-Request-ID` correlation header. |
| `prompt_id` | VARCHAR(60) | NOT NULL, FK → ai_prompt.prompt_id ON DELETE RESTRICT | |
| `mode` | VARCHAR(40) | nullable | Free-text mode discriminator per prompt (e.g. `summary`, `chat`). |
| `actor_user_id` | BIGINT | FK → user.id ON DELETE SET NULL | NULL for public-endpoint requests (S5 signed-PDF-token path). |
| `entity_type` | VARCHAR(40) | nullable | |
| `entity_id` | BIGINT | nullable | |
| `language` | VARCHAR(8) | NOT NULL, CHECK IN ('en','ar','bilingual') | |
| `provider` | VARCHAR(40) | NOT NULL, CHECK IN ('openai','anthropic') | |
| `model_used` | VARCHAR(80) | NOT NULL | |
| `tokens_input` | INTEGER | nullable | |
| `tokens_output` | INTEGER | nullable | |
| `cost_usd_micros` | BIGINT | nullable | |
| `latency_ms` | INTEGER | nullable | |
| `cache_hit` | BOOLEAN | NOT NULL DEFAULT FALSE | |
| `stream_mode` | BOOLEAN | NOT NULL DEFAULT FALSE | |
| `outcome` | VARCHAR(20) | NOT NULL, CHECK IN ('success','error','timeout','rate_limited','cancelled') | |
| `error_class` | VARCHAR(80) | nullable | |
| `error_message` | TEXT | nullable | **[SENSITIVE]** Sanitised at controller (Pino redact) before write per AC-S10-07. fn does NOT re-redact. Defence-in-depth: redacted in `fn_audit_trigger v_redact_fields` post-migration 041. |
| `created_at` | TIMESTAMPTZ | DEFAULT NOW | |
| `is_active` | BOOLEAN | DEFAULT TRUE | Schema uniformity; never flips in practice. |

**Indexes (6):**

| Index | Columns | Purpose |
|---|---|---|
| `idx_ai_request_log_actor_prompt_created` | `(actor_user_id, prompt_id, created_at)` | Per-user rate-limit lookup + cost report. |
| `idx_ai_request_log_prompt_outcome_created` | `(prompt_id, outcome, created_at DESC)` | Admin error dashboard. |
| `idx_ai_request_log_error_tail` | `(created_at DESC)` WHERE `outcome <> 'success'` | Fast error tail. |
| `idx_ai_request_log_entity_created` | `(entity_type, entity_id, created_at DESC)` | Per-entity AI history. |
| `idx_ai_request_log_prompt_id` | `(prompt_id)` | FK index. |
| `idx_ai_request_log_active` | `(id)` WHERE `is_active=TRUE` | Schema uniformity. |

**Append-only enforcement trigger** (mirrors M2 `fn_trg_approval_decision_deny_update` / M3 `fn_trg_signature_event_deny_update`):
- `trg_ai_request_log_deny_update` — BEFORE UPDATE on `ai_request_log` → `fn_trg_ai_request_log_deny_update`. RAISES SQLSTATE `42501` with the message `'fn_trg_ai_request_log_deny_update: ai_request_log is append-only'`.

**Audit trigger:** `audit_ai_request_log_changes` — AFTER INSERT only → `fn_audit_trigger`.
**Write-path restriction:** RLS deny-direct on INSERT/UPDATE/DELETE; only `fn_ai_request_log_create` (DEFINER) writes. UPDATE additionally blocked by the trigger above.

---

## Functions (12 new + 2 extended + 1 trigger fn)

### Write functions

| Function | Security | Grants | Purpose |
|---|---|---|---|
| `fn_ai_insight_upsert` | DEFINER | neondb_owner only | Atomic soft-deactivate prior active row + INSERT new row. `SELECT FOR UPDATE` on prior row (S2-17). NULL-safe via `IS NOT DISTINCT FROM` (S2-18). Validates provider/language; raises `22023` on invalid. Raises `23503` when `prompt_id` missing or inactive. Returns `{ id, expiresAt }`. |
| `fn_ai_insight_evict_expired` | DEFINER | neondb_owner only (cron-only — REVOKE FROM PUBLIC explicitly) | Soft-deactivate `ai_insight` rows where `expires_at <= now() AND is_active=TRUE`. `FOR UPDATE OF SKIP LOCKED` (S2-17 cron-safe). System-actor sentinel pattern: cron driver `SET app.current_user_id='0'` before call (S2-20). Returns `{ data: { evictedCount } }`. |
| `fn_ai_request_log_create` | DEFINER | neondb_owner only | Append a row to `ai_request_log` for every AI invocation attempt. Validates outcome/provider/language; raises `22023` on invalid. **No `p_prompt_payload` parameter** — defence-in-depth (the prompt is never reachable as a fn argument). Returns `{ id, requestId }`. |
| `fn_contract_ai_summary_persist` | DEFINER (carve-out) | neondb_owner | Update `contract.ai_summary_en/ai_summary_ar/ai_risk_score` (M1a 003 reserved columns). Permission gate: `contract.edit OR contract.read.all` (1-arg `fn_current_user_has_permission`). `SELECT FOR UPDATE` on contract row (S2-17). Emits `ai_summary_generated` and/or `ai_risk_score_updated` activity rows via 6-arg `fn_contract_activity_create` (S2-19). Raises `42501` (forbidden), `P0001` (not found), `23514` (risk score out of range). |
| `fn_contract_version_diff_summary_persist` | DEFINER (carve-out) | neondb_owner | **The ONLY allowed UPDATE path on `contract_version.diff_summary` column** — the rest of the table is append-only at M1a. Permission gate: `contract.read.all OR .department OR .own OR contract.edit`. `SELECT FOR UPDATE` on version row. Emits `ai_diff_summary_generated` activity. Migration 045 patched the body (DEFECT-1) to drop nonexistent `updated_at`/`updated_by` columns; signature unchanged. Raises `42501`, `P0001`. |

### Read functions

| Function | Security | Grants | Purpose |
|---|---|---|---|
| `fn_ai_insight_get_cached` | DEFINER | neondb_owner | Cache lookup. NULL-safe entity_id matching. Treats `expires_at <= now()` as miss. Returns full row JSONB (camelCase keys) or NULL. |
| `fn_ai_request_log_check_rate_limit` | DEFINER | neondb_owner | Pre-flight rate gate (NOT GATE/COMMIT — DN-4). Returns `{ allowed, remainingHour, remainingDay, retryAfterSeconds }`. Counts both successful and errored rows + cache hits (AC-S9-03/04). Raises `23503` on missing/inactive `prompt_id`. |
| `fn_ai_prompt_get` | INVOKER | authenticated | Read single ai_prompt row. RLS allows broad read (non-sensitive config). |
| `fn_ai_prompt_list` | INVOKER | authenticated; RLS narrows to `ai.observability.read OR platform_admin` | Reference-list pagination wrapper. |
| `fn_ai_insight_list` | INVOKER | authenticated; RLS narrows to `ai.observability.read OR audit.read.all` | Admin observability (S11). Filterable by entity_type / insight_type / language / provider; `includeExpired=false` default. |
| `fn_ai_request_log_list` | INVOKER | authenticated; RLS narrows to self OR `ai.observability.read` OR `audit.read.all` | Admin observability (S11). 90-day max range; raises `22023` on `fromDate > toDate` or range > 90 days. Joins to `"user"` via `fn_user_get_by_id`. |
| `fn_ai_request_log_cost_report` | INVOKER | authenticated; RLS narrows to `ai.observability.read OR audit.read.all` | Aggregated cost report (S12). 90-day max window. Aggregations: total cost / total tokens / success+error counts / avg latency / cache-hit ratio. |

### Trigger function

| Function | Purpose |
|---|---|
| `fn_trg_ai_request_log_deny_update` | BEFORE UPDATE on `ai_request_log` — raises SQLSTATE `42501`. Body identical to M2 / M3 deny-update templates (S2-19 byte-for-byte mirror). |

### Extended (cross-module CMW — body update via CREATE OR REPLACE)

| Function | Migration | Change |
|---|---|---|
| `fn_contract_activity_create` | 040 | Whitelist tuple 20 → 23 values (+`ai_summary_generated`, +`ai_risk_score_updated`, +`ai_diff_summary_generated`). Body byte-for-byte M3 032 except the `IF NOT IN` literal (S2-19). |
| `fn_audit_trigger` | 041 | `v_redact_fields` literal 25 → 27 names (+`payload`, +`error_message`). Defence-in-depth alongside Pino redact at controller. Body byte-for-byte M3 034 except the array literal (S2-19). |

---

## RLS policies (4 — across 3 tables)

| Table | Policy | Command | Rule summary |
|---|---|---|---|
| `ai_prompt` | `ai_prompt_read` | SELECT | `USING (TRUE)` — non-sensitive config; broad read. |
| `ai_prompt` | `ai_prompt_write_admin` | ALL | `platform_admin` OR `ai.observability.read`. |
| `ai_insight` | `ai_insight_select_scope` | SELECT | **Polymorphic dispatch** — admin bypass via `ai.observability.read` OR `audit.read.all`; `entity_type='contract'` / `'contract_version'` defers to contract RLS via EXISTS subquery; `'executive_dashboard'` gates on `ai.invoke.executive` OR `platform_admin`; `'regulatory_update' / '_summary'` gates on `ai.invoke.regulatory`. INSERT/UPDATE/DELETE: implicit deny — only DEFINER fn_'s. |
| `ai_request_log` | `ai_request_log_select_self_or_admin` | SELECT | `actor_user_id = current_user_id` OR `ai.observability.read` OR `audit.read.all`. INSERT/UPDATE/DELETE: implicit deny — only DEFINER `fn_ai_request_log_create` writes; UPDATE additionally blocked by trigger. |

> **DN-1 (cross-module note).** `ai_insight_select_scope` is the first polymorphic-dispatch RLS policy in the codebase. Future modules adding new `entity_type` values (e.g. `template`, `clause`, `obligation`) MUST also extend this policy with the corresponding subquery — there is no automatic dispatch.

---

## Permissions (4 new) and role grants (12 distinct)

| Permission | Description | Roles granted |
|---|---|---|
| `ai.invoke.contract` | Invoke contract-scoped AI (insights, drafting, version-diff-summary). | Super Admin (pre-emptive), platform_admin, legal_counsel, contract_drafter |
| `ai.invoke.executive` | Invoke executive anomaly detection. | Super Admin, platform_admin, executive |
| `ai.invoke.regulatory` | Invoke regulatory impact (explain, amendment) AI endpoints. | Super Admin, platform_admin, legal_counsel |
| `ai.observability.read` | Read AI observability dashboards (requests, insights, cost reports). | Super Admin, platform_admin |

Pre-emptive Super Admin grants per the M1a 006 / M1c 018 / M2 028 / M3 037 precedent — avoids the post-smoke patch cycle.

> **DBI nit:** Agent 4's design summary listed `rolePermissionGrantsCount=14`, but the actual distinct `(role, permission_code)` pairs applied = **12** (Super Admin overlap was double-counted in the 14 figure). State Writer records 12.

---

## Migrations applied (6 total — 040..045)

| # | File | Contents |
|---|---|---|
| 040 | `040_m4_extend_contract_activity_check_and_whitelist.sql` | ATOMIC pair: `DROP + ADD contract_activity_activity_type_check` (20→23 values; +`ai_summary_generated`, +`ai_risk_score_updated`, +`ai_diff_summary_generated`) AND `CREATE OR REPLACE fn_contract_activity_create` extending whitelist. Body byte-for-byte M3 032 except `IF NOT IN` tuple. Stable constraint name via dynamic `pg_constraint` lookup. |
| 041 | `041_m4_extend_audit_redact_list.sql` | `CREATE OR REPLACE fn_audit_trigger` extending `v_redact_fields` 25→27 (+`payload`, +`error_message`). Body byte-for-byte M3 034 except array literal. Defence-in-depth — Pino redact already runs at controller. |
| 042 | `042_m4_ai_tables.sql` | All 3 new tables + 17 indexes + 4 RLS policies + 1 deny-update trigger fn + trigger + 2 audit triggers (`audit_ai_insight_changes` AFTER INSERT/UPDATE/DELETE; `audit_ai_request_log_changes` AFTER INSERT-only). `ai_prompt` audit trigger explicitly OMITTED. |
| 043 | `043_m4_ai_functions.sql` | All 12 new fn_ DDL + per-fn EXECUTE GRANT/REVOKE matrix. Mandatory dedicated fn-functions migration per Agent 4 v2.1 quality check #16. **DEFECT-1 introduced here** in `fn_contract_version_diff_summary_persist` body. |
| 044 | `044_m4_ai_permissions_and_seed.sql` | INSERT 4 permissions + 12 role_permission rows + 6 ai_prompt seed rows. All `ON CONFLICT DO NOTHING` idempotent. |
| 045 | `045_m4_fix_fn_contract_version_diff_summary_persist_append_only.sql` | **DEFECT-1 patch** — `CREATE OR REPLACE fn_contract_version_diff_summary_persist` dropping the UPDATE clause references to nonexistent `updated_at`/`updated_by` columns on `contract_version` (M1a 003 made it append-only at table level). `updatedAt` is materialised locally at function entry via `v_new_at TIMESTAMPTZ := CURRENT_TIMESTAMP`. JSONB return shape byte-identical to 043; signature unchanged; controller bindings unchanged. |

All 6 migrations applied to `test` (`br-billowing-boat-ajq9m0g6`) AND `m0-foundation` (`br-snowy-brook-aje2ehtl`). Final `schema_migrations.version=45` on both branches.

---

## Cross-module writes (CMW)

| ID | Target | Operation | Backward-compatible | Migration |
|---|---|---|---|---|
| **AE-1 / activity** | M1a-owned `contract_activity.activity_type` CHECK + `fn_contract_activity_create` whitelist | `DROP + ADD CHECK` + `CREATE OR REPLACE` fn_. | Yes — additive 20→23. | 040 |
| **CC-2 / audit** | M0-owned `fn_audit_trigger` redact list | `CREATE OR REPLACE` extending `v_redact_fields` 25→27. | Yes — additive. | 041 |

---

## Key DB Impl outcomes (M4)

| ID | Severity | Topic | Outcome |
|---|---|---|---|
| **M4-DBI-NIT-1** | INFO | Grant count nit | Agent 4 reported 14 grants; actual distinct pairs = 12. State Writer records 12. |
| **M4-DBI-NIT-2** | INFO | Index count nit | Agent 4 reported 19; live = 17 explicit + 2 PK + 1 UNIQUE auto = 20 physical. State Writer records 17 explicit. |
| **M4-DBI-NOTE-S2-20** | INFO | Sentinel parity | When cron sets `app.current_user_id='0'`, audit_log records `changed_by=0`. Coercion `0 → NULL` lives in `fn_contract_activity_create` only; `fn_audit_trigger` does not coerce. `fn_ai_insight_evict_expired` does NOT call `fn_contract_activity_create` (eviction is silent), so the difference is invisible from the activity-feed standpoint. |
| **DEFECT-1** | HIGH | Column mismatch (caught downstream of Stage 4) | `fn_contract_version_diff_summary_persist` (043) referenced nonexistent `updated_at`/`updated_by` on `contract_version`. plpgsql lazy-compiles bodies, so 043 applied cleanly and the DB-Impl probe (which only exercised the NOT FOUND branch) passed. Testing Agent caught the bug on first successful invocation (`SQLSTATE 42703`). Migration 045 patched the fn body (Option A — match table schema). |

---

## S2-21 PROMOTION — PUBLIC EXECUTE allowlist (live verified)

Per the gate2-decisions.md Q3 Option A, M4 contributes **0 net new** PUBLIC EXECUTE grants on fn_'s. Live query against m0-foundation branch (`br-snowy-brook-aje2ehtl`) post-migration 045:

```
proname
-------
fn_signature_decline
fn_signature_get_by_invitation_token
fn_signature_sign
fn_signer_qa_session_record_message
fn_signer_qa_session_start
(5 rows — exactly the M3 baseline allowlist)
```

M3 (introduced 5) + M4 (zero net new) = **two consecutive modules satisfying the criterion**. **QA Stage 4 recommends formally codifying S2-21 from CANDIDATE to MANDATORY in `feedback_stage2_checks_s2_16_to_s2_20.md`.**

---

## S2-22 CODIFICATION RECOMMENDATION

DEFECT-1 escape proves the gap. **QA Stage 4 recommends codifying S2-22:**

- **Stage-2 design-time check:** for every `UPDATE` / `INSERT` clause in any fn_ body, verify EVERY referenced column exists in the active branch's table DDL (cross-reference against `project-artifacts/database/`).
- **DB-Impl Step 4 enhancement:** functional probe MUST exercise the success path of every `UPDATE` / `INSERT` branch in every new fn_, not just error/NOT FOUND paths.

---

## Concurrency primitive verification (S2-17)

| Function | Lock primitive |
|---|---|
| `fn_ai_insight_upsert` | `SELECT FOR UPDATE` on prior active row (NULL-safe via `IS NOT DISTINCT FROM`) before `INSERT`. |
| `fn_ai_insight_evict_expired` | `FOR UPDATE OF ai_insight SKIP LOCKED` — cron-safe; concurrent BE upserts hold their row, cron skips. |
| `fn_contract_ai_summary_persist` | `SELECT FOR UPDATE` on contract row before `UPDATE`. |
| `fn_contract_version_diff_summary_persist` | `SELECT FOR UPDATE` on `contract_version` row before `UPDATE` (post-045 patch retained). |

---

## NULL-safe equality (S2-18)

`IS NOT DISTINCT FROM` used at:
- `fn_ai_insight_get_cached`: `entity_id IS NOT DISTINCT FROM p_entity_id`.
- `fn_ai_insight_upsert`: same — for the `SELECT FOR UPDATE` of the prior active row.

Composite UNIQUE INDEX `idx_ai_insight_unique_active` uses `COALESCE(entity_id, 0::BIGINT)` to enforce uniqueness across NULL entity_ids (executive_dashboard rows). Postgres treats NULL as DISTINCT in UNIQUE indexes by default; the `0::BIGINT` sentinel is safe because no real entity has id=0 (BIGSERIAL starts at 1).

---

## System-actor sentinel (S2-20) — 3rd cron in codebase

- `ai-insight-eviction.cron.service.ts` (third in-process cron driver after M2 `fn_approval_escalate` + M3 `fn_signature_invitation_expire_due`) MUST `SET app.current_user_id = '0'` before invoking `fn_ai_insight_evict_expired`.
- `fn_ai_insight_evict_expired` is `SECURITY DEFINER` + `REVOKE FROM PUBLIC` + `GRANT EXECUTE TO neondb_owner` only.
- Eviction is silent — does NOT emit `contract_activity` rows. The system-actor sentinel coercion `0 → NULL` lives in `fn_contract_activity_create` only; `fn_audit_trigger` does not coerce, so audit_log rows for the soft-delete UPDATEs record `changed_by=0`. Defer to a framework-level decision whether `fn_audit_trigger` should also coerce 0→NULL for full system-actor consistency (M4-DBI-NOTE-S2-20).

---

## Sensitive-field redaction extensions (M4)

`fn_audit_trigger v_redact_fields` extended in migration 041 — net 27 names total (M0 17 + M1a 2 + M2 2 + M3 4 + M4 2). M4 additions:

- `payload` — `ai_insight.payload` (AI output may contain contract excerpts).
- `error_message` — `ai_request_log.error_message` (provider error strings may echo prompt fragments).

Pino redact at the controller is the primary defence; the audit-trigger redact list is belt-and-braces.

> **`ai_prompt_payload` is NEVER stored in any DB row** and NEVER a parameter of any fn_ — it is the fully-rendered prompt (system + user + tool defs) and lives only in controller memory. Pino redact intercepts the key in any structured log call (defence-in-depth: not even reachable as a fn parameter, so cannot be leaked via DB).

---

*Generated by Documentation Generator from M4 db-design.md, db-implementation-summary.json, 045-defect1-patch-summary.md, and qa-stage4-report.md. No Codex review run for M4 (Dexian decision 2026-05-04).*

---
---

# M5 — Regulatory Radar

> **Module:** M5 — Regulatory Radar (eighth module — UAE regulations master library + radar feed + per-contract impact analysis + impact-category taxonomy admin).
> **Generated:** 2026-05-05.
> **Predecessor:** M4 (`schema_migrations.version=45`).
> **Schema migration window:** 046 → 052 (7 designed) + 053 (M5-PROD-DEFECT-1 patch). Final `schema_migrations.version=53` on both `test` and `m0-foundation` branches.
> **Codex review:** SKIPPED (Dexian decision 2026-05-04; 4th consecutive validation through M2/M3/M4/M5). Stage 2 + Stage 4 absorb the safety net via S2-16..S2-23.

This dictionary documents the database surface introduced by M5: 5 new tables (1 lookup + 1 master + 1 reference taxonomy + 2 transactional), 15 fn objects, 32 indexes (incl. 5 PK + 1 COALESCE-sentinel UNIQUE), ~18 RLS policies, 5 audit triggers, 3 new permissions / 12 grants, and 2 cross-module modifications (`contract_activity` CHECK enum + `fn_contract_activity_create` whitelist 23→25 in atomic migration 047).

For the wire surface see [`api/openapi.yaml`](api/openapi.yaml). For the implementation handoff see [`dev-handoff.md`](dev-handoff.md) (M5 Implementation Notes section). For the Lovable transformation log see [`lovable-handoff.md`](lovable-handoff.md) (M5 Migration section).

---

## ER Diagram Fragment

```
                                          contract  (M1a)
                                             |
                                             | contract_id  (CASCADE)
                                             v
              regulator (lookup, M5)    regulatory_impact (transactional, M5; G1-reconstituted)
                  |  |                        ^   ^
       issuer_id  |  | regulator_id           |   | regulation_id (RESTRICT)
       (RESTRICT) |  | (RESTRICT)             |   |
                  v  v                        |   |
            regulation     regulatory_update  |   |
            (master, M5)   (transactional, M5)|   |
                  ^             |             |   |
        superseded_by_id        | regulatory_update_id (CASCADE; NULLABLE — structural impacts)
        (self-ref;              +-----------------+
         SET NULL,              |
         max-5 chain)  category_id (SET NULL)
                                v
                        impact_category (reference taxonomy, M5;
                                         id BIGSERIAL + key UNIQUE)
```

Cardinality:
- one **regulator** has 0..N **regulation** rows (issuer_id RESTRICT) and 0..N **regulatory_update** rows (regulator_id RESTRICT).
- one **regulation** has 0..N **regulatory_impact** rows (regulation_id RESTRICT — must repeal/supersede instead of delete).
- one **regulatory_update** has 0..N **regulatory_impact** rows (regulatory_update_id CASCADE; NULLABLE — distinguishes structural impacts).
- one **contract** has 0..N **regulatory_impact** rows (contract_id CASCADE — when admin hard-deletes a contract, its impacts disappear).
- **regulation.superseded_by_id** is self-referential (max 5-hop chain enforced in `fn_regulation_get_by_id` recursive CTE; AC-S2-02).

---

## Tables

### regulator (lookup; CREATE NEW — Q3 = (b) shared lookup)

**Purpose:** Shared lookup table for UAE regulators (issuers of regulations + sources of regulatory updates). Used by both `regulation.issuer_id` and `regulatory_update.regulator_id`. Admin-managed; not user-extensible at runtime.
**Kind:** lookup
**Owned by:** M5
**Used by:** `fn_regulation_*`, `fn_regulatory_update_*` (FK + JSONB embed)
**Delete strategy:** soft via `is_active`; FK from regulation/regulatory_update is RESTRICT — admin cannot delete a regulator that is in use.

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| code | VARCHAR(40) | NOT NULL UNIQUE | Canonical code (e.g. `MoHRE`, `FTA`) |
| name_en | VARCHAR(200) | NOT NULL | Display name (English) |
| name_ar | VARCHAR(200) | nullable | Display name (Arabic) |
| jurisdiction | VARCHAR(40) | nullable | One of `uae_federal` / `dubai` / `abu_dhabi` / `sharjah` / `difc` / `adgm` / `dmcc` / `other` |
| description_en, description_ar | TEXT | nullable | Free-text description |
| source_url | TEXT | nullable | Regulator website |
| display_order | INTEGER | NOT NULL DEFAULT 0 | FE picker ordering |
| created_at, updated_at | TIMESTAMPTZ | DEFAULT NOW() | Audit columns |
| created_by, updated_by | BIGINT | FK → user.id ON DELETE SET NULL | Audit columns |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Indexes (5):** `pk_regulator(id)`, `uq_regulator_code(code)` (UNIQUE), `idx_regulator_active(id) WHERE is_active=TRUE`, `idx_regulator_code(code) WHERE is_active=TRUE`, `idx_regulator_created_by`, `idx_regulator_updated_by`.

**RLS:** SELECT — any authenticated user. INSERT/UPDATE/DELETE — `platform_admin` only via `fn_current_user_has_permission('config.manage')`.

**Audit trigger:** `audit_regulator_changes`.

**Seed:** 9 rows in migration 048 (`MoHRE`, `FTA`, `Central Bank`, `DIFC`, `ADGM`, `TDRA`, `MoJ`, `MoE`, `Other`).

---

### regulation (master; CREATE NEW)

**Purpose:** UAE regulatory references — federal/emirate/free-zone laws, decrees, ministerial decisions, circulars. Self-referential supersession chain. Soft-delete only (status='repealed' + is_active=FALSE). `reference_code` is immutable post-create per AC-S4-05.
**Kind:** master / reference
**Owned by:** M5
**Delete strategy:** soft (is_active=FALSE + status='repealed'); active-impact guard at fn body returns 409 (AC-S5-02 — cleaner UX than raw 23503 FK violation).

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | |
| reference_code | VARCHAR(80) | NOT NULL UNIQUE | Citable code like `FED-DL-33-2021`. Immutable post-create — `fn_regulation_update` raises 23501 if patched. |
| title_en | VARCHAR(500) | NOT NULL | |
| title_ar | VARCHAR(500) | nullable | |
| issuer_id | BIGINT | NOT NULL, FK → regulator.id ON DELETE RESTRICT | Q3 = (b) shared lookup |
| regulation_type | VARCHAR(60) | NOT NULL, CHECK (6 values) | `federal_decree_law` / `cabinet_resolution` / `ministerial_decision` / `free_zone_regulation` / `circular` / `guideline` |
| jurisdiction | VARCHAR(40) | nullable, CHECK (8 values) | `uae_federal` / `dubai` / `abu_dhabi` / `sharjah` / `difc` / `adgm` / `dmcc` / `other` |
| effective_date | DATE | nullable | |
| superseded_by_id | BIGINT | FK → regulation.id ON DELETE SET NULL | Self-reference. When set, `fn_regulation_update` auto-flips status to `superseded` (AC-S4-02). |
| summary_en, summary_ar | TEXT | nullable | |
| source_url | TEXT | nullable | |
| tags | TEXT[] | NOT NULL DEFAULT '{}' | Q4 — denormalized; junction normalization deferred to M7+. |
| status | VARCHAR(20) | NOT NULL DEFAULT 'active', CHECK (4 values) | `active` / `superseded` / `repealed` / `draft` |
| is_seed | BOOLEAN | NOT NULL DEFAULT FALSE | |
| created_at, updated_at | TIMESTAMPTZ | DEFAULT NOW() | Audit columns |
| created_by, updated_by | BIGINT | FK → user.id ON DELETE SET NULL | Audit columns |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Check constraints:** `chk_regulation_no_self_supersede` — `superseded_by_id IS NULL OR superseded_by_id <> id` (AC-S4-03 defence-in-depth; fn body raises 23514 with field-keyed message).

**Indexes (8):** `pk_regulation`, `uq_regulation_reference_code`, `idx_regulation_issuer_id`, `idx_regulation_superseded_by_id`, `idx_regulation_active(id) WHERE is_active=TRUE`, `idx_regulation_listing(effective_date DESC NULLS LAST, created_at DESC) WHERE is_active=TRUE` (AC-S1-01), `idx_regulation_filter_axes(jurisdiction, regulation_type, status) WHERE is_active=TRUE` (AC-S1-02), `idx_regulation_reference_code_trgm USING GIN (reference_code gin_trgm_ops) WHERE is_active=TRUE` (AC-S1-03 — depends on pg_trgm from M1a contract.sql), `idx_regulation_tags_gin USING GIN (tags) WHERE is_active=TRUE`, plus `idx_regulation_created_by` / `idx_regulation_updated_by`.

**RLS (3 policies):** `regulation_select_authenticated`, `regulation_modify_legal_or_admin`, `regulation_delete_admin_only` (`platform_admin` role-aware; legal_counsel cannot DELETE — AC-S5-04 enforced both at RLS and as defence-in-depth at fn body).

**Audit trigger:** `audit_regulation_changes`.

---

### impact_category (reference taxonomy; CREATE NEW — Q5 = id BIGSERIAL + key UNIQUE)

**Purpose:** Configurable categorisation taxonomy for regulatory impact. PK is `id BIGSERIAL` to keep audit trigger compatible (Q5 — id retained explicitly to avoid the DB-IMPL-I-1 code-PK incompatibility that bit M3 `signature_party_side` / `signature_method` and M4 `ai_prompt`); `key VARCHAR(60) UNIQUE` is the stable join key for AI prompt context. `active` flag is separate from `is_active` soft-delete: `active=FALSE` hides from FE picker; `is_active=FALSE` is admin-only soft-deletion.
**Kind:** reference / taxonomy
**Owned by:** M5
**Delete strategy:** soft via `is_active`; visibility flag `active`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Q5 — keeps audit trigger compatible |
| key | VARCHAR(60) | NOT NULL UNIQUE | Stable snake_case code; immutable in `fn_impact_category_upsert` (the upsert match column) |
| name_en | VARCHAR(200) | NOT NULL | |
| name_ar | VARCHAR(200) | NOT NULL | AC-S15-03 — required (bilingual taxonomy) |
| description_en, description_ar | TEXT | nullable | |
| icon | VARCHAR(60) | NOT NULL DEFAULT 'shield' | lucide-react icon name |
| colour | VARCHAR(30) | NOT NULL DEFAULT 'slate' | Tailwind colour token |
| active | BOOLEAN | NOT NULL DEFAULT TRUE | FE picker visibility (separate from is_active) |
| display_order | INTEGER | NOT NULL DEFAULT 0 | |
| sources | JSONB | NOT NULL DEFAULT '[]' | Array of source-name strings |
| severity_scale | JSONB | NOT NULL DEFAULT '["low","medium","high","critical"]' | FE radar legend; CHECK enforces array typeof |
| ai_prompt_context | TEXT | nullable | Admin-authored AI guidance content; not user PII |
| default_clause_categories | TEXT[] | NOT NULL DEFAULT '{}' | Q4 — denormalized; M7+ junction deferred |
| is_seed | BOOLEAN | NOT NULL DEFAULT FALSE | |
| created_at, updated_at, created_by, updated_by, is_active | … | … | Standard audit |

**Check constraints:** `chk_impact_category_severity_scale_array` — `jsonb_typeof(severity_scale) = 'array'` (AC-S15-04 defence-in-depth; `fn_impact_category_upsert` validates first).

**Indexes (5):** `pk_impact_category`, `uq_impact_category_key`, `idx_impact_category_active(id) WHERE is_active=TRUE`, `idx_impact_category_display_order(display_order ASC, id ASC) WHERE is_active=TRUE AND active=TRUE` (AC-S14-01), `idx_impact_category_key_active(key) WHERE is_active=TRUE`, plus FK-on-audit indexes.

**RLS (2 policies):** `impact_category_select_authenticated` (any JWT — AC-S14-05; `contract_recipient` allowed — only M5 endpoint with no permission gate beyond JWT), `impact_category_modify_admin_only` (`config.manage` permission; legal_counsel denied — AC-S15-05).

**Audit trigger:** `audit_impact_category_changes`.

**Seed:** 8 rows in migration 052 (per Lovable extraction).

---

### regulatory_update (transactional; CREATE NEW — radar feed)

**Purpose:** Stream of incoming regulatory news. Drives the radar visualisation. M4 already declared `regulatory_update` + `regulatory_update_summary` in `AiInsightEntityType` union — M5 reifies the data plane (M5-CC-3 confirmed cross-module ready).
**Kind:** transactional
**Owned by:** M5
**Delete strategy:** soft via `is_active`; cascade-soft-deletes `regulatory_impact` rows where `regulatory_update_id = :id` on DELETE (AC-S10-02 — structural impacts with column IS NULL untouched).

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | |
| regulator_id | BIGINT | NOT NULL, FK → regulator.id ON DELETE RESTRICT | Q3 = (b) shared lookup |
| title_en | VARCHAR(500) | NOT NULL | |
| title_ar | VARCHAR(500) | nullable | |
| summary_en, summary_ar | TEXT | nullable | |
| reference_number | VARCHAR(120) | nullable | |
| published_date | DATE | NOT NULL | AC-S9-02 floor — fn body checks against MIN(detected_at) of associated impacts before allowing patch |
| effective_date | DATE | nullable | |
| compliance_deadline | DATE | nullable | FE radar cliff visualisation |
| severity | VARCHAR(20) | NOT NULL DEFAULT 'medium', CHECK (4 values) | `low` / `medium` / `high` / `critical` |
| source_url | TEXT | nullable | |
| affected_clause_categories | TEXT[] | NOT NULL DEFAULT '{}' | Q4 — denormalized; M7+ junction deferred |
| category_id | BIGINT | FK → impact_category.id ON DELETE SET NULL | |
| sub_source | VARCHAR(120) | nullable | |
| is_seed | BOOLEAN | NOT NULL DEFAULT FALSE | |
| created_at, updated_at, created_by, updated_by, is_active | … | … | Standard audit |

**Check constraints:**
- `chk_regulatory_update_effective_date` — `effective_date IS NULL OR effective_date >= published_date` (AC-S8-03)
- `chk_regulatory_update_compliance_deadline` — `compliance_deadline IS NULL OR compliance_deadline >= published_date` (AC-S8-04)

**Indexes (8):** `pk_regulatory_update`, `idx_regulatory_update_regulator_id`, `idx_regulatory_update_category_id`, `idx_regulatory_update_active(id) WHERE is_active=TRUE`, `idx_regulatory_update_radar(severity, effective_date DESC NULLS LAST, regulator_id, category_id) WHERE is_active=TRUE` (AC-S6-01/02), `idx_regulatory_update_published_desc(published_date DESC, id DESC) WHERE is_active=TRUE` (AC-S6 sort), `idx_regulatory_update_compliance_deadline(compliance_deadline) WHERE is_active=TRUE AND compliance_deadline IS NOT NULL` (cliff filter), `idx_regulatory_update_clause_categories_gin USING GIN (affected_clause_categories) WHERE is_active=TRUE`, plus FK-on-audit indexes.

**RLS (3 policies):** `regulatory_update_select_authenticated`, `regulatory_update_modify_legal_or_admin`, `regulatory_update_delete_admin_only` (AC-S10-04).

**Audit trigger:** `audit_regulatory_update_changes`.

---

### regulatory_impact (transactional; CREATE NEW — G1-reconstituted)

**Purpose:** Per-contract impact analysis when a regulatory_update affects a contract. Stores impact score, bilingual note (short — radar tooltip) + summary (long — AI-generated; BulkAmendmentSheet, RegulatoryImpactBanner). Idempotent inserts via UNIQUE INDEX (Q7 COALESCE-sentinel). **G1 reconstitution context:** regulatory_impact was an orphan in Lovable (the schema did not exist; the FE component referenced an absent table). M5 reconstitutes the schema from Phase L1 `entity-graph.json.reconstitutedCreateTable` + AC clarifications + the M5 types.ts ALTER chain.
**Kind:** transactional
**Owned by:** M5
**Delete strategy:** soft via `is_active`; cascade-soft-delete inheritance from `regulatory_update_delete` (AC-S10-02).

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | |
| contract_id | BIGINT | NOT NULL, FK → contract.id ON DELETE CASCADE | G1 — when admin hard-deletes a contract, its impacts disappear |
| regulation_id | BIGINT | NOT NULL, FK → regulation.id ON DELETE RESTRICT | G1 — must repeal/supersede instead |
| regulatory_update_id | BIGINT | nullable, FK → regulatory_update.id ON DELETE CASCADE | NULLABLE — distinguishes structural impacts (regulation only; column IS NULL) from update-driven impacts (column IS NOT NULL). All fn_ bodies that compare this column MUST use `IS NOT DISTINCT FROM` (S2-18). |
| impact_score | INTEGER | nullable, CHECK (0..100) | |
| impact_note_en, impact_note_ar | TEXT | nullable | Q6 — short-form tag (radar tooltip) |
| impact_summary_en, impact_summary_ar | TEXT | nullable | Q6 — AI-generated long-form executive summary (BulkAmendmentSheet, RegulatoryImpactBanner) |
| detected_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | |
| resolved | BOOLEAN | NOT NULL DEFAULT FALSE | |
| resolution_action | VARCHAR(40) | nullable, CHECK (4 values) | `amended` / `waived` / `out_of_scope` / `pending` |
| resolution_note | TEXT | nullable | Q8 — admin-bounded free text; NOT redacted in audit_log (no PII risk per Agent 2 sensitiveFields analysis) |
| is_seed | BOOLEAN | NOT NULL DEFAULT FALSE | |
| created_at, updated_at, is_active | … | … | Standard audit |
| created_by | BIGINT | FK → user.id ON DELETE SET NULL | **Nullable** — `fn_regulatory_impact_create_bulk` may run with system-actor sentinel (currently always JWT-driven; reserved for future regulatory feed cron) |
| updated_by | BIGINT | FK → user.id ON DELETE SET NULL | |

**Indexes (8):**
- `pk_regulatory_impact`
- **`idx_regulatory_impact_unique_active(contract_id, regulation_id, COALESCE(regulatory_update_id, 0::BIGINT)) WHERE is_active=TRUE`** UNIQUE — Q7 COALESCE-sentinel idempotency. Postgres treats NULL as DISTINCT in UNIQUE indexes by default; without intervention two structural-impact rows on the same `(contract_id, regulation_id)` pair would both be allowed. The `0::BIGINT` sentinel is safe because BIGSERIAL starts at 1; no real `regulatory_update` has id=0. PG15+ NULLS NOT DISTINCT considered; chose COALESCE for portability + parity with M4 `ai_insight` (consistent pattern across the codebase).
- `idx_regulatory_impact_contract_id`, `idx_regulatory_impact_regulation_id`, `idx_regulatory_impact_regulatory_update_id`
- `idx_regulatory_impact_active(id) WHERE is_active=TRUE`
- `idx_regulatory_impact_detected_desc(detected_at DESC) WHERE is_active=TRUE` (AC-S12-07)
- `idx_regulatory_impact_update_id_detected_at(regulatory_update_id, detected_at) WHERE is_active=TRUE AND regulatory_update_id IS NOT NULL` (AC-S7 / AC-S6-04 aggregate; AC-S9-02 floor lookup)
- `idx_regulatory_impact_contract_resolved(contract_id, resolved, detected_at DESC) WHERE is_active=TRUE` (AC-S5-02 / AC-S6 banner cold render — REG-OI-A second-fetch path; <1ms)
- FK-on-audit indexes for created_by/updated_by

**RLS (4 policies):** `regulatory_impact_select_inherit_contract` (defers to `contract_select_role_aware` via EXISTS — non-admin sees impacts only for visible contracts; executive sees system-wide via `audit.read.all` permission); `regulatory_impact_modify_legal_or_drafter_or_admin` (polymorphic for resolve — `regulations.manage` OR `contract.drafted_by = current_user`); `regulatory_impact_delete_admin_only`; bulk-write path bypasses via DEFINER carve-out (see DN-3 below).

**Audit trigger:** `audit_regulatory_impact_changes`.

---

## Functions (15 new + 1 extended)

### Read functions (6)

| Function | Returns | Purpose |
|---|---|---|
| `fn_regulation_list(p_page, p_limit, p_jurisdiction, p_regulation_type, p_issuer_id, p_status, p_search, p_actor_id) → JSONB` | List | S1 — Paginated regulations with embedded `RegulatorRef`. Sort effective_date DESC NULLS LAST, created_at DESC. ILIKE search via gin_trgm_ops. |
| `fn_regulation_get_by_id(p_id, p_actor_id) → JSONB` | Detail | S2 — Full Regulation with recursive supersession chain (max 5 hops; AC-S2-02). Empty array when terminal. |
| `fn_regulatory_update_list(p_page, p_limit, p_regulator_id, p_severity, p_category_id, p_effective_from, p_effective_to, p_compliance_deadline_max, p_actor_id) → JSONB` | List | S6 — Radar feed list with embedded `RegulatorRef` + `ImpactCategoryRef`. |
| `fn_regulatory_update_get_by_id(p_id, p_actor_id) → JSONB` | Detail | S7 — RegulatoryUpdate with RLS-aware `impactSummary` aggregate (totalImpacts, resolvedCount, pendingCount, avgImpactScore). |
| `fn_regulatory_impact_list(p_page, p_limit, p_contract_id, p_regulation_id, p_regulatory_update_id, p_resolved, p_actor_id) → JSONB` | List | S12 — At least one scoping filter required (AC-S12-02). RLS-narrowed for non-admin. S2-18 NULL-safe equality on regulatoryUpdateId via `IS NOT DISTINCT FROM`. |
| `fn_impact_category_list(p_include_inactive, p_actor_id) → JSONB` | List | S14 — No pagination (small reference table). Sort `display_order ASC, id ASC`. AC-S14-05 — accessible to all authenticated roles incl. `contract_recipient`. |

### Write functions (9 — 8 INVOKER + 1 DEFINER carve-out)

| Function | Type | Purpose |
|---|---|---|
| `fn_regulation_create(p_reference_code, p_title_en, p_title_ar, p_issuer_id, p_regulation_type, p_jurisdiction, p_effective_date, p_summary_en, p_summary_ar, p_source_url, p_tags, p_status, p_actor_id) → JSONB` | INVOKER | S3 — `regulations.manage`. Returns `fn_regulation_get_by_id(v_id)`. |
| `fn_regulation_update(p_id, p_patch, p_actor_id) → JSONB` | INVOKER | S4 — JSONB patch (camelCase keys). `referenceCode` immutable (23501 → AC-S4-05). Self-supersede 23514 → AC-S4-03. **M5-PROD-DEFECT-1 patched** in migration 053 — structured FK pre-check on supersededById raises `'fn_regulation_update: supersededById:Referenced regulation not found' USING ERRCODE='23503'` so `translatePgError` STRUCTURED_RAISE_RE returns 400 (AC-S4-04). Auto-flips status='superseded' when supersededById is being set (AC-S4-02). |
| `fn_regulation_delete(p_id, p_actor_id) → JSONB` | INVOKER | S5 — Soft-delete + status='repealed'. Active-impact guard returns 23503 cleaner-UX (AC-S5-02). platform_admin only — defence-in-depth role check at fn body (AC-S5-04). |
| `fn_regulatory_update_create(p_regulator_id, p_title_*, p_summary_*, p_reference_number, p_published_date, p_effective_date, p_compliance_deadline, p_severity, p_source_url, p_affected_clause_categories, p_category_id, p_sub_source, p_actor_id) → JSONB` | INVOKER | S8 — `regulations.manage`. Date-ordering CHECKs at table level + defensive raises at fn body. |
| `fn_regulatory_update_update(p_id, p_patch, p_actor_id) → JSONB` | INVOKER | S9 — JSONB patch. AC-S9-02 publishedDate floor guard — must not move below MIN(detected_at) of impacts. |
| `fn_regulatory_update_delete(p_id, p_actor_id) → JSONB` | INVOKER | S10 — platform_admin only. Cascade-soft-deletes regulatory_impact rows (AC-S10-02; structural impacts with NULL regulatory_update_id untouched). Returns `cascadedImpacts` count (AC-S10-01). |
| **`fn_regulatory_impact_create_bulk(p_regulatory_update_id, p_regulation_id, p_contract_ids, p_impact_payload, p_actor_id) → JSONB`** | **DEFINER** | S11 — **Only DEFINER carve-out in M5.** Defence-in-depth permission gate at fn body line 1 + S2-17 atomic gate+commit (SELECT FOR UPDATE on regulatory_update before per-contract INSERT loop). Idempotent ON CONFLICT DO NOTHING on COALESCE-sentinel UNIQUE. Q9 EMIT — emits `regulatory_impact_detected` activity per successfully-inserted impact via `fn_contract_activity_create` 6-arg signature. `p_impact_payload` JSONB is SENSITIVE — pino-redacted at controller. |
| `fn_regulatory_impact_resolve(p_id, p_resolution_action, p_resolution_note, p_actor_id) → JSONB` | INVOKER | S13 — Polymorphic permission: `regulations.manage` OR caller is `contract.drafted_by`. `resolution_action='pending'` un-resolves. Q9 EMIT — emits `regulatory_impact_resolved` only when v_resolved=TRUE. |
| `fn_impact_category_upsert(p_dto, p_actor_id) → JSONB` | INVOKER | S15 — Single-call upsert ON CONFLICT (key) DO UPDATE. `config.manage` only (AC-S15-05). Returns `createdOrUpdated` discriminator. |

**All 15 fn_'s:** `REVOKE ALL ON FUNCTION ... FROM PUBLIC; GRANT EXECUTE ... TO neondb_owner;` plus `SET search_path = public, pg_temp`. **Zero new PUBLIC EXECUTE grants** (S2-21 mandatory; PUBLIC allowlist stays at the M3 set of 5 names — verified live; 4th consecutive validation since codification at M4).

### Extended functions (1)

| Function | Operation | Migration | Change |
|---|---|---|---|
| `fn_contract_activity_create` | EXTEND (atomic) | 047 | `IF NOT IN` whitelist tuple grown 23→25 (+`regulatory_impact_detected`, +`regulatory_impact_resolved`). Body byte-for-byte M4 040 except the tuple + inline comment + COMMENT ON FUNCTION text. v_actor IN (NULL,0)→NULL coercion preserved verbatim (S2-20). 6-arg signature unchanged. Constraint name `contract_activity_activity_type_check` discovered via dynamic `pg_constraint` lookup. Atomically paired with the CHECK enum extension in the same migration — both land in the same commit boundary. |

---

## DEFINER carve-out (DN-3)

`fn_regulatory_impact_create_bulk` is the only `SECURITY DEFINER` fn in M5. Rationale: legal_counsel must write impacts on contracts they don't directly draft/own, but the `regulatory_impact_modify_legal_or_drafter_or_admin` RLS policy gates on contract drafter — RLS would block legitimate bulk-detect writes. The carve-out trades RLS defence for fn-body defence-in-depth:

1. **Permission gate at fn body line 1** — `IF NOT fn_current_user_has_permission('regulations.manage') THEN RAISE 42501`.
2. **S2-17 atomic gate+commit** — SELECT FOR UPDATE on the `regulatory_update` row before the per-contract INSERT loop. Serialises concurrent bulk-detect runs against the same update; prevents the TOCTOU pattern where two parallel callers both run ON CONFLICT-checks before either has inserted. ON CONFLICT idempotency alone is NOT sufficient — under concurrent runs we could double-emit `contract_activity` rows even when the impact INSERT is deduped. Mirrors M1c 020 / M2 026 / M2 031 / M3 atomic gate+commit precedent (Codex M1c TOCTOU lesson — historical context only post Codex skip; the pattern is now codified in S2-17).
3. **Implicit transaction atomicity** — if any per-contract INSERT raises (other than ON CONFLICT skip), the whole batch rolls back. Acceptable per AC-S11-* (failure-atomic semantics).

> **Future modules:** do NOT add additional DEFINER carve-outs without explicit invariant review. The carve-out pattern is a security-budget item.

---

## Cross-module writes (CMW)

| ID | Target | Operation | Backward-compatible | Migration |
|---|---|---|---|---|
| **AE-1 / activity (M5)** | M1a-owned `contract_activity.activity_type` CHECK + `fn_contract_activity_create` whitelist | `DROP + ADD CHECK` + `CREATE OR REPLACE` fn_. | Yes — additive 23→25. | 047 |
| **CC-2 / audit** | M0-owned `fn_audit_trigger` redact list | NOT EXTENDED in M5. Q10 = NOT EXTEND. `impact_payload` is a fn parameter only (never a column path); no DB redaction needed. Pino redact at controller covers it semantically via `ai_prompt_payload` (M4 precedent — same payload class). | n/a — Q10 NOT EXTEND. | (none) |

---

## Migrations applied (8 total — 046..052 + 053 patch)

| # | File | Contents |
|---|---|---|
| 046 | `046_m5_regulatory_permissions_and_grants.sql` | **MANDATORY FIRST.** INSERT 3 new permission codes (`regulations.read`, `regulations.manage`, `config.manage`) + role_permission grants (Super Admin pre-emptive + role-specific per matrix). Resolves M5-CC-1 — without this, every M5 endpoint 403s. Mirrors M2 028 / M3 037 / M4 044 precedent. All `ON CONFLICT DO NOTHING`. |
| 047 | `047_m5_extend_contract_activity_check_and_whitelist.sql` | ATOMIC pair — extend `contract_activity.activity_type` CHECK enum 23→25 (+`regulatory_impact_detected`, +`regulatory_impact_resolved`) AND `CREATE OR REPLACE fn_contract_activity_create` body byte-for-byte M4 040 except `IF NOT IN` tuple. Stable constraint name via dynamic `pg_constraint` lookup. |
| 048 | `048_m5_regulator_lookup.sql` | CREATE NEW lookup table `regulator` (id BIGSERIAL + code UNIQUE) + RLS + audit trigger + 9 seed regulators. |
| 049 | `049_m5_regulatory_tables.sql` | CREATE NEW 4 entities: `regulation` (with self-ref `superseded_by_id`), `impact_category`, `regulatory_update`, `regulatory_impact` (G1-reconstituted). Indexes (FK, partial active, GIN on TEXT[] arrays per Q4, COALESCE-sentinel UNIQUE), RLS enabled, audit triggers attached. |
| 050 | `050_m5_regulatory_functions.sql` | All 15 `CREATE OR REPLACE FUNCTION` statements with per-fn EXECUTE GRANT/REVOKE. Mandatory dedicated `NNN_fn_<entity>_functions.sql` per Agent 4 v2.1 quality check #14. Zero new PUBLIC EXECUTE grants (S2-21 — count stays at 5). |
| 051 | `051_m5_regulatory_rls_policies.sql` | All RLS policies for the 4 entities. ~16-20 policies total (4-7 per entity). |
| 052 | `052_m5_regulatory_seed.sql` | 8 default `impact_category` rows (per Lovable extraction). All `ON CONFLICT DO NOTHING`. No `regulation` or `regulatory_update` seed — admin-authored data. |
| 053 | `053_m5_fix_fn_regulation_update_supersede_pre_check.sql` | **M5-PROD-DEFECT-1 patch.** `CREATE OR REPLACE fn_regulation_update` adding a 9-line structured-raise FK pre-check block on `supersededById` inside the existing `IF p_patch ? 'supersededById'` branch (AFTER self-supersede guard, BEFORE the UPDATE). Mirrors `fn_regulatory_impact_create_bulk` (050 lines 499-505) so `translatePgError` 23503 STRUCTURED_RAISE_RE branch fires, returning 400 with `{ supersededById: 'Referenced regulation not found' }` (was raw-FK 422). Body byte-for-byte preserved otherwise. Codifies S2-23 mandatory check. |

All 8 migrations applied to `test` (`br-billowing-boat-ajq9m0g6`) AND `m0-foundation` (`br-snowy-brook-aje2ehtl`). Final `schema_migrations.version=53` on both branches.

---

## Permission codes added (3) + role grants (12)

| Code | Module | Action | Grants |
|---|---|---|---|
| `regulations.read` | regulations | read | Super Admin, platform_admin, legal_counsel, contract_drafter, contract_approver, contract_approver_2, executive (7 roles) |
| `regulations.manage` | regulations | manage | Super Admin, platform_admin, legal_counsel (3 roles — write paths) |
| `config.manage` | config | manage | Super Admin, platform_admin (2 roles — impact_category admin gate) |

Grants: 12 distinct (role, permission_code) pairs — Super Admin gets all 3 (pre-emptive grant per M1a 006 / M1c 018 / M2 028 / M3 037 / M4 044 lesson); platform_admin gets all 3; legal_counsel gets read+manage; contract_drafter/contract_approver/contract_approver_2/executive get read only.

> **`contract_recipient` is not granted any M5 permission.** Route gates correctly 403 contract_recipient on `regulations.read`-protected endpoints (verified in QA Stage 4 / AC-S1-06 / AC-S6-11 / AC-S12-04). The lone exception is `GET /impact-categories` (AC-S14-05) where the route gate is JWT-only — `contract_recipient` is allowed because the taxonomy is small canonical reference data used by FE form pickers.

---

## Sensitive-field redaction (M5 additions)

DB-layer (`fn_audit_trigger v_redact_fields`): **NOT EXTENDED** (Q10 — NOT EXTEND).

App-layer (Pino redact in `src/utils/logger.util.ts` SENSITIVE_PATHS):
- `impactPayload` / `impact_payload` (full envelope — DN-5; AI-generated content; ai_prompt_payload class per M4 precedent).
- `summaryAr` / `summary_ar` (mirrors M4 `summaryEn` coverage; defence-in-depth on regulatory summary text).
- `noteEn` / `note_en` / `noteAr` / `note_ar` (inner per-contract payload fields).

Intentional non-redacts:
- `resolutionNote` — Q8 admin-bounded free text; AC-S13-07 stored verbatim.
- `impactScore` — numeric metric; not user PII.

> **`impact_payload` is a fn parameter only — never a DB column.** Q10 NOT EXTEND honoured: `fn_audit_trigger` redact list is unchanged. Pino redact at controller is the sole defence; semantically covered by `ai_prompt_payload` already in `project.config.json sensitiveFields` (M4 precedent — same payload class).

---

## S2-21 invariant — PUBLIC EXECUTE allowlist (live verified)

M5 contributes **0 net new** PUBLIC EXECUTE grants on fn_'s. Live query against `m0-foundation` branch post-migration 053:

```
proname
-------
fn_signature_decline
fn_signature_get_by_invitation_token
fn_signature_sign
fn_signer_qa_session_record_message
fn_signer_qa_session_start
(5 rows — exactly the M3 baseline allowlist)
```

M3 (5) + M4 (0) + M5 (0) = **fourth consecutive module satisfying the invariant.** S2-21 is MANDATORY (promoted at M4). Stage 4 enumerate-PUBLIC-grants check is now the canonical pre-merge gate.

---

## S2-23 codification — FK pre-validation parity

DEFECT-1 in M5 (`fn_regulation_update.supersededById`) was a parity miss: the sibling fn `fn_regulatory_impact_create_bulk` in the SAME migration 050 had the canonical structured-raise pre-check on its FK params, but `fn_regulation_update` did not. The raw 23503 FK violation surfaced at `translatePgError` and fell through to UnprocessableEntityError(422) — the AC-S4-04 envelope expected 400 with `{ supersededById: <msg> }`.

**Stage 2 lesson S2-23 (codified to `feedback_stage2_checks_s2_16_to_s2_20.md` post-DEFECT-1):**
- For every fn_ accepting an FK id parameter (every BIGINT `p_*_id` param + every JSONB-extracted FK in patch DTOs), Stage 2 design-time check MUST verify a structured-raise PERFORM/IF NOT FOUND/RAISE 23503 pre-check exists before the UPDATE/INSERT clause.
- Canonical template:
  ```sql
  IF v_target_id IS NOT NULL THEN
    PERFORM 1 FROM <target_table>
      WHERE id = v_target_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_<x>: %', '<paramName>:Referenced <entity> not found'
        USING ERRCODE = '23503';
    END IF;
  END IF;
  ```
- DB-Impl Step 4 functional probe MUST include happy + negative path with regex match on the structured raise envelope.
- `translatePgError` 23503 branch ordering: constraint-name allowlist → STRUCTURED_RAISE_RE → fallback 422. Structured-raise preferred over more constraint-name overrides because constraint names are migration-scoped while structured raises are fn-body-scoped.

**Forward-looking carry-forward (Stage 4 INFO):** 4 sibling M5 fn_'s currently lack the structured-raise pre-check on FK params:
- `fn_regulation_create.issuerId`
- `fn_regulatory_update_create.regulatorId` + `categoryId`
- `fn_regulatory_update_update.regulatorId` + `categoryId`

None currently fail tests (the cleaner-UX wins are defensive, not behaviour-changing for valid FKs). Captured as forward-looking codified-from-escape carry-forward — patch when next AC requires the 400 envelope.

---

## Concurrency primitive verification (S2-17)

| Function | Lock primitive |
|---|---|
| `fn_regulation_update` | `SELECT FOR UPDATE` on regulation row before UPDATE. |
| `fn_regulation_delete` | `SELECT FOR UPDATE` on regulation row before active-impact guard + UPDATE. |
| `fn_regulatory_update_update` | `SELECT FOR UPDATE` on regulatory_update row before published-date floor check + UPDATE. |
| `fn_regulatory_update_delete` | `SELECT FOR UPDATE` on regulatory_update row before cascade UPDATE. |
| `fn_regulatory_impact_create_bulk` | `SELECT FOR UPDATE` on **regulatory_update** row (NOT individual contract rows) before per-contract INSERT loop — atomic gate+commit pattern; serialises concurrent bulk-detect runs against the same update. |
| `fn_regulatory_impact_resolve` | `SELECT FOR UPDATE` on regulatory_impact row before UPDATE. |
| `fn_impact_category_upsert` | `INSERT ... ON CONFLICT (key) DO UPDATE` is atomic (single statement); no explicit FOR UPDATE needed. |

---

## NULL-safe equality (S2-18)

`IS NOT DISTINCT FROM` used at:
- `fn_regulatory_impact_list`: `regulatory_update_id IS NOT DISTINCT FROM p_regulatory_update_id` — handles the NULL filter case where caller wants only structural impacts.

Composite UNIQUE INDEX `idx_regulatory_impact_unique_active` uses `COALESCE(regulatory_update_id, 0::BIGINT)` to enforce uniqueness across NULL `regulatory_update_id` (structural impacts). Postgres treats NULL as DISTINCT in UNIQUE indexes by default; the `0::BIGINT` sentinel is safe because BIGSERIAL starts at 1; no real `regulatory_update` has id=0 (M4 ai_insight `entity_id` precedent — consistent pattern).

---

## DB-IMPL-I-1 not recurring in M5

All 5 M5 entities use `id BIGSERIAL PRIMARY KEY`. The DB-IMPL-I-1 escape (M3 `signature_party_side` / `signature_method` and M4 `ai_prompt` used a TEXT/VARCHAR PK code instead of `id BIGSERIAL`, which breaks the `fn_audit_trigger.NEW.id` reference) does NOT recur in M5. Q5 (impact_category) explicitly opted to retain `id BIGSERIAL` over the alternative `key`-as-PK pattern precisely to avoid this trap. Audit triggers are STANDARD on all 5 M5 tables.

---

## System-actor sentinel (S2-20) — N/A in M5

M5 introduces NO new cron driver. The 3 existing crons (M2 approval-escalation, M3 signature-expiration, M4 ai-insight-eviction) remain wired in `server.ts` unchanged. The `regulatory_impact.created_by` column is intentionally NULLABLE for future-cron compatibility, but no current path passes a sentinel actor.

---

## Key DB Impl outcomes (M5)

| ID | Severity | Topic | Outcome |
|---|---|---|---|
| **M5-PROD-DEFECT-1** | HIGH | FK-pre-validation parity miss caught by Testing Agent | `fn_regulation_update.supersededById` raised raw 23503 FK violation that fell through `translatePgError` to 422 instead of the AC-S4-04 mandated 400. Patched in migration 053 (9-line structured-raise pre-check); `schema_migrations.version` 52 → 53 on both branches. Test re-run 27/27 PASS, full M5 suite 78/78 PASS, zero regressions. Codified S2-23 mandatory check. |
| **M5-DBI-INFO-1** | INFO | All M5 entities BIGSERIAL | DB-IMPL-I-1 NOT recurring. Q5 explicitly chose `id BIGSERIAL` for `impact_category` to avoid the M3/M4 TEXT-PK trap. |
| **M5-CC-3** | INFO | M4 cross-module readiness confirmed | M4's `AiInsightEntityType` union already includes `regulatory_update` + `regulatory_update_summary` literals (verified). M5 introduces NO new entity_type values. |

---

## Forward-looking S2-23 carry-forward (4 sibling fn_'s)

Stage 4 INFO — captured for the next module / ad-hoc patch session:
- `fn_regulation_create.p_issuer_id` (S3) — would 422 on raw FK miss; AC-S3 currently does not require 400 envelope, so deferred.
- `fn_regulatory_update_create.p_regulator_id` + `p_category_id` (S8) — same.
- `fn_regulatory_update_update.regulatorId` + `categoryId` (S9) — same.

Apply the canonical S2-23 template when patching.

---

*Generated by Documentation Generator from M5 db-design.md, db-implementation-summary.json, 053-defect1-patch-summary.md, be-implementation-summary.json, and qa-stage4-report.json. No Codex review run for M5 (Dexian decision 2026-05-04; 4th consecutive validated).*
