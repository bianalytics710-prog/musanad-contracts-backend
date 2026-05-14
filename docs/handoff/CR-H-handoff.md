# CR-H — Advisory Drafter + Notification Delivery — Technical Handoff

Generated: 2026-05-14T00:00:00.000Z
Module: M16
Status: SHIP-GO-WITH-WARNINGS (QA Stage 4 cleared, 4 post-ship debt items)
Git: See delivery report for BE/FE SHAs.

---

## TL;DR

CR-H delivers two interleaved systems: (1) a template-driven advisory drafting pipeline in which an LLM generates contract advisories from correlation signals using Mustache templates (Hormuz FM Invocation, Sanctions Hold Notice, Cure Notice), advisories go through a named-human approval lifecycle with separation-of-duties enforcement, and approved advisories are dispatched via real SMTP email + capture-mode Teams/Slack; (2) a v1.2 notification delivery infrastructure that adds real nodemailer-based SMTP sending, a universal notification dispatch log visible to Platform Admin, per-user preference subscriptions (28-cell grid), and an exponential-backoff retry worker for failed deliveries. All advisory text is treated as sensitive — Pino-redacted at the BE layer and audit-trigger-redacted at the DB layer. No advisory leaves the system without named human approval (production credibility invariant #7).

---

## Architecture Overview

### Advisory Drafter Pipeline

```
POST /advisory-drafts/generate
  └─ advisory-drafter.service.ts
       ├─ fn_advisory_context_build (DEBT-CRH-1: not yet authored → fallback minimal context)
       ├─ fn_ai_prompt_get(kind, variant) (DEBT-CRH-2: 2-arg vs 1-arg mismatch → LLM bypassed, Mustache-only)
       ├─ AIProvider (gpt-4o) → LLM response
       ├─ Mustache.render(body_template_en/ar, context)
       └─ fn_advisory_draft_generate (DEFINER) → persists draft + ai_request_log in one TX

Draft lifecycle:
  unapproved → [modify → modified →] approved/rejected

POST /advisory-drafts/:id/approve  → fn_advisory_draft_approve (SOD + role-match guards)
POST /advisory-drafts/:id/reject   → fn_advisory_draft_reject (SOD + ≥10-char reason)
POST /advisory-drafts/:id/modify   → fn_advisory_draft_modify (sets modified; re-approval required)
POST /advisory-drafts/:id/dispatch → fn_advisory_dispatch (DEFINER)
                                       └─ fn_notification_send × (channels × recipients)
                                            └─ notification_dispatcher.service → nodemailer (email)
                                                                                → capture log (teams/slack)
```

### Notification Dispatcher + Retry Worker

```
fn_notification_send (DEFINER — no HTTP route)
  ├─ Checks notification_subscription preference gate
  ├─ Writes notification_dispatch_log (status=sent/captured_only/pending_retry)
  └─ Calls fn_audit_log_record_v2 (Strategy A — in-fn audit)

notification-retry.worker.ts (node-cron every 60s)
  ├─ fn_notification_dispatch_retry_due (FOR UPDATE SKIP LOCKED — S2-24 CTE split)
  ├─ Re-attempt via notification-dispatcher.service
  └─ fn_notification_dispatch_update_retry_outcome
       └─ Backoff: 1m→5m→30m→2h→8h → final_failed at retry_count=5
```

### Frontend Routes

| Route | Permission | Surface |
|---|---|---|
| /app/legal/advisory-queue | advisory.draft.review | Legal Counsel queue — list + detail + approve/reject/modify/dispatch |
| /app/legal/advisory-queue/$id | advisory.draft.review | Advisory draft detail with source lineage |
| /app/admin/advisory-templates | advisory.template.manage | Platform Admin template catalogue |
| /app/admin/advisory-templates/$id | advisory.template.manage | Template editor (create/edit) |
| /app/admin/notifications | notification.dispatch_log.read | Universal dispatch log viewer |
| /app/profile/notification-preferences | all authenticated | Self-service 28-cell preference matrix |

---

## HITL Decisions Locked (Autonomous Mode — pre-locked at pipeline start)

All 6 decisions were pre-locked in `pipeline-state.json` `autonomous_decisions[]` before implementation began (no HITL gate interaction required).

### Q1 — Separation-of-duties: can the draft generator approve their own draft?
**Locked:** default-on (self_approval_denied enforced)
**Why:** Annex D §D.6.6 explicitly requires named-human approval by a different user. The fn_advisory_draft_approve ERRCODE 42501 guard and FE Approve button hide when currentUserId === draft.createdBy.

### Q2 — Draft type reference table or CHECK constraint?
**Locked:** CHECK constraint for v1 (8 values); promote to reference table at CR-I if list exceeds 8.
**Why:** 8 values is the project threshold for lookup table promotion. v1 seeds 3; 5 deferred to CR-I.

### Q3 — Mustache rendering location: DB (plv8) or BE service?
**Locked:** BE service (advisory-drafter.service.ts)
**Why:** plv8 is not enabled on Neon. BE service layer has full Node.js Mustache library + error handling.

### Q4 — correlation.matched_clause_id: EXTEND or JSONB projection?
**Locked:** EXTEND (additive FK column)
**Why:** FK integrity needed for AC-S21 parameter substitution. Cheaper at every advisory-generation call. Backward-compatible additive (NULL default). S2-22b join-target tracing: advisory_draft.contract_id is a direct denormalised FK (never via correlation.contract_id).

### Q5 — Teams/Slack delivery: real webhook or capture-mode?
**Locked:** Capture-mode only for v1.2 (payload stored in dispatch log; no real webhook calls)
**Why:** v1.2 brief §4.10 explicitly scopes Teams/Slack as capture-mode for demo evidence. Real webhooks deferred to v2.

### Q6 — Default notification preference opt-in posture?
**Locked:** Opt-in to high+critical only (priority_min='high') for advisory × email/in_app
**Why:** Annex D §13.13 default-cautious. Backfill migration 214 creates 2 rows per existing user. Users can lower to medium/low via preference matrix.

---

## Migration List (203..223)

| # | File | Contents |
|---|---|---|
| 203 | 203_crh_extend_correlation_matched_clause.sql | EXTEND correlation: +matched_clause_id FK + 2 score/reason columns + index |
| 204 | 204_crh_create_advisory_template.sql | advisory_template table + 4 indexes + RLS + trigger |
| 205 | 205_crh_create_advisory_draft.sql | advisory_draft table + 6 indexes + RLS + trigger |
| 206 | 206_crh_create_advisory_dispatch_log.sql | advisory_dispatch_log append-only table + 3 indexes + RLS (no trigger — Strategy A) |
| 207 | 207_crh_create_notification_dispatch_log.sql | notification_dispatch_log append-only table + 5 indexes (incl. retry partial) + RLS |
| 208 | 208_crh_create_notification_subscription.sql | notification_subscription table + UNIQUE + 2 indexes + RLS + trigger |
| 209 | 209_crh_extend_audit_trigger_redact_list.sql | fn_audit_trigger redact list 43→56 (+13 advisory sensitive fields) |
| 210 | 210_crh_create_permissions.sql | 5 new permissions + 27 role_permission grants |
| 211 | 211_crh_seed_advisory_templates.sql | 3 advisory_template seed rows (EN+AR Mustache) |
| 212 | 212_crh_seed_notification_templates.sql | 3 net-new notification_template rows (advisory.dispatched.*) |
| 213 | 213_crh_seed_ai_prompt.sql | 3 ai_prompt rows (kind=advisory_drafter per variant) |
| 214 | 214_crh_backfill_notification_subscription_defaults.sql | Backfill existing users with HITL-Q6 defaults (ON CONFLICT DO NOTHING) |
| 215 | 215_crh_fn_advisory_template_functions.sql | fn_advisory_template_list/get_by_id/create/update/delete (5 fn_'s) |
| 216 | 216_crh_fn_advisory_draft_functions.sql | fn_advisory_draft_generate/list/get_by_id/approve/reject/modify (6 fn_'s) |
| 217 | 217_crh_fn_advisory_dispatch_functions.sql | fn_advisory_dispatch + fn_advisory_dispatch_log_list (2 fn_'s) |
| 218 | 218_crh_fn_notification_send_function.sql | fn_notification_send + fn_notification_dispatch_retry_due + fn_notification_dispatch_update_retry_outcome (3 fn_'s) |
| 219 | 219_crh_fn_notification_log_subscription_functions.sql | fn_notification_dispatch_log_list/get_by_id + fn_notification_subscription_list/set (4 fn_'s) |
| 220 | 220_crh_grant_pre_emptive_backfill.sql | Defensive re-application of all 27 role_permission grants + pgrant audit |
| 221 | 221_crh_fix_advisory_draft_get_by_id_risk_score_columns.sql | Fix column refs in fn_advisory_draft_get/approve/reject/modify: overall_score→health_score, computed_at→calculated_at (DEFECT-CRH-DB-03) |
| 222 | 222_crh_fix_notification_dispatch_retry_due_for_update.sql | Fix fn_notification_dispatch_retry_due: split FOR UPDATE SKIP LOCKED claim from outer jsonb_agg (S2-24 CTE pattern; DEFECT-CRH-DB-04) |
| 223 | 223_crh_post_qa_patch.sql | Post-QA patch for DEBT-CRH-1 (fn_advisory_context_build stub) — see Known Debt |

---

## New Permissions + Grants Matrix

| Permission | Super Admin | platform_admin | legal_counsel | operations | finance_treasury | compliance_esg | procurement_supplier_risk | executive | contract_drafter | contract_approver |
|---|---|---|---|---|---|---|---|---|---|---|
| advisory.template.manage | Y | Y | Y | — | — | — | — | — | — | — |
| advisory.draft.review | Y | Y | Y | — | — | — | — | — | — | — |
| advisory.dispatch | Y | Y | Y | — | — | — | — | — | — | — |
| notification.dispatch_log.read | Y | Y | — | — | — | — | — | — | — | — |
| notification.preferences.write.self | Y | Y | Y | Y | Y | Y | Y* | Y | Y | Y |

*procurement_supplier_risk grant skipped on initial deploy (DEFECT-CRH-DB-01 — role row absent from this branch; pre-existing M15 seed issue).

---

## Stage 2 Risks Mitigated

| Check | How mitigated |
|---|---|
| S2-16 DTO-to-fn-body match | Contract Generator pass asserted parameter lists; all 20 fn_ parameter lists pinned in api-contracts.json |
| S2-17 Concurrency locks | SELECT FOR UPDATE on advisory_draft in approve/reject/modify/dispatch; FOR UPDATE SKIP LOCKED in retry_due (S2-24 CTE) |
| S2-18 NULL-safe equality | dispatched_at IS NULL idempotency guard; myQueue filter uses IS DISTINCT FROM |
| S2-19 Cross-fn signature | fn_notification_send 9-arg form locked; fn_audit_log_record_v2 6-arg from R-PA7/128; fn_ai_request_log_create 18-arg from M4/043 |
| S2-20 Actor sentinel | All 5 DEFINER fn_'s NULLIF(p_actor_id, 0) before fn_audit_log_record_v2; worker uses SYSTEM_ACTOR_ID=0 |
| S2-21 Zero PUBLIC grants | 60 REVOKE FROM PUBLIC + GRANT TO neondb_owner statements. **16th consecutive clean module.** |
| S2-22 Column existence | All INSERTs/UPDATEs column-explicit; tables created before fn_'s |
| S2-22b Join-target tracing | advisory_draft.contract_id is direct denormalised FK — never via correlation.contract_id |
| S2-23 FK pre-validation | 6 FK references pre-validated with P0002 raises |
| S2-24 Split aggregate | fn_notification_dispatch_retry_due uses inner CTE (FOR UPDATE SKIP LOCKED claim) + outer jsonb_agg (fixed via migration 222) |
| S2-25 Explicit ERRCODEs | All RAISE EXCEPTION uses USING ERRCODE from standard catalog |
| S2-26 WHEN OTHERS SQLSTATE | All fn_ bodies WHEN OTHERS uses USING ERRCODE = SQLSTATE |
| S2-27 COMMENT ON FUNCTION | Every fn_ has paired COMMENT ON FUNCTION |
| S2-28 Idless table strategy | advisory_dispatch_log + notification_dispatch_log documented as Strategy A |

---

## Known Debt

### DEBT-CRH-1 (HIGH) — fn_advisory_context_build not authored
`fn_advisory_context_build(bigint, bigint)` is called by advisory-drafter.service.ts but was not specified in db-design.md or created in any migration. The service has a graceful fallback ("minimal context") that lets the hero scenario succeed. However, **the dynamic correlation/clause/risk-score context lineage never reaches the LLM prompt** — AC-S5-01 advisory lineage is partly degraded. All advisory drafts currently use Mustache-only generation without rich context.

**Fix:** Author a new migration with `fn_advisory_context_build(p_actor_id BIGINT, p_correlation_id BIGINT) RETURNS JSONB` that returns `{contractId, correlation, matchedClauses[], matchedSignal, riskScoreSummary}` per the service's CorrelationContextRow type definition.

**Status as shipped:** Post-QA patch migration 223 provides a stub; real implementation deferred to follow-up CR.

### DEBT-CRH-2 (MEDIUM) — fn_ai_prompt_get 1-arg vs 2-arg mismatch
M4 (migration 043) defines `fn_ai_prompt_get(p_prompt_id text)` — 1 positional arg. The advisory-drafter.service calls `['advisory_drafter', draftType]` — 2 args. The 2-arg call raises `function does not exist` on every draft generation. The service falls back to Mustache-only rendering. All advisory drafts currently bypass LLM enrichment entirely.

**Fix (two options):** (A) Author `fn_ai_prompt_get_by_kind(p_kind text, p_variant text)` as a new 2-arg overload; or (B) change the service to compose `prompt_id = '${kind}.${variant}'` and call the existing 1-arg fn_.

Option B is cheaper and does not require a new migration if the ai_prompt seed rows use the composite key format.

### DEFECT-CRH-DB-01 (LOW, pre-existing) — procurement_supplier_risk role absent
The `procurement_supplier_risk` role row is missing from the m0-foundation branch, causing the notification.preferences.write.self grant in migration 210 to be skipped for that role. This is a pre-existing issue from M15 seed migration not being applied to this branch.

**Fix:** Verify M15 seed migration was applied to the m0-foundation branch. If not, apply it and re-run migration 210 / migration 220 defensively.

### DEBT-CRH-3 (LOW) — channelPayload field missing from dispatch log detail
`fn_notification_dispatch_log_get_by_id` does not expose a `channelPayload` field. The `NotificationPayloadPreviewModal` falls back to `bodyRendered` plaintext. The "capture-mode demo moment" for Teams/Slack renders as plain text rather than structured JSON.

**Fix:** Extend fn_ to expose `channelPayload` sourced from `notification_dispatch_log.context_payload` or by joining `advisory_dispatch_log.rendered_payload` where advisory_draft_id is set.

### DEBT-CRH-4 (LOW) — NotificationSubscriptionCell.id undefined for synthesised defaults
`fn_notification_subscription_list` synthesises 28 cells for rows that have no explicit DB record. These synthesised cells have no `id`. The FE type declares `number | null` but callers may assume a non-null id.

**Fix:** Change FE type to `id?: number` or emit `id: null` explicitly from the fn_ for synthesised cells.

### DEBT-CRH-5 (LOW) — Vitest coverage numerics not captured
Test report (55/55 PASS) qualitatively covers all 20 fn_'s and 7 service paths but does not include numeric lines/functions/branches percentages from `npm test -- --coverage`. Cannot assert ≥90% line/function and ≥80% branch thresholds.

**Fix:** Future modules should run `npm test -- --coverage --reporter=json` and capture the output to the module test-report.

### DEBT-CRH-6 (POST-IMPL) — Playwright E2E specs not authored
47 e2e-tagged ACs in requirements-analysis.json have no `tests/e2e/M16-*.spec.ts`. The integration hero scenario (10 tests in CR-H-hormuz-end-to-end.test.ts) serves as the BE E2E proxy. Post-impl MCP browser walk is the AC verification surface per project precedent (`feedback_e2e_means_mcp_browser_walk.md`).

---

## Production Credibility Invariants Honored

### #6 — No LLM call without audit
Every `fn_advisory_draft_generate` execution inserts an `ai_request_log` row (kind='advisory_drafter', actor_id, model_version, prompt_hash, response_hash, cost_usd) inside the same DB transaction. If the ai_request_log insert fails, the draft is not persisted. DEBT-CRH-2 means the LLM call itself currently falls back to Mustache-only — but when the LLM call succeeds, the audit is guaranteed atomic.

### #7 — No advisory dispatched without named human approval
`fn_advisory_dispatch` raises 23514 `draft_not_approved` if `approval_status != 'approved'`. The HTTP controller maps this to 422. The FE Dispatch button is only visible on approved drafts. Separation-of-duties (HITL Q1) prevents the generator from being their own approver.

### #8 — Source traceability
Every `advisory_draft` row carries `correlation_id` (FK to the triggering correlation), `template_id` + `template_version` (snapshot at generation time), `prompt_hash` (SHA-256 of canonical prompt), `response_hash` (SHA-256 of raw LLM response), and `model_version`. The audit trail is append-only and hash-chain signed via fn_audit_log_record_v2. DEBT-CRH-1 affects richness of context lineage but not the core traceability of which correlation/template/LLM call produced each draft.

---

## How to Extend This Module

### To add a new advisory template type
1. Add the new value to the `draft_type` CHECK constraint in a new migration (`ALTER TABLE advisory_template DROP CONSTRAINT ... ADD CONSTRAINT ... CHECK (draft_type IN (... 'new_type'))`). Same for advisory_draft.
2. Seed an ai_prompt row with kind='advisory_drafter' variant='new_type'.
3. Create the template via the Platform Admin UI or directly via `fn_advisory_template_create`.
4. At CR-I (if draft_type values exceed 8): promote CHECK to a `advisory_draft_type` reference table.

### To wire real Teams/Slack delivery (replace capture-mode)
1. Add `TEAMS_WEBHOOK_URL` and `SLACK_WEBHOOK_URL` env vars to the env validator.
2. In `notification-dispatcher.service.ts`, replace the `teams_capture` and `slack_capture` capture-only branches with real `axios.post(webhookUrl, payload)` calls.
3. Error handling pattern mirrors the nodemailer SMTP path — catch → update status=failed in notification_dispatch_log.
4. No DB migrations required.

### To author fn_advisory_context_build (resolves DEBT-CRH-1)
1. Create a new migration: `fn_advisory_context_build(p_actor_id BIGINT, p_correlation_id BIGINT) RETURNS JSONB`
2. Query: correlation JOIN contract JOIN contract_clause_extracted (via matched_clause_id) JOIN latest_risk_score.
3. Return shape: `{ contractId, correlationId, matchedClauses: [...], matchedSignal: {...}, riskScoreSummary: { healthScore, calculatedAt } }`.
4. Service drops the `try/catch` fallback path once the fn_ exists.

---

## Test Coverage

| Suite | Tests | Status |
|---|---|---|
| tests/db/CR-H-fns.test.ts | 38 | 55/55 PASS |
| tests/services/notification-dispatcher.test.ts | 7 | PASS |
| tests/integration/CR-H-hormuz-end-to-end.test.ts | 10 | PASS |
| S2-21 PUBLIC grant check | 1 | PASS (16th consecutive clean) |
| S2-19 fn_notification_send signature integrity | 1 | PASS |
| Audit chain integrity — approve emits audit_log row | 1 | PASS |

Full suite regression: 1248 + 55 = 1303 tests, 0 failures.

---

## Files Owned by CR-H

### Backend
**Services:**
- src/services/advisory-drafter.service.ts
- src/services/notification-dispatcher.service.ts

**Workers:**
- src/workers/notification-retry.worker.ts

**Schemas:**
- src/schemas/advisory-templates.schemas.ts
- src/schemas/advisory-drafts.schemas.ts
- src/schemas/notification-dispatch-log.schemas.ts
- src/schemas/notification-preferences.schemas.ts

**Controllers:**
- src/controllers/advisory-templates.controller.ts
- src/controllers/advisory-drafts.controller.ts
- src/controllers/notification-dispatch-log.controller.ts
- src/controllers/notification-preferences.controller.ts

**Routes:**
- src/routes/v1/admin/advisory-templates.routes.ts
- src/routes/v1/advisory-drafts.routes.ts
- src/routes/v1/admin/notification-dispatch-log.routes.ts
- src/routes/v1/users/notification-preferences.routes.ts

**Modified:**
- src/routes/v1/admin/index.ts (advisory-templates + notification-dispatch-log mounted)
- src/routes/v1/index.ts (advisory-drafts + users/notification-preferences mounted)
- src/utils/logger.util.ts (+68 Pino redact paths for 13 CR-H sensitive fields)

**Database:**
- database/migrations/203_crh_extend_correlation_matched_clause.sql
- database/migrations/204_crh_create_advisory_template.sql
- database/migrations/205_crh_create_advisory_draft.sql
- database/migrations/206_crh_create_advisory_dispatch_log.sql
- database/migrations/207_crh_create_notification_dispatch_log.sql
- database/migrations/208_crh_create_notification_subscription.sql
- database/migrations/209_crh_extend_audit_trigger_redact_list.sql
- database/migrations/210_crh_create_permissions.sql
- database/migrations/211_crh_seed_advisory_templates.sql
- database/migrations/212_crh_seed_notification_templates.sql
- database/migrations/213_crh_seed_ai_prompt.sql
- database/migrations/214_crh_backfill_notification_subscription_defaults.sql
- database/migrations/215_crh_fn_advisory_template_functions.sql
- database/migrations/216_crh_fn_advisory_draft_functions.sql
- database/migrations/217_crh_fn_advisory_dispatch_functions.sql
- database/migrations/218_crh_fn_notification_send_function.sql
- database/migrations/219_crh_fn_notification_log_subscription_functions.sql
- database/migrations/220_crh_grant_pre_emptive_backfill.sql
- database/migrations/221_crh_fix_advisory_draft_get_by_id_risk_score_columns.sql
- database/migrations/222_crh_fix_notification_dispatch_retry_due_for_update.sql
- database/migrations/223_crh_post_qa_patch.sql

**Tests:**
- tests/db/CR-H-fns.test.ts
- tests/services/notification-dispatcher.test.ts
- tests/integration/CR-H-hormuz-end-to-end.test.ts

### Frontend
**Routes:**
- src/routes/app/admin.advisory-templates.tsx
- src/routes/app/admin.advisory-templates.$id.tsx
- src/routes/app/legal.advisory-queue.tsx
- src/routes/app/legal.advisory-queue.$id.tsx
- src/routes/app/admin.notifications.tsx
- src/routes/app/profile.notification-preferences.tsx

**Services:**
- src/services/api/admin/advisory-templates.service.ts
- src/services/api/advisory-drafts.service.ts
- src/services/api/admin/notification-dispatch-log.service.ts
- src/services/api/notification-preferences.service.ts

**Types:**
- src/types/admin/advisory-templates.types.ts
- src/types/advisory-drafts.types.ts
- src/types/admin/notification-dispatch-log.types.ts
- src/types/notification-preferences.types.ts

**Components:**
- src/components/admin/AdvisoryTemplateEditor.tsx
- src/components/advisory/AdvisoryDraftPreview.tsx
- src/components/advisory/AdvisoryModifyDialog.tsx
- src/components/advisory/AdvisoryRejectDialog.tsx
- src/components/admin/NotificationDispatchLogTable.tsx
- src/components/admin/NotificationPayloadPreviewModal.tsx
- src/components/profile/NotificationPreferencesMatrix.tsx

**Modified:**
- src/config/sidebar.ts (3 new entries: legal.advisoryQueue, admin advisory-templates, admin notifications)
- src/i18n/en.json (+165 keys; 5664→5829)
- src/i18n/ar.json (+165 keys; 5664→5829; EN/AR parity MATCH at 5829/5829)

---

*Signed off: 2026-05-14 — Agent 15 (Documentation Generator)*
