# M2 — Approval Workflows — Database Data Dictionary

**Generated:** 2026-05-04
**Module owner:** M2
**Predecessor:** M1c (complete; M2 introduces the approval engine + extends contract.status, fn_contract_activity_create, fn_contract_status_update, and fn_audit_trigger redact list).
**Schema migration window:** 023 → 031 (8 migrations: 7 designed + 1 design-error patch + 1 cycle-1 bug-fix patch).

This dictionary documents the database surface introduced by M2: 4 new tables, 16 fn objects (11 new owned + 2 split AE-2 + 3 trigger fn helpers), 25 indexes, 14 RLS policies, 3 immutability triggers, 4 audit triggers, 6 new permissions / 21 grants, and 5 cross-module modifications. For the wire surface see `../api/openapi.yaml`. For the implementation handoff see `../M2-technical-handoff.md`.

---

## 1. ER Diagram Fragment

```
                                                      contract  (M1a)
                                                          |
                            initiated_by                  | contract_id (RESTRICT)
                            ┌─── user (M0)               v
                            |                       approval_chain
                            |       (one in_progress    |
                            |        per contract)     | chain_id (CASCADE)
                            |                          v
                            |                     approval_step  ────────┐
                            |   approver_user_id        |                │ approver_role
                            └─── delegated_to           | step_id        │ → role.name (M0)
                                 reassigned_to          v   (CASCADE)    │
                                                  approval_decision      │
                                                                          │
                                  approval_matrix  (admin-configurable) ─┘
                                  contract_type  step_order  parallel_group
                                  approver_role / escalation_role / hours
```

Cardinality:
- one **contract** has 0..N **approval_chain** rows; only one may be `in_progress` at a time (uq_approval_chain_one_active_per_contract).
- one **approval_chain** has 1..N **approval_step** rows (matrix-driven).
- one **approval_step** has 0..N **approval_decision** rows (append-only audit history).
- **approval_matrix** is independent — referenced by snapshot, not by FK. matrix_snapshot is frozen on chain initiation (M2-NEW-2).

---

## 2. Tables

### 2.1 approval_matrix

**Purpose:** Admin-configurable rules driving fn_approval_route_init. Tuples of (contract_type, value range, step_order, parallel_group, approver_role, is_required, escalation_role, escalation_after_hours).
**Kind:** master / admin-configurable
**Owned by:** M2
**Used by:** fn_approval_route_init (snapshot), fn_approval_route_init_preview (read), fn_approval_matrix_list, fn_approval_matrix_set
**Delete strategy:** soft (is_active=false via fn_approval_matrix_set replace pattern); RESTRICTIVE deny-direct-delete RLS

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Auto-incrementing identifier |
| contract_type | TEXT | NOT NULL, in M1a 8-value enum | M1a contract_type |
| min_value_aed | NUMERIC(18,2) | NOT NULL, >= 0 | Lower bound (inclusive) |
| max_value_aed | NUMERIC(18,2) | NULL = no upper bound | Upper bound (inclusive); >= min_value_aed when set |
| step_order | INTEGER | NOT NULL, >= 1 | Position in the chain |
| parallel_group | INTEGER | NULL or = step_order | Parallel grouping; M2-NEW-4 derives all-of vs any-of from peer is_required pattern |
| approver_role | TEXT | NOT NULL, must exist in role.name | Role assigned to the step |
| is_required | BOOLEAN | NOT NULL, DEFAULT TRUE | Marks all-of vs any-of in parallel groups |
| escalation_role | TEXT | NULL or in role.name | Escalation target role |
| escalation_after_hours | INTEGER | NULL or > 0 | Hours after step creation to trigger escalation |
| created_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | UTC creation timestamp |
| updated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | UTC update timestamp |
| created_by | BIGINT | FK → user.id ON DELETE SET NULL | Admin who created |
| updated_by | BIGINT | FK → user.id ON DELETE SET NULL | Admin who last updated |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Check constraints:** `chk_approval_matrix_value_range`, `chk_approval_matrix_min_value_nonneg`, `chk_approval_matrix_step_order_pos`, `chk_approval_matrix_parallel_eq_step`, `chk_approval_matrix_contract_type` (M1a 8-value enum)

**Indexes (5):**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| pk_approval_matrix | id | PK BTREE | Primary key |
| uq_approval_matrix_active_rule | (contract_type, min_value_aed, COALESCE(max_value_aed, -1), step_order, COALESCE(parallel_group, -1), approver_role) WHERE is_active=TRUE | UNIQUE BTREE | Prevents duplicate active rules |
| idx_approval_matrix_lookup | (contract_type, min_value_aed, max_value_aed, step_order, parallel_group) WHERE is_active=TRUE | BTREE | fn_approval_route_init scan |
| idx_approval_matrix_active | (is_active) | BTREE | Soft-delete partition |
| idx_approval_matrix_audit | (updated_at, updated_by) | BTREE | Audit panel ordering |

**RLS (3 policies):** approval_matrix_select_matrix_read_perm (PERMISSIVE SELECT), approval_matrix_modify_admin (PERMISSIVE ALL), approval_matrix_deny_direct_delete (RESTRICTIVE DELETE).

**Audit trigger:** `audit_approval_matrix_changes` — INSERT/UPDATE/DELETE; redact list extended by M2 to include `matrix_snapshot` (separate column on approval_chain, redacted because it contains a JSONB copy of these rules).

---

### 2.2 approval_chain

**Purpose:** Per-contract chain instance. matrix_snapshot is frozen at chain initiation (M2-NEW-2 — admin matrix edits do not propagate to in-flight chains).
**Kind:** transactional
**Owned by:** M2
**Used by:** fn_approval_route_init, fn_approval_decide, fn_approval_chain_get, fn_approval_chain_list, fn_approval_escalate
**Delete strategy:** ON DELETE RESTRICT FK to contract; status='cancelled' is the cancel path; RESTRICTIVE deny-direct-delete RLS

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Chain id |
| contract_id | BIGINT | NOT NULL, FK → contract.id ON DELETE RESTRICT | Parent contract |
| status | TEXT | NOT NULL, CHECK (in_progress, approved, rejected, resubmission_requested, cancelled) | Chain status |
| current_step_order | INTEGER | NOT NULL, >= 0 | Active step pointer |
| total_steps | INTEGER | NOT NULL, >= 1 | Captured at initiation |
| matrix_snapshot | JSONB | NOT NULL | **Sensitive — redacted in audit_log.** Frozen JSONB copy of matrix rules at init |
| initiated_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | Submission UTC timestamp |
| initiated_by | BIGINT | NOT NULL, FK → user.id | Drafter / admin who submitted |
| completed_at | TIMESTAMPTZ | NULL | Set when status enters terminal state |
| created_at, updated_at | TIMESTAMPTZ | DEFAULT NOW() | Audit columns |
| created_by, updated_by | BIGINT | FK → user.id | Audit columns |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag |

**Check constraints:** `chk_approval_chain_completed_at_status` — completed_at NULL iff status='in_progress'.

**Indexes (6):**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| pk_approval_chain | id | PK BTREE | Primary key |
| uq_approval_chain_one_active_per_contract | contract_id WHERE status='in_progress' AND is_active=TRUE | UNIQUE BTREE | Idempotency backstop for fn_approval_route_init |
| idx_approval_chain_contract | (contract_id, initiated_at DESC) | BTREE | fn_approval_chain_get most-recent lookup |
| idx_approval_chain_status | (status) WHERE is_active=TRUE | BTREE | Admin chain monitor filter |
| idx_approval_chain_initiated_by | (initiated_by, initiated_at DESC) | BTREE | "submitted by me" filter |
| idx_approval_chain_active | (is_active) | BTREE | Soft-delete partition |

**RLS (4 policies):**

| Policy | Op | Type | Condition (summary) |
|---|---|---|---|
| approval_chain_select_via_contract | SELECT | PERMISSIVE | EXISTS row in contract visible to actor |
| approval_chain_insert_drafter_or_admin | INSERT | PERMISSIVE | actor has approval.submit_for_review AND owns contract OR admin |
| approval_chain_update_engine_or_admin | UPDATE | PERMISSIVE | invoker = fn_approval_decide / DEFINER fn OR admin (USING + WITH CHECK byte-identical) |
| approval_chain_deny_direct_delete | DELETE | RESTRICTIVE | always FALSE |

**Audit trigger:** `audit_approval_chain_changes`. matrix_snapshot is redacted (M2 extension).

**Immutability trigger:** `trg_approval_chain_immutable_fields` (BEFORE UPDATE) — blocks any UPDATE that changes `matrix_snapshot`, `contract_id`, or `initiated_by` (M2-NEW-2; replaces the RLS self-ref subquery anti-pattern documented in BE-M1c-C1).

---

### 2.3 approval_step

**Purpose:** One row per approver in a chain. G2 first-class columns: parallel_group, is_required, escalation_role, escalation_after_hours, reassigned_to, delegated_to.
**Kind:** transactional
**Owned by:** M2
**Used by:** fn_approval_my_pending, fn_approval_decide, fn_approval_delegate, fn_approval_reassign, fn_approval_escalate, fn_approval_chain_get/list
**Delete strategy:** ON DELETE CASCADE FK to approval_chain; soft via is_active; RESTRICTIVE deny-direct-delete RLS

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Step id |
| approval_chain_id | BIGINT | NOT NULL, FK → approval_chain.id ON DELETE CASCADE | Parent chain |
| step_order | INTEGER | NOT NULL, >= 1 | Position |
| parallel_group | INTEGER | NULL or = step_order | Parallel grouping |
| approver_role | TEXT | NOT NULL, in role.name | Resolved role |
| approver_user_id | BIGINT | NULL or FK → user.id | Resolved user (NULL = role-only) |
| is_required | BOOLEAN | NOT NULL DEFAULT TRUE | All-of vs any-of marker |
| escalation_role | TEXT | NULL or in role.name | Escalation target role |
| escalation_after_hours | INTEGER | NULL or > 0 | Hours after creation |
| status | TEXT | NOT NULL, CHECK (pending, approved, rejected, skipped, escalated, resubmission_requested, delegated, reassigned) | Step status (delegated/reassigned reserved, unwritten by M2) |
| delegated_to | BIGINT | NULL or FK → user.id | Set by fn_approval_delegate |
| reassigned_to | BIGINT | NULL or FK → user.id | Set by fn_approval_reassign |
| decided_at | TIMESTAMPTZ | NULL or NOT NULL when status terminal | Set on terminal transition |
| created_at, updated_at | TIMESTAMPTZ | DEFAULT NOW() | Audit |
| created_by, updated_by | BIGINT | FK → user.id | Audit |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete |

**Check constraints:** `chk_approval_step_assignment` (approver_user_id OR approver_role required), `chk_approval_step_parallel_eq_step`, `chk_approval_step_decided_at_terminal`.

**Indexes (9):**

| Index | Columns | Type | Purpose |
|---|---|---|---|
| pk_approval_step | id | PK BTREE | Primary key |
| idx_approval_step_chain | (approval_chain_id, step_order, parallel_group NULLS FIRST) | BTREE | Chain rendering |
| idx_approval_step_pending | (status) WHERE status='pending' AND is_active=TRUE | BTREE | fn_approval_my_pending hot path |
| idx_approval_step_approver_user | (approver_user_id) WHERE status='pending' AND is_active=TRUE | BTREE | OR-arm 1 |
| idx_approval_step_approver_role | (approver_role) WHERE approver_user_id IS NULL AND status='pending' AND is_active=TRUE | BTREE | OR-arm 2 |
| idx_approval_step_delegated_to | (delegated_to) WHERE delegated_to IS NOT NULL AND is_active=TRUE | BTREE | OR-arm 3 |
| idx_approval_step_reassigned_to | (reassigned_to) WHERE reassigned_to IS NOT NULL AND is_active=TRUE | BTREE | OR-arm 4 |
| idx_approval_step_escalation_due | (created_at, escalation_after_hours) WHERE status='pending' AND escalation_after_hours IS NOT NULL AND is_active=TRUE | BTREE | Cron candidate scan |
| idx_approval_step_active | (is_active) | BTREE | Soft-delete partition |

**RLS (4 policies):** approval_step_select_via_chain, approval_step_insert_via_route_init, approval_step_update_assigned_or_admin (USING + WITH CHECK byte-identical), approval_step_deny_direct_delete (RESTRICTIVE).

**Audit trigger:** `audit_approval_step_changes`.

**Immutability trigger:** `trg_approval_step_immutable_fields` (BEFORE UPDATE) — blocks UPDATE on `approval_chain_id` or `step_order`.

---

### 2.4 approval_decision

**Purpose:** Per-step decision audit log. Append-only. Supports approve / reject / request_resubmission / delegate / reassign / escalate.
**Kind:** transactional / append-only
**Owned by:** M2
**Used by:** fn_approval_decide / _delegate / _reassign / _escalate (INSERT only); fn_approval_chain_get (read)
**Delete strategy:** append-only — ON DELETE CASCADE FK to approval_step; RESTRICTIVE deny-update + deny-direct-delete RLS
**Special:** no `updated_at` / `updated_by` columns; `decision_note` is sensitive (redacted in audit_log per AE-Sensitive)

| Column | Type | Constraints | Description |
|---|---|---|---|
| id | BIGSERIAL | PRIMARY KEY | Decision id |
| approval_step_id | BIGINT | NOT NULL, FK → approval_step.id ON DELETE CASCADE | Parent step |
| decision | TEXT | NOT NULL, CHECK (approve, reject, request_resubmission, delegate, reassign, escalate) | Decision type |
| decided_by | BIGINT | NULL or FK → user.id ON DELETE SET NULL | Actor; NULL for system events (cron escalation — actor coerced to NULL via fn_contract_activity_create system-event handling) |
| decided_at | TIMESTAMPTZ | NOT NULL DEFAULT NOW() | UTC |
| decision_note | TEXT | NULL except when decision in (reject, request_resubmission) | **Sensitive — redacted in audit_log** |
| delegated_to | BIGINT | NULL except when decision='delegate' | Target user (chk_approval_decision_delegated_population) |
| reassigned_to | BIGINT | NULL except when decision='reassign' | Target user (chk_approval_decision_reassigned_population) |
| metadata | JSONB | NULL | Optional. systemEvent flag set to TRUE for cron escalations (uses chain.initiated_by + metadata.systemEvent=true to avoid synthetic system user) |
| created_at | TIMESTAMPTZ | DEFAULT NOW() | Audit |
| created_by | BIGINT | FK → user.id | Audit |
| is_active | BOOLEAN | NOT NULL DEFAULT TRUE | Soft delete flag (rarely flipped — append-only) |

**Check constraints:** `chk_approval_decision_delegated_population`, `chk_approval_decision_reassigned_population`.

**Indexes (5):** pk_approval_decision, idx_approval_decision_step (approval_step_id, decided_at), idx_approval_decision_decided_by, idx_approval_decision_decision (decision) WHERE is_active, idx_approval_decision_active.

**RLS (4 policies):** approval_decision_select_via_step (PERMISSIVE), approval_decision_insert_via_engine (PERMISSIVE), approval_decision_deny_update (RESTRICTIVE — append-only), approval_decision_deny_direct_delete (RESTRICTIVE).

**Audit trigger:** `audit_approval_decision_changes`. `decision_note` is redacted (M2 extension).

**Immutability trigger:** `trg_approval_decision_deny_update` (BEFORE UPDATE) — RAISE on any UPDATE attempt (append-only enforcement).

---

## 3. State Machine

### Contract status transitions (codified in fn_contract_status_update_user / _internal)

| From | To | fn | Permission |
|---|---|---|---|
| draft | in_review | fn_contract_status_update_user | approval.submit_for_review |
| in_review | draft | fn_contract_status_update_user | approval.submit_for_review (own) OR contract.delete |
| in_review | in_approval | fn_contract_status_update_user (atomically calls fn_approval_route_init) | approval.submit_for_review |
| in_approval | approved | fn_approval_decide → fn_contract_status_update_internal (DEFINER) | implicit (assigned approver) |
| in_approval | rejected | fn_approval_decide → fn_contract_status_update_internal (DEFINER) | implicit |
| in_approval | draft (resubmission) | fn_approval_decide → fn_contract_status_update_internal (DEFINER) | implicit |
| approved | active | fn_contract_status_update_user | contract.edit |
| any non-terminal | cancelled | fn_contract_status_update_user | contract.delete OR (contract.draft AND ownership) |

**Direct override rejection:** fn_contract_status_update_user RAISES P0001 with hint `'Use fn_approval_decide for in_approval transitions'` when caller targets approved/rejected/resubmission_requested directly while contract.status='in_approval' (AC-S12-02 / M2-NEW-1). BE translatePgError → HTTP 409 with the hint preserved.

```
                ┌──────────────┐  approval.submit_for_review
                │    draft     │ ────────────────────────────►  in_review
                └──────────────┘ ◄──── approval.submit_for_review (own) OR contract.delete
                       │
                       │ contract.delete OR (contract.draft AND ownership)
                       ▼
                  cancelled  ◄──────  any non-terminal

      in_review  ── approval.submit_for_review ──►  in_approval  (chain created atomically)
                                                       │
                                fn_approval_decide ────┤
                                                       ├───►  approved  ── contract.edit ──►  active
                                                       ├───►  rejected
                                                       └───►  draft (resubmission)
```

### Chain status

`in_progress` (initial) → `approved` | `rejected` | `resubmission_requested` | `cancelled` (all terminal; non-recoverable).

### Step status

`pending` (initial) → `approved` | `rejected` | `skipped` (any-of peer short-circuit) | `escalated` | `resubmission_requested` (terminal). `delegated` and `reassigned` are reserved on the CHECK enum but unwritten by M2 — fn_approval_delegate / fn_approval_reassign leave step.status='pending' (AC-S3-01 / AC-S8-03).

---

## 4. Functions

All M2-owned fn_'s SET search_path = public, pg_temp; all return JSONB; all reads are STABLE; all writes are VOLATILE; all are SECURITY INVOKER except fn_approval_escalate and fn_contract_status_update_internal which are SECURITY DEFINER (system-only — REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner).

### Read functions (STABLE, INVOKER)

#### fn_approval_my_pending  *(S1)*

Paginated list of pending steps assigned to the calling user via the 4 OR-arms. RLS narrows naturally via approval_step → approval_chain → contract.

| Param | Type | Default |
|---|---|---|
| p_actor_id | BIGINT | — |
| p_page | INTEGER | 1 |
| p_limit | INTEGER | 20 |
| p_sort | TEXT | 'oldest' |

**Returns:** `{ data: MyPendingApprovalListItem[], pagination: {...} }`. `MyPendingApprovalListItem` carries hoursPending, escalationRole, escalationAfterHours, requesterUserRef, parallelGroup, isRequired, plus contract identity + value.

**Errors:** 22023 invalid sort key; 22023 page/limit out of range.

#### fn_approval_matrix_list  *(S4)*

Paginated, ordered list of active matrix rules. Permission gate `approval.matrix.read`. Order: contract_type ASC, step_order ASC, parallel_group NULLS FIRST, approver_role ASC.

| Param | Type | Default |
|---|---|---|
| p_actor_id | BIGINT | — |
| p_page | INTEGER | 1 |
| p_limit | INTEGER | 50 |
| p_contract_type | TEXT | NULL |

**Returns:** `{ data: ApprovalMatrixRule[], pagination: {...} }`.

**Errors:** 42501 missing approval.matrix.read; 23514 invalid contract_type.

#### fn_approval_route_init_preview  *(S6)*

Read-only matrix lookup (STABLE). Does not persist any rows. Returns the rules that *would* apply for a (contract_type, value_aed) pair so the FE can display "will route to N approvers" before submission.

| Param | Type | Default |
|---|---|---|
| p_actor_id | BIGINT | — |
| p_contract_type | TEXT | — |
| p_value_aed | NUMERIC | — |

**Returns:** `{ contractType, valueAed, steps: RouteInitPreviewStep[], hasNoMatchingRule: boolean }`.

**Errors:** 42501 missing approval.matrix.read; 22023 negative value_aed.

#### fn_approval_chain_get  *(S10)*

Returns the most recent chain for a contract (or by chain id) with full step + decision detail. matrix_snapshot is OMITTED from this projection (sensitive).

| Param | Type | Default |
|---|---|---|
| p_actor_id | BIGINT | — |
| p_chain_id | BIGINT | NULL |
| p_contract_id | BIGINT | NULL |

> Implementation places p_actor_id first to match S10/S11 pattern (deviation from db-design.md Section 3 documented in db-impl-summary.json I2).

**Returns:** `{ chain: {...}, steps: ApprovalChainStepDetail[] }`. Each step embeds `decisions[]` ordered by decided_at ASC.

**Errors:** 22023 if neither chain_id nor contract_id supplied; NULL when not found (controller maps to 404).

#### fn_approval_chain_list  *(S11)*

Paginated, role-aware list of chains. platform_admin / Super Admin / legal_counsel see all; others narrowed via parent contract.read.* RLS.

| Param | Type | Default |
|---|---|---|
| p_actor_id | BIGINT | — |
| p_page | INTEGER | 1 |
| p_limit | INTEGER | 20 |
| p_contract_id | BIGINT | NULL |
| p_status | TEXT | NULL |
| p_submitted_by | BIGINT | NULL |

**Returns:** `{ data: ApprovalChainListItem[], pagination: {...} }`.

**Errors:** 22023 invalid status filter / page / limit.

---

### Write functions (VOLATILE)

#### fn_approval_matrix_set  *(S5, INVOKER)*

Atomic upsert / replace of matrix rules for a (contract_type, value range). Soft-deletes existing active rows for the (contract_type, min, max) tuple and INSERTs the new ordered rule set. Acquires `pg_advisory_xact_lock(hashtext(contract_type||':'||min||':'||COALESCE(max,'')))` to prevent concurrent admin races. **Calls fn_audit_log_record (M1b) with the canonical signature** `(p_table_name TEXT, p_record_id BIGINT, p_action TEXT, p_new_values JSONB, p_actor_id BIGINT)` — action='INSERT' with new_values.event='APPROVAL_MATRIX_SET' discriminator (canonical signature corrected via patch migration 030).

**Permissions:** approval.matrix.write
**Errors:** 42501 (perm), 22023 (gaps in step_order; empty rules; parallelGroup ≠ stepOrder), 23514 (invalid contract_type), P0002 (approverRole / escalationRole missing in role).

#### fn_approval_route_init  *(S7, INVOKER)*

Atomically creates approval_chain, INSERTs all approval_step rows from matched matrix rules, transitions contract.status from draft|in_review to in_approval, emits one `submitted_for_approval` contract_activity row. Idempotency: rejects with P0001 if an in_progress chain already exists (uq_approval_chain_one_active_per_contract is the DB backstop).

**Concurrency:** SELECT FOR UPDATE on contract row + on existing in_progress chain (idempotency).
**Permissions:** approval.submit_for_review
**Errors:** 42501 (perm), P0002 (contract not found), P0001 (status not in draft/in_review; existing chain), 22023 (no matching matrix rule).

#### fn_approval_decide  *(S2, INVOKER)*

Approver acts on a step. Inserts decision row, updates step+chain+contract status as needed. Parallel-group aware (all-of vs any-of derived from peer is_required pattern, M2-NEW-4). On terminal chain transitions, calls **fn_contract_status_update_internal (DEFINER)** which emits the lifecycle status_changed activity row; this fn separately emits the rich `approval_decided` row (BE-M1b-004 audit-after-render).

**Concurrency:** SELECT FOR UPDATE on step + chain + contract (cascaded order).
**Actor authorization (post-031, NULL-safe):**
```
IF NOT (
    step.approver_user_id  IS NOT DISTINCT FROM p_actor_id
 OR step.delegated_to      IS NOT DISTINCT FROM p_actor_id
 OR step.reassigned_to     IS NOT DISTINCT FROM p_actor_id
) THEN RAISE 42501 'actor:Not the assigned approver';
```
The pre-031 form `column = p_arg OR column = p_arg ...` was NULL-OR-fragile under SQL three-valued logic — when delegated_to/reassigned_to were NULL, the OR-chain evaluated to NULL and plpgsql IF NULL was treated as FALSE, BYPASSING the RAISE (privilege escalation potential). Fix landed in migration 031.

**Errors:** 42501 (actor mismatch / approval.act perm), 22023 (invalid decision; missing decisionNote on reject/request_resubmission), P0002 (step not found), P0001 (status not pending — idempotency).

#### fn_approval_delegate  *(S3, INVOKER)*

Voluntary delegation by the assigned approver. Updates step.delegated_to (status remains 'pending'). Inserts decision row with decision='delegate'. Self-delegation rejected.

**Concurrency:** SELECT FOR UPDATE on step.
**Permissions:** approval.delegate AND actor === step.approver_user_id
**Errors:** 42501 (actor mismatch), P0002 (step not found), 22023 (self-delegation; target role incompatible), P0001 (status not pending).

#### fn_approval_reassign  *(S8, INVOKER)*

Admin force-reassigns a stalled pending step. Updates step.approver_user_id (replaced) AND step.reassigned_to (audit pointer). Inserts decision row with decision='reassign'.

**Concurrency:** SELECT FOR UPDATE on step.
**Permissions:** approval.reassign
**Errors:** 42501 (perm), P0002 (step not found), P0001 (non-pending step), 22023 (target role incompatible).

#### fn_approval_escalate  *(S9, DEFINER, system-only)*

**No HTTP endpoint.** Invoked exclusively by the in-process node-cron driver (BE service `approval-escalation.cron.service.ts`). REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner. Idempotency-guarded (M2-NEW-3) via pre-check on (chain, step_order, escalation_role) with FOR UPDATE on the candidate idempotency-row peer. Emits `approval_escalated` contract_activity row.

**System-event handling (post-031):** The cron driver sets `app.current_user_id='0'` (SYSTEM_ACTOR_ID sentinel). When the escalation calls fn_contract_activity_create with effective actor=0, fn_contract_activity_create coerces `v_actor IN (NULL, 0) → NULL` just before INSERT so that contract_activity.actor_id is NULL (system event) rather than violating FK on user(id). Fix landed in migration 031.

| Param | Type |
|---|---|
| p_step_id | BIGINT |

**Errors:** P0002 (step not found), P0001 (idempotency — peer escalation row exists for same scope).

#### fn_contract_status_update_user  *(S12 / AE-2, INVOKER)*

Drafter-facing wrapper. Same wire signature as the M1a placeholder it replaces. Adds **SELECT FOR UPDATE on contract row** (UPGRADE — M1a placeholder had no lock). Hard-coded per-transition whitelist; in_review→in_approval atomically delegates to fn_approval_route_init.

| Param | Type | Default |
|---|---|---|
| p_contract_id | BIGINT | — |
| p_new_status | TEXT | — |
| p_actor_id | BIGINT | — |
| p_reason | TEXT | NULL |

**Errors:** P0002 (contract not found), P0001 (in_approval direct override → "Use fn_approval_decide for in_approval transitions" hint, M2-NEW-1 / AC-S12-02; invalid transition pair AC-S12-03), 23514 (newStatus not in 16-value enum), 42501 (per-transition perm gate).

**Activity:** emits exactly one `status_changed` contract_activity row per successful transition (M1a duplicate-guard semantics preserved, AC-S12-08).

#### fn_contract_status_update_internal  *(AE-2, DEFINER, system-only)*

REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner. Called only by fn_approval_decide for `in_approval → approved | rejected | draft (resubmission)` transitions. **Never called by BE controllers.** Same parameter shape as the user wrapper; SELECT FOR UPDATE on contract.

---

### Trigger helper fn's

| Function | Fires | Purpose |
|---|---|---|
| fn_trg_approval_chain_immutable_fields | BEFORE UPDATE on approval_chain | Blocks UPDATE that changes matrix_snapshot, contract_id, or initiated_by (M2-NEW-2) |
| fn_trg_approval_step_immutable_fields | BEFORE UPDATE on approval_step | Blocks UPDATE on approval_chain_id or step_order |
| fn_trg_approval_decision_deny_update | BEFORE UPDATE on approval_decision | RAISE on any UPDATE attempt (append-only enforcement) |

---

## 5. Cross-Module Modifications

| ID | Migration | Target | Type | Summary |
|---|---|---|---|---|
| AE-3 | 023 | contract.status CHECK | EXTEND_CHECK_CONSTRAINT | 14→16 values (+`in_approval`, +`cancelled`); stable name `contract_status_check` via dynamic pg_constraint lookup. **CRITICAL FIRST migration** — every M2 fn that writes contract.status fails until this lands. |
| AE-2 | 026 | fn_contract_status_update | OWN-AND-SPLIT | DROP M1a placeholder; CREATE `_user` (INVOKER, FOR UPDATE) + `_internal` (DEFINER, system-only). Wire signature preserved. Concurrency UPGRADE (M1a had no lock). Behaviour change: previously-permissive transitions now return 409 with M2-NEW-1 hint. |
| AE-1 | 027 | fn_contract_activity_create whitelist + contract_activity_activity_type_check | EXTEND_IN_LIST_AND_TABLE_CHECK | 9→14 values (`+submitted_for_approval, +approval_decided, +approval_reassigned, +approval_escalated, +approval_delegated`). S2-17 fidelity: SECURITY DEFINER, search_path, REVOKE/GRANT, actor fallback preserved verbatim. Migration 031 added system-event coercion (v_actor IN (NULL, 0) → NULL). |
| AE-4 | 028 | permission + role_permission | INSERT (additive) | 6 new permissions (snake_case) + 21 grants. 0 new roles (reuses M1a roles). approval.escalate intentionally NOT introduced (system-only). |
| AE-Sensitive | 029 | fn_audit_trigger redact list | CREATE OR REPLACE | M0 17 + M1a `body_en` / `body_ar` (2) + M2 `decision_note` / `matrix_snapshot` (2) = 21 redacted fields. project.config.json `sensitiveFields` updated at state-update. |

**AE-5 (deferred):** `contract.approval_chain_id` forward-FK column NOT introduced — HQ4=B. fn_approval_chain_get(contract_id) covers the lookup; FE caches via React Query. Optional projection extension to fn_contract_get_by_id deferred.

### Permissions added (6) — snake_case

| Code | Description | Granted to |
|---|---|---|
| approval.submit_for_review | Submit a contract into the approval chain (S7 + draft→in_review) | platform_admin, contract_drafter, Super Admin |
| approval.act | Decide on a pending step (approve/reject/request_resubmission) | platform_admin, legal_counsel, contract_approver, contract_approver_2, Super Admin |
| approval.delegate | Voluntarily delegate own pending step | platform_admin, legal_counsel, contract_approver, contract_approver_2, Super Admin |
| approval.matrix.read | Read approval matrix rules + preview (S4 + S6) | platform_admin, legal_counsel, Super Admin |
| approval.matrix.write | Replace approval matrix rules (S5) | platform_admin, Super Admin |
| approval.reassign | Admin override reassign of a pending step (S8) | platform_admin, legal_counsel, Super Admin |

Grant breakdown: platform_admin 6, legal_counsel 4, contract_drafter 1, contract_approver 2, contract_approver_2 2, Super Admin 6 = 21 total. Pre-emptive Super Admin pattern follows the M1a 006 / M1c 018 lesson.

`approval.escalate` is intentionally NOT introduced — fn_approval_escalate is SECURITY DEFINER + cron-invoked; no human user holds it.

---

## 6. Audit & Redaction

`fn_audit_trigger` (M0) is extended in migration 029. Redact list:

```
M0 (17): password, refresh_token, access_token, openai_api_key, anthropic_api_key,
         smtp_password, uae_pass_client_secret, supabase_service_role_key,
         jwt_secret, signer_email, signer_phone, emirates_id,
         signature_image, ai_prompt_payload, contract_body, signer_name, ip_address
M1a (2): body_en, body_ar
M2 (2): decision_note, matrix_snapshot
─── total 21 ───
```

Trigger bindings:
- `audit_approval_matrix_changes` — fires on approval_matrix INSERT/UPDATE/DELETE
- `audit_approval_chain_changes` — fires on approval_chain INSERT/UPDATE/DELETE (matrix_snapshot redacted)
- `audit_approval_step_changes` — fires on approval_step INSERT/UPDATE/DELETE
- `audit_approval_decision_changes` — fires on approval_decision INSERT/DELETE (UPDATE blocked by RESTRICTIVE policy + immutability trigger; decision_note redacted)

---

## 7. RLS Policies (14 total — 10 PERMISSIVE + 4 RESTRICTIVE)

WITH CHECK is byte-identical to USING on all UPDATE policies (Codex BE-M1b-006). All M2 tables ENABLE + FORCE ROW LEVEL SECURITY.

| Table | Policy | Op | Type |
|---|---|---|---|
| approval_matrix | approval_matrix_select_matrix_read_perm | SELECT | PERMISSIVE |
| approval_matrix | approval_matrix_modify_admin | ALL | PERMISSIVE |
| approval_matrix | approval_matrix_deny_direct_delete | DELETE | RESTRICTIVE |
| approval_chain | approval_chain_select_via_contract | SELECT | PERMISSIVE |
| approval_chain | approval_chain_insert_drafter_or_admin | INSERT | PERMISSIVE |
| approval_chain | approval_chain_update_engine_or_admin | UPDATE | PERMISSIVE |
| approval_chain | approval_chain_deny_direct_delete | DELETE | RESTRICTIVE |
| approval_step | approval_step_select_via_chain | SELECT | PERMISSIVE |
| approval_step | approval_step_insert_via_route_init | INSERT | PERMISSIVE |
| approval_step | approval_step_update_assigned_or_admin | UPDATE | PERMISSIVE |
| approval_step | approval_step_deny_direct_delete | DELETE | RESTRICTIVE |
| approval_decision | approval_decision_select_via_step | SELECT | PERMISSIVE |
| approval_decision | approval_decision_insert_via_engine | INSERT | PERMISSIVE |
| approval_decision | approval_decision_deny_update | UPDATE | RESTRICTIVE |
| approval_decision | approval_decision_deny_direct_delete | DELETE | RESTRICTIVE |

**Sensitive-field pre-image protection:** the M1a self-ref subquery RLS anti-pattern (BE-M1c-C1) is replaced by the BEFORE UPDATE immutability triggers (M2-NEW-2) on approval_chain (matrix_snapshot, contract_id, initiated_by) and approval_step (approval_chain_id, step_order). approval_decision uses a RESTRICTIVE deny-update policy + a deny-update trigger (defense in depth).

---

## 8. Migration History

| # | Filename | Purpose | Notes |
|---|---|---|---|
| 023 | `023_m2_extend_contract_status_check.sql` | AE-3 — extend contract.status CHECK 14→16 values | **CRITICAL FIRST.** Stable constraint name `contract_status_check`. Dynamic pg_constraint lookup pattern from M1b 010. |
| 024 | `024_m2_approval_tables_rls_indexes.sql` | 4 new tables + 25 indexes + 14 RLS + 4 audit triggers + 3 immutability triggers | M2-NEW-2 immutability triggers replace RLS self-ref subquery anti-pattern |
| 025 | `025_m2_approval_functions.sql` | 11 owned fn_approval_* | All SET search_path = public, pg_temp; INVOKER except fn_approval_escalate (DEFINER) |
| 026 | `026_m2_split_fn_contract_status_update.sql` | AE-2 — DROP M1a placeholder; CREATE _user + _internal | UPGRADE FOR UPDATE; DEFINER + REVOKE/GRANT for internal |
| 027 | `027_m2_extend_fn_contract_activity_create_whitelist.sql` | AE-1 — 9→14 activity_type values | S2-17 verbatim body preservation |
| 028 | `028_m2_approval_permissions_and_grants.sql` | AE-4 — 6 perms + 21 grants | Pre-emptive Super Admin pattern |
| 029 | `029_m2_extend_audit_redact_list.sql` | AE-Sensitive — extend redact list | 19 → 21 fields |
| **030** | `030_m2_fix_fn_approval_matrix_set_audit_call.sql` | **PATCH cycle 1** — fn_audit_log_record signature mismatch | Agent 4 design error; caught at DB Impl functional probe (report-don't-fix protocol). Re-issued fn_approval_matrix_set body with M1b 011 canonical signature `(TEXT, BIGINT, TEXT, JSONB, BIGINT)` and action='INSERT' + new_values.event='APPROVAL_MATRIX_SET' discriminator. Migration 025 left immutable. |
| **031** | `031_m2_fix_actor_check_and_cron_actor.sql` | **PATCH cycle 2** — NULL-safe equality + system-event actor sentinel | Caught by Testing Agent integration tests. Two CREATE OR REPLACE: (1) fn_approval_decide actor IF-NOT block uses `IS NOT DISTINCT FROM` (NULL-safe equality) — fixes privilege escalation where any user with approval.act could decide on any pending step; (2) fn_contract_activity_create coerces `v_actor IN (NULL, 0) → NULL` just before INSERT — fixes cron driver SYSTEM_ACTOR_ID sentinel FK violation against user(id). 5/5 smoke probes passed. |

Both Neon branches (`m0-foundation` / `br-snowy-brook-aje2ehtl` and `test` / `br-billowing-boat-ajq9m0g6`) are at `schema_migrations.version = 31`.

---

## 9. Seed Data

approval_matrix is INTENTIONALLY EMPTY at seed time (db-design.md §7.1 — "no system-required initial rules"). Admins configure rules at runtime via `PUT /admin/approval-matrix`. Tests use targeted INSERTs for fixture data; production deployments must run a one-time admin configuration step before `POST /contracts/:id/submit-for-approval` returns successfully.

The 6 permissions + 21 grants are seeded in migration 028 (additive, idempotent INSERT ... ON CONFLICT DO NOTHING).

---

## 10. Sensitive Fields Registry (M2 additions)

| Field | Table | Reason |
|---|---|---|
| decision_note | approval_decision | Internal commercial / legal commentary |
| matrix_snapshot | approval_chain | Frozen role-mapping rules; sensitive policy data |

Both are added to `project.config.json sensitiveFields` and to `fn_audit_trigger v_redact_fields` (migration 029). Pino redaction on the BE side: 14 paths each (top-level / req.body / req.body.* / req.query / req.params / *.* / *.*.* / snake_case).

---

*Generated by Documentation Generator (Agent 15) post-QA Stage 4. Sources: db-design.md (2014 lines), db-design-summary.json, db-impl-summary.json, qa-stage4-result.json. v1.0 — M2 ship.*
