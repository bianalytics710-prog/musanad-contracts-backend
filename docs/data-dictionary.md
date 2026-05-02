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
