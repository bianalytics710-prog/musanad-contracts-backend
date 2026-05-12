# M11 — Document Ingestion Pipeline (CR-D0) — Database Data Dictionary

Generated: 2026-05-12T00:00:00Z
Module owner: M11 (CR-D0)
Schema version: 140 (both `m0-foundation` and `test` Neon branches)

---

## Tables

### contract_version — 9-column extension (migration 132)

**Purpose**: Tracks the ingestion lifecycle and extracted-text artifact for every contract version. All 9 columns are additive — pre-existing rows default to `ingestion_status='pending'` and all other columns NULL.
**Owned by**: M1a (table), extended by M11 (CR-D0)
**Used by**: M11 ingestion worker, FE Document tab, future CR-D clause extractor

| Column | Type | Constraints | Description |
|---|---|---|---|
| extracted_text_uri | TEXT | nullable | SENSITIVE. Supabase Storage path; signed URLs only. Path schema: `<tenantId>/<contractId>/v<n>/<uuid>.txt`. UUID suffix prevents overwrite on retry (N12). Listed in fn_audit_trigger redact list (migration 133) + Pino redact paths. |
| ocr_used | BOOLEAN | NOT NULL DEFAULT FALSE | TRUE if Tesseract or gpt-4o Vision was invoked on any page; FALSE for digital_pdf and mammoth_docx paths. |
| ocr_confidence_avg | NUMERIC(3,2) | nullable, CHECK [0.00..1.00] | Arithmetic mean of per-page Tesseract confidence. NULL when `ocr_used = FALSE`. Validated by fn_contract_version_ingestion_complete. |
| page_count | INTEGER | nullable, CHECK >= 0 | PDF page count (from pdf-parse) or DOCX section count (from mammoth; 1 if no section headers). |
| ingestion_status | TEXT | NOT NULL DEFAULT 'pending', CHECK enum | enum-of-5: `pending` / `extracting` / `complete` / `failed` / `partial`. Lifecycle: pending → extracting → (complete | failed | partial). `partial` reserved for retry-budget exhaustion. |
| ingestion_error | TEXT | nullable | SENSITIVE. Truncated to 2000 chars by fn_contract_version_ingestion_fail. May contain partial extracted text or stack traces. Listed in redact list. |
| extraction_engine | TEXT | nullable, CHECK enum | enum-of-5: `digital_pdf` / `tesseract` / `gpt4o_vision` / `mammoth_docx` / `mixed`. `mixed` = at least one Tesseract page + at least one gpt-4o page. Set on completion. |
| extracted_at | TIMESTAMPTZ | nullable | Timestamp of extraction completion or terminal failure. NULL while `pending` or `extracting`. |
| ingestion_attempt_count | INTEGER | NOT NULL DEFAULT 0, CHECK >= 0 | Worker increments on each retry. fn_contract_version_ingestion_fail reads it; terminal failure when `>= 2` (Q5 retry-2x-then-fail). |

**Migration 140 patch context**: Migration 137 (function bodies for `fn_contract_version_ingest`, `fn_contract_version_ingestion_complete`, `fn_contract_version_ingestion_fail`) referenced `updated_at = CURRENT_TIMESTAMP` in UPDATE statements on `contract_version`. The `contract_version` table is append-only (created by M1a migration 003) and has no `updated_at` column. Migration 140 re-creates all three functions with the `updated_at` line removed. Migration 138 (M_parity backfill prep) had the same bug and was superseded by migration 139 (corrected UPDATE without `updated_at`); migration 138 is recorded in `schema_migrations` as `crd0_mparity_backfill_prep_skipped_design_defect` and its SQL had zero effect on the DB.

**Indexes added by migration 132**:

| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_contract_version_ingestion_pending | id WHERE ingestion_status IN ('pending','extracting') | BTREE partial | Worker pickup loop — narrows scan to actionable rows only |
| idx_contract_version_extracted_text_uri | id WHERE extracted_text_uri IS NOT NULL | BTREE partial | FE Document tab + future CR-D pre-flight check |

**Constraints added by migration 132**:

| Constraint | Expression |
|---|---|
| contract_version_ingestion_status_check | ingestion_status IN ('pending','extracting','complete','failed','partial') |
| contract_version_extraction_engine_check | extraction_engine IS NULL OR extraction_engine IN ('digital_pdf','tesseract','gpt4o_vision','mammoth_docx','mixed') |
| contract_version_ocr_confidence_avg_range | ocr_confidence_avg IS NULL OR (ocr_confidence_avg BETWEEN 0.00 AND 1.00) |
| contract_version_page_count_nonneg | page_count IS NULL OR page_count >= 0 |
| contract_version_ingestion_attempt_count_nonneg | ingestion_attempt_count >= 0 |

---

### ingestion_review_queue (new table — migration 134)

**Purpose**: Per-page low-confidence review queue. One row per PDF page where Tesseract scored below `ocr.confidence_threshold` (Q1 = 0.75) OR where the daily Vision cap (`ai.daily_vision_cap_pages`, Q2 = 500) forced human-only routing. Tenant-scoped per §4.9.
**Owned by**: M11 (CR-D0)
**Used by**: M11 admin review UI (`/app/admin/ingestion-queue`), future CR-D quality gate

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier (fn_audit_trigger compatible — A16). |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Required by §4.9. Worker hydrates via SET LOCAL before INSERT (N18). RLS GUC narrows reads. |
| contract_version_id | BIGINT | NOT NULL, FK contract_version(id) ON DELETE RESTRICT | Bound to the version it was generated from (OPEN-DECISION-N Path B — auditable provenance). |
| page_no | INTEGER | NOT NULL, CHECK >= 1 | 1-indexed page number within the contract version. |
| tesseract_confidence | NUMERIC(3,2) | nullable, CHECK [0.00..1.00] | Per-page confidence reported by Tesseract.js. NULL when page was routed directly to gpt-4o without Tesseract. |
| tesseract_text | TEXT | nullable | SENSITIVE — confidential contract content. Excluded from list endpoint response; in fn_audit_trigger redact list. |
| gpt4o_text | TEXT | nullable | SENSITIVE — confidential contract content. NULL when gpt4o_used = FALSE. In redact list. |
| gpt4o_used | BOOLEAN | NOT NULL DEFAULT FALSE | TRUE when the page was routed to gpt-4o Vision. |
| final_text | TEXT | nullable | SENSITIVE — reviewer-confirmed text. Set by fn_ingestion_review_resolve (confirm: COALESCE(gpt4o_text, tesseract_text); correct: p_corrected_text; reject: NULL). |
| review_status | TEXT | NOT NULL DEFAULT 'pending_auto', CHECK enum | enum-of-4: `pending_auto` / `pending_human` / `resolved` / `rejected`. |
| reviewed_by | BIGINT | nullable, FK user(id) ON DELETE SET NULL | User who resolved the page. |
| reviewed_at | TIMESTAMPTZ | nullable | Timestamp of review action. |
| data_classification | TEXT | NOT NULL DEFAULT 'demo', CHECK enum | CR-C invariant — every new content table carries this column at CREATE time. enum-of-3: `demo` / `pilot` / `production`. |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | Record creation timestamp (UTC). |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT CURRENT_TIMESTAMP | Last update timestamp (UTC). |
| created_by | BIGINT | nullable, FK user(id) ON DELETE SET NULL | User who created this record. |
| updated_by | BIGINT | nullable, FK user(id) ON DELETE SET NULL | User who last updated this record. |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft-delete flag. RESTRICTIVE deny_direct_delete policy makes hard DELETE impossible; use is_active = FALSE. |

**Unique constraint**: `ingestion_review_queue_tenant_version_page_unique` on `(tenant_id, contract_version_id, page_no)` — fn_ingestion_review_queue_record is idempotent via ON CONFLICT DO UPDATE.

**Indexes**:

| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_ingestion_review_queue_tenant_id | tenant_id | BTREE | FK support |
| idx_ingestion_review_queue_contract_version_id | contract_version_id | BTREE | FK support |
| idx_ingestion_review_queue_active | id WHERE is_active = TRUE | BTREE partial | Soft-delete filter |
| idx_ingestion_review_queue_pending_worklist | (tenant_id, created_at DESC) WHERE review_status IN ('pending_auto','pending_human') AND is_active = TRUE | BTREE partial | Reviewer worklist |

---

## Functions

### fn_contract_version_ingest(BIGINT) — migration 137 + patched by 140

**Type**: Write (SECURITY DEFINER)
**Purpose**: Idempotent state-flip `pending|failed|partial → extracting` on contract_version. Increments `ingestion_attempt_count` on every call. Returns `alreadyInProgress: true` if already `extracting` or `complete`.
**Called via**: `SELECT fn_contract_version_ingest(p_contract_version_id)`

**Parameters**:

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_contract_version_id | BIGINT | Yes | contract_version.id to advance to extracting. |

**Returns**: JSONB
```json
{
  "contractVersionId": "integer",
  "ingestionStatus": "extracting",
  "queuedAt": "ISO 8601",
  "alreadyInProgress": "boolean"
}
```

**Business rules**:
- Permission gate: `document.ingest` required (system-only; Super Admin break-glass per OPEN-DECISION-L Path A).
- Concurrency lock: `SELECT FOR UPDATE` on the target row before state flip (S2-17).
- Idempotent: rows in `extracting` or `complete` status return early without mutation.
- `ingestion_attempt_count` increments on every non-idempotent call (Q5 retry counter).
- No `updated_at` column on `contract_version` — append-only table per M1a (DEFECT-1 patch).

**Error conditions**:
- `fn_contract_version_ingest: permission_denied: document.ingest required` (ERRCODE 42501)
- `fn_contract_version_ingest: contract_version not found (id=N)` (ERRCODE P0002)

---

### fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT) — migration 137 + patched by 140

**Type**: Write (SECURITY DEFINER)
**Purpose**: Marks ingestion complete. Records artifact URI + telemetry (page count, OCR flag, confidence, engine). Emits `pg_notify('contract_ingested')` for future CR-D consumer.
**Called via**: `SELECT fn_contract_version_ingestion_complete(p_contract_version_id, p_extracted_text_uri, p_page_count, p_ocr_used, p_ocr_confidence_avg, p_extraction_engine)`

**Parameters**:

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_contract_version_id | BIGINT | Yes | Target version. |
| p_extracted_text_uri | TEXT | Yes | Supabase Storage path (SENSITIVE). |
| p_page_count | INTEGER | Yes | >= 0. |
| p_ocr_used | BOOLEAN | Yes | TRUE if Tesseract or Vision was invoked. |
| p_ocr_confidence_avg | NUMERIC | Conditional | Required when p_ocr_used = TRUE. Range [0.00..1.00]. |
| p_extraction_engine | TEXT | Yes | One of the five extraction_engine enum values. |

**Returns**: JSONB `{ contractVersionId, ingestionStatus: "complete", extractedAt, notifyEmitted }`

**Business rules**:
- Input validation: extractedTextUri not blank; pageCount >= 0; extraction_engine in enum; ocrConfidenceAvg required when ocrUsed = TRUE.
- Emits `pg_notify('contract_ingested', { contractVersionId, tenantId })` — CR-D clause extractor will LISTEN on this channel.
- No `updated_at` column on `contract_version` — append-only (DEFECT-1 patch via migration 140).

---

### fn_contract_version_ingestion_fail(BIGINT, TEXT) — migration 137 + patched by 140

**Type**: Write (SECURITY DEFINER)
**Purpose**: Marks ingestion failed. Records error message (truncated to 2000 chars — SENSITIVE). Emits `pg_notify('ingestion_failed')` for admin notification rendering.
**Called via**: `SELECT fn_contract_version_ingestion_fail(p_contract_version_id, p_error_message)`

**Parameters**:

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_contract_version_id | BIGINT | Yes | Target version. |
| p_error_message | TEXT | Yes | Error description (stack trace or message). Truncated to 2000 chars. |

**Returns**: JSONB `{ contractVersionId, ingestionStatus: "failed", failedAt, attemptCount }`

**Business rules**:
- Error message truncated defensively to `LEFT(p_error_message, 2000)` — prevents large stack traces from bloating the `ingestion_error` column.
- `attemptCount` returned so the BE service layer can decide whether to re-queue (< 2 attempts) or terminal-fail.
- NOTIFY payload includes `attemptCount` for admin notification context.

---

### fn_contract_version_ingestion_status(BIGINT) — migration 137

**Type**: Read (SECURITY INVOKER, STABLE)
**Purpose**: Returns current ingestion status for a single contract_version. RLS via M1a `contract_version_select_parent_aware` policy. Returns NULL on not-found / RLS-invisible (controller maps to 404).
**Called via**: `SELECT fn_contract_version_ingestion_status(p_contract_version_id)`

**Parameters**:

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_contract_version_id | BIGINT | Yes | Target version. |

**Returns**: JSONB
```json
{
  "contractVersionId": "integer",
  "ingestionStatus": "pending|extracting|complete|failed|partial",
  "ingestionError": "text or null",
  "pageCount": "integer or null",
  "ocrUsed": "boolean",
  "ocrConfidenceAvg": "number or null",
  "extractionEngine": "string or null",
  "extractedAt": "ISO 8601 or null",
  "extractedTextUri": "string — STRIPPED by controller before HTTP response",
  "lowConfidencePageCount": "integer — pending_auto|pending_human queue rows"
}
```

**Business rules**:
- `lowConfidencePageCount` computed via correlated subquery (S2-24 anti-nested-aggregate pattern) — count of active ingestion_review_queue rows with `review_status IN ('pending_auto','pending_human')`.
- Returns NULL (not P0002) on not-found — controller translates to 404.
- `extractedTextUri` is present in the DB JSONB but stripped by the controller before the HTTP response; use `/extracted-text` for signed-URL delivery.

---

### fn_ingestion_review_queue_record(UUID, BIGINT, INTEGER, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) — migration 137

**Type**: Write (SECURITY DEFINER)
**Purpose**: Worker INSERT path into ingestion_review_queue. Bypasses FORCE RLS for system-context queue writes. Idempotent on UNIQUE(tenant_id, contract_version_id, page_no) via ON CONFLICT DO UPDATE.
**Called via**: `SELECT fn_ingestion_review_queue_record(p_tenant_id, p_contract_version_id, p_page_no, p_tesseract_confidence, p_tesseract_text, p_gpt4o_text, p_gpt4o_used, p_initial_review_status)`

**Parameters**:

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_tenant_id | UUID | Yes | Tenant UUID (worker hydrates via GUC lookup — N18). |
| p_contract_version_id | BIGINT | Yes | Target version. |
| p_page_no | INTEGER | Yes | 1-indexed page number. |
| p_tesseract_confidence | NUMERIC | No | Per-page confidence [0.00..1.00]. NULL if Tesseract not run. |
| p_tesseract_text | TEXT | No | SENSITIVE — Tesseract output for this page. |
| p_gpt4o_text | TEXT | No | SENSITIVE — gpt-4o Vision output. NULL if gpt4o_used = FALSE. |
| p_gpt4o_used | BOOLEAN | Yes | TRUE if Vision was invoked on this page. |
| p_initial_review_status | TEXT | Yes | One of: `pending_auto`, `pending_human`. |

**Returns**: JSONB `{ id, contractVersionId, pageNo, reviewStatus, createdAt }`

**Business rules**:
- FK pre-validation: both tenant + contract_version existence checked before INSERT (S2-23).
- `p_initial_review_status` must be `pending_auto` or `pending_human` — no other values accepted.
- `data_classification` defaults to `'demo'` at INSERT; service layer may update post-insert via fn_ingestion_review_resolve.

---

### fn_ingestion_review_queue_list(INTEGER, INTEGER, TEXT, BIGINT, BOOLEAN) — migration 137

**Type**: Read (SECURITY INVOKER, STABLE)
**Purpose**: Paginated reviewer worklist and admin monitor for ingestion_review_queue. Default sort: pending_auto > pending_human > resolved > rejected, then created_at DESC. RLS narrows by tenant_id GUC. Excludes `tesseract_text` and `gpt4o_text` from the list response (sensitivity — full text only available via resolve UI).
**Called via**: `SELECT fn_ingestion_review_queue_list(p_page, p_limit, p_review_status, p_contract_version_id, p_gpt4o_used)`

**Parameters**:

| Parameter | Type | Default | Description |
|---|---|---|---|
| p_page | INTEGER | 1 | Page number (clamped to >= 1). |
| p_limit | INTEGER | 20 | Rows per page (clamped to [1..100]). |
| p_review_status | TEXT | NULL | Optional filter: pending_auto / pending_human / resolved / rejected. |
| p_contract_version_id | BIGINT | NULL | Optional filter by version. |
| p_gpt4o_used | BOOLEAN | NULL | Optional filter for Vision-processed pages. |

**Returns**: JSONB `{ data: [...], pagination: { total, page, limit, totalPages } }`

**Business rules**:
- F-S2-22 patch (applied at Agent 5/6): JOIN path is `ingestion_review_queue → contract_version → contract.title_en / title_ar`. JSONB keys: `contractTitleEn` + `contractTitleAr` (not `contractTitle` — `contract_version` has no `title` column; S2-22b).
- S2-24 pattern: `jsonb_agg` over inner subquery, not nested aggregate inside jsonb_build_object.
- `reviewedByName` uses `concat_ws(' ', NULLIF(u.first_name,''), NULLIF(u.last_name,''))` — NULL-safe for partially populated names (W3 lesson from R-PA7).

---

### fn_ingestion_review_resolve(BIGINT, TEXT, TEXT, BIGINT) — migration 137

**Type**: Write (SECURITY INVOKER)
**Purpose**: Reviewer-driven resolution of a low-confidence ingestion page. Actions: confirm / correct / reject.
**Called via**: `SELECT fn_ingestion_review_resolve(p_queue_id, p_action, p_corrected_text, p_actor_id)`

**Parameters**:

| Parameter | Type | Required | Description |
|---|---|---|---|
| p_queue_id | BIGINT | Yes | ingestion_review_queue.id. |
| p_action | TEXT | Yes | `confirm`, `correct`, or `reject`. |
| p_corrected_text | TEXT | Conditional | Required when p_action = 'correct'. |
| p_actor_id | BIGINT | Yes | app.current_user_id (passed by controller). |

**Returns**: JSONB `{ queueId, reviewStatus, finalText, reviewedAt }`

**Business rules**:
- `confirm`: final_text = COALESCE(gpt4o_text, tesseract_text); review_status = 'resolved'.
- `correct`: final_text = p_corrected_text; review_status = 'resolved'.
- `reject`: final_text = NULL; review_status = 'rejected'.
- Already-resolved rows raise ERRCODE 22023 with "reviewStatus:" prefix — BE translatePgError maps to HTTP 409.
- RLS-invisible rows (wrong tenant) return P0002, which the BE maps to 404 (tenant isolation maintained without leaking existence).

---

### fn_audit_trigger() — extended by migration 133

**Type**: Trigger function (SECURITY DEFINER)
**Purpose**: Generic audit trigger extended from 32 → 37 redact entries. F-S2-9 patch adds 5 CR-D0 sensitive fields.
**Extended by**: Migration 133 (CR-D0) — body byte-for-byte identical to CR-C 128 except the redact ARRAY literal and COMMENT version bump.

**CR-D0 redact additions (32 → 37)**:

| Field | Source | Sensitivity |
|---|---|---|
| `tesseract_text` | ingestion_review_queue | Confidential contract content |
| `gpt4o_text` | ingestion_review_queue | Confidential contract content |
| `final_text` | ingestion_review_queue | Reviewer-confirmed contract content |
| `ingestion_error` | contract_version | May contain partial text or stack traces |
| `extracted_text_uri` | contract_version | Supabase Storage path (F-S2-9 patch — 5th entry, not 4th) |

Preserves: CR-C 128 `PERFORM fn_audit_log_record_v2` hash-chain routing; M7 102 `v_user_id=0 → NULL` coercion (S2-20 system actor sentinel).

---

## Views

No new views introduced in M11 (CR-D0). The document ingestion pipeline operates entirely on tables and functions.

---

## Triggers

### audit_ingestion_review_queue_changes

**Table**: ingestion_review_queue
**Events**: AFTER INSERT OR UPDATE OR DELETE (FOR EACH ROW)
**Function**: fn_audit_trigger()
**Created by**: Migration 134

**Purpose**: Audit trail for all ingestion_review_queue mutations. Captures old_values and new_values as JSONB in audit_log via fn_audit_log_record_v2 (hash-chain routing from CR-C 128). Compatible with BIGSERIAL primary key (A16 / N11).

**Sensitive field redaction**: `tesseract_text`, `gpt4o_text`, `final_text`, `ingestion_error`, `extracted_text_uri` are all replaced with `"[REDACTED]"` in both old_values and new_values before writing to audit_log (migration 133 extended the redact list to 37 entries).

---

## RLS Policies

### ingestion_review_queue — Row Level Security

**ENABLE ROW LEVEL SECURITY** and **FORCE ROW LEVEL SECURITY** applied in migration 134.

| Policy name | Type | Command | Condition | Notes |
|---|---|---|---|---|
| ingestion_review_queue_tenant_select | PERMISSIVE | SELECT | `tenant_id = app.current_tenant_id::uuid AND (fn_current_user_has_permission('document.review') OR fn_current_user_has_permission('ingestion_queue.read'))` | Dual-permission OR — reviewers and read-only admins both get visibility. |
| ingestion_review_queue_tenant_modify | PERMISSIVE | ALL (USING + WITH CHECK) | `tenant_id = app.current_tenant_id::uuid AND fn_current_user_has_permission('document.review')` | Write path requires document.review (stricter than read). |
| ingestion_review_queue_deny_direct_delete | RESTRICTIVE | DELETE | `FALSE` | CR-C audit-immutability invariant — hard DELETE blocked even for neondb_owner via RLS path; soft-delete via is_active = FALSE only. |

---

## Permissions Introduced (migration 136)

| Code | Module | Action | Roles granted | Description |
|---|---|---|---|---|
| `document.ingest` | document | ingest | Super Admin (break-glass only) | System-only — invoke ingestion fn_'s. Normal flow uses DEFINER + system-bootstrap context; no role grant to drafter/worker roles (OPEN-DECISION-L Path A). |
| `document.review` | document | review | legal_counsel, platform_admin, Super Admin | Review low-confidence ingestion pages (confirm/correct/reject via fn_ingestion_review_resolve). |
| `ingestion_queue.read` | ingestion_queue | read | platform_admin, Super Admin | Read-only access to admin ingestion-queue monitor (`/app/admin/ingestion-queue`). |

---

## system_setting Widening (migrations 135 + 136)

Migration 135 widens the `system_setting.category` CHECK constraint from 7 → 8 values by adding `'ai'` as the eighth allowed category (OPEN-DECISION-K / N20). The seven pre-existing categories from CR-C migration 126 are preserved verbatim.

Migration 136 seeds 2 new `system_setting` rows with `category = 'ai'`:

| Key | Default value | Description |
|---|---|---|
| `ocr.confidence_threshold` | 0.75 | Tesseract confidence below which a page routes to gpt-4o Vision. Tunable via /admin/config without redeploy. Q1 autonomous-mode lock. |
| `ai.daily_vision_cap_pages` | 500 | Per-tenant daily gpt-4o Vision page cap. At 80% admin notification queued; at 100% low-confidence pages route to `pending_human` without invoking Vision. Q2 autonomous-mode lock. |

---

## ai_request_log Scalar Mapping Note (migration 136)

Migration 136 seeds 1 `ai_prompt` row (`ai-document-ingestion-vision`) as FK prerequisite for ai_request_log writes. The document-ingestion service maps Vision calls to the existing scalar columns on ai_request_log (no `metadata` JSONB column exists on ai_request_log in the current schema):

| ai_request_log column | Value |
|---|---|
| entity_type | `'contract_version'` |
| entity_id | contract_version.id |
| mode | `'vision_extract'` |
| prompt_id | `'ai-document-ingestion-vision'` |
| provider | `'openai'` |
| model_used | `'gpt-4o'` |
| latency_ms | wall-clock extraction time for the page |
| cost_usd_estimate | estimated cost per Vision call |
| status | `'success'` or `'error'` |

`prompt_hash` and `page_no` metadata are deferred to a CR-D follow-up that would add a `metadata JSONB` column to ai_request_log (OPEN-DECISION N16/N17 — out of scope for CR-D0).

---

*Generated: 2026-05-12 | Agent 15 — Documentation Generator | Source: migrations 132..140, M11.json decisions, after-state.md*
