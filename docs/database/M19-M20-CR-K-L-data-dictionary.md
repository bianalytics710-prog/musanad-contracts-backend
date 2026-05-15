# Data Dictionary — M19 + M20 / CR-K + CR-L
## Risk Cases (Mitigation Workflow) + Reports & Briefings

**Module:** M19 (CR-K) + M20 (CR-L) — Unit 7 (FINAL unit of v1.2 scope)
**Author:** Agent 15 (Documentation Generator)
**Date:** 2026-05-15
**Migration range applied:** 251..277 (27 migrations)
**DB head:** 277
**Baseline before:** schema_migrations.version = 250
**S2-21 streak:** 18th consecutive clean module preserved (47/47 net-new fns clean)

---

## 1. New Tables (5)

### 1.1 `risk_case` (CR-K, mig 253)

Unified risk-case primitive — alert + workflow task + evidence + escalation lifecycle. 8-state machine.
Per-case-type visibility via `system_setting.risk_case_visibility_map`. Tenant-scoped, FORCE RLS.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Row-level tenant isolation |
| `correlation_id` | `BIGINT` | nullable, FK → correlation(id) SET NULL | Link to source correlation (correlation_alert cases) |
| `contract_id` | `BIGINT` | nullable, FK → contract(id) SET NULL | Link to underlying contract (when relevant) |
| `case_type` | `TEXT` | NOT NULL, CHECK | One of `correlation_alert`, `obligation_due`, `sla_breach`, `system`, `manual` |
| `priority` | `TEXT` | NOT NULL, CHECK | One of `low`, `medium`, `high`, `critical` |
| `title` | `TEXT` | NOT NULL, CHECK length>0 | Short title (max 500 chars) |
| `body` | `TEXT` | nullable | **SENSITIVE** — narrative body, redacted in audit_log + Pino |
| `assigned_role` | `TEXT` | nullable | FK-by-name to `role.name` — validated in fn |
| `assigned_user_id` | `BIGINT` | nullable, FK → user(id) SET NULL | Optional named assignee |
| `status` | `TEXT` | NOT NULL, DEFAULT 'open', CHECK | 8-state: open / in_review / approved / rejected / escalated / accept_risk / snoozed / closed |
| `sla_hours` | `INTEGER` | nullable, CHECK >0 | SLA window from creation |
| `due_at` | `TIMESTAMPTZ` | nullable | Computed `created_at + sla_hours` via `fn_demo_now()` |
| `snoozed_until` | `TIMESTAMPTZ` | nullable | Snooze target (max 30 days from `fn_demo_now()`) |
| `closed_at` | `TIMESTAMPTZ` | nullable | Closure timestamp |
| `closed_by` | `BIGINT` | nullable, FK → user(id) SET NULL | Closer |
| `closure_outcome` | `TEXT` | nullable, CHECK | One of `mitigated`, `accepted`, `no_action`, `advisory_dispatched` |
| `dedupe_key` | `TEXT` | nullable, UNIQUE partial per tenant | `correlation:<id>` for auto-create idempotency |
| `metadata` | `JSONB` | NOT NULL, DEFAULT `'{}'` | Free-form metadata (`autoCreated`, `autoCreateReason`, etc.) |
| `data_classification` | `TEXT` | NOT NULL, DEFAULT 'internal', CHECK | Standard 4-tier |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Audit (forensic wall-clock) |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Audit |
| `created_by` | `BIGINT` | nullable, FK → user(id) | Audit |
| `updated_by` | `BIGINT` | nullable, FK → user(id) | Audit |
| `is_active` | `BOOLEAN` | NOT NULL, DEFAULT TRUE | Soft delete |

**Indexes:**
- `uq_risk_case_tenant_dedupe` (tenant_id, dedupe_key) WHERE dedupe_key IS NOT NULL — auto-create idempotency
- `idx_risk_case_tenant_id`, `idx_risk_case_correlation_id`, `idx_risk_case_contract_id`, `idx_risk_case_assigned_user_id`, `idx_risk_case_assigned_role`
- `idx_risk_case_status_priority` (status, priority) WHERE is_active — list-view query
- `idx_risk_case_due_at` (due_at) WHERE status NOT IN (terminal/accept_risk) AND is_active — escalation worker scan
- `idx_risk_case_active` (id) WHERE is_active

**RLS:** FORCE RLS. Policies: select-visible / modify-visible / RESTRICTIVE deny-DELETE.
**Audit trigger:** `audit_risk_case_changes` → `fn_audit_trigger()` (Strategy B).
**Delete strategy:** Soft (`is_active=false`); no hard-delete fn (mirrors `audit_log` policy per HITL CR-K-Q4).

### 1.2 `risk_case_event` (CR-K, mig 254)

Append-only timeline of risk-case events. Strategy A audit (in-fn `fn_audit_log_record_v2`; no default trigger). RESTRICTIVE deny-UPDATE + deny-DELETE policies enforce append-only at the RLS layer (S2-RLS-1 split-policy pattern).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `risk_case_id` | `BIGINT` | NOT NULL, FK → risk_case(id) CASCADE | Parent case |
| `event_type` | `TEXT` | NOT NULL, CHECK | 10-value enum: created / assigned / status_changed / comment_added / evidence_uploaded / escalated / accepted_risk / snoozed / closed / reopened |
| `actor_id` | `BIGINT` | nullable, FK → user(id) | NULL for system events (S2-20 sentinel — BE passes `NULLIF(actorId, 0)`) |
| `payload` | `JSONB` | NOT NULL, DEFAULT `'{}'` | **SENSITIVE** — redacted in audit + Pino |
| `occurred_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Forensic wall-clock |

**Indexes:** `idx_risk_case_event_tenant_id`, `idx_risk_case_event_case` (risk_case_id, occurred_at), `idx_risk_case_event_actor_id`.
**RLS:** FORCE RLS. 4 policies: select-via-parent-visibility / insert-tenant-only / deny-UPDATE (RESTRICTIVE) / deny-DELETE (RESTRICTIVE).
**No audit trigger** (Strategy A — write-time audit emitted inside the writing fn_).

### 1.3 `risk_case_attachment` (CR-K, mig 255)

Evidence attachments for risk cases. File bodies live in Supabase Storage at `risk-case-evidence/<tenantId>/<caseId>/<uuid>-<fileName>`. 50 MB cap. Soft delete only — no hard-delete fn (forensic chain-of-custody, HITL CR-K-Q4).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `risk_case_id` | `BIGINT` | NOT NULL, FK → risk_case(id) RESTRICT | Parent case |
| `file_uri` | `TEXT` | NOT NULL | **SENSITIVE** — Supabase Storage path; BE mints signed URL (TTL 60s) |
| `file_name` | `TEXT` | NOT NULL | Original filename |
| `file_mime` | `TEXT` | NOT NULL | MIME type |
| `file_bytes` | `BIGINT` | NOT NULL, CHECK 0 < x ≤ 52428800 | 50 MB cap |
| `uploaded_by` | `BIGINT` | NOT NULL, FK → user(id) | Uploader |
| `uploaded_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Forensic wall-clock |
| `is_active` | `BOOLEAN` | NOT NULL, DEFAULT TRUE | Soft delete |

**Indexes:** `idx_risk_case_attachment_tenant_id`, `idx_risk_case_attachment_case` (risk_case_id) WHERE is_active, `idx_risk_case_attachment_uploaded_by`, `idx_risk_case_attachment_active`.
**RLS:** FORCE RLS. 3 policies (select-via-parent / insert-tenant / RESTRICTIVE deny-DELETE).
**Audit trigger:** `audit_risk_case_attachment_changes` → `fn_audit_trigger()` (Strategy B). `file_uri` redacted via the global redact list.

### 1.4 `report_template` (CR-L, mig 260)

Report template definitions per tenant. Drives `/app/reports` library. `data_source` slug maps to `fn_report_data_<slug>`. Soft delete via `is_active=false`; report_run history preserved per HITL CR-L-Q3.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `template_id` | `TEXT` | NOT NULL, UNIQUE per tenant, CHECK length>0 | Stable slug — e.g. `executive_weekly_brief` |
| `display_name_en` | `TEXT` | NOT NULL, CHECK length>0 | English display name |
| `display_name_ar` | `TEXT` | nullable | Arabic display name |
| `description` | `TEXT` | nullable | Description |
| `report_kind` | `TEXT` | NOT NULL, CHECK | One of `excel`, `pdf`, `both` |
| `data_source` | `TEXT` | NOT NULL, CHECK length>0 | Maps to `fn_report_data_<slug>`; pg_proc EXISTS check enforced at fn level |
| `parameter_schema` | `JSONB` | NOT NULL, DEFAULT `'{}'` | Per-template parameter definition |
| `assigned_roles` | `JSONB` | NOT NULL, DEFAULT `'[]'`, CHECK array | Roles whose users can run this template (overlap match) |
| `is_scheduled` | `BOOLEAN` | NOT NULL, DEFAULT FALSE | Triggers scheduler-worker registration |
| `schedule_cron` | `TEXT` | nullable; CHECK NOT NULL when is_scheduled | 5-field UTC cron expression |
| `schedule_recipients` | `JSONB` | nullable, CHECK array | Recipient email/role list for scheduled runs |
| `last_run_at` | `TIMESTAMPTZ` | nullable | Updated by `fn_report_run_complete` on success |
| `enabled` | `BOOLEAN` | NOT NULL, DEFAULT TRUE | Soft-disable toggle (separate from is_active) |
| `data_classification` | `TEXT` | NOT NULL, DEFAULT 'internal', CHECK | Standard 4-tier |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Audit |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Audit |
| `created_by` | `BIGINT` | nullable, FK → user(id) | Audit |
| `updated_by` | `BIGINT` | nullable, FK → user(id) | Audit |
| `is_active` | `BOOLEAN` | NOT NULL, DEFAULT TRUE | Soft delete |

**Indexes:**
- `uq_report_template_tenant_template_id` (tenant_id, template_id) — natural key
- `idx_report_template_tenant_id`
- `idx_report_template_scheduled` (is_scheduled, enabled) WHERE is_scheduled AND enabled AND is_active — scheduler-worker scan
- `idx_report_template_active`

**RLS:** FORCE RLS. 3 policies (select-roles-overlap-or-admin / modify-admin-only / deny-DELETE RESTRICTIVE).
**Audit trigger:** `audit_report_template_changes` → `fn_audit_trigger()` (Strategy B).

### 1.5 `report_run` (CR-L, mig 261)

Append-only record of report generations. Strategy A audit (in-fn at status transitions). RESTRICTIVE deny-UPDATE + deny-DELETE policies. Status state machine: `pending → generating → complete | failed`. Keep forever per HITL CR-L-Q3.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PK | Surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `report_template_id` | `BIGINT` | NOT NULL, FK → report_template(id) RESTRICT | Parent template |
| `triggered_by` | `TEXT` | NOT NULL, CHECK | One of `manual`, `scheduled` |
| `triggered_by_user_id` | `BIGINT` | nullable, FK → user(id); CHECK NOT NULL when triggered_by='manual' | Manual-trigger actor |
| `parameters` | `JSONB` | NOT NULL, DEFAULT `'{}'` | **SENSITIVE** — may reveal investigation targets |
| `format` | `TEXT` | NOT NULL, CHECK | One of `excel`, `pdf` |
| `output_uri` | `TEXT` | nullable | **SENSITIVE** — Supabase Storage path; BE mints signed URL (TTL 60s) |
| `output_size_bytes` | `BIGINT` | nullable, CHECK ≥0 | Final output size |
| `status` | `TEXT` | NOT NULL, DEFAULT 'pending', CHECK | 4-state: pending / generating / complete / failed |
| `error_message` | `TEXT` | nullable | **SENSITIVE** — failure context; never echoed in API errors |
| `started_at` | `TIMESTAMPTZ` | nullable | Set by `fn_report_run_pending_get` |
| `completed_at` | `TIMESTAMPTZ` | nullable | Set by `fn_report_run_complete` |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Forensic wall-clock |

**Indexes:** `idx_report_run_tenant_id`, `idx_report_run_template_id`, `idx_report_run_user_id` (WHERE NOT NULL), `idx_report_run_pending` (id, report_template_id) WHERE status='pending' — worker pickup target for FOR UPDATE SKIP LOCKED, `idx_report_run_status`.
**RLS:** FORCE RLS. 4 policies (select-by-trigger-user-or-admin / insert-tenant / RESTRICTIVE deny-UPDATE / RESTRICTIVE deny-DELETE). DEFINER fns (`fn_report_run_pending_get`, `fn_report_run_complete`) bypass for lifecycle UPDATEs.
**No audit trigger** (Strategy A).

---

## 2. EXTEND Statements (2)

### 2.1 `fn_audit_trigger` redact list — mig 251

Extends the global audit-log redact array. Baseline 55 → 58 with three net-new field names: `body`, `file_uri`, `output_uri`. (`payload`, `parameters`, `error_message` already present from M16 baseline.) Parallel `fn_audit_log_canonicalize` extension for hash-chain redact parity.

### 2.2 `system_setting.category` CHECK extension — mig 252

Adds 10th value `risk_case` to the category CHECK constraint. Mirrors mig 168 `scoring` precedent (`DROP CHECK; ADD CHECK with new value list`).

Final allowed values: `general | uae_pass | branding | security | email | calendar | audit_retention | ai | scoring | risk_case`.

---

## 3. Functions Created (47)

### 3.1 Risk-Case Write Functions (10) — mig 258

All INVOKER VOLATILE unless noted. Standard tail: `COMMENT ON FUNCTION` + `REVOKE EXECUTE FROM PUBLIC` + `GRANT EXECUTE TO neondb_owner`.

| Fn | Mode | Purpose |
|---|---|---|
| `fn_risk_case_create` | INVOKER | Create a manual risk case. Permission gate `risk.case.create`. Validates assigned_role/_user against active roles. case_type defaults `manual`. |
| `fn_risk_case_auto_create_from_correlation` | **DEFINER** | Worker-only. Idempotent via `dedupe_key='correlation:<id>'`. SAVEPOINT-protected unique-violation handler. priority derived from correlation_rule (fallback `medium`). |
| `fn_risk_case_assign` | INVOKER | Reassign role + optional user. Composite gate: `risk.case.create` OR `risk.case.escalate` OR current assignee. |
| `fn_risk_case_add_comment` | INVOKER | Append `comment_added` event. Visible-only. |
| `fn_risk_case_add_evidence` | INVOKER | Insert into `risk_case_attachment` + emit `evidence_uploaded` event. 50 MB cap (defense in depth — BE also enforces multer limit). |
| `fn_risk_case_status_transition` | INVOKER | Strict matrix: open→in_review, in_review→approved\|rejected. Other transitions use dedicated endpoints. P0001 → 409 on invalid (HITL CR-K-Q3). |
| `fn_risk_case_escalate` | INVOKER | Reads `system_setting.escalation_matrix`. Cycle detection: `matrixHopCount > 10` → P0001. |
| `fn_risk_case_accept_risk` | INVOKER | Reads `system_setting.accept_risk_approval_matrix` (critical→Executive; high→Legal Counsel; medium→peer). Permission `risk.case.accept_risk` + matrix approver check + self-approval blocked at BE+FE. |
| `fn_risk_case_snooze` | INVOKER | 30-day cap from `fn_demo_now()`. Validates future timestamp. |
| `fn_risk_case_close` | INVOKER | Requires prior approved/rejected/accept_risk/escalated. Records closure_outcome + closed_at=`fn_demo_now()`. |

### 3.2 Risk-Case Read Functions (4) — mig 259

| Fn | Mode | Purpose |
|---|---|---|
| `fn_risk_case_list` | INVOKER STABLE | Filterable + paginated. S2-24 split-aggregate. Visibility map from `system_setting.risk_case_visibility_map`. **Mig 274 patch:** COUNT extracted to scalar query before WITH (DEFECT-CRKL-DB-INFLIGHT-1 fix). |
| `fn_risk_case_get_by_id` | INVOKER STABLE | Full detail: timeline + attachments + linked correlation + linked contract + linkedAdvisoryDrafts (via correlation_id indirection) + slaCountdownSeconds (`fn_demo_now()`-driven). |
| `fn_risk_case_evidence_get` | INVOKER STABLE | Attachment metadata. BE controller mints signed URL post-call. |
| `fn_risk_case_escalation_check` | **DEFINER STABLE** | Worker-only. Cross-tenant. `fn_demo_now()` for due_at + snoozed_until comparison. Worker sets per-row tenant GUC before calling `fn_risk_case_escalate`. |

### 3.3 Report Template Functions (5) — mig 263

| Fn | Mode | Purpose |
|---|---|---|
| `fn_report_template_list` | INVOKER STABLE | Branches on `admin_mode` arg. User mode: roles-overlap filter + enabled+is_active. Admin mode: all rows. |
| `fn_report_template_get_by_id` | INVOKER STABLE | Single template — admin OR roles-overlap visibility. |
| `fn_report_template_create` | INVOKER | `data_source` validated via `EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'fn_report_data_' \|\| p_data_source)`. CHECK enforces cron NOT NULL when is_scheduled. |
| `fn_report_template_update` | INVOKER | Partial update; `templateId` / `tenantId` / `reportKind` immutable (rejected at BE before fn invocation per M16 DD-6 precedent). |
| `fn_report_template_delete` | INVOKER | Soft delete (`is_active=false`, `enabled=false`). Run history preserved. |

### 3.4 Report Run Functions (4) — mig 264

| Fn | Mode | Purpose |
|---|---|---|
| `fn_report_run_trigger` | INVOKER | Permission `report.read` + roles-overlap with template.assigned_roles. Inserts `pending` row; returns runId. Forces `triggered_by='manual'` unless caller is scheduler service account. |
| `fn_report_run_complete` | **DEFINER** | Worker-only. Transitions `generating → complete` (with outputUri + outputSizeBytes) OR `generating → failed` (with errorMessage). Updates `report_template.last_run_at` on success. P0001 if already terminal. |
| `fn_report_run_get_by_id` | INVOKER STABLE | Visibility: triggered_by_user_id = caller OR `report.run.read.all`. Returns raw fileUri; BE mints signed URL post-call. |
| `fn_report_run_pending_get` | **DEFINER** | Worker pickup. CTE + FOR UPDATE SKIP LOCKED (S2-24). Atomically flips `pending → generating` and emits `fn_audit_log_record_v2` audit inside the same CTE (S2-8). **Mig 275 patch:** DEFINER carve-out for scheduler service account (DEFECT-CRKL-SMOKE-1 fix). |

### 3.5 Report Data Functions (24) — migs 265..271

All STABLE INVOKER. Uniform envelope: `{ payload: <per-template>, meta: { tenantId, generatedAt: fn_demo_now(), sourceTraceability: [{tableName, recordIds, count}], parameters } }`. Every fn pins tenant via explicit `WHERE tenant_id = current_setting('app.current_tenant_id', true)::UUID` on MV reads. S2-24 split-aggregate.

| Persona | Slug (24 total) | Migration |
|---|---|---|
| Executive (4) | `executive_weekly_brief`, `executive_monthly_board`, `executive_avar_trend`, `executive_top10_exposures` | 265 |
| Legal (4) | `legal_advisory_queue`, `legal_clause_review_backlog`, `legal_fm_eligibility`, `legal_regulatory_digest` | 266 |
| Procurement (4) | `procurement_supplier_scorecard`, `procurement_supplier_scorecard_detail`, `procurement_icv_compliance`, `procurement_sla_breach` | 267 |
| Operations (3) | `operations_risk_board_snapshot`, `operations_delivery_delay`, `operations_penalty_exposure` | 268 |
| Finance Treasury (3) | `finance_fx_exposure`, `finance_price_review_queue`, `finance_payment_delay` | 269 |
| Compliance & ESG (3) | `compliance_sanctions_exposure`, `compliance_subcontractor_chain`, `compliance_audit_rights` | 270 |
| Platform Admin (3) | `admin_system_health`, `admin_audit_chain_verification`, `admin_source_health_snapshot` | 271 |

**Common invariants** (per DB Impl report design-vs-reality A-table — A1..A11 adapter-mapped at fn body authorship):
- `latest_risk_score` MV column is `id` (not `risk_score_id`)
- `risk_score.health_score` (not `overall_score`); `risk_score.calculated_at` (not `computed_at`)
- `contract` has no `tenant_id` column → tenant scope flows via `risk_case.tenant_id` / `risk_score.tenant_id` / `correlation.tenant_id`
- `contract.title` is `title_en` + `title_ar` → `COALESCE(title_en, title_ar)`
- All role joins use `JOIN role r ON r.id = u.role_id` (single role per user)
- `fn_current_user_has_permission(TEXT)` — single-arg signature; BE sets `app.current_user_id` GUC

---

## 4. Permissions (8 new) — mig 256 + 262

| Permission | Granted to (roles) | Description |
|---|---|---|
| `risk.case.create` | 8 — platform_admin, Super Admin, operations, finance_treasury, compliance_esg, legal_counsel, contract_drafter, contract_approver_2 | Create manual risk cases |
| `risk.case.escalate` | 8 — same set + executive | Escalate to next matrix role |
| `risk.case.accept_risk` | 4 — platform_admin, Super Admin, executive, legal_counsel | Record Accept-Risk decision |
| `risk.case.close` | 10 — broad set (all main personas) | Close a finalised case |
| `report.read` | 11 — broad incl. contract_recipient | Read templates + trigger runs |
| `report.template.manage` | 2 — platform_admin, Super Admin | Admin template CRUD |
| `report.schedule.manage` | 2 — platform_admin, Super Admin | Manage schedule + scheduler |
| `report.run.read.all` | 2 — platform_admin, Super Admin | See all runs (cross-user) |

**Total grants:** 47 distinct `(role, permission)` pairs across the 8 permissions. Mig 273 defensively re-applies all `(role, permission)` pairs with `ON CONFLICT DO NOTHING` (95 statements covering REVOKE+GRANT trio for 47 fns).

**Remap (HIGH-2 conflict resolution):** `procurement_supplier_risk` is a **permission**, not a role. All "procurement" grants were remapped to `contract_drafter`, `contract_approver`, `contract_approver_2`.

---

## 5. Triggers (3 new)

| Trigger | Table | Events | Purpose |
|---|---|---|---|
| `audit_risk_case_changes` | `risk_case` | INSERT, UPDATE, DELETE | Strategy B audit; redacts `body`, `metadata.justification`, etc. |
| `audit_risk_case_attachment_changes` | `risk_case_attachment` | INSERT, UPDATE, DELETE | Strategy B; redacts `file_uri` |
| `audit_report_template_changes` | `report_template` | INSERT, UPDATE, DELETE | Strategy B; standard audit |

`risk_case_event` and `report_run` use **Strategy A** (in-fn `fn_audit_log_record_v2`) — no default trigger; RESTRICTIVE deny-UPDATE + deny-DELETE policies enforce append-only.

---

## 6. RLS Policies (15 new) — S2-RLS-1 compliance

| Table | Policies | Notes |
|---|---|---|
| `risk_case` | 3 — select-visible / modify-visible / deny-DELETE (RESTRICTIVE) | Visibility via system_setting map |
| `risk_case_event` | 4 — select-via-parent / insert-tenant / deny-UPDATE (RESTRICTIVE) / deny-DELETE (RESTRICTIVE) | S2-RLS-1 split deny-UPDATE-and-DELETE pattern |
| `risk_case_attachment` | 3 — select-via-parent / insert-tenant / deny-DELETE (RESTRICTIVE) | UPDATE allowed for `is_active` toggle only |
| `report_template` | 3 — select-roles-overlap / modify-admin / deny-DELETE (RESTRICTIVE) | Soft-delete only |
| `report_run` | 4 — select-by-user / insert-tenant / deny-UPDATE (RESTRICTIVE) / deny-DELETE (RESTRICTIVE) | DEFINER fns bypass UPDATE for lifecycle |

All 5 tables: `ALTER TABLE ... FORCE ROW LEVEL SECURITY` applied at DDL.

---

## 7. Seed Data

### 7.1 system_setting (3 rows) — mig 257, category `risk_case`

| Key | Purpose |
|---|---|
| `escalation_matrix` | JSONB matrix mapping current role → next role for `fn_risk_case_escalate` |
| `risk_case_visibility_map` | JSONB map: case_type → roles allowed to see |
| `accept_risk_approval_matrix` | JSONB map: priority → role required to approve (critical→Executive; high→Legal Counsel; medium→peer) |

All three are admin-editable via the existing CR-C system_setting CRUD surface. Idempotent `ON CONFLICT (key) DO NOTHING`.

### 7.2 ADNOC Report Templates (24 rows) — mig 272

24 ADNOC-tenant templates seeded — one per `data_source` slug (see §3.5 grouping).

| Schedule | Templates |
|---|---|
| `0 9 * * 1` (Mon 9am UTC) | `executive_weekly_brief` |
| `0 6 * * *` (daily 6am UTC) | `compliance_sanctions_exposure` |
| Manual-only | The other 22 templates |

Tenant: ADNOC (`00000000-0000-0000-0000-000000000001`). AR display names use `[NEEDS TRANSLATION]` placeholders per M14/M15/M16 precedent. Idempotent `ON CONFLICT (tenant_id, template_id) DO NOTHING`.

---

## 8. Time-Freeze Compliance (CR-J carry-forward)

**Total `fn_demo_now()` occurrences across Unit 7 fns:** **45** (target ≥34).

| Fn group | `fn_demo_now()` usage |
|---|---|
| `fn_risk_case_create` / `_auto_create_from_correlation` | `due_at` computation |
| `fn_risk_case_get_by_id` | `slaCountdownSeconds` |
| `fn_risk_case_snooze` | future-validation + 30-day cap |
| `fn_risk_case_close` | `closed_at` |
| `fn_risk_case_escalation_check` | `due_at` + `snoozed_until` comparison |
| `fn_risk_case_list` | SLA bucket comparison |
| `fn_report_template_create` / `_update` | `updated_at` |
| `fn_report_run_pending_get` / `_complete` | `started_at` + `completed_at` + `last_run_at` |
| All 24 `fn_report_data_*` | `meta.generatedAt` + date-range defaults |

**`CURRENT_TIMESTAMP` retained for** (forensic wall-clock — design §0.5):
- `audit_log.changed_at`
- `risk_case_event.occurred_at`
- `risk_case_attachment.uploaded_at`
- `report_run.created_at`

Time-freeze GUC (`app.demo.time_now`) is honoured by every Unit-7 business-logic time reference.

---

## 9. Migration List (251..277)

| # | File | Purpose |
|---|---|---|
| 251 | `251_unit7_extend_audit_trigger_redact_list.sql` | EXTEND fn_audit_trigger + fn_audit_log_canonicalize +3 fields (body / file_uri / output_uri) |
| 252 | `252_unit7_extend_system_setting_category.sql` | DROP/ADD CHECK to add 10th category `risk_case` |
| 253 | `253_crk_create_risk_case.sql` | risk_case table + RLS + audit trigger + indexes |
| 254 | `254_crk_create_risk_case_event.sql` | risk_case_event append-only + S2-RLS-1 split policies |
| 255 | `255_crk_create_risk_case_attachment.sql` | risk_case_attachment + 50 MB cap + audit |
| 256 | `256_crk_create_permissions.sql` | 4 CR-K permissions + grants |
| 257 | `257_crk_seed_system_setting_risk_case.sql` | 3 system_setting rows (matrices) |
| 258 | `258_crk_fn_risk_case_write_functions.sql` | 10 write fns |
| 259 | `259_crk_fn_risk_case_read_functions.sql` | 4 read fns (incl. escalation-check) |
| 260 | `260_crl_create_report_template.sql` | report_template + RLS + audit |
| 261 | `261_crl_create_report_run.sql` | report_run append-only + S2-RLS-1 |
| 262 | `262_crl_create_permissions.sql` | 4 CR-L permissions + grants |
| 263 | `263_crl_fn_report_template_functions.sql` | 5 template fns |
| 264 | `264_crl_fn_report_run_functions.sql` | 4 run fns (incl. worker pickup, complete) |
| 265 | `265_crl_fn_report_data_executive.sql` | 4 executive data fns |
| 266 | `266_crl_fn_report_data_legal.sql` | 4 legal data fns |
| 267 | `267_crl_fn_report_data_procurement.sql` | 4 procurement data fns |
| 268 | `268_crl_fn_report_data_operations.sql` | 3 operations data fns |
| 269 | `269_crl_fn_report_data_finance.sql` | 3 finance data fns |
| 270 | `270_crl_fn_report_data_compliance.sql` | 3 compliance data fns |
| 271 | `271_crl_fn_report_data_admin.sql` | 3 admin data fns |
| 272 | `272_crl_seed_adnoc_report_templates.sql` | 24 ADNOC report_template seed rows |
| 273 | `273_unit7_grant_pre_emptive_backfill.sql` | 95-statement REVOKE+GRANT trio backstop |
| 274 | `274_unit7_inflight_fn_risk_case_list_count_cte_fix.sql` | In-flight: COUNT extracted to scalar query (DEFECT-CRKL-DB-INFLIGHT-1) |
| 275 | `275_unit7_fn_report_template_list_scheduled_only.sql` | In-flight: DEFINER carve-out for scheduler service account (DEFECT-CRKL-SMOKE-1) |
| 276 | `276_unit7_in_flight_defect_placeholder_3.sql` | Empty placeholder retained |
| 277 | `277_unit7_post_walk_debt_patch.sql` | Empty placeholder retained for post-walk debt |

**Rollback discipline:** Every migration has a `-- ROLLBACK:` block. DROP TABLE CASCADE for new tables; DROP FUNCTION (signature) for new fns; CREATE OR REPLACE to previous body for EXTEND. The two-empty-placeholder convention (mirroring M16 / M18) reserves slots for post-walk discovery; both 276 and 277 were applied as no-op placeholders.

---

## 10. Cross-References

- **Module handoff:** `docs/M19-M20-handoff.md` — narrative + HITL decisions + permission matrix + defects
- **OpenAPI spec:** `docs/api/cr-k-l.yaml` — 48 endpoints with full request/response shapes
- **Adjacent dictionaries:**
  - `docs/database/M16-CR-H-data-dictionary.md` — advisory_template + notification (M19 inherits redact list)
  - `docs/database/M17-M18-CR-I-J-data-dictionary.md` — demo harness + `fn_demo_now()` (M19 builds on time-freeze)

---

*Generated by Agent 15 (Documentation Generator) — Unit 7 / M19 + M20 / CR-K + CR-L — 2026-05-15*
