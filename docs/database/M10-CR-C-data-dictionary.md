# M10 / CR-C — Audit Hardening + Multi-Tenancy + Admin Cockpit Foundation — Database Data Dictionary

> **Module:** M10 — CR-C
> **Generated:** 2026-05-10
> **Migrations:** 123..131 (9 files)
> **Module owner:** CR-C (extends M0, M7, R-PA baseline)

This document covers only the database objects **introduced or extended by CR-C**. All previously documented objects remain in their module's data dictionary (M0 in `data-dictionary.md`, M7 CRIP modules).

---

## Tables — Extended

### `audit_log` (M0 → extended by CR-C, migration 128)

**Purpose:** Tamper-evident append-only audit trail. CR-C extends with SHA-256 hash chain columns (Annex D.7.1).
**Owned by:** M0. **Extended by:** M10 / CR-C.

**New columns added (migration 128):**

| Column | Type | Constraints | Description |
|---|---|---|---|
| `prev_hash` | TEXT | NOT NULL (after backfill) | Hex SHA-256 of the previous row's `this_hash`. Genesis row = `repeat('0', 64)`. Set exclusively by `fn_audit_log_record_v2`. |
| `this_hash` | TEXT | NOT NULL (after backfill) | Hex SHA-256 of `(prev_hash || canonical_row_payload)`. Canonical payload is deterministic JSON with alphabetically sorted keys (UTC ISO 8601 µs timestamp). |

**New indexes (migration 128):**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| `idx_audit_log_this_hash` | `this_hash` | BTREE | Spot-check by hash in `fn_audit_chain_verify` without full table scan; primary chain walk still uses `id ASC`. |

**Append-only enforcement added (migration 128):**
- `BEFORE UPDATE` trigger: `audit_log_no_update` → `fn_audit_log_no_update_guard()` — raises P0001 on any UPDATE attempt.
- `BEFORE DELETE` trigger: `audit_log_no_delete` → `fn_audit_log_no_delete_guard()` — raises P0001 on any DELETE attempt.
- Both triggers fire regardless of RLS bypass (SECURITY DEFINER), providing defence-in-depth over the M0 `USING(false)` RLS deny policies.

**Backfill (migration 128):** A single-transaction anonymous DO block walked `audit_log ORDER BY id ASC` and computed `prev_hash`/`this_hash` for every existing row. The genesis row received `prev_hash = repeat('0', 64)`.

**M0 baseline columns retained verbatim:** `id BIGSERIAL PK, table_name TEXT, record_id BIGINT, action TEXT CHECK('INSERT','UPDATE','DELETE'), old_values JSONB, new_values JSONB, changed_by BIGINT, changed_at TIMESTAMPTZ`. Annex D.7.1 column-name aliases (`entity_id`, `before_state`, etc.) are **not** introduced — OPEN-DECISION-A: honored at canonical-payload-construction level only.

---

### `tenant` (M7 → extended by CR-C, migration 124)

**Purpose:** Customer tenant root. ADNOC (UUID `00000000-0000-0000-0000-000000000001`) is the seed row. CR-C extends with profile columns.
**Owned by:** M7. **Extended by:** M10 / CR-C.

**New columns added (migration 124):**

| Column | Type | Constraints | Description |
|---|---|---|---|
| `name` | TEXT | NOT NULL, UNIQUE (after backfill) | Human-display name. Backfilled from `display_name` on existing rows. NAMING-CONFLICT-1 resolution: `slug` retained for URL stability. |
| `industry` | TEXT | nullable | Free-form industry tag (`oil_gas`, `energy`, `banking`, ...). Lookup table candidate post-pilot. |
| `risk_appetite` | TEXT | NOT NULL DEFAULT 'standard', CHECK IN ('low','standard','high') | Closed-enum risk band. |
| `data_region` | TEXT | nullable | ISO/region code for data-residency hints (e.g. `UAE`, `EU`, `US`). |

**New index (migration 124):**

| Index | Columns | Condition | Purpose |
|---|---|---|---|
| `idx_tenant_name` | `name` | `WHERE is_active = TRUE` | Partial index for active-tenant name lookups. |

**New RLS policy (migration 124, additive):**

| Policy | Command | Condition | Notes |
|---|---|---|---|
| `tenant_admin_read` | SELECT | `fn_current_user_has_permission('tenant.read')` | Additive alongside existing M7 policies (`tenant_self_row_select`, `tenant_platform_admin_all`). |

**M7 columns retained:** `id UUID PK DEFAULT gen_random_uuid(), slug VARCHAR(50) UNIQUE NOT NULL, display_name VARCHAR(200) NOT NULL, config_pack VARCHAR(50) NOT NULL DEFAULT 'default', is_active BOOLEAN, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, created_by BIGINT, updated_by BIGINT`.

**Not added:** `data_classification` (tenant is the root entity; excluded per OPEN-DECISION-C / AC-S5-03).

---

## Tables — New

### `notification_template` (Owner: CR-C M10, migration 125)

**Purpose:** Bilingual EN/AR transactional message templates (email / in_app / teams_capture / slack_capture). Tenant-scoped. Replaces ~26 hardcoded strings. Rendered via `fn_notification_template_render` with `{{paramName}}` placeholder substitution.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier. |
| `tenant_id` | UUID | NOT NULL, FK → tenant(id) ON DELETE RESTRICT | Tenant scope. ON DELETE RESTRICT prevents orphan templates on accidental tenant deactivation. |
| `template_id` | TEXT | NOT NULL, UNIQUE per tenant | Stable code-side identifier (e.g. `signature.invitation.email`). Immutable after create (AC-S12-05). Code references this string, not the BIGSERIAL id. |
| `channel` | TEXT | NOT NULL, CHECK IN ('email','in_app','teams_capture','slack_capture') | Message channel. Closed-enum CHECK. |
| `subject_en` | TEXT | nullable | Email subject in English (null for in_app / teams / slack). |
| `subject_ar` | TEXT | nullable | Email subject in Arabic. |
| `body_en` | TEXT | NOT NULL | Template body in English. `{{paramName}}` placeholders substituted at render time. |
| `body_ar` | TEXT | NOT NULL | Template body in Arabic. |
| `parameter_schema` | JSONB | NOT NULL DEFAULT '{}' | Declared placeholder names + types: `{"signerName":"string","contractTitle":"string"}`. Used by `fn_notification_template_render` for `missingParameters[]` detection. Must be a JSON object (not array/scalar). |
| `last_modified_by` | BIGINT | FK → user(id) ON DELETE SET NULL | Admin who last edited the template (denormalised convenience column). |
| `data_classification` | TEXT | NOT NULL DEFAULT 'demo', CHECK IN ('demo','pilot','production') | CR-C universal column. Included at CREATE TABLE time (not re-altered by migration 127). |
| `created_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | Record creation timestamp (UTC). |
| `updated_at` | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | Last update timestamp (UTC). |
| `created_by` | BIGINT | FK → user(id) ON DELETE SET NULL | User who created this record. |
| `updated_by` | BIGINT | FK → user(id) ON DELETE SET NULL | User who last updated this record. |
| `is_active` | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag. |

**Unique constraint:** `UNIQUE (tenant_id, template_id)` — one template per channel-purpose per tenant.

**Indexes:**

| Index | Columns | Condition | Purpose |
|---|---|---|---|
| `idx_notification_template_tenant` | `tenant_id` | — | FK support. |
| `idx_notification_template_last_modified_by` | `last_modified_by` | — | FK support. |
| `idx_notification_template_active` | `id` | `WHERE is_active = TRUE` | Soft-delete filter. |
| `idx_notification_template_channel` | `(tenant_id, channel)` | `WHERE is_active = TRUE` | List endpoint channel filter. |
| `idx_notification_template_template_id` | `(tenant_id, template_id)` | `WHERE is_active = TRUE` | Render lookup (matches UNIQUE constraint). |
| `idx_notification_template_data_class` | `data_classification` | `WHERE is_active = TRUE` | Demo-purge scan. |

**RLS (migration 125):**
- ENABLE RLS + FORCE RLS.
- 4 policies: SELECT via `notification.template.manage` permission; INSERT/UPDATE/DELETE via DEFINER functions only (deny-direct policies for non-admin callers).

**Audit trigger:** `audit_notification_template_changes` using standard `fn_audit_trigger()`. BIGSERIAL `id` column is compatible with the M0 trigger pattern.

---

## `data_classification` Column Rollout — 34 Content Tables (migration 127)

CR-C adds `data_classification TEXT NOT NULL DEFAULT 'demo' CHECK (data_classification IN ('demo','pilot','production'))` to **34 content tables** in a single transaction (migration 127). Existing rows default to `'demo'`.

**Pattern per table:**
```sql
ALTER TABLE <table>
  ADD COLUMN IF NOT EXISTS data_classification TEXT NOT NULL DEFAULT 'demo'
  CHECK (data_classification IN ('demo','pilot','production'));
COMMENT ON COLUMN <table>.data_classification IS
  'CR-C: demo / pilot / production. Existing rows default to ''demo''. Demo rows purged by fn_demo_data_purge.';
```

**Table rollout by tier (34 tables total):**

| Tier | Tables |
|---|---|
| Tier 1 — Contracts/Parties | `contract`, `contract_attachment`, `contract_clause`, `contract_obligation`, `contract_template`, `contract_comment`, `contract_watch`, `contract_activity`, `contract_tag`, `contract_version`, `party`, `payment_schedule` (12) |
| Tier 2 — Signature | `signature_party`, `signature_party_side`, `signature_event`, `signature_invitation`, `signature_method`, `signer_qa_session` (6) |
| Tier 3 — Approvals | `approval_chain`, `approval_step`, `approval_decision`, `approval_matrix` (4) |
| Tier 4 — Regulatory | `regulation`, `regulator`, `regulatory_update`, `regulatory_impact`, `impact_category` (5) |
| Tier 5 — Impact Signals | `impact_signal_contract` (1; `impact_signal` is a VIEW — skipped) |
| Tier 6 — AI | `ai_insight`, `ai_prompt`, `ai_request_log` (3) |
| Tier 7 — Imports | `import_batch` (1) |
| Tier 8 — CRIP | `osint_source`, `osint_signal`, `source_credential`, `source_health`, `internal_signal_kind`, `party_relationship` (6) |
| Tier 9 — CR-C own | `notification_template` (column included at CREATE TABLE in migration 125; not re-altered in 127) |

**Excluded tables (AC-S5-03):** `user`, `role`, `permission`, `role_permission`, `audit_log` (append-only), `schema_migrations`, `token_blacklist`, `tenant`, `system_setting` (key catalog).

All existing `fn_*_create` writers continue to succeed via DEFAULT (AC-S5-05).

---

## `system_setting` CHECK Extension (R-PA → extended by CR-C, migration 126)

**Purpose:** Extend the `category` CHECK constraint from 3 values to 7 values and seed ~22 new setting rows.

**Before (R-PA baseline):** `CHECK (category IN ('general','uae_pass','branding'))`

**After (CR-C migration 126):** `CHECK (category IN ('general','uae_pass','branding','security','email','calendar','audit_retention'))`

**New setting rows seeded (migration 126 — all ON CONFLICT (key) DO NOTHING):**

| Category | Keys seeded |
|---|---|
| `email` | `email.smtp.host`, `email.smtp.port`, `email.smtp.encryption`, `email.smtp.auth_user`, `email.smtp.auth_pass_ref` (is_secret=true), `email.from_address`, `email.from_name_en`, `email.from_name_ar`, `email.reply_to`, `email.daily_send_limit`, `email.enabled` |
| `security` | `security.session_timeout_min`, `security.password_policy_min_length`, `security.password_policy_require_special`, `security.mfa_required`, `security.ip_allowlist` |
| `calendar` | `calendar.weekend_days`, `calendar.working_hours_start`, `calendar.working_hours_end`, `calendar.holidays` |
| `audit_retention` | `audit.retention_days` |
| `branding` (additions) | `branding.logo_uri`, `branding.favicon_uri`, `branding.footer_en`, `branding.footer_ar` (alongside existing `branding.color_primary`, `branding.color_accent`) |

`email.smtp.auth_pass_ref` has `is_secret = TRUE` — returned as `'***REDACTED***'` by `fn_system_setting_list`.

---

## Functions — New (Write)

### `fn_audit_log_record_v2(TEXT, BIGINT, TEXT, JSONB, JSONB, BIGINT)` — migration 128

**Type:** Write (SECURITY DEFINER — bypasses audit_log RLS deny-direct-INSERT)
**Purpose:** Single source of truth for all audit_log writes. Computes prev/this hash chain with pessimistic concurrency lock.
**Called via:** `SELECT fn_audit_log_record_v2(p_table_name, p_record_id, p_action, p_old_values, p_new_values, p_changed_by)`

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `p_table_name` | TEXT | Yes | Table being audited (or sentinel string like `__demo_purge__`). |
| `p_record_id` | BIGINT | No | Row id being audited. NULL for sentinel events. |
| `p_action` | TEXT | Yes | One of `'INSERT'`, `'UPDATE'`, `'DELETE'`. |
| `p_old_values` | JSONB | No | Pre-redaction old row snapshot. NULL for INSERT. |
| `p_new_values` | JSONB | No | Pre-redaction new row snapshot. NULL for DELETE. |
| `p_changed_by` | BIGINT | No | User id override. Defaults to `app.current_user_id` GUC. `0` coerced to NULL (S2-20 system-actor sentinel). |

**Returns:** `JSONB { id: BIGINT, prevHash: TEXT, thisHash: TEXT }`

**Business rules:**
- Validates `p_action` IN ('INSERT','UPDATE','DELETE') — RAISE 22023 on failure.
- Coerces `v_actor = 0` → NULL (S2-20 system-actor sentinel, preserved from M1b/CRIP).
- Pessimistic lock: `SELECT id, this_hash FROM audit_log ORDER BY id DESC LIMIT 1 FOR UPDATE` — serializes chain writes (OPEN-DECISION-D).
- Genesis row (empty table): `v_prev_hash = repeat('0', 64)`.
- Canonical payload constructed by `fn_audit_log_canonicalize` — alphabetically sorted keys, UTC ISO 8601 µs timestamp, NULLs explicit.
- Hash: `encode(digest(v_prev_hash || v_canonical, 'sha256'), 'hex')` — requires pgcrypto extension.
- Sensitive fields already redacted by the caller (`fn_audit_trigger`, `fn_audit_log_record` shim) before values reach this function.

**Error conditions:**
- `22023 invalid_action_value` — bad p_action.
- `P0001 audit_chain_integrity_violation` — prev row hash is NULL post-backfill (defensive).

**Callers:** `fn_audit_trigger` (replaces direct INSERT from migration 128), `fn_audit_log_record` shim (M1b 011), `fn_demo_data_purge` (sentinel row), all future cross-cutting BE emitters.

---

### `fn_audit_log_canonicalize(JSONB)` — migration 128

**Type:** Pure function (IMMUTABLE, PARALLEL SAFE, INVOKER)
**Purpose:** Deterministic JSON serializer. Mirrors BE `src/utils/audit-canonical.util.ts` byte-for-byte. Keys sorted alphabetically at every depth; arrays preserve element order; NULLs explicit.
**Called via:** `SELECT fn_audit_log_canonicalize(payload::jsonb)` — internal to `fn_audit_log_record_v2` and `fn_audit_chain_verify`.

---

### `fn_audit_log_no_update_guard()` / `fn_audit_log_no_delete_guard()` — migration 128

**Type:** Trigger functions (SECURITY DEFINER)
**Purpose:** Append-only enforcement. Raise P0001 `'audit_log is append-only'` on any UPDATE or DELETE to `audit_log`. Fire regardless of RLS bypass (neondb_owner pool).

---

### `fn_demo_data_purge(p_dry_run BOOLEAN)` — migration 129

**Type:** Write (SECURITY DEFINER — must override per-table RLS to scan + delete)
**Purpose:** Delete every row WHERE `data_classification = 'demo'` across 38 table operations in dependency-safe (children-first) order. Idempotent. Emits sentinel `__demo_purge__` audit row via `fn_audit_log_record_v2`.

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `p_dry_run` | BOOLEAN | No | FALSE | When TRUE, returns same response shape but performs NO DELETE. Bypasses confirmToken check. |

**Returns:** `JSONB { success: true, tablesPurged: TEXT[], rowsDeleted: INTEGER, details: JSONB, dryRun: BOOLEAN }`

**Business rules:**
- Compound permission gate: caller must be active Super Admin (role check inside fn body — NOT just `demo.purge` permission check). RAISE 42501 `super_admin_required` if not.
- Delete order is topologically sorted (children before parents across 38 table operations).
- Sentinel audit row emitted post-purge (not on dry run).

**Error conditions:**
- `42501 super_admin_required`.
- `P0001 demo_purge_fk_violation` + table name (defensive — non-demo row references a demo row; should not occur in correct data).

---

### `fn_audit_chain_verify(p_start_seq BIGINT, p_end_seq BIGINT)` — migration 129

**Type:** Read (SECURITY INVOKER, gated by audit.verify permission)
**Purpose:** Walk audit_log in id ASC order and recompute + compare hashes. Returns the first mismatch or success.

**Returns:** `JSONB { verified: BOOLEAN, totalRows: INTEGER, brokenAtSeq: BIGINT|null, expectedHash: TEXT|null, actualHash: TEXT|null, checkedAt: TIMESTAMPTZ }`

**NFR:** < 30 seconds @ 100k rows.

---

### `fn_data_classification_summary()` — migration 129

**Type:** Read (SECURITY INVOKER, gated by `audit.verify OR demo.purge` permission)
**Purpose:** Return per-table counts of rows by `data_classification` value across all 34 content tables.

**Returns:** `JSONB { tables: [{tableName, demo, pilot, production, total}], totals: {demo, pilot, production} }`

---

### `fn_role_create(TEXT, TEXT)` — migration 130

**Type:** Write (SECURITY INVOKER, gated by role.manage)
**Purpose:** Create a new application role. Validates non-empty name; bubbles UNIQUE 23505 on name collision.

**Returns:** `JSONB { id: BIGINT, name: TEXT }`

---

### `fn_role_update(BIGINT, TEXT, TEXT)` — migration 130

**Type:** Write (SECURITY INVOKER, gated by role.manage)
**Purpose:** Rename or update description of a role. Built-in role names are immutable (OPEN-DECISION-E — 8 hard-coded names).

**Error conditions:** `P0002 role_not_found`, `P0001 cannot_rename_system_role`, `23505` name collision.

---

### `fn_role_delete(BIGINT)` — migration 130

**Type:** Write (SECURITY INVOKER, gated by role.manage)
**Purpose:** Soft-delete role (is_active = FALSE). Blocks if any active user is assigned OR if built-in.

**Error conditions:** `P0002 role_not_found`, `P0001 cannot_delete_system_role` (built-in), `P0001 role_in_use` + userCount (active users assigned).

---

### `fn_role_permission_grant(BIGINT, BIGINT)` — migration 130

**Type:** Write (SECURITY INVOKER, gated by role.manage)
**Purpose:** Grant a permission to a role. Idempotent (re-grant returns `alreadyExists = true`). Strict allowlist: unknown permId raises P0002 (OPEN-DECISION-F).

---

### `fn_role_permission_revoke(BIGINT, BIGINT)` — migration 130

**Type:** Write (SECURITY INVOKER, gated by role.manage)
**Purpose:** Revoke a permission from a role. Idempotent. Super Admin essential grants (8 hard-coded permission codes) raise P0001 `cannot_revoke_system_grant`.

---

### `fn_tenant_list(p_page INT, p_limit INT, p_search TEXT)` — migration 130

**Type:** Read (SECURITY INVOKER, gated by tenant.read)
**Purpose:** Paginated list of tenants. Search matches `name OR slug` case-insensitively (ILIKE). Returns extended columns (name, industry, riskAppetite, dataRegion).

---

### `fn_tenant_get_by_id(p_id UUID)` — migration 130

**Type:** Read (SECURITY INVOKER, gated by tenant.read)
**Purpose:** Single tenant detail by UUID. Returns NULL (→ 404) for unknown or inactive tenant.

---

### `fn_notification_template_list(p_page INT, p_limit INT, p_channel TEXT, p_search TEXT)` — migration 130

**Type:** Read (SECURITY INVOKER, gated by notification.template.manage)
**Purpose:** Paginated list of tenant-scoped notification templates. Optional channel filter; ILIKE search on templateId / subjectEn / subjectAr.

---

### `fn_notification_template_get_by_id(p_id BIGINT)` — migration 130

**Type:** Read (SECURITY INVOKER, gated by notification.template.manage)
**Purpose:** Full template detail including body EN+AR, parameterSchema, audit columns. Tenant-scoped (RLS + permission gate). Returns NULL (→ 404) for templates outside current tenant.

---

### `fn_notification_template_update(p_id BIGINT, p_subject_en TEXT, p_subject_ar TEXT, p_body_en TEXT, p_body_ar TEXT, p_parameter_schema JSONB)` — migration 130

**Type:** Write (SECURITY INVOKER, gated by notification.template.manage)
**Purpose:** Update editable template fields. `templateId` and `channel` are immutable after create (silently ignored in fn body; Zod rejects at route layer). Validates `parameter_schema` is a JSON object (not array/scalar).

**Error conditions:** `P0002 template_not_found`, `22023 body_en_required / body_ar_required / parameter_schema_must_be_object`.

---

### `fn_notification_template_render(p_template_id TEXT, p_channel TEXT, p_locale TEXT, p_parameters JSONB)` — migration 130

**Type:** Read (SECURITY INVOKER, gated by notification.template.manage OR system actor)
**Purpose:** Render a template with locale + `{{paramName}}` substitution (HTML-escaped). Returns `{ subject, body, missingParameters[], extraParameters[] }`. Used by BE notification dispatcher AND exposed for FE preview.

**Error conditions:** `22023 invalid_locale` (not 'en' or 'ar'), `P0002 template_not_found`.

---

## Functions — Extended (Write)

### `fn_system_setting_set` — extended by migration 130

Extended with per-key value validators for all 22 new keys introduced in migration 126:
- Port range check (`email.smtp.port`: 1..65535).
- Hex color check (`branding.color_primary`, `branding.color_accent`).
- Weekday allowlist check (`calendar.weekend_days` array elements: Monday..Sunday).
- HH:MM time check (`calendar.working_hours_start`, `calendar.working_hours_end`).
- Email regex check (`email.from_address`, `email.reply_to`).
- Integer ranges (`email.daily_send_limit`: 1..1_000_000, `security.session_timeout_min`, `security.password_policy_min_length`, `audit.retention_days`).
- Boolean checks (`email.enabled`, `security.mfa_required`, `security.password_policy_require_special`).

`is_secret` response values returned as `'***REDACTED***'` (pre-existing behavior extended to `email.smtp.auth_pass_ref`).

### `fn_system_setting_list` — extended by migration 130

Extended to support new 7-category filter including `security`, `email`, `calendar`, `audit_retention`. Known defect D-CRC-1 (category filter query param ignored at controller layer) — follow-up fix planned.

---

## Permissions — New (migration 123)

| Permission code | Description | Granted to |
|---|---|---|
| `audit.verify` | Walk + verify hash-chained audit_log integrity | `platform_admin`, `Super Admin` |
| `email.config.manage` | Read and update SMTP configuration, send test emails | `platform_admin` |
| `tenant.read` | Read tenant list and tenant detail | `platform_admin`, `Super Admin` |
| `branding.manage` | Upload logo/favicon, update branding settings | `platform_admin`, `Super Admin` |
| `notification.template.manage` | List, view, edit, and preview notification templates | `platform_admin` |
| `demo.purge` | Trigger demo data purge (combined with Super Admin role check) | `Super Admin` only |

**Also added:** `platform_admin → role.manage` grant (permission already existed from M0; only the role_permission row is new).

**NAMING-CONFLICT-2 (per OPEN-DECISION):** Brief's `system.config.write` was NOT introduced — existing `settings.write` (R-PA0) is reused. Net-new permission count = 6 (not 8).

---

## Triggers — New (migration 128)

| Trigger | Table | Event | Function | Purpose |
|---|---|---|---|---|
| `audit_log_no_update` | `audit_log` | BEFORE UPDATE | `fn_audit_log_no_update_guard()` | Append-only enforcement. Raises P0001 on any UPDATE attempt. |
| `audit_log_no_delete` | `audit_log` | BEFORE DELETE | `fn_audit_log_no_delete_guard()` | Append-only enforcement. Raises P0001 on any DELETE attempt. |
| `audit_notification_template_changes` | `notification_template` | INSERT, UPDATE, DELETE | `fn_audit_trigger()` | Standard audit trigger capturing old_values/new_values in hash-chained audit_log via fn_audit_log_record_v2 (post-migration 128). |

---

## BE Utility Module

### `src/utils/audit-canonical.util.ts`

TypeScript mirror of `fn_audit_log_canonicalize` (PL/pgSQL). Must match byte-for-byte. Keys sorted alphabetically at every depth; arrays preserve element order; NULLs explicit; timestamp format: UTC ISO 8601 µs (`yyyy-MM-ddTHH:mm:ss.uuuuuuZ`).

Used by the BE audit dispatcher to construct the canonical payload before computing `this_hash`. Cross-platform parity tested in `tests/utils/audit-canonical.util.test.ts` (3 fixture vectors; all PASS).

---

*Data dictionary version: 1.0 | Generated: 2026-05-10 | Agent 15 — Documentation Generator*
