# M12 — Clause Taxonomy + Two-Stage Extractor + pgvector + Auto-Obligations — Database Data Dictionary

Generated: 2026-05-12T17:00:00Z
Module owner: M12 (CR-D)
Migration range: 141–149, 157 (cross-cutting), 159 (backfill)

---

## Tables

### clause_taxonomy

**Purpose**: Closed-vocabulary clause type registry — 50 Annex A clause types in 8 families. Drives Stage 2 LLM classification and parameter extraction discipline. Tenant-scoped from day one (future tenants can add additive taxonomies).
**Owned by**: M12
**Used by**: M13 (rule predicates read clause_type_v2 from contract_clause_extracted which references this taxonomy), FE clause-taxonomy admin viewer, clause extraction worker

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Surrogate key — exists for fn_audit_trigger NEW.id compatibility (CF-6 resolution) |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Tenant FK; populated via app.current_tenant_id GUC at seed time |
| clause_type_id | TEXT | NOT NULL, UNIQUE with tenant_id | Stable snake_case identifier per Annex A.11 (e.g. force_majeure, price_review). Never reused |
| family | TEXT | NOT NULL, CHECK 8 values | One of 8 Annex A families: force_majeure / termination / pricing / performance / indemnity / compliance / governance / operational |
| display_name_en | TEXT | NOT NULL | Human-readable EN name per Annex A.11 |
| display_name_ar | TEXT | NOT NULL | AR translation. Pilot: replace [AR] placeholders via Legal SME per Annex A.13.4 |
| definition_en | TEXT | NOT NULL | Full EN definition |
| definition_ar | TEXT | NOT NULL | AR definition placeholder |
| identification_cues_en | TEXT | NOT NULL | Text patterns the extractor uses to locate this clause type in EN documents |
| identification_cues_ar | TEXT | NOT NULL | Text patterns for AR documents |
| parameter_schema | JSONB | NOT NULL, DEFAULT '{}' | Per-clause-type parameter definitions. Shape: { paramName: { type, required, enum_values? }, ... } |
| version | INTEGER | NOT NULL, DEFAULT 1 | Taxonomy revision counter. Bumps on additive parameter-schema extension per Annex A.13.2 |
| is_deprecated | BOOLEAN | NOT NULL, DEFAULT FALSE | Deprecated types stop being produced by the extractor but historical rows are retained |
| data_classification | TEXT | NOT NULL, DEFAULT 'demo', CHECK (demo/pilot/production) | CR-C/M10 rollout marker |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation timestamp (UTC) |
| created_by | BIGINT | FK user(id) | User who seeded this row |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update timestamp (UTC) |
| updated_by | BIGINT | FK user(id) | User who last updated this row |
| is_active | BOOLEAN | NOT NULL, DEFAULT TRUE | Soft delete flag |

**Unique constraints**:
| Constraint | Columns | Notes |
|---|---|---|
| clause_taxonomy_tenant_type_unique | (tenant_id, clause_type_id) | Business key — one type per tenant |

**Indexes**:
| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_clause_taxonomy_tenant_family | (tenant_id, family) WHERE is_active=TRUE | BTREE | Admin viewer grouped-by-family display |
| idx_clause_taxonomy_active | (id) WHERE is_active=TRUE | BTREE | Standard soft-delete partial index |
| idx_clause_taxonomy_tenant_active_not_deprecated | (tenant_id, clause_type_id) WHERE is_active=TRUE AND is_deprecated=FALSE | BTREE | Stage 2 prompt builder — only non-deprecated types feed the LLM |

**Foreign keys**:
| Column | References | On Delete |
|---|---|---|
| tenant_id | tenant(id) | RESTRICT |
| created_by | user(id) | (SET NULL implied) |
| updated_by | user(id) | (SET NULL implied) |

**Added in**: Migration 142 (`142_crd_create_clause_taxonomy.sql`)
**Seed data**: 50 rows inserted in migration 143 (`143_crd_seed_clause_taxonomy_annex_a.sql`) — ADNOC tenant only, ON CONFLICT DO NOTHING

---

### contract_clause_extracted

**Purpose**: Per-contract LLM-extracted clause records with mandatory text_excerpts (Annex A.1.2 discipline) and pgvector embedding for semantic search. Separate from the M_parity 058 `contract_clause` LIBRARY table — that table holds re-usable template clauses for drafting; this one holds extraction outputs per contract version.
**Owned by**: M12
**Used by**: M13 (rule predicates clause_parameter + has_clause read from this table via OD-1), contract_obligation (derived_from_clause_id FK), FE contract detail Clauses tab, review queue

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Tenant FK. Denormalized from app.current_tenant_id GUC at extraction time |
| contract_id | BIGINT | NOT NULL, FK contract(id) ON DELETE RESTRICT | Parent contract. RESTRICT preserves clause history on soft-delete |
| contract_version_id | BIGINT | NOT NULL, FK contract_version(id) ON DELETE CASCADE | Source document version. CASCADE — if a version is hard-deleted, its clauses are removed |
| clause_type_v2 | TEXT | NOT NULL | Closed-taxonomy identifier per Annex A.11. Logical FK to clause_taxonomy.clause_type_id (no hard FK — cross-tenant taxonomy safe) |
| parameters | JSONB | NOT NULL, DEFAULT '{}' | Per-clause-type extracted parameters per Annex A.3..A.10. SENSITIVE — redacted from fn_audit_trigger |
| text_excerpts | JSONB | NOT NULL, DEFAULT '{}' | Per-parameter verbatim source-text. Every parameter key MUST have a matching text_excerpts key per Annex A.1.2. SENSITIVE — redacted |
| page_no | INTEGER | nullable | Source page number in the document |
| source_offset_start | INTEGER | nullable | Character offset in extracted text where clause begins |
| source_offset_end | INTEGER | nullable | Character offset where clause ends |
| confidence | NUMERIC(5,4) | CHECK (IS NULL OR 0..1) | Stage 2 LLM-reported confidence. Below clause.review_confidence_threshold (0.70) routes to review queue |
| summary_en | TEXT | nullable | LLM-generated EN clause summary. SENSITIVE — redacted |
| summary_ar | TEXT | nullable | LLM-generated AR clause summary. SENSITIVE — redacted |
| review_status | TEXT | NOT NULL, DEFAULT 'auto', CHECK 5 values | auto / pending_review / reviewed / rejected / pending_extraction |
| reviewed_by | BIGINT | FK user(id) ON DELETE SET NULL | Legal counsel who resolved this clause |
| reviewed_at | TIMESTAMPTZ | nullable | When review resolution was recorded |
| extraction_model_version | TEXT | nullable | e.g. gpt-4o-2024-08-06 |
| extraction_prompt_hash | TEXT | nullable | SHA-256 of canonical Stage 2 prompt at extraction time. Audit trail for prompt-drift analysis. SENSITIVE — redacted |
| embedding | VECTOR(1536) | nullable | text-embedding-3-small vector. NULL if embedding step skipped or failed; semantic search treats NULL as no-match |
| data_classification | TEXT | NOT NULL, DEFAULT 'demo', CHECK (demo/pilot/production) | CR-C rollout marker |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation timestamp (UTC) |
| created_by | BIGINT | FK user(id) | User who triggered extraction |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update timestamp (UTC) |
| updated_by | BIGINT | FK user(id) | User who last updated this row |
| is_active | BOOLEAN | NOT NULL, DEFAULT TRUE | Soft delete flag |

**Unique constraints**:
| Constraint | Columns | Notes |
|---|---|---|
| contract_clause_extracted_idempotency_key | (tenant_id, contract_version_id, clause_type_v2, source_offset_start) | Idempotency key for re-extraction via fn_clause_upsert ON CONFLICT DO UPDATE |

**Indexes**:
| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_contract_clause_extracted_embedding_ivfflat | (embedding) USING ivfflat (vector_cosine_ops) WITH (lists=100) | ivfflat | pgvector semantic search. lists tunable via system_setting clause.ivfflat_lists (CF-8) |
| idx_contract_clause_extracted_parameters_gin | (parameters) USING GIN (jsonb_path_ops) WHERE is_active=TRUE | GIN | Drives clause_parameter predicate JSONB path lookups in fn_rule_evaluate (M13/OD-1) |
| idx_contract_clause_extracted_tenant_contract_status | (tenant_id, contract_id, review_status) WHERE is_active=TRUE | BTREE | Drives fn_clause_review_queue_list filters |
| idx_contract_clause_extracted_review_status_pending | (id) WHERE review_status='pending_review' AND is_active=TRUE | BTREE | Partial index on small pending set — review queue list |

**Foreign keys**:
| Column | References | On Delete |
|---|---|---|
| tenant_id | tenant(id) | RESTRICT |
| contract_id | contract(id) | RESTRICT |
| contract_version_id | contract_version(id) | CASCADE |
| reviewed_by | user(id) | SET NULL |
| created_by | user(id) | (default) |
| updated_by | user(id) | (default) |

**Added in**: Migration 144 (`144_crd_create_contract_clause_extracted.sql`)

---

### contract_obligation (modified)

**Purpose**: Extended by M12 — pre-existing M_parity 058 table. CR-D adds derived_from_clause_id column and widens the obligation_type CHECK to include cure and certification obligation types.
**Owned by**: M_parity (base), M12 (extension)
**Used by**: M12 auto-obligation derivation, FE obligation calendar

| Column (new only) | Type | Constraints | Description |
|---|---|---|---|
| derived_from_clause_id | BIGINT | nullable, FK contract_clause_extracted(id) ON DELETE SET NULL | Back-reference to the extracted clause that auto-generated this obligation. NULL for manually-created obligations. Idempotency key for fn_obligations_derive_from_clause |

**obligation_type CHECK widened** (migration 145): adds `cure` (from cure_period clause) and `certification` (from icv_in_country_value clause). Full enum: payment / delivery / reporting / renewal / compliance / notice / other / cure / certification.

**New index added**:
| Index name | Columns | Purpose |
|---|---|---|
| uq_contract_obligation_derived_from_clause_type | (derived_from_clause_id, obligation_type) WHERE derived_from_clause_id IS NOT NULL AND is_active=TRUE | UNIQUE partial — idempotency key for fn_obligations_derive_from_clause. Pre-existing manually-created obligations (NULL back-ref) unaffected |

**Added in**: Migration 145 (`145_crd_extend_contract_obligation.sql`)

---

## Functions

All 7 M12 functions are in migration 146 (`146_crd_clause_functions.sql`). All carry explicit ERRCODE on every RAISE, WHEN OTHERS preserves SQLSTATE, COMMENT ON FUNCTION, and REVOKE FROM PUBLIC + GRANT TO neondb_owner.

---

### fn_clause_taxonomy_list

**Type**: Read
**Purpose**: Returns all 50 non-deprecated clause_taxonomy rows for the current tenant. Used by the admin clause-taxonomy viewer and Stage 2 LLM prompt builder.
**Called via**: `SELECT fn_clause_taxonomy_list(p_actor_id)`
**Security**: INVOKER STABLE

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_actor_id | BIGINT | Yes | Caller user ID — for permission gate |

**Returns**: JSONB
```
{
  "data": [
    {
      "id": integer,
      "clauseTypeId": "force_majeure",
      "family": "force_majeure",
      "displayNameEn": "Force Majeure",
      "displayNameAr": "[AR] Force Majeure",
      "definitionEn": "...",
      "definitionAr": "...",
      "identificationCuesEn": "...",
      "identificationCuesAr": "...",
      "parameterSchema": { "param_name": { "type": "duration_days", "required": false } },
      "version": 1,
      "isDeprecated": false
    }
  ],
  "groupedByFamily": {
    "force_majeure": [...],
    "termination": [...],
    "pricing": [...],
    "performance": [...],
    "indemnity": [...],
    "compliance": [...],
    "governance": [...],
    "operational": [...]
  }
}
```

**Permission gate**: clause.taxonomy.read (all roles)
**Business rules**:
- Filters is_active=TRUE AND is_deprecated=FALSE
- Ordered by family, display_name_en
- Returns both flat data array and groupedByFamily map

**Error conditions**:
- `42501 permission_denied` — actor lacks clause.taxonomy.read

---

### fn_clause_extraction_request

**Type**: Write
**Purpose**: Queues clause extraction for a contract_version. Sets review_status='pending_extraction' on any existing contract_clause_extracted rows for this version. Idempotent — no-op if extraction already in progress.
**Called via**: `SELECT fn_clause_extraction_request(p_contract_version_id, p_actor_id)`
**Security**: DEFINER

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_contract_version_id | BIGINT | Yes | Version to queue for extraction |
| p_actor_id | BIGINT | Yes | Actor (for audit + permission gate) |

**Returns**: JSONB `{ "queued": boolean, "extractionRunId": integer | null }`

**Permission gate**: clause.extract (system-only)
**Business rules**:
- Validates contract_version exists (RAISE P0002 if not)
- Idempotent on (contract_version_id) — re-call while pending is no-op, returns queued=false
- Does NOT create contract_clause_extracted rows directly; the extraction worker calls fn_clause_upsert per-clause

**Error conditions**:
- `P0002 contract_version not found` — 404
- `42501 permission_denied` — 403

---

### fn_clause_upsert

**Type**: Write
**Purpose**: Persists one LLM-extracted clause. Idempotent on the idempotency key (tenant_id, contract_version_id, clause_type_v2, source_offset_start). Auto-triggers fn_obligations_derive_from_clause (wrapped in a SAVEPOINT — obligation failure does not roll back the clause persist) when confidence >= 0.70 AND clause_type_v2 is in the 5 obligation-deriving types.
**Called via**: `SELECT fn_clause_upsert(p_contract_version_id, p_clause_type_v2, p_parameters, p_text_excerpts, ...)`
**Security**: DEFINER

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_contract_version_id | BIGINT | Yes | Source version |
| p_clause_type_v2 | TEXT | Yes | Closed-taxonomy clause type identifier |
| p_parameters | JSONB | Yes | Extracted parameter values |
| p_text_excerpts | JSONB | Yes | Per-parameter verbatim source text (mandatory — every parameter key must appear here) |
| p_page_no | INTEGER | No | Source page number |
| p_source_offset_start | INTEGER | No | Character offset start |
| p_source_offset_end | INTEGER | No | Character offset end |
| p_confidence | NUMERIC | Yes | LLM-reported confidence 0..1 |
| p_model_version | TEXT | Yes | LLM model version string |
| p_prompt_hash | TEXT | Yes | SHA-256 of canonical Stage 2 prompt |
| p_embedding | VECTOR(1536) | No | Embedding vector from text-embedding-3-small |
| p_summary_en | TEXT | No | LLM-generated EN summary |
| p_summary_ar | TEXT | No | LLM-generated AR summary |

**Returns**: JSONB `{ "clauseId": integer, "isNew": boolean, "derivedObligationIds": [integer] }`

**Permission gate**: clause.extract (system-only)
**Business rules**:
- REJECTS if any key in parameters has no corresponding key in text_excerpts (Annex A.1.2 refuse-to-fabricate discipline)
- Confidence < 0.70 sets review_status='pending_review'
- Confidence >= 0.70 sets review_status='auto'
- Validates clause_type_v2 exists in clause_taxonomy for this tenant
- Auto-calls fn_obligations_derive_from_clause for 5 obligation-deriving types: force_majeure / term_and_renewal / cure_period / icv_in_country_value / insurance
- Obligation derivation wrapped in SAVEPOINT — failure rolls back only the obligation rows, not the clause (OD-5)

**Error conditions**:
- `22023 parameter_without_excerpt` — 400 'Parameter <key> has no matching text_excerpt — extraction rejected'
- `P0002 contract_version not found` — 404
- `P0002 unknown clause_type_v2` — 404 'clause_type_v2 <value> not in tenant taxonomy'

---

### fn_clause_review_queue_list

**Type**: Read
**Purpose**: Returns paginated list of extracted clause records with review_status='pending_review'. Joins contract for contractTitleEn/contractTitleAr (S2-22b pattern).
**Called via**: `SELECT fn_clause_review_queue_list(p_page, p_limit, p_contract_id, p_family, p_confidence_band)`
**Security**: INVOKER STABLE

**Parameters**:
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_page | INTEGER | Yes | 1 | Page number |
| p_limit | INTEGER | Yes | 20 | Page size (max 100) |
| p_contract_id | BIGINT | No | null | Filter by specific contract |
| p_family | TEXT | No | null | Filter by Annex A family |
| p_confidence_band | TEXT | No | null | 'low' (<0.50) or 'medium' (0.50-0.70) |

**Returns**: JSONB
```
{
  "data": [
    {
      "clauseId": integer,
      "contractId": integer,
      "contractTitleEn": "string",
      "contractTitleAr": "string",
      "clauseTypeV2": "force_majeure",
      "family": "force_majeure",
      "confidence": 0.65,
      "pageNo": 3,
      "sourceOffsetStart": integer,
      "sourceOffsetEnd": integer,
      "parameters": {},
      "textExcerpts": {},
      "summaryEn": "string | null",
      "summaryAr": "string | null",
      "extractedAt": "ISO8601"
    }
  ],
  "pagination": { "total": integer, "page": integer, "limit": integer, "totalPages": integer }
}
```

**Permission gate**: clause.review (legal_counsel, platform_admin)
**Business rules**:
- RLS-narrowed to current tenant via app.current_tenant_id GUC
- Only returns pending_review rows (low-confidence extraction outputs awaiting legal review)

---

### fn_clause_review_resolve

**Type**: Write
**Purpose**: Resolves a pending_review extracted clause. Accepts confirm / correct / reject actions. correct persists parameter and text-excerpt corrections. Triggers obligation re-derivation idempotently for obligation-deriving clause types on confirm or correct.
**Called via**: `SELECT fn_clause_review_resolve(p_clause_id, p_action, p_parameters_correction, p_text_excerpts_correction)`
**Security**: INVOKER

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_clause_id | BIGINT | Yes | contract_clause_extracted.id to resolve |
| p_action | TEXT | Yes | confirm / correct / reject |
| p_parameters_correction | JSONB | No | Required when action=correct |
| p_text_excerpts_correction | JSONB | No | Required when action=correct |

**Returns**: JSONB `{ "clauseId": integer, "newReviewStatus": "reviewed|rejected", "derivedObligationIds": [integer] }`

**Permission gate**: clause.review (legal_counsel, platform_admin)
**Business rules**:
- action must be one of confirm / correct / reject (22023 invalid_action otherwise)
- correct requires parameters_correction or text_excerpts_correction non-empty
- correct re-validates text_excerpt completeness — rejects if any corrected parameter has no excerpt
- Double-resolve guard: P0001 'already_resolved' prefix -> 409 if clause already reviewed/rejected
- confirm or correct on obligation-deriving clause re-runs fn_obligations_derive_from_clause idempotently

**Error conditions**:
- `22023 invalid_action` — 400
- `22023 correction_text_excerpt_missing` — 400
- `P0001 already_resolved` — 409
- `P0002 clause not found` — 404
- `42501 permission_denied` — 403

---

### fn_clause_semantic_search

**Type**: Read
**Purpose**: pgvector cosine-similarity search over extracted clauses. The BE service computes the query embedding via text-embedding-3-small (logged in ai_request_log) and passes the vector to this function.
**Called via**: `SELECT fn_clause_semantic_search(p_query_embedding, p_contract_id, p_limit, p_similarity_min)`
**Security**: INVOKER STABLE

**Parameters**:
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_query_embedding | VECTOR(1536) | Yes | — | Pre-computed query vector |
| p_contract_id | BIGINT | No | null | Restrict search to one contract |
| p_limit | INTEGER | Yes | 10 | Max results (max 50) |
| p_similarity_min | NUMERIC | No | 0.0 | Minimum cosine similarity threshold |

**Returns**: JSONB
```
{
  "data": [
    {
      "clauseId": integer,
      "contractId": integer,
      "contractTitleEn": "string",
      "contractTitleAr": "string",
      "clauseTypeV2": "force_majeure",
      "family": "force_majeure",
      "similarity": 0.94,
      "summaryEn": "string | null",
      "summaryAr": "string | null",
      "pageNo": integer | null
    }
  ]
}
```

**Permission gate**: clause.search (all contract-readable roles)
**Business rules**:
- Uses idx_contract_clause_extracted_embedding_ivfflat for cosine_ops (lists=100 default)
- RLS narrows results to current tenant
- Returns results ordered by cosine distance ASC (highest similarity first)
- NULL-embedding rows are excluded from results (no-match for missing embeddings)

**Error conditions**:
- `42501 permission_denied` — 403

---

### fn_obligations_derive_from_clause

**Type**: Write
**Purpose**: Reads clause parameters JSONB and creates contract_obligation rows for the 5 obligation-deriving clause types per HITL Q4. Idempotent via unique index on (derived_from_clause_id, obligation_type).
**Called via**: `SELECT fn_obligations_derive_from_clause(p_clause_id)` — called internally by fn_clause_upsert and fn_clause_review_resolve
**Security**: DEFINER

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_clause_id | BIGINT | Yes | contract_clause_extracted.id to derive obligations from |

**Returns**: JSONB `{ "obligationIds": [integer], "obligationsCreated": integer, "obligationsSkippedAsDup": integer }`

**Permission gate**: System-only (called transitively by fn_clause_upsert + fn_clause_review_resolve)
**Business rules**:
- force_majeure: notice_period_days=N -> obligation_type='notice', responsible_party='affected_party'
- term_and_renewal: due_date = expiry_date minus renewal_notice_period_days; obligation_type='renewal'
- cure_period: cure_period_days=N -> obligation_type='cure'
- icv_in_country_value: icv_reporting_period_months=12 -> obligation_type='certification', due_date at anniversary
- insurance: expiry-driven -> obligation_type='notice'
- Idempotency: UPDATE on conflict (derived_from_clause_id, obligation_type, due_date) instead of duplicate INSERT
- Skips any clause_type_v2 not in the 5-type list (no-op, returns empty array)
- Includes updated_at = NOW() in every UPDATE (CF-4: contract_obligation.updated_at exists and must be kept current)

**Error conditions**:
- `P0002 clause not found` — 404
- `22023 missing_required_parameter` — 400 (e.g. force_majeure without notice_period_days)

---

## RLS Policies

### clause_taxonomy — Row Level Security

FORCE RLS enabled (ALTER TABLE clause_taxonomy FORCE ROW LEVEL SECURITY)

| Policy name | Command | Condition | Notes |
|---|---|---|---|
| clause_taxonomy_tenant_select | SELECT | tenant_id = app.current_tenant_id::uuid | Tenant isolation — only own taxonomy rows visible |
| clause_taxonomy_tenant_modify | ALL | tenant_id = app.current_tenant_id::uuid | Same condition on writes |
| clause_taxonomy_deny_direct_delete | DELETE | FALSE (RESTRICTIVE) | Soft-delete only via is_active = FALSE |

### contract_clause_extracted — Row Level Security

FORCE RLS enabled

| Policy name | Command | Condition | Notes |
|---|---|---|---|
| contract_clause_extracted_tenant_select | SELECT | tenant_id = app.current_tenant_id::uuid | Tenant isolation |
| contract_clause_extracted_tenant_modify | ALL | tenant_id = app.current_tenant_id::uuid | All writes scoped to tenant |
| contract_clause_extracted_deny_direct_delete | DELETE | FALSE (RESTRICTIVE) | Soft-delete only via is_active |

**Note**: fn_clause_upsert and fn_clause_extraction_request are SECURITY DEFINER and run as neondb_owner — they bypass RLS to insert/update clause rows. These functions carry explicit permission gates in the function body.

---

## Triggers

### audit_clause_taxonomy_changes
**Table**: clause_taxonomy
**Events**: INSERT, UPDATE, DELETE
**Purpose**: Standard audit trail — captures old_values and new_values as JSONB in audit_log via fn_audit_trigger()
**Added in**: Migration 142

### audit_contract_clause_extracted_changes
**Table**: contract_clause_extracted
**Events**: INSERT, UPDATE, DELETE
**Purpose**: Standard audit trail
**Sensitive field redaction**: parameters, text_excerpts, extraction_prompt_hash, summary_en, summary_ar — these 5 fields are added to fn_audit_trigger's v_redact_fields array in migration 157 (extends M11 migration 133 baseline, 37 → 41 names total)
**Added in**: Migration 144; redaction extension in migration 157

---

## Permissions and Grants

Migration 147 (`147_crd_permissions_grants_seed.sql`)

| Permission | Granted to | Notes |
|---|---|---|
| clause.extract | Super Admin (break-glass only) | Called by ingestion worker on contract.ingested PG NOTIFY; no human role grant |
| clause.review | legal_counsel, platform_admin | Review-queue access + resolve actions |
| clause.taxonomy.read | all roles | Taxonomy is non-sensitive reference content visible to all authenticated users |
| clause.search | all contract-readable roles | Semantic search scoped to clauses the user can already read |

**Total grants**: 18 role_permission rows (clause.taxonomy.read × 9 roles + clause.search × 8 readable roles + clause.review × 2 + clause.extract × 1 Super Admin)

---

## System Settings

Migration 149 (`149_crd_system_setting_seed.sql`)

| Key | Value | Category | Description |
|---|---|---|---|
| clause.review_confidence_threshold | 0.70 | ai | HITL Q1 lock — clauses below 70% confidence route to review queue |
| clause.embedding_model | text-embedding-3-small | ai | HITL Q3 lock — 1536-dim embedding model for pgvector semantic search |
| clause.ivfflat_lists | 100 | ai | CF-8 resolution — ivfflat index lists parameter; tunable post-deploy without schema change |

---

## AI Prompt Seed

Migration 148 (`148_crd_ai_prompt_seed.sql`)

| Prompt ID | Model | Temperature | Max Tokens | Rate Limit |
|---|---|---|---|---|
| clause-extraction-stage-2 | gpt-4o | 0.10 | 8192 | 50/user/hour, 500/user/day |

**Purpose**: FK prerequisite for ai_request_log telemetry per extraction call. Structured-output system+user prompt for Stage 2 clause classification + parameter extraction.

---

## Cross-Module Coupling Note

This module's data is consumed by M13 (CR-E). The rule engine reads `contract_clause_extracted` via the `clause_parameter` and `has_clause` predicates in Annex C DSL. The GIN index on `parameters` (`idx_contract_clause_extracted_parameters_gin`) was sized with this read pattern in mind. See M13 data dictionary for the full rule evaluation flow.
