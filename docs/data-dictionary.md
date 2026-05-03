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
