# M13 — Correlation Rule Engine + DSL — Database Data Dictionary

Generated: 2026-05-12T17:00:00Z
Module owner: M13 (CR-E)
Migration range: 150–156, 157 (cross-cutting), 158 (channel verification)

---

## Tables

### correlation_rule

**Purpose**: Tenant-scoped correlation rule registry. Each row stores one rule's match and produce YAML blocks (per Annex C grammar), a SHA-256 version_hash for audit traceability, and metadata for the admin UI. PG NOTIFY 'correlation_rule_changed' fires on every UPDATE to invalidate the in-memory rule cache.
**Owned by**: M13
**Used by**: correlation (produces rows referencing rule_id), correlation_rule_fixture, BE rule evaluator service, FE /app/admin/rules

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Tenant FK |
| rule_id | TEXT | NOT NULL, UNIQUE with tenant_id | Stable rule identifier e.g. rule.sanctions.direct_counterparty. Referenced by correlation rows for portability |
| name | TEXT | NOT NULL | Human-readable EN rule name |
| name_ar | TEXT | nullable | AR rule name |
| scenario | TEXT | nullable | Scenario tag for grouping (e.g. hormuz / sanctions / brent / epc_sla / renewal) |
| enabled | BOOLEAN | NOT NULL, DEFAULT TRUE | Per-tenant enable/disable (HITL Q4 — tenant-scoped; disabling affects only the owning tenant) |
| meta | JSONB | NOT NULL, DEFAULT '{}' | Free-form metadata: owner, rationale, evaluation_timeout_seconds override per HITL Q1 |
| match_yaml | TEXT | NOT NULL | YAML match block per Annex C grammar. BE parser validates before persist |
| produce_yaml | TEXT | NOT NULL | YAML produce block per Annex C.5 grammar |
| version_hash | TEXT | NOT NULL | SHA-256 of canonical YAML serialization (sorted-key). Recomputed by fn_rule_create + fn_rule_update. Captured in correlation rows at fire time for retroactive audit |
| last_reviewed_by | BIGINT | FK user(id) ON DELETE SET NULL | Last user to mark this rule as reviewed |
| last_reviewed_at | TIMESTAMPTZ | nullable | When last reviewed |
| data_classification | TEXT | NOT NULL, DEFAULT 'demo', CHECK (demo/pilot/production) | CR-C/M10 rollout marker |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation timestamp (UTC) |
| created_by | BIGINT | FK user(id) | User who created this rule |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update timestamp (UTC) |
| updated_by | BIGINT | FK user(id) | User who last updated this rule |
| is_active | BOOLEAN | NOT NULL, DEFAULT TRUE | Soft delete flag |

**Unique constraints**:
| Constraint | Columns | Notes |
|---|---|---|
| uq_correlation_rule_tenant_rule_id | (tenant_id, rule_id) | One rule_id per tenant |

**Indexes**:
| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_correlation_rule_tenant_active | (tenant_id) WHERE is_active=TRUE AND enabled=TRUE | BTREE | Rule evaluator — load enabled rules per tenant |
| idx_correlation_rule_scenario | (tenant_id, scenario) WHERE is_active=TRUE | BTREE | FE admin rules list filtered by scenario |
| idx_correlation_rule_tenant_rule_id | (tenant_id, rule_id) | BTREE | FK-style lookup by logical rule_id from correlation rows |
| idx_correlation_rule_version_hash | (version_hash) | BTREE | Supports retroactive audit queries linking correlation snapshots to rule versions |

**Foreign keys**:
| Column | References | On Delete |
|---|---|---|
| tenant_id | tenant(id) | RESTRICT |
| last_reviewed_by | user(id) | SET NULL |
| created_by | user(id) | (default) |
| updated_by | user(id) | (default) |

**Added in**: Migration 150 (`150_cre_create_correlation_rule.sql`)
**Seed data**: 7 rule rows in migration 155 (`155_cre_seed_rules_and_fixtures.sql`) — Hormuz CP, Hormuz Supply, Sanctions Direct, Sanctions Chain, Brent, EPC SLA, Renewal

---

### correlation

**Purpose**: Output of rule firing. One row per (signal, contract, rule) triple. Carries a rule_version_hash snapshot for retroactive audit — the correlation references the rule version that fired even after the rule is subsequently edited.
**Owned by**: M13
**Used by**: FE /app/correlations list, FE contract detail Risk Insights tab, dismissal workflow

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Tenant FK |
| signal_id | BIGINT | NOT NULL, FK osint_signal(id) ON DELETE RESTRICT | Triggering signal. RESTRICT — preserves correlation rows even if signal is soft-deleted |
| contract_id | BIGINT | NOT NULL, FK contract(id) ON DELETE RESTRICT | Matched contract |
| rule_id | TEXT | NOT NULL | Logical rule identifier (not FK to correlation_rule.id — rule_id string is portable across exports) |
| rule_version_hash | TEXT | NOT NULL | SHA-256 snapshot of rule YAML at fire time — supports retroactive diff against current rule body |
| confidence | NUMERIC(3,2) | NOT NULL, CHECK (0..1) | Rule confidence from produce block confidenceBase |
| match_reason | TEXT | NOT NULL | Rendered from match_reason_template per Annex C.5.1 |
| match_evidence | JSONB | NOT NULL, DEFAULT '{}' | Structured evidence supporting the match. SENSITIVE — redacted from fn_audit_trigger |
| match_geographies | JSONB | NOT NULL, DEFAULT '[]' | ISO country codes or geography labels matched |
| match_entities | JSONB | NOT NULL, DEFAULT '[]' | Named entities matched (id, name, kind). SENSITIVE — redacted |
| status | TEXT | NOT NULL, DEFAULT 'active', CHECK (active/dismissed/expired) | Correlation lifecycle status |
| dismissed_by | BIGINT | FK user(id) ON DELETE SET NULL | Actor who dismissed this correlation |
| dismissed_at | TIMESTAMPTZ | nullable | Dismissal timestamp |
| dismissed_reason | TEXT | nullable | Mandatory business justification (min 10 chars enforced at BE layer) |
| expires_at | TIMESTAMPTZ | nullable | Default: creation + 30 days. Configurable per rule in produce.correlation.expires_at |
| data_classification | TEXT | NOT NULL, DEFAULT 'demo', CHECK (demo/pilot/production) | CR-C rollout marker |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation timestamp (UTC) |
| created_by | BIGINT | FK user(id) | System actor who fired the rule (NULL = system) |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update timestamp (UTC) |
| updated_by | BIGINT | FK user(id) | User who last updated (e.g. dismissal actor) |
| is_active | BOOLEAN | NOT NULL, DEFAULT TRUE | Soft delete flag |

**Unique constraints**:
| Constraint | Columns | Notes |
|---|---|---|
| uq_correlation_signal_contract_rule | (tenant_id, signal_id, contract_id, rule_id) | Accept-both-correlations per HITL Q2 — two different rules can produce 2 rows for the same (signal, contract) pair; but one rule fires at most once per triple |

**Indexes**:
| Index name | Columns | Type | Purpose |
|---|---|---|---|
| idx_correlation_tenant_status | (tenant_id, status) WHERE is_active=TRUE | BTREE | FE correlations list by status filter |
| idx_correlation_contract_id | (contract_id) WHERE is_active=TRUE | BTREE | Contract detail Risk Insights tab load |
| idx_correlation_signal_id | (signal_id) | BTREE | FK index — RESTRICT on osint_signal delete |
| idx_correlation_rule_id | (tenant_id, rule_id) WHERE is_active=TRUE | BTREE | Filter by rule in correlations list |
| idx_correlation_created_at | (tenant_id, created_at DESC) WHERE is_active=TRUE | BTREE | Default chronological sort in list view |
| idx_correlation_expires_at | (expires_at) WHERE status='active' AND is_active=TRUE | BTREE | Expiry sweep (future cron driver) |

**Foreign keys**:
| Column | References | On Delete |
|---|---|---|
| tenant_id | tenant(id) | RESTRICT |
| signal_id | osint_signal(id) | RESTRICT |
| contract_id | contract(id) | RESTRICT |
| dismissed_by | user(id) | SET NULL |
| created_by | user(id) | (default) |
| updated_by | user(id) | (default) |

**Added in**: Migration 151 (`151_cre_create_correlation.sql`)

---

### correlation_rule_fixture

**Purpose**: Test fixtures attached to rules. Used by the admin test-against-fixture panel and CI integration tests. Defines given_signal + given_contract_seed_set + expected_match for automated rule verification.
**Owned by**: M13
**Used by**: fn_rule_test_against_fixture, FE /app/admin/rules/:id test panel, CI rule regression tests

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Tenant FK |
| correlation_rule_id | BIGINT | NOT NULL, FK correlation_rule(id) ON DELETE CASCADE | Parent rule — cascades on rule hard-delete |
| fixture_id | TEXT | NOT NULL, UNIQUE with correlation_rule_id | e.g. case_01_match, case_02_no_match per Annex C.9 |
| description | TEXT | nullable | Human-readable fixture description |
| given_signal | JSONB | NOT NULL | Signal shape to evaluate against. Simulates an osint_signal row |
| given_contract_seed_set | TEXT | nullable | Named contract seed set (e.g. 'sanctions_demo_contracts') for integration tests |
| expected_match | BOOLEAN | NOT NULL | Whether this fixture expects a positive correlation |
| expected_correlation | JSONB | nullable | Expected shape of correlation output for assertion purposes |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation timestamp (UTC) |
| created_by | BIGINT | FK user(id) | User who added this fixture |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last update timestamp (UTC) |
| updated_by | BIGINT | FK user(id) | User who last updated |
| is_active | BOOLEAN | NOT NULL, DEFAULT TRUE | Soft delete flag |

**Unique constraints**:
| Constraint | Columns | Notes |
|---|---|---|
| uq_correlation_rule_fixture_rule_fixture_id | (correlation_rule_id, fixture_id) | One fixture_id per rule |

**Added in**: Migration 152 (`152_cre_create_correlation_rule_fixture_and_eval_error.sql`)
**Seed data**: 14 fixture rows in migration 155 — positive + negative fixture per each of 7 seed rules

---

### correlation_evaluation_error

**Purpose**: Evaluation timeout / error marker rows (OD-2 resolution). Stores per-rule-per-signal-evaluation timeouts and other evaluator-level errors. Keeps diagnostic information separate from the correlation table — avoids JSONB diagnostic column bloat on correlation rows.
**Owned by**: M13
**Used by**: Admin observability (future), BE rule evaluator error handling

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| tenant_id | UUID | NOT NULL, FK tenant(id) ON DELETE RESTRICT | Tenant FK |
| signal_id | BIGINT | NOT NULL | Signal being evaluated when error occurred |
| rule_id | TEXT | NOT NULL | Rule that timed out or errored |
| error_type | TEXT | NOT NULL | 'evaluation_timeout' or other evaluator error class |
| error_detail | TEXT | nullable | Diagnostic message (non-sensitive — rule engine errors only, not contract content) |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | When error was recorded |
| is_active | BOOLEAN | NOT NULL, DEFAULT TRUE | Soft delete flag |

**Added in**: Migration 152

---

## Functions

All 9 M13 functions are in migration 153 (`153_cre_rule_functions.sql`). All carry explicit ERRCODE on every RAISE, WHEN OTHERS preserves SQLSTATE, COMMENT ON FUNCTION, and REVOKE FROM PUBLIC + GRANT TO neondb_owner.

---

### fn_rule_create

**Type**: Write
**Purpose**: Inserts a new correlation_rule row. Computes version_hash from canonical YAML serialization. Emits PG NOTIFY 'correlation_rule_changed' for in-memory cache invalidation.
**Called via**: `SELECT fn_rule_create(p_rule_id, p_name, p_name_ar, p_scenario, p_enabled, p_meta, p_match_yaml, p_produce_yaml)`
**Security**: INVOKER

**Parameters**:
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_rule_id | TEXT | Yes | — | Unique rule identifier per tenant |
| p_name | TEXT | Yes | — | EN rule name |
| p_name_ar | TEXT | No | null | AR rule name |
| p_scenario | TEXT | No | null | Scenario tag |
| p_enabled | BOOLEAN | No | true | Initial enabled state |
| p_meta | JSONB | No | '{}' | Owner, rationale, timeout override |
| p_match_yaml | TEXT | Yes | — | Validated YAML match block (validated by BE parser before call) |
| p_produce_yaml | TEXT | Yes | — | Validated YAML produce block |

**Returns**: JSONB `{ "ruleId": integer, "versionHash": "string" }`

**Permission gate**: rule.manage (platform_admin)
**Business rules**:
- Rejects duplicate rule_id per tenant (23505 -> 409)
- version_hash = encode(digest(canonical_serialize(match_yaml + produce_yaml + meta_keys), 'sha256'), 'hex')
- Emits pg_notify('correlation_rule_changed', payload) for in-memory cache invalidation (HITL Q3 hot-reload)

**Error conditions**:
- `23505 duplicate rule_id` — 409
- `42501 permission_denied` — 403

---

### fn_rule_update

**Type**: Write
**Purpose**: Updates an existing correlation_rule row. Recomputes version_hash if match_yaml or produce_yaml changed. Emits PG NOTIFY 'correlation_rule_changed'.
**Called via**: `SELECT fn_rule_update(p_id, p_name, p_name_ar, p_scenario, p_enabled, p_meta, p_match_yaml, p_produce_yaml, p_actor_id)`
**Security**: INVOKER

**Returns**: JSONB with full updated rule row shape

**Permission gate**: rule.manage (platform_admin)
**Business rules**:
- Only supplied fields are updated (partial patch via COALESCE)
- version_hash recomputed only when match_yaml or produce_yaml changes
- PG NOTIFY emitted only on YAML changes (cache invalidation not needed for name/scenario updates)

**Error conditions**:
- `P0002 rule not found` — 404
- `42501 permission_denied` — 403

---

### fn_rule_delete

**Type**: Write
**Purpose**: Soft-deletes a correlation_rule row (sets is_active = false). Does not remove fixture rows — they are retained for audit.
**Called via**: `SELECT fn_rule_delete(p_id, p_actor_id)`
**Security**: INVOKER

**Returns**: JSONB `{ "id": integer, "isActive": false }`

**Permission gate**: rule.manage (platform_admin)
**Business rules**:
- Soft-delete only — is_active = false. No hard DELETE possible (RESTRICTIVE deny-delete policy)
- Double-delete guard: P0001 'already_deleted' -> 409 if already inactive

**Error conditions**:
- `P0002 rule not found` — 404
- `P0001 already_deleted` — 409
- `42501 permission_denied` — 403

---

### fn_rule_list

**Type**: Read
**Purpose**: Paginated list of correlation_rule rows for the tenant with filtering by enabled status, scenario tag, and name search.
**Called via**: `SELECT fn_rule_list(p_page, p_limit, p_enabled, p_scenario, p_search, p_actor_id)`
**Security**: INVOKER STABLE

**Parameters**:
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| p_page | INTEGER | Yes | 1 | Page number |
| p_limit | INTEGER | Yes | 20 | Page size (max 100) |
| p_enabled | BOOLEAN | No | null | Filter by enabled state |
| p_scenario | TEXT | No | null | Filter by scenario tag |
| p_search | TEXT | No | null | Full-text search on name |
| p_actor_id | BIGINT | Yes | — | For permission gate |

**Returns**: JSONB with items array (list fields: id, ruleId, name, nameAr, scenario, enabled, lastReviewedAt, versionHashShort, versionHash, updatedAt) + pagination object

**Permission gate**: rule.read (platform_admin, legal_counsel)

---

### fn_rule_get_by_id

**Type**: Read
**Purpose**: Returns full rule record including matchYaml, produceYaml, meta, and associated fixture summary rows.
**Called via**: `SELECT fn_rule_get_by_id(p_id, p_actor_id)`
**Security**: INVOKER STABLE

**Returns**: JSONB with full rule shape plus `"fixtures": [{ id, fixtureId, description, expectedMatch }]`

**Permission gate**: rule.read (platform_admin, legal_counsel)
**Error conditions**:
- `P0002 rule not found` — 404
- `42501 permission_denied` — 403

---

### fn_rule_evaluate

**Type**: Write
**Purpose**: Evaluates all enabled rules for a given signal against all contracts visible to the tenant. Produces correlation rows for matching (signal, contract, rule) triples. Enforces per-rule evaluation timeout per HITL Q1.
**Called via**: Internal by BE rule evaluator service (triggered by osint_signal_inserted PG NOTIFY)
**Security**: DEFINER

**Business rules**:
- Loads enabled=TRUE rules for the tenant
- Evaluates each rule's match block predicates against the signal + contract data
- For matching pairs: inserts correlation row with rule_version_hash snapshot
- Evaluates all ~30 Annex C.4 predicates (one-time cost per HITL Q6)
- Timeout per rule: meta.evaluation_timeout_seconds override > system_setting rule.eval_timeout_seconds (default 5s per HITL Q1)
- Timeout events insert a correlation_evaluation_error row (OD-2)
- OD-1: reads clause data only from contract_clause_extracted (not legacy contract_clause LIBRARY)

**Error conditions**:
- Evaluation timeout -> inserts correlation_evaluation_error row, continues to next rule
- `42501 permission_denied` — 403

---

### fn_rule_test_against_fixture

**Type**: Read
**Purpose**: Runs a rule against one or all of its registered fixtures in simulation mode. Does not persist correlations. Returns pass/fail + match evidence for the test-against-fixture panel in the admin UI.
**Called via**: `SELECT fn_rule_test_against_fixture(p_rule_id, p_fixture_id, p_actor_id)`
**Security**: INVOKER STABLE

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_rule_id | BIGINT | Yes | Rule to test (correlation_rule.id) |
| p_fixture_id | TEXT | No | Specific fixture — if null, runs all fixtures |
| p_actor_id | BIGINT | Yes | For permission gate |

**Returns**: JSONB `{ "ruleId": "string", "fixtureId": "string", "expectedMatch": boolean, "actualMatch": boolean, "matchEvidence": {}, "matchReason": "string | null", "diffNotes": ["string"], "passed": boolean, "durationMs": integer }`

**Permission gate**: rule.manage (platform_admin)
**Business rules**:
- Pure simulation — no rows written to correlation table
- Returns pass=true when actualMatch == expectedMatch

**Error conditions**:
- `P0002 rule not found or no fixtures` — 404
- `42501 permission_denied` — 403

---

### fn_correlation_dismiss

**Type**: Write
**Purpose**: Dismisses an active correlation with a mandatory business reason. Sets status='dismissed', records dismissed_by + dismissed_at + dismissed_reason.
**Called via**: `SELECT fn_correlation_dismiss(p_correlation_id, p_reason, p_actor_id)`
**Security**: INVOKER

**Parameters**:
| Parameter | Type | Required | Description |
|---|---|---|---|
| p_correlation_id | BIGINT | Yes | Correlation to dismiss |
| p_reason | TEXT | Yes | Business justification (min 10 chars) |
| p_actor_id | BIGINT | Yes | Actor performing dismissal |

**Returns**: JSONB `{ "correlationId": integer, "newStatus": "dismissed" }`

**Permission gate**: correlation.dismiss (platform_admin, legal_counsel)
**Business rules**:
- Requires status='active' (P0001 'already_dismissed' -> 409 if already dismissed)
- reason minimum 10 characters (22023 -> 400)
- Recorded in audit_log via audit trigger on correlation table

**Error conditions**:
- `P0002 correlation not found` — 404
- `P0001 already_dismissed` — 409
- `22023 reason too short` — 400
- `42501 permission_denied` — 403

---

### fn_correlation_list

**Type**: Read
**Purpose**: Paginated list of correlation rows for the tenant with filtering by contract, status, rule_id, and date range.
**Called via**: `SELECT fn_correlation_list(p_page, p_limit, p_contract_id, p_status, p_rule_id, p_from_date, p_to_date, p_actor_id)`
**Security**: INVOKER STABLE

**Returns**: JSONB with items array (full Correlation interface fields including contractTitleEn/Ar, ruleName, ruleScenario) + pagination object

**Permission gate**: correlation.read (platform_admin, legal_counsel)
**Business rules**:
- RLS-narrowed to current tenant
- Only contracts visible to the actor via v_role_can_see_all or explicit permission are returned
- match_evidence and match_entities are included in response but redacted from audit logs

---

## RLS Policies

### correlation_rule — Row Level Security

FORCE RLS enabled

| Policy name | Command | Condition | Notes |
|---|---|---|---|
| correlation_rule_tenant_select | SELECT | tenant_id = app.current_tenant_id::uuid | Tenant isolation |
| correlation_rule_tenant_modify | ALL | tenant_id = app.current_tenant_id::uuid | Write isolation |
| correlation_rule_deny_direct_delete | DELETE | FALSE (RESTRICTIVE) | Soft-delete only |

### correlation — Row Level Security

FORCE RLS enabled

| Policy name | Command | Condition | Notes |
|---|---|---|---|
| correlation_tenant_select | SELECT | tenant_id = app.current_tenant_id::uuid | Tenant isolation |
| correlation_tenant_modify | ALL | tenant_id = app.current_tenant_id::uuid | Write isolation |
| correlation_deny_direct_delete | DELETE | FALSE (RESTRICTIVE) | Soft-delete only — dismissal via fn_correlation_dismiss |

### correlation_rule_fixture — Row Level Security

FORCE RLS enabled (3 matching policies per M11 pattern)

### correlation_evaluation_error — Row Level Security

FORCE RLS enabled (3 matching policies per M11 pattern)

---

## Triggers

### audit_correlation_rule_changes
**Table**: correlation_rule
**Events**: INSERT, UPDATE, DELETE
**Purpose**: Standard audit trail via fn_audit_trigger()
**Sensitive field redaction**: match_yaml, produce_yaml (added to v_redact_fields in migration 157) — may contain counterparty names and source IDs

### audit_correlation_changes
**Table**: correlation
**Events**: INSERT, UPDATE, DELETE
**Purpose**: Standard audit trail
**Sensitive field redaction**: match_evidence, match_entities (added in migration 157, extends v_redact_fields 37 → 41 names)

### audit_correlation_rule_fixture_changes
**Table**: correlation_rule_fixture
**Added in**: Migration 152

### audit_correlation_evaluation_error_changes
**Table**: correlation_evaluation_error
**Added in**: Migration 152

---

## Permissions and Grants

Migration 154 (`154_cre_permissions_grants_seed.sql`)

| Permission | Granted to | Notes |
|---|---|---|
| rule.read | platform_admin, legal_counsel | List and view rules |
| rule.manage | platform_admin | Create, update, delete rules + test against fixture |
| correlation.read | platform_admin, legal_counsel | View active/dismissed/expired correlations |
| correlation.dismiss | platform_admin, legal_counsel | Dismiss active correlations with mandatory reason |

**Total grants**: ~13 role_permission rows

---

## System Settings

Migration 156 (`156_cre_system_setting_seed.sql`)

| Key | Value | Category | Description |
|---|---|---|---|
| rule.eval_timeout_seconds | 5 | ai | HITL Q1 lock — default per-rule evaluation timeout; overridable per-rule via meta.evaluation_timeout_seconds |
| rule.hot_reload_lag_target_seconds | 5 | ai | HITL Q3 lock — target latency from rule save to next evaluation using new version |

---

## Seed Rules

Migration 155 (`155_cre_seed_rules_and_fixtures.sql`) — 7 rules + 14 fixtures

| Rule ID | Scenario | Description |
|---|---|---|
| rule.hormuz.charter_party_disruption | hormuz | Matches charter party contracts when Hormuz disruption signal fires |
| rule.hormuz.supply_chain | hormuz | Matches supply chain contracts in Hormuz disruption scenarios |
| rule.sanctions.direct_counterparty | sanctions | Direct counterparty SDN hit — highest confidence (0.95) |
| rule.sanctions.indirect_chain | sanctions | Counterparty graph descendants match via recursive CTE (M9 party_relationship) |
| rule.brent.price_review | brent | Brent crude price crossing threshold for price_review clause contracts |
| rule.epc_sla.performance | epc_sla | EPC SLA breach signal against performance clause contracts (promoted from CR-I per v1.2) |
| rule.renewal.contract_expiry | renewal | Upcoming renewal obligation matched against renewal clause records |

---

## Cross-Module Coupling Note

M13 reads M12 data via two patterns: (1) the `has_clause` predicate in rule match blocks queries `contract_clause_extracted.clause_type_v2`; (2) the `clause_parameter` predicate queries `contract_clause_extracted.parameters` JSONB paths using the GIN index. M13 also reads `osint_signal` from M7/CR-A and uses the `party_relationship` recursive CTE from M9/CR-B for the sanctions chain rule predicate. M13 does NOT modify any M12 tables.

See M12 data dictionary for clause_taxonomy and contract_clause_extracted schema details.
