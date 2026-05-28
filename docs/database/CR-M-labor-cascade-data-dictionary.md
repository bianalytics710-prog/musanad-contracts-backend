# Data Dictionary — CR-M / Labor-Law Cascade + ADNOC-World Foundation

**Module:** CR-M (change-request extending M5 regulatory / M7 OSINT / M16 advisory)
**Author:** Agent 15 (Documentation Generator) — CR changelog mode (additive only)
**Date:** 2026-05-28
**Migration range applied:** 281..295 (15 migrations)
**DB head:** 295 (dev: `br-snowy-brook-aje2ehtl`, test: `br-billowing-boat-ajq9m0g6`)
**Baseline before CR-M:** schema_migrations.version = 280
**S2-21 streak:** 19th consecutive clean module (all 8 new fn_'s + fn_audit_trigger)

---

## 1. New Tables (3)

### 1.1 `party_workforce` (migration 282)

Current workforce snapshot per contractor party. One active row per `(tenant_id, party_id)` enforced by partial unique index. Feeds the labor-law cascade headcount-band match and Emiratisation compliance logic. Tenant-scoped (unlike `party`, which is single-tenant).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PRIMARY KEY | Auto-incrementing surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `party_id` | `BIGINT` | NOT NULL, FK → party(id) RESTRICT | Contractor party |
| `headcount` | `INTEGER` | NOT NULL, CHECK ≥ 0 | Total employee headcount |
| `headcount_band` | `TEXT` | NOT NULL, CHECK IN ('<20','20-49','50+') | Statutory band — stored discriminator; cascade matches on this |
| `emiratisation_target` | `INTEGER` | NOT NULL DEFAULT 0, CHECK ≥ 0 | Required Emirati headcount per Federal Decree-Law No.9/2024 |
| `emiratisation_actual` | `INTEGER` | NOT NULL DEFAULT 0, CHECK ≥ 0 | Current Emirati headcount |
| `is_compliant` | `BOOLEAN` | NOT NULL DEFAULT TRUE | Denormalized: `emiratisation_actual >= emiratisation_target`. Maintained by `fn_party_workforce_set`. |
| `category` | `TEXT` | NOT NULL DEFAULT 'operational_support', CHECK IN ('drilling','logistics','epc','operational_support','other') | Contractor service category |
| `source` | `TEXT` | NOT NULL DEFAULT 'demo_seed', CHECK IN ('manual','demo_seed','import') | Data provenance |
| `notes` | `TEXT` | nullable | Free-text notes |
| `data_classification` | `TEXT` | NOT NULL DEFAULT 'demo', CHECK IN ('demo','pilot','production') | Data tier |
| `created_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Record creation |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Last update |
| `created_by` | `BIGINT` | FK → user(id) SET NULL | Actor who created |
| `updated_by` | `BIGINT` | FK → user(id) SET NULL | Actor who last updated |
| `is_active` | `BOOLEAN` | NOT NULL DEFAULT TRUE | Soft-delete flag |

**Indexes:**
| Index | Columns | Type | Purpose |
|---|---|---|---|
| `uq_party_workforce_tenant_party_active` | `(tenant_id, party_id) WHERE is_active` | UNIQUE | One active row per (tenant, party) — upsert key |
| `idx_party_workforce_tenant_id` | `tenant_id` | BTREE | Tenant filter |
| `idx_party_workforce_party_id` | `party_id` | BTREE | Party FK join |
| `idx_party_workforce_created_by` | `created_by` WHERE NOT NULL | BTREE | Audit join |
| `idx_party_workforce_updated_by` | `updated_by` WHERE NOT NULL | BTREE | Audit join |
| `idx_party_workforce_active` | `id` WHERE is_active | BTREE | Active-row filter |
| `idx_party_workforce_band_compliance` | `(tenant_id, headcount_band, is_compliant)` WHERE is_active | BTREE | **Cascade fan-out scan** — primary query path |

**RLS:** ENABLE + FORCE. SELECT gated `party.workforce.read`; modify gated `party.workforce.manage` (fn body); RESTRICTIVE deny-DELETE.

**Audit trigger:** `audit_party_workforce_changes` (fn_audit_trigger — default strategy, `id BIGSERIAL PK`).

---

### 1.2 `regulatory_cascade_run` (migration 283)

Append-only header for one labor-law cascade execution. One row per run of `fn_regulatory_cascade_run`. Mirrors the `risk_score` (169) append-only snapshot pattern.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PRIMARY KEY | Auto-incrementing surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `signal_id` | `BIGINT` | NOT NULL, FK → osint_signal(id) RESTRICT | Driving regulatory signal (decree) |
| `regulation_ref` | `TEXT` | nullable | Denormalized citation snapshot (e.g. `Federal Decree-Law No. 9 of 2024`) |
| `status` | `TEXT` | NOT NULL DEFAULT 'completed', CHECK IN ('running','completed','failed') | Run lifecycle (normally `completed` — fn is atomic) |
| `summary` | `JSONB` | NOT NULL DEFAULT '{}' | `{ byBand: {...}, totals: {...}, generatedAt }` band breakdown |
| `params` | `JSONB` | NOT NULL DEFAULT '{}' | Run params snapshot (clause types, band config) |
| `affected_contractor_count` | `INTEGER` | NOT NULL DEFAULT 0 | Count of non-compliant/affected contractor items |
| `total_penalty_min_aed` | `NUMERIC(18,2)` | NOT NULL DEFAULT 0 | Sum of `penalty_exposure_min_aed` across items |
| `total_penalty_max_aed` | `NUMERIC(18,2)` | NOT NULL DEFAULT 0 | Sum of `penalty_exposure_max_aed` across items |
| `data_classification` | `TEXT` | NOT NULL DEFAULT 'demo', CHECK | Data tier |
| `run_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | When the cascade ran |
| `created_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Record creation |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Last update (status: running→completed) |
| `created_by` | `BIGINT` | FK → user(id) SET NULL | Actor who triggered the run |
| `updated_by` | `BIGINT` | FK → user(id) SET NULL | Last update actor |
| `is_active` | `BOOLEAN` | NOT NULL DEFAULT TRUE | Soft-delete flag |

**Key indexes:** `(tenant_id, run_at DESC) WHERE is_active` — list ordering.

**RLS:** FORCE. SELECT gated `regulatory.cascade.read`; modify tenant-scoped (write gate enforced in fn body — `regulatory.cascade.run`); RESTRICTIVE deny-DELETE.

**Audit trigger:** `audit_regulatory_cascade_run_changes`.

---

### 1.3 `regulatory_cascade_item` (migration 284)

One row per affected contractor per cascade run. Carries per-contractor headcount snapshot, affected employment clause/contract/ICV ids, penalty AED range, and remediation lifecycle. FK into `regulatory_cascade_run` (master). Unique on `(cascade_run_id, party_id)`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | `BIGSERIAL` | PRIMARY KEY | Auto-incrementing surrogate key |
| `tenant_id` | `UUID` | NOT NULL, FK → tenant(id) RESTRICT | Tenant isolation |
| `cascade_run_id` | `BIGINT` | NOT NULL, FK → regulatory_cascade_run(id) CASCADE | Parent run |
| `party_id` | `BIGINT` | NOT NULL, FK → party(id) RESTRICT | Affected contractor |
| `headcount_band` | `TEXT` | NOT NULL, CHECK IN ('<20','20-49','50+') | **As-of snapshot** at run time (denormalized — documented Rule 7 exception) |
| `is_compliant` | `BOOLEAN` | NOT NULL DEFAULT TRUE | As-of snapshot |
| `emiratisation_gap` | `INTEGER` | NOT NULL DEFAULT 0 | `max(target-actual, 0)` at run time |
| `affected_clause_ids` | `JSONB` | NOT NULL DEFAULT '[]' | Array of `contract_clause_extracted.id` (icv_in_country_value / strike_lockout / key_personnel) |
| `affected_contract_ids` | `JSONB` | NOT NULL DEFAULT '[]' | Array of `contract.id` for this party's active ADNOC contracts |
| `icv_attachment_ids` | `JSONB` | NOT NULL DEFAULT '[]' | Array of `contract_attachment.id` where `kind='icv_certificate'` (AD-7 model — no icv_certificate table) |
| `penalty_exposure_min_aed` | `NUMERIC(15,2)` | NOT NULL DEFAULT 0, CHECK ≥ 0 | Minimum penalty exposure (per statutory band range) |
| `penalty_exposure_max_aed` | `NUMERIC(15,2)` | NOT NULL DEFAULT 0, CHECK ≥ 0 | Maximum penalty exposure |
| `penalty_basis` | `JSONB` | NOT NULL DEFAULT '{}' | **SENSITIVE** — `{ band, emiratisationGap, finePerHeadMin/Max, statutoryFloor/Ceiling }`. Redacted by `fn_audit_trigger` (281) and Pino. |
| `remediation_status` | `TEXT` | NOT NULL DEFAULT 'pending', CHECK IN ('pending','in_progress','amended','dismissed','resolved') | Remediation lifecycle |
| `advisory_draft_id` | `BIGINT` | nullable, FK → advisory_draft(id) SET NULL | Set post-hoc by `fn_regulatory_cascade_item_link_draft` after BE generates the draft |
| `remediation_note` | `TEXT` | nullable | **SENSITIVE** — free-text remediation notes. Redacted by `fn_audit_trigger` + Pino. |
| `data_classification` | `TEXT` | NOT NULL DEFAULT 'demo', CHECK | Data tier |
| `created_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Record creation |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Last update |
| `created_by` / `updated_by` | `BIGINT` | FK → user(id) SET NULL | Audit actors |
| `is_active` | `BOOLEAN` | NOT NULL DEFAULT TRUE | Soft-delete flag |

**Table constraints:**
- `reg_cascade_item_penalty_order`: CHECK `penalty_exposure_max_aed >= penalty_exposure_min_aed`
- `reg_cascade_item_uq_run_party`: UNIQUE `(cascade_run_id, party_id)`

**Key indexes:** `(cascade_run_id, remediation_status) WHERE is_active` — detail filter.

**RLS:** FORCE. SELECT gated `regulatory.cascade.read`; modify tenant-scoped (write gate in fn bodies); RESTRICTIVE deny-DELETE.

**Audit trigger:** `audit_regulatory_cascade_item_changes`.

---

## 2. New Functions (8)

### 2.1 `fn_party_workforce_set(p_actor_id BIGINT, p_party_id BIGINT, p_data JSONB)` — WRITE

**Security:** VOLATILE, SECURITY INVOKER. **Gate:** `party.workforce.manage`.
**Purpose:** Upsert the current workforce row for a contractor party (one active row per tenant+party).

**Parameters:**
| Parameter | Type | Description |
|---|---|---|
| `p_actor_id` | BIGINT | Calling user id |
| `p_party_id` | BIGINT | Contractor party id |
| `p_data` | JSONB | `{ headcount, emiratisationTarget, emiratisationActual, category?, notes? }` |

**Behavior:** Validates `p_party_id` exists and is active (P0002 if not); derives `headcount_band` from headcount (`<20`/`20-49`/`50+`); computes `is_compliant = (emiratisation_actual >= emiratisation_target)`; upserts via `WHERE NOT EXISTS` pattern (partial index). Returns via `fn_party_workforce_get`.

**Returns:** JSONB — see `fn_party_workforce_get`.

**Error conditions:** `P0002` party not found; `22023` validation (missing/invalid fields).

---

### 2.2 `fn_party_workforce_get(p_actor_id BIGINT, p_party_id BIGINT)` — READ

**Security:** STABLE, SECURITY INVOKER. **Gate:** `party.workforce.read`.
**Purpose:** Get the active workforce row for a contractor party, joined with party names.

**Returns:** JSONB `{ id, partyId, partyNameEn, partyNameAr, headcount, headcountBand, emiratisationTarget, emiratisationActual, isCompliant, category, source, updatedAt }` or NULL (controller → 404).

---

### 2.3 `fn_party_workforce_list(p_actor_id BIGINT, p_band TEXT, p_compliant BOOLEAN, p_search VARCHAR, p_limit INTEGER, p_offset INTEGER)` — READ

**Security:** STABLE, SECURITY INVOKER. **Gate:** `party.workforce.read`.
**Purpose:** Paginated list of workforce records, filterable by band/compliance/name.

**Parameters:**
| Parameter | Type | Default | Description |
|---|---|---|---|
| `p_band` | TEXT | NULL | Filter by `headcount_band` |
| `p_compliant` | BOOLEAN | NULL | Filter by `is_compliant` |
| `p_search` | VARCHAR | NULL | ILIKE on `party.name_en` |
| `p_limit` | INTEGER | 100 | Page size |
| `p_offset` | INTEGER | 0 | Offset |

**Returns:** JSONB `{ data: [PartyWorkforce...], pagination: { total, limit, offset } }`.

---

### 2.4 `fn_regulatory_cascade_run(p_actor_id BIGINT, p_signal_id BIGINT, p_params JSONB)` — WRITE (workhorse)

**Security:** VOLATILE, **SECURITY DEFINER** (bypasses FORCE RLS to INSERT items across tenant). `SET search_path = public, pg_temp`. **Gate:** manual `fn_current_user_has_permission('regulatory.cascade.run')` check (roles: `compliance_esg`, `platform_admin`, `Super Admin`). Reject `42501` otherwise.

**Purpose:** Fan a regulatory decree signal across ADNOC's contractor population, producing one `regulatory_cascade_item` per non-compliant or clause-matched contractor. Runs as a single transaction — atomically consistent (<5s for ~40 contractors).

**Behavior (CTE-split, S2-24 compliant):**
1. Validate `p_signal_id` exists, `kind='regulatory'` (P0002 / 22023 if not).
2. INSERT `regulatory_cascade_run` (status `running`).
3. Read penalty band config from `system_setting` key `regulatory.labor_cascade.penalty_bands`.
4. Determine employment clause types (config or default `{icv_in_country_value, strike_lockout, key_personnel}`).
5. CTE fan-out: `pw` (workforce) → `party_contracts` → `clauses` (jsonb_agg in own CTE) → `icv` (jsonb_agg in own CTE) → `penalty` (band config × emiratisation_gap, clamped) → INSERT cascade items.
6. UPDATE run header with totals (separate aggregate query, not nested).
7. WHEN OTHERS re-raises `USING ERRCODE = SQLSTATE` (atomic rollback — no partial run).

**Returns:** `fn_regulatory_cascade_get(p_actor_id, v_run_id)` — full run with items.

**NFR:** <5s for ~40 contractors (set-based CTE, single transaction).

---

### 2.5 `fn_regulatory_cascade_list(p_actor_id BIGINT, p_signal_id BIGINT, p_limit INTEGER, p_offset INTEGER)` — READ

**Security:** STABLE, SECURITY INVOKER. **Gate:** `regulatory.cascade.read`.
**Purpose:** Paginated list of cascade runs ordered `run_at DESC`.

**Returns:** JSONB `{ data: [RunListItem...], pagination: { total, limit, offset } }`. Each item: `{ id, signalId, regulationRef, status, runAt, affectedContractorCount, totalPenaltyMinAed, totalPenaltyMaxAed, summary, createdByName }`. `createdByName` via `concat_ws` (null-safe — M16 lesson).

---

### 2.6 `fn_regulatory_cascade_get(p_actor_id BIGINT, p_run_id BIGINT)` — READ

**Security:** STABLE, SECURITY INVOKER. **Gate:** `regulatory.cascade.read`.
**Purpose:** Full run detail — header + items array. N+1 prevented by CTE `jsonb_agg`.

**Returns:** JSONB with run header fields + `items` array. Each item: `{ id, partyId, contractorNameEn, contractorNameAr, emirate, headcountBand, isCompliant, emiratisationGap, affectedClauseCount, affectedClauseIds, affectedContractIds, icvAttachmentIds, icvAttachmentCount, penaltyExposureMinAed, penaltyExposureMaxAed, penaltyBasis, remediationStatus, advisoryDraftId, advisoryDraftStatus }`. Returns NULL if run not found (controller → 404).

**NFR:** <1s.

---

### 2.7 `fn_regulatory_cascade_item_set_status(p_actor_id BIGINT, p_item_id BIGINT, p_status TEXT, p_note TEXT)` — WRITE

**Security:** VOLATILE, SECURITY INVOKER. **Gate:** `regulatory.cascade.read` (any read-capable persona can advance remediation — CR-M-Q6 lock).
**Purpose:** Advance remediation status on a cascade item. `SELECT ... FOR UPDATE` row lock (S2-17).

**Behavior:** Validates `p_status` in enum (22023); row exists (P0002); sets `remediation_status`, `remediation_note`, `updated_by/at`. Returns item JSONB.

---

### 2.8 `fn_regulatory_cascade_item_link_draft(p_actor_id BIGINT, p_item_id BIGINT, p_advisory_draft_id BIGINT)` — WRITE

**Security:** VOLATILE, SECURITY INVOKER. **Gate:** `advisory.draft.review` OR `regulatory.cascade.run`.
**Purpose:** Link an existing advisory draft to a cascade item after the BE service has generated it. Sets `advisory_draft_id`, transitions `remediation_status` to `'amended'` if currently `pending`/`in_progress`.

**Behavior:** Validates item exists (P0002); validates draft exists in tenant (P0002); sets FK + status; `updated_by/at`. Returns item JSONB.

**Note:** The DB layer does NOT call `fn_advisory_draft_generate` (S2-19 — that fn requires a `correlation_id` and LLM-rendered text that only the BE service produces; verified 10-arg signature against migration 216).

---

## 3. Audit Trigger Changes (migration 281)

`fn_audit_trigger()` body extended (redact list 58→60):

| Field added | Reason |
|---|---|
| `penalty_basis` | Internal penalty derivation trace — redact to keep audit_log lean, avoid leaking fine model |
| `remediation_note` | Free-text may contain counterparty-sensitive remediation detail |

---

## 4. Seed Data (migrations 285–292, 295)

| Seed | Migration | Count |
|---|---|---|
| ADNOC Group + 8 subsidiaries (`party`) | 285 | 9 rows |
| ADNOC Offshore → ADNOC Drilling + 8 subsidiary edges (`party_relationship`) | 285 | 9 edges |
| Representative contractors (`party`) | 286 | ~40 rows |
| Workforce attributes (`party_workforce`) | 286 | ~40 rows (8 `<20`-compliant; 18 `20-49` 7c/11nc; 14 `50+` 9c/5nc) |
| Penalty band config (`system_setting`, key `regulatory.labor_cascade.penalty_bands`) | 287 | 1 row |
| `osint_source` `mohre_labor` | 288 | 1 row |
| Federal Decree-Law No.9/2024 `osint_signal` (via `fn_osint_signal_upsert`) | 288 | 1 row |
| `labor_law_amendment_v1` `advisory_template` (EN+AR Mustache, 5 placeholders, `draft_type='custom'`, `assigned_approver_role='legal_counsel'`) | 291 | 1 row |
| 4 new permissions | 292 | 4 rows |
| `procurement_supplier_risk` role (closes DEFECT-CRH-DB-01) | 292 | 1 row |
| `role_permission` grants (CR-M permissions × roles) | 292/293 | 18+backfill |
| Demo contractor contracts (10) + employment clauses (17) + ICV attachments (5) | 295 | 10+17+5 rows |

---

## 5. RLS Summary

All three new tables: ENABLE + FORCE RLS, GUC-scoped on `app.current_tenant_id`, permission-gated SELECT, tenant-scoped modify (write gate enforced in fn bodies), RESTRICTIVE deny-direct-DELETE (soft-delete only). Pattern matches `osint_source` (103) / `correlation` (151) / `advisory_template` (204).

---

*Agent 15 (Documentation Generator) — CR changelog mode, additive data dictionary. Generated 2026-05-28.*
