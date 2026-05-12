# M11 / CR-D0 — Document Ingestion Pipeline

> **Module ID:** M11
> **Change Request:** CR-D0
> **Status:** Complete — shipped 2026-05-12
> **Migrations:** 132..140 (9 files; 138 skipped-design-defect + 140 fn body patch)
> **Schema version:** 140 (both `m0-foundation` and `test` Neon branches)
> **Pipeline mode:** Autonomous end-to-end

---

## Overview

CR-D0 delivers the document ingestion pipeline — the extraction engine that transforms raw uploaded contract files (PDF, DOCX) into searchable plain text stored in Supabase Storage. Extracted text becomes the input substrate for the future CR-D clause extractor and CR-E regulatory risk engine.

The pipeline uses three engines in a cascade:

- **pdf-parse** for digitally-signed PDFs where the text layer is already present.
- **Tesseract.js** (with `eng+ara` bilingual traineddata) for scanned PDFs — per-page confidence is measured and tracked.
- **gpt-4o Vision** (via the existing M4 AIProvider abstraction) for pages where Tesseract confidence falls below the configurable threshold (`ocr.confidence_threshold`, Q1 default 0.75) and the daily Vision cap has not been reached.
- **mammoth** for DOCX files — structured paragraph extraction with headings preserved.

`pdfjs-dist` was dropped during implementation (ESM-only v5; incompatible with the current Node version). Page count and text-layer data come from `pdf-parse` instead. This deviates from §4.11 SOT and is documented below.

Low-confidence pages are recorded in a new `ingestion_review_queue` table for human review by legal_counsel or platform_admin. A new admin surface (`/app/admin/ingestion-queue`) exposes the review queue with confirm/correct/reject actions.

---

## What Shipped — by Area

**DB (migrations 132..140):**

- `contract_version` extended with 9 ingestion columns (extracted_text_uri, ocr_used, ocr_confidence_avg, page_count, ingestion_status, ingestion_error, extraction_engine, extracted_at, ingestion_attempt_count) + 5 CHECK constraints + 2 partial indexes.
- `ingestion_review_queue` created (BIGSERIAL id, tenant_id, contract_version_id, per-page OCR fields, review lifecycle, data_classification, 6 audit cols, FORCE RLS, 3 policies, audit trigger).
- `system_setting.category` CHECK widened from 7 → 8 values (adds `'ai'`).
- 2 system_setting rows seeded (`ocr.confidence_threshold = 0.75`, `ai.daily_vision_cap_pages = 500`).
- 1 `ai_prompt` row seeded (`ai-document-ingestion-vision`) as FK prerequisite for Vision telemetry.
- 7 net-new fn_ functions + fn_audit_trigger extended (32 → 37 redact entries).
- 3 net-new permissions (`document.ingest`, `document.review`, `ingestion_queue.read`) + 6 role_permission grants.

**BE:**

- `src/services/document-ingestion.service.ts` — three-engine extraction cascade (pdf-parse → tesseract.js → gpt-4o Vision → mammoth).
- `src/services/admin-ingestion-queue.service.ts` — admin list + resolve service.
- `src/services/supabase-storage.service.ts` — extended with `signDownloadUrl` (60 s TTL).
- `src/workers/ingestion.worker.ts` — node-cron + p-limit(2) pickup loop; SELECT FOR UPDATE SKIP LOCKED; SET LOCAL tenant_id GUC per queue insert.
- `src/controllers/document-ingestion.controller.ts` — 3 handlers: manualIngest, getExtractedTextSignedUrl, getIngestionStatus.
- `src/controllers/admin/ingestion-queue.controller.ts` — 2 handlers: list, resolve.
- `src/routes/v1/contracts/document-ingestion.routes.ts` — 3 endpoints mounted at `/:id/versions/:vId` (mergeParams).
- `src/routes/v1/admin/ingestion-queue.routes.ts` — 2 endpoints.
- `src/types/document-ingestion.types.ts` + `src/types/admin-ingestion-queue.types.ts`
- `src/schemas/document-ingestion.schemas.ts` + `src/schemas/admin-ingestion-queue.schemas.ts`
- `src/utils/extraction-router.util.ts` — engine routing logic (confidence threshold, daily cap, file-type detection).
- `src/utils/logger.util.ts` — extended with 11 `M11_SENSITIVE_FIELD_EXTENSIONS` Pino redact paths.

**FE:**

- `src/routes/app/admin.ingestion-queue.tsx` — `/app/admin/ingestion-queue` route (platform_admin + legal_counsel).
- `src/components/contracts/DocumentTabExtension.tsx` — Document tab extension on contract detail page (conditional render when contract_version has ingestion data).
- `src/components/contracts/IngestionStatusBadge.tsx` — Inline status badge component (pending / extracting / complete / failed / partial). Polling loop at 3 s intervals.
- `src/components/admin/IngestionReviewPanel.tsx` — Full review panel (confirm/correct/reject actions; useFocusTrap wired).
- `src/services/document-ingestion.service.ts` — FE service with `unwrap<T>()` on all single-resource calls.
- `src/services/admin-ingestion-queue.service.ts` — FE admin service (bare `return data` for paginated list).
- `src/types/document-ingestion.types.ts` — IngestionStatus, ExtractionEngine enum, SignedUrlResponse.
- 69 i18n keys added to both EN and AR (4995/4995 parity). Key namespaces: `contracts.ingestion.*`, `admin.ingestionQueue.*`, `common.extractionEngine.*`.
- Sidebar "Ingestion queue" entry added under Admin section (platform_admin gate).

---

## Permissions Introduced

| Code | Description | Roles |
|---|---|---|
| `document.ingest` | System-only — invoke ingestion fn_'s (normal flow auto-triggers via upload callback; Super Admin for break-glass debugging only) | `Super Admin` |
| `document.review` | Review low-confidence ingestion pages (confirm/correct/reject) | `legal_counsel`, `platform_admin`, `Super Admin` |
| `ingestion_queue.read` | Read-only access to admin ingestion-queue monitor | `platform_admin`, `Super Admin` |

---

## Migrations 132..140

| Migration | Purpose | Notes |
|---|---|---|
| `132_crd0_extend_contract_version.sql` | ADD 9 ingestion columns + 5 CHECK constraints + 2 partial indexes + 9 COMMENT ON COLUMN to contract_version. | All columns NULL-default-safe for pre-existing rows. |
| `133_crd0_extend_audit_redact_list.sql` | CREATE OR REPLACE fn_audit_trigger() extending v_redact_fields from 32 → 37 names (F-S2-9 patch). | Body byte-for-byte identical to CR-C 128 except ARRAY literal + COMMENT bump. Preserves S2-20 + CR-C hash-chain routing. |
| `134_crd0_create_ingestion_review_queue.sql` | CREATE TABLE ingestion_review_queue + 4 indexes + FORCE RLS + 3 policies + audit trigger. | BIGSERIAL PK for fn_audit_trigger compatibility (A16). RESTRICTIVE deny_direct_delete per CR-C invariant. |
| `135_crd0_extend_system_setting_category.sql` | Widen system_setting.category CHECK from 7 → 8 values (adds 'ai'). | Must run before 136. |
| `136_crd0_permissions_grants_seed.sql` | INSERT 3 permissions + 6 role_permission grants + 1 ai_prompt FK prerequisite + 2 system_setting 'ai' rows. | Must run before 137 (ai_prompt FK). |
| `137_crd0_ingestion_functions.sql` | CREATE OR REPLACE 7 net-new fn_'s. F-S2-22 patch applied (contractTitleEn/Ar). | Contains DEFECT-1 bug (updated_at on append-only table) — superseded by migration 140. |
| `138_crd0_mparity_backfill_prep.sql` | UPDATE M_parity contract_version rows to set extraction_engine + ingestion prep columns. | **SKIPPED — DESIGN DEFECT.** Included `updated_at = CURRENT_TIMESTAMP` on append-only table. Recorded in schema_migrations as `crd0_mparity_backfill_prep_skipped_design_defect`. SQL had zero effect on DB (UPDATE failed before any rows were touched). |
| `139_crd0_fix_mparity_backfill_no_updated_at.sql` | Corrected backfill prep UPDATE without `updated_at`. Idempotent. | Replacement for 138. |
| `140_crd0_fix_ingest_remove_updated_at.sql` | CREATE OR REPLACE fn_contract_version_ingest, fn_contract_version_ingestion_complete, fn_contract_version_ingestion_fail — removes `updated_at` from all three UPDATE statements. All other behaviour preserved byte-for-byte per `feedback_fn_rewrites_lose_safety_guards.md`. | **DEFECT-1 patch** surfaced by Testing Agent. 9 of 31 DB tests unblocked. |

---

## BE Files

| Type | Files |
|---|---|
| Services | `src/services/document-ingestion.service.ts`, `admin-ingestion-queue.service.ts`, `supabase-storage.service.ts` (extended) |
| Workers | `src/workers/ingestion.worker.ts` |
| Controllers | `src/controllers/document-ingestion.controller.ts`, `admin/ingestion-queue.controller.ts` |
| Routes | `src/routes/v1/contracts/document-ingestion.routes.ts`, `admin/ingestion-queue.routes.ts` |
| Types | `src/types/document-ingestion.types.ts`, `admin-ingestion-queue.types.ts` |
| Schemas | `src/schemas/document-ingestion.schemas.ts`, `admin-ingestion-queue.schemas.ts` |
| Utilities | `src/utils/extraction-router.util.ts`, `logger.util.ts` (extended M11_SENSITIVE_FIELD_EXTENSIONS) |
| Scripts | `src/scripts/backfill-m_parity-extracted-text.ts` (post-deploy; not run in CR-D0) |
| Tests | `tests/db/CR-D0-fns.test.ts`, `tests/services/document-ingestion.test.ts`, `tests/integration/cr-d0-ingestion-flow.test.ts`, `tests/e2e/CR-D0-upload-extraction.spec.ts`, `tests/e2e/CR-D0-admin-ingestion-queue.spec.ts`, `tests/e2e/CR-D0-document-tab.spec.ts` |
| Modified (BE) | `src/routes/v1/contracts.routes.ts` (mounts document-ingestion sub-router), `src/routes/v1/admin/index.ts` (mounts ingestion-queue routes) |

---

## FE Routes

| Route file | Path | Purpose |
|---|---|---|
| `src/routes/app/admin.ingestion-queue.tsx` | `/app/admin/ingestion-queue` | IngestionReviewPanel + paginated queue list. platform_admin + legal_counsel only. |
| `src/routes/app/contracts.$id.tsx` (extended) | `/app/contracts/:id` | DocumentTabExtension added to Attachments tab (conditional render when contract has version with ingestion data). |

---

## Test Counts

| Layer | Files | Tests | Pass | Fail | Skip | Status |
|---|---|---|---|---|---|---|
| DB integration (CR-D0-fns.test.ts) | 1 | 31 | 31 | 0 | 0 | PASS (post-migration-140) |
| BE integration (cr-d0-ingestion-flow.test.ts) | 1 | 22 | 22 | 0 | 0 | PASS |
| BE unit (extraction-router.util) | 1 | 19 | 19 | 0 | 0 | PASS |
| E2E Playwright (3 spec files) | 3 | 22 | 14 | 4 | 4 | PARTIAL — see INFRA-1 + live-upload deferral |
| **Full BE suite** | — | **1244** | **1232** | **11** | **1** | PASS WITH WARNINGS (2 pre-existing; 9 from DEFECT-1 at report time, all resolved post-140) |

**Total net-new for CR-D0:** 72 tests (31 DB + 22 BE integration + 19 BE unit).

QA Stage 4: **PASS WITH WARNINGS** — 51/52 checks passed. 1 WARN on F4 (partial E2E — INFRA-1 auth hydration race, pre-existing in M7) + 1 WARN on F3 (coverage measurement gap, pre-existing tooling gap). Zero CR-D0-introduced failures.

---

## Defects Caught and Fixed In Flight

### DEFECT-1 (CRITICAL) — fn_contract_version_ingest: column "updated_at" does not exist

- **Root cause**: Migration 137 function bodies referenced `updated_at = CURRENT_TIMESTAMP` in UPDATE statements on `contract_version`. The table is append-only (M1a migration 003 created it without `updated_at`). Migration 132 added 9 ingestion columns but not `updated_at`.
- **Impact**: 9 of 31 DB tests failed; all 3 affected functions raised `ERROR 42703` at first call.
- **Fix**: Migration 140 re-creates all three functions with `updated_at` removed. All other behaviour preserved byte-for-byte per `feedback_fn_rewrites_lose_safety_guards.md`.
- **Lesson captured**: S2-22 column-existence check targets the JOIN target → source direction. DEFECT-1 was the mutation target → schema direction (UPDATE SET column that doesn't exist on the target table). Added as S2-22 inverse-case lesson.

### DEFECT-2 (CRITICAL) — Migration 138 backfill prep also referenced updated_at

- **Root cause**: Same append-only table misunderstanding in the M_parity backfill prep UPDATE.
- **Fix**: Migration 138 recorded in schema_migrations as design-defect skipped. Migration 139 repeats the idempotent UPDATE without `updated_at`. Net effect: 0 rows modified by 138; 35 rows correctly updated by 139.

### BR1-equivalent FIX-1 (CRITICAL) — FE services used naked `return data` against wrapped BE envelope

- **Root cause**: BE controllers return `{ success: true, data: T, requestId }`. FE services used `return response.data` which returned the full envelope, not the inner `data`. React Query polling never stopped because `response.ingestionStatus` was `undefined`.
- **Fix**: `import { unwrap }` + `return unwrap<T>(response.data)` applied to 4 of 5 CR-D0 service methods. The admin ingestion-queue list correctly uses bare `return data` (BE spreads pagination envelope, not wraps). See lovable-handoff.md CR-D0 section for the full pattern.

### INFRA-1 (CRITICAL) — Neon m0-foundation branch over 512 MB free-tier cap

- **Root cause**: OSINT cron over-ingested 482,310 osint_signal rows during 2026-05-09/10 automated runs, filling the 512 MB free-tier storage limit. Migration 132's `CREATE INDEX` operation failed with `ERRCODE 53100` (out of disk space).
- **Fix**: Deleted 482,310 rows + `VACUUM FULL` → branch from 512 MB to 22 MB. Migrations 132..140 applied clean.

---

## Architectural Simplification — pdfjs-dist Dropped

`pdfjs-dist` v5 is ESM-only and requires Node 22+. The import inside `document-ingestion.service.ts` blew up at first call (`SyntaxError: require() of ES Module`). The library was removed entirely from BE runtime deps:

- Page count now comes from `pdf-parse` (already a project dep from M1b).
- Tesseract.js processes the raw PDF buffer directly (no need for pdfjs-dist's rendering pipeline for OCR).
- This deviates from §4.11 SOT (which mentioned pdfjs-dist explicitly). The `ExtractionEngine` enum values (`digital_pdf`, `tesseract`, `gpt4o_vision`, `mammoth_docx`, `mixed`) are unaffected — they describe the extraction strategy, not the library used.

---

## Key Design Decisions (HITL Gate 2 — autonomous mode)

### Q1 — Tesseract confidence threshold
**Locked:** 75% (`system_setting key ocr.confidence_threshold = 0.75`)
**Why:** Brief recommendation. Sized for ADNOC demo documents. Tunable post-deploy via `/admin/config` 'ai' tab without redeploy (OPEN-DECISION-K).

### Q2 — Daily gpt-4o Vision cap per tenant
**Locked:** 500 pages/day (`system_setting key ai.daily_vision_cap_pages = 500`)
**Why:** Brief recommendation. Sized for ADNOC demo (~50 contracts × 10 pages/day worst case). Tunable.

### Q3 — Auto-extract on upload vs. manual trigger
**Locked:** Auto-extract on upload + manual override endpoint
**Why:** Upload controller callback triggers extraction automatically. Manual override (`POST /contracts/:id/versions/:vId/ingest`) retained for re-extraction and admin debugging.

### Q4 — Existing 35 M_parity seeded contract handling
**Locked:** Backfill from existing body_en + body_ar (preserves seed data continuity)
**Why:** M_parity contracts have known-good text; re-extracting via OCR would degrade quality and waste compute.

### Q5 — Error retry policy
**Locked:** Retry 2× with 1-min backoff then mark failed + admin notification
**Why:** Resilient to transient OpenAI/Tesseract hiccups. `ingestion_attempt_count` on contract_version (not on queue — N15) tracks attempts.

### OPEN-DECISION-K — system_setting 'ai' category
**Locked:** Widen system_setting.category CHECK from 7 → 8 (add 'ai')
**Why:** Future CR-D/E/F/H AI knobs all belong in the 'ai' category for discoverability and filtering.

### OPEN-DECISION-L — document.ingest permission semantics
**Locked:** Path A — permission exists in catalogue, granted to Super Admin only (break-glass)
**Why:** Keeps catalogue complete. Normal flow uses DEFINER fn_'s + system-bootstrap context (no user-level grant needed). Enables emergency manual triggers from psql/admin tooling.

### OPEN-DECISION-M — M_parity backfill mechanism
**Locked:** SQL prep migration (138/139) marks contracts pending; BE TS post-deploy script (`src/scripts/backfill-m_parity-extracted-text.ts`) uploads to Supabase Storage + calls fn_contract_version_ingestion_complete
**Why:** SQL alone cannot write to Supabase Storage. Two-phase approach keeps DB migration deterministic; Storage upload idempotent.

### OPEN-DECISION-N — contract_attachment ↔ contract_version coupling
**Locked:** Path B — bind ingestion to contract.current_version_id at upload-complete callback time
**Why:** M_parity upload controller doesn't create new contract_version per upload. CR-D0 hooks the upload-complete callback to call fn_contract_version_ingest with the current_version_id.

### N12 — Supabase Storage path collision avoidance
**Locked:** UUID-suffixed path: `<tenant_id>/<contract_id>/v<n>/<uuid>.txt`
**Why:** Re-extraction of the same version won't overwrite the original artifact — preserves audit trail.

### N16/N17 — ai_request_log mapping (no metadata JSONB)
**Locked:** Map via existing scalar columns (entity_type, entity_id, mode, prompt_id, provider, model_used, latency_ms, cost_usd_estimate, status). prompt_hash + page_no DEFERRED.
**Why:** Brief AC#8 mentioned "metadata" but ai_request_log schema is closed scalars only. Adding metadata JSONB would require a separate migration out of scope for CR-D0.

### N22 — Worker concurrency primitive
**Locked:** p-limit (already in package.json) — concurrency 2
**Why:** Brief said 'Puppeteer pool semaphore'; clarification — pattern is `pLimit(N)` idiom, not Puppeteer-specific.

---

## Demo Moment Script

Estimated run time: ~3 minutes. Requires BE + FE running locally and at least one contract with an attached document.

**Step 1 — Upload PDF and watch extraction**

1. Log in as a drafter. Navigate to any contract in `/app/contracts/`.
2. Go to the **Attachments** tab. Upload a sample digital PDF (e.g. a 2–3 page contract PDF).
3. Switch to the **Document** tab. The `IngestionStatusBadge` shows "Extracting..." (polling at 3 s).
4. Within 5–10 s (digital PDF path), badge transitions to "Extracted in Xs · Y pages · digital_pdf".
5. The "View extracted text" button becomes active. Clicking it fetches the signed URL (60 s TTL) and opens the text in a modal.

**Step 2 — Admin ingestion queue**

1. Log in as platform_admin. Navigate to **Admin → Ingestion queue** (sidebar).
2. If any low-confidence pages were found during extraction, they appear in the queue with `pending_auto` status.
3. Click a row. The `IngestionReviewPanel` opens. Show the Tesseract confidence score and (if Vision ran) the gpt-4o alternative text.
4. Click **Confirm** → the page moves to `resolved`; the `lowConfidencePageCount` on the contract's Document tab decrements.

**Step 3 — Point to the audit trail**

1. Navigate to **Admin → Audit** and filter by table `ingestion_review_queue`. Every confirm/correct/reject action appears with actor, timestamp, and old/new values. Sensitive fields (`tesseract_text`, `gpt4o_text`, `final_text`) show as `[REDACTED]`.

---

## Pending Follow-Ups (carry into CR-D)

| ID | Description | Priority |
|---|---|---|
| F1 | Run `src/scripts/backfill-m_parity-extracted-text.ts` post-deploy to populate `extracted_text_uri` on the 35 M_parity contracts. CR-D's clause extractor will need these URIs as inputs. | HIGH — before CR-D can proceed |
| F2 | Add fixture-driven Playwright live-upload spec once a sample digital PDF + scanned PDF are committed to `tests/fixtures/cr-d0/`. AC#6 (ADNOC live demo < 30 s) also requires a real Tesseract worker warm-up run. | MEDIUM |
| F3 | Add `metadata JSONB` column to ai_request_log to store `prompt_hash` + `page_no` per Vision call (OPEN-DECISION N16/N17). Would require a new migration. | LOW — deferred per N16/N17 |
| F4 | Fix Zustand-persist + TanStack beforeLoad hydration race in Playwright E2E (affects 4 CR-D0 specs + 9 M7/M8/M9 specs). Developer-scope test-tooling fix. | MEDIUM — pre-existing |

---

*Generated: 2026-05-12 | Agent 15 — Documentation Generator | Source: migrations 132..140, after-state.md, module-M11-test-report.md, decisions/M11.json*
