# M0 Foundation - Developer Handoff

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M0 - Foundation
> **Generated:** 2026-05-02
> **Audience:** Developers picking up M0 or extending it via M1+ feature modules.

This is the practical guide for getting M0 running locally, understanding the architecture, and adding new features. For database details see `data-dictionary.md`. For ops/SRE concerns see `ops-runbook.md`. For the Lovable-to-production transformation log see `lovable-handoff.md`.

---

## 1. Quick start

```bash
# 1. Clone both repos
git clone https://github.com/disc-product/musanad-contracts-backend.git
git clone https://github.com/disc-product/musanad-contracts-frontend.git

# 2. Install backend deps
cd musanad-contracts-backend
npm install
cp .env.example .env.local
# Fill in DATABASE_URL (Neon), JWT_SECRET (>= 32 chars), OPENAI_API_KEY,
# SMTP_* (or run Mailpit), and CORS_ORIGIN=http://localhost:5173.

# 3. Install frontend deps
cd ../musanad-contracts-frontend
npm install
cp .env.example .env.local
# VITE_API_BASE_URL=http://localhost:4000 is already correct.

# 4. Run dev servers (two terminals)
# Backend:
cd musanad-contracts-backend && npm run dev   # listens on :4000
# Frontend:
cd musanad-contracts-frontend && npm run dev  # listens on :5173

# 5. Log in
# Open http://localhost:5173 -> /auth/login
# Bootstrap admin: admin@musanad.local / ChangeMe@123
# IMPORTANT: rotate this password on first login (see "Known follow-ups").
```

The bootstrap admin is seeded by `001_foundation.sql` with a bcrypt(12) hash of `ChangeMe@123`. The plaintext is NOT in the migration file - the DB Implementation Agent generated the hash at migration time.

---

## 2. Architecture overview

M0 implements the v2.6 "Database Objects First" pattern:

```
[ Frontend (TanStack Start) ]
        |  axios (JWT)
        v
[ Express controller ]      <- thin HTTP layer, Zod-validates
        |  db.callFunction("fn_*")
        v
[ PostgreSQL fn_ function ] <- ALL business logic lives here
        |  (RLS enforced via app.current_user_id GUC)
        v
[ Tables ]
```

**Rules:**
- Controllers do NOT contain business logic. They validate input, call `db.callFunction()`, wrap the JSONB in the `ApiResponse<T>` envelope, and return.
- All business logic lives in `fn_*` functions. Naming: `fn_<entity>_<operation>` (e.g. `fn_user_create`).
- `rls.middleware.ts` runs `SET LOCAL app.current_user_id = <jwt.sub>` inside a transaction before every authenticated `fn_` call. RLS policies read this GUC.
- JSONB output keys are **camelCase** and match the TypeScript interfaces in `src/types/api.types.ts`.
- No ORM. No stored procedures. Raw `pg` driver + parameterized queries.

**Backend file layout:**

```
src/
  server.ts                    -- Express bootstrap (helmet, cors, pino, OTel)
  controllers/                 -- one per resource (auth, user, role, permission)
  routes/v1/                   -- mounts controllers under /api/v1
  middleware/
    auth.middleware.ts         -- JWT verify (aud, iss, exp)
    rls.middleware.ts          -- SET LOCAL app.current_user_id
    rate-limit.middleware.ts   -- per-IP / per-user rate limiters
    validation.middleware.ts   -- Zod request validation
    correlation.middleware.ts  -- X-Request-ID
    error.middleware.ts        -- global error -> ErrorResponse mapper
  schemas/                     -- Zod schemas (auth, user)
  database/
    client.ts                  -- pg pool wrapper + callFunction()
    config.ts                  -- pool config (TLS verified, no rejectUnauthorized:false)
    migrate.ts                 -- migration runner (up + down via -- ROLLBACK markers)
  integrations/
    ai/                        -- AIProvider abstraction (OpenAI primary, Anthropic stub)
    mail/                      -- Nodemailer wrapper + templates/
    uae-pass/                  -- mock + live providers + state-store
  utils/                       -- env-validation, errors, jwt, logger, password, telemetry
  types/                       -- api.types.ts (mirrors workspace types.ts)
```

---

## 3. Auth flow

### Login (`POST /api/v1/auth/login`)

1. Zod validates `{email, password}`.
2. `fn_auth_get_user_for_login(email)` returns a record with `passwordHash` + lockout state, or NULL.
3. **Timing normalization (CRX-2 fix):** if NULL, the controller still runs `bcrypt.compare(password, DUMMY_HASH)` to equalize timing. Response is always a generic 401 on mismatch (no email enumeration).
4. If `lockedUntil > now()` -> 423 ACCOUNT_LOCKED.
5. `bcrypt.compare(password, passwordHash)` mismatch -> `fn_auth_record_login_failure(userId, 5, 15)` -> 401 (or 423 if now locked).
6. Match -> `fn_auth_record_login_success(userId)` -> sign access JWT (15m) + refresh JWT (7d) -> return `LoginResponse`.

### Refresh (`POST /api/v1/auth/refresh`) - rotation

1. Verify refresh JWT (`aud`, `iss`, `exp` - all three required).
2. SHA-256 hash the refresh token.
3. `fn_auth_check_token_blacklist(hash)` -> if blacklisted, 401.
4. `fn_user_get_by_id(sub)` to confirm user is still active.
5. **Atomic blacklist (CRX-1 fix):** `fn_auth_blacklist_if_absent(hash, userId, expiresAt)` returns `{inserted: true}` only if THIS call wrote the row; concurrent racers see `{inserted: false}` and get 401. Closes the TOCTOU window.
6. Sign a NEW access JWT and a NEW refresh JWT (fresh `jti`).
7. Return `RefreshResponse` (both tokens). Client must replace BOTH.

### Logout (`POST /api/v1/auth/logout`)

1. Verify access JWT for authentication.
2. SHA-256 hash the refresh token from the body.
3. `fn_auth_blacklist_token(hash, userId, expiresAt)` (idempotent via `ON CONFLICT DO NOTHING`).

### Lockout & bcrypt

- `auth.maxFailedAttempts = 5`, `auth.lockoutMinutes = 15` (in `project.config.json`, passed to `fn_auth_record_login_failure`).
- bcrypt cost = 12 (in `src/utils/password.util.ts`). Do NOT lower without a security review.

---

## 4. AI Provider abstraction

`src/integrations/ai/` exposes a swappable provider interface.

```typescript
import { getAIProvider } from "@/integrations/ai";

const ai = getAIProvider();          // env-selected (AI_PROVIDER=openai|anthropic)
const text = await ai.generate(prompt, { maxTokens: 1000 });
const obj  = await ai.generateJSON(prompt, schema);
```

- **Primary:** OpenAI (`openai.provider.ts`). Models from env: `OPENAI_MODEL_DEFAULT=gpt-4o`, `OPENAI_MODEL_FAST=gpt-4o-mini`.
- **Future:** Anthropic stub (`anthropic.provider.ts`) - throws NotImplementedError until wired up.
- **Selector:** `AI_PROVIDER=openai` (default).

**M0 itself does not call any AI endpoint.** The abstraction is present so feature modules drop endpoints in without touching infrastructure. The 10 Lovable edge functions become 10 backend routes (`/api/ai/*`, `/api/contracts/extract*`, `/api/templates/extract`) in feature modules - see `prompts/_migration-notes.json` in the workspace for per-prompt deltas.

**Known follow-up (CRX-8):** the OpenAI provider currently has no explicit timeout or 429 backoff. Add a 30s timeout + capped exponential retry on 429/5xx before any AI feature ships in production.

---

## 5. Mailer

`src/integrations/mail/` wraps Nodemailer + SMTP.

```typescript
import { sendMail } from "@/integrations/mail";
await sendMail({ to: "x@y.com", subject: "...", template: "verify", vars: {...} });
```

Templates live in `src/integrations/mail/templates/`.

**Dev:** Mailpit local catcher (`docker run -p 1025:1025 -p 8025:8025 axllent/mailpit`). UI at http://localhost:8025. Email is captured, never sent.
**Prod:** any SMTP provider. Decided closer to go-live (Brevo / Mailtrap / Resend / SES / self-hosted Postfix). Switch is purely env-var driven; no code change.

Required env vars: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL`.

---

## 6. UAE Pass (mocked)

Per decisions.md G3, UAE Pass is mocked in M0. Routes exist on both BE and FE. Real federation is deferred - see `uae-pass-integration.md` for the pre-production checklist.

- `UAE_PASS_PROVIDER=mock` (default) -> `mock.provider.ts` returns a synthetic identity.
- `UAE_PASS_PROVIDER=live` -> `live.provider.ts` throws NotImplementedError until real wiring lands.

**State protection (CRX-3 fix):** `/auth/uae-pass/initiate` generates a 32-hex CSRF state, stores it with a 5-minute TTL in an in-memory Map (`state-store.ts`), and returns it. `/auth/uae-pass/callback` validates the state - missing, expired, or already-consumed -> 401.

**Known follow-up:** the in-memory state store is single-process. Before scaling beyond 1 replica, swap to Redis or a `uae_pass_state` DB table.

---

## 7. Frontend stack (preserved per developer decision)

The frontend is **TanStack Start + React 19 + Tailwind 4** - kept verbatim from the Lovable prototype per `project.config.json`'s `preserveStack: true`. Do **not** migrate to vanilla Vite + React Router; the developer chose this stack to maximize UI/UX preservation.

Key facts:
- **Routing:** `@tanstack/react-router` file-based routes under `src/routes/`. The route tree (`src/routeTree.gen.ts`) is auto-regenerated by the dev server and is gitignored.
- **State:** `@tanstack/react-query` + `zustand`. Auth store in `src/store/auth.store.ts`.
- **HTTP:** `axios` with a JWT interceptor + 401-refresh-and-retry pattern (`src/lib/api-client.ts`).
- **Forms:** `react-hook-form` + `@hookform/resolvers/zod` + Zod.
- **Design system:** Tailwind 4 CSS-first - tokens in `src/styles.css` `@theme inline`. OKLCH palette: ink / gold / sage / amber / terracotta / slate / plum. Dark mode toggled via `.dark` class. RTL via `html[dir="rtl"]`.
- **Theme provider:** `src/components/theme-provider.tsx` - dark mode + RTL.
- **i18n:** `react-i18next`. 2,990 EN keys + 2,990 AR keys (parity verified) + 12 dashboard.* keys added in M0.
- **SSR runtime:** Cloudflare Workers (`wrangler.jsonc` configured; deploy deferred per project config).

**Frontend files added in M0:**
```
src/
  routes/
    auth.login.tsx, auth.uae-pass.tsx, auth.uae-pass.callback.tsx
    app/index.tsx                  -- protected dashboard (M0 placeholder)
  services/
    auth.service.ts, user.service.ts, role.service.ts, permission.service.ts
  store/
    auth.store.ts                  -- Zustand (persist exclude: tokens? see CRX-7 follow-up)
  lib/
    api-client.ts                  -- axios + JWT + refresh-rotation interceptor
  i18n/
    en.json, ar.json               -- 2,990 + 12 keys each
```

---

## 8. Adding a new feature module

```bash
# From the framework root
cd "C:/Users/azureadmin/projects/Lovable Modernization"
# Run the slash command (in Claude Code)
/new-module
# This launches Phase 1: requirements-analyst, dependency-discovery, db-architect, contract-generator, qa-stage1, qa-stage2.
# Stops at HITL Gate 2 (DB design review). Run /approve-db to start Phase 2 implementation.
```

Phase 2 sequence: DB Implementation -> BE Implementation -> tsc -> FE Implementation (Harden Mode for Lovable components or Regenerate) -> tsc -> Integration Verifier -> Smoke Tests -> Testing Agent -> QA Stage 4 -> Codex adversarial review -> Documentation Generator (this agent) -> git commit.

When extending an existing M0 entity (e.g., adding a `phone` column to `"user"`):

1. New migration in `database/migrations/NNN_*.sql`. Include `-- ROLLBACK BEGIN` / `-- ROLLBACK END` markers.
2. Update `fn_user_create`, `fn_user_update`, `fn_user_get_by_id`, `fn_user_list` to handle the new field.
3. Update `src/types/api.types.ts` `User` / `UserListItem` / `CreateUserDto` / `UpdateUserDto`.
4. Update `src/schemas/user.schemas.ts` Zod schemas.
5. Run `/state-update` from the framework root to refresh the artifact store.

---

## 9. Sensitive fields

The 17 sensitive field names are codified in three places that must stay in sync:

1. `project.config.json` -> `sensitiveFields` (15 listed, project-wide superset).
2. `src/types/api.types.ts` -> `SENSITIVE_FIELD_NAMES` (17 - includes DB column names).
3. `database/migrations/00*_*.sql` -> `fn_audit_trigger` redact array (17 - matches #2).

Sensitive list:
```
contract_body, signer_email, signer_phone, emirates_id, signature_image,
ai_prompt_payload, password, password_hash, token_hash, refresh_token,
access_token, openai_api_key, anthropic_api_key, smtp_password,
uae_pass_client_secret, supabase_service_role_key, jwt_secret
```

**Pino redaction paths** (configured in `src/utils/logger.util.ts`):
- `req.body.password`, `req.body.refreshToken`, `req.body.accessToken`
- `req.headers.authorization`, `req.headers.cookie`
- `res.body.passwordHash`, `res.body.tokenHash`
- `loginUserRecord.passwordHash` (return type of `fn_auth_get_user_for_login`)

**Zustand persist exclusion:** Tokens currently persist to localStorage (CRX-7 follow-up - see below). Sensitive UI state (e.g., draft passwords) MUST be excluded via the partialize option.

**Never:** log a sensitive field, persist to localStorage outside auth tokens (and even those are flagged for refactor), embed in URLs, or expose in API error messages.

---

## 10. Known follow-ups (deferred work; track as GitHub issues)

These were surfaced during QA Stage 4 / Codex review but deferred from M0 as non-blocking:

| Item | Source | Action | Priority |
|---|---|---|---|
| Refactor Zustand auth -> httpOnly cookies + CSRF | Codex CRX-7 | Auth hardening sprint before production | High (production blocker) |
| Add OpenAI 30s timeout + 429 backoff | Codex CRX-8 | First feature module that wires AI endpoints | High (when AI ships) |
| Provision Neon `test` branch + `TEST_DATABASE_URL` | DB Impl §10 / SEC-12 | Before M1 - test isolation | High |
| Fix `<html dir>` SSR hydration mismatch | QA FE-20 | Frontend bug in route root | Medium |
| Resolve 753 prettier formatting issues | QA FE-22 | Run `npm run format` | Low (auto-fix) |
| Add unit tests for env-validation, errors, logger utils | QA BE-16 | Coverage gap | Medium |
| Document missing env vars (audit `.env.example` against code) | QA BE-11 | Doc gap | Low |
| **Bootstrap admin password rotation** | Manual action | Rotate `ChangeMe@123` on first login | **High (do this NOW)** |

---

## 11. Testing

- **Backend:** `npm test` -> Vitest. 23 tests passing in M0.
  - Integration tests run against the Neon `m0-foundation` branch (acceptable for M0; first feature module MUST provision a separate `test` branch for isolation).
  - `cross-env NODE_OPTIONS=--max-old-space-size=4096` is already configured to prevent OOM during integration runs.
- **Frontend:** `npm test` -> Vitest + jsdom. 16 tests passing in M0.
- **E2E smoke:** Playwright run executed during Phase 2 smoke test - report at `.claude/workspace/current-module/smoke-test-fe-report.md`.
- **Coverage targets** (per CLAUDE.md): lines/functions >= 90%, branches >= 80%. M0 coverage report: see `npm run test:coverage`.

---

## 12. Migrations

`database/migrate.ts` is the migration runner. Usage:

```bash
npm run migrate          # apply all pending migrations (UP)
npm run migrate:down     # rollback the latest applied migration (DOWN)
```

The runner reads each `.sql` file in `database/migrations/` (sorted by NNN prefix), looks up `schema_migrations`, and applies missing ones inside a transaction. The `-- ROLLBACK BEGIN` / `-- ROLLBACK END` markers in each file delimit the DOWN block.

Currently applied: `001_foundation`, `002_security_hardening`. Use the runner for all subsequent migrations.

---

*Generated by Documentation Generator. For ops/SRE concerns, see `ops-runbook.md`. For the per-component Lovable transformation log, see `lovable-handoff.md`.*

---
---

# M1a Implementation Notes — Contracts: Core CRUD & Lifecycle

> **Module:** M1a (first sub-module of split M1).
> **Generated:** 2026-05-03.
> **Verdict:** APPROVED (Codex BE round 1+2 + FE round 1; QA Stage 4 41/44 hard-gate PASS; 139/139 BE tests).

---

## Architecture summary

- **4 tables:** `contract`, `contract_tag`, `contract_version`, `contract_activity` (append-only timeline; not bound to `fn_audit_trigger`).
- **12 fn_ functions** (10 SECURITY INVOKER + 2 SECURITY DEFINER: `fn_contract_delete` for the TOCTOU-safe soft-delete and `fn_contract_activity_create` as the trigger-only writer to `contract_activity`).
- **2 activity-emit trigger functions** (`fn_trg_contract_activity_emit`, `fn_trg_contract_version_activity_emit`) bound by `trg_contract_activity_emit_iu` and `trg_contract_version_activity_emit`.
- **12 RLS policies** (3 RESTRICTIVE: `contract_deny_direct_delete`, `contract_deny_direct_is_active_update`, `contract_activity_deny_direct_insert`).
- **11 HTTP endpoints** under `/api/v1/contracts*`. S12 (system story — auto-emit activity) has no endpoint; covered by triggers.
- **Frontend:** Harden Mode pipeline. 3 components hardened from Lovable, 8 regenerated-light. 13-item Harden checklist applied across all 11 contract components — all 13 PASS.
- **Sequential implementation:** DB → BE → tsc → FE → tsc → Integration Verifier → Smoke (+4 patches) → Testing (139/139) → QA Stage 4 (41/44 hard-gate) → Codex BE (3 critical/high blockers) → DB patch 008 → Codex BE round 2 (APPROVED) → Codex FE (APPROVED with 3 medium follow-ups) → FE patches → Documentation.

---

## 13-item Harden checklist results

The Harden checklist was applied across all 11 contract components (3 hardened, 8 regenerated-light). FE Implementation Summary records all 13 PASS:

| Item | Description | Result |
|---|---|---|
| T1 | Data layer extraction (replace Supabase with services) | PASS |
| T2 | React Query wrapping (queries + mutations + invalidation) | PASS |
| T3 | i18n keys (no hardcoded strings) | PASS |
| T4 | Three data states (loading / empty / error) | PASS |
| T5 | Token replacement (no inline colors) | PASS |
| T6 | Accessibility (WCAG 2.1 AA) | PASS |
| T7 | Type safety (no `any`) | PASS |
| T8 | Form hygiene (zod + react-hook-form) | PASS |
| T9 | Destructive confirmation (modal + typed confirmation) | PASS |
| T10 | Debounce (search inputs - 300 ms) | PASS |
| T11 | Error boundary | PASS |
| T12 | Date/time handling (formatDateTime + Asia/Dubai) | PASS |
| T13 | Sensitive field protection (no log, no persist, no expose) | PASS |

3-cycle rule per component honoured. No developer waivers. Approximately 127 new i18n keys per locale added under the existing `contracts.*` namespace (sub-trees: `languageOptions`, `governingLawOptions`, `relationshipTypeOptions`, `fields`, `form`, `create`, `edit`, `detail`, `delete`, `status`, `tags`, `tree`, `versions`, `activity`, `toasts`).

---

## Codex review findings + how each was resolved

The Codex adversarial review caught three concurrency defects on the BE round 1 that QA Stage 4 missed (race conditions are notoriously hard to spot through code-pattern audits). All three were fixed in migration `008_m1a_concurrency_fixes.sql` and re-reviewed; round 2 verdict: APPROVED.

### Backend round 1 - blocking findings

| ID | Severity | File | Issue | Fix (in migration 008) |
|---|---|---|---|---|
| **BE-001** | critical | `fn_contract_create`, `fn_contract_update` | Parent soft-delete can race with child create/update. Unlocked active-row read of `parent_contract_id` lets a concurrent `fn_contract_delete` complete after the child's parent-active check, leaving an active child under an inactive parent (violates AC-S5-04). | Add `SELECT 1 FROM contract WHERE id = p_parent_id AND is_active = true FOR UPDATE` in all parent-assignment paths. |
| **BE-002** | high | `fn_contract_update` | Concurrent body updates create stale version snapshots. `v_existing` is read without FOR UPDATE; concurrent caller commits between read and version INSERT, producing a `contract_version` row that does not match the final committed `contract.body_*`. | Lock the contract row with `SELECT ... FOR UPDATE` before reading `v_existing` so the entire read-update-version sequence serialises per contract. |
| **BE-003** | high | `fn_contract_set_tags` | Tag-set replacement is not serialised. Two concurrent `[A]` -> `[B]` and `[A]` -> `[C]` callers each compute their diff from the same stale `[A]` snapshot, ending in `[B, C]` instead of one winner. | `SELECT 1 FROM contract WHERE id = p_id AND is_active = true FOR UPDATE` before reading the current tag set. |

All three patches applied to dev + test branches via migration 008. Codex round 2: all three resolved; **APPROVED**.

### Frontend round 1 - non-blocking medium findings (deferred)

| ID | Severity | Issue | Resolution |
|---|---|---|---|
| **FE-C1** | medium | Create / edit / version-create forms don't actively reset `bodyEn` / `bodyAr` on unmount (memory hygiene). T13 logging passed; this is defence-in-depth. | **Patched** - added `useEffect(() => () => form.reset({...}), [])` to RHF forms; clear dialog body state on close in `ContractVersionCreateDialog`. |
| **FE-C2** | low | Route id validation uses `Number.parseInt`; `123abc` accepted as `123`. | **Patched** - added strict `/^[1-9]\d*$/` regex pre-check before `parseInt` in `routes/app/contracts.$id.tsx`. |
| **FE-C3** | medium | Privileged actions render unconditionally (create / delete / status / edit / version / tags). BE 403 is the only gate. | **Patched** - gated the 6 controls with `selectHasPermission` from `auth.store`; BE remains the source of truth. |
| **FE-C4** | trivial | Modal focus trap missing - Tab can escape `ContractDeleteDialog` / `ContractStatusDialog` / `ContractVersionCreateDialog`. | **DEFERRED to M1b/M2**: full focus-trap helper (`@react-aria/dialog`) adoption is broader than M1a scope. QA Stage 4 F3 also flagged as trivial. |
| **FE-C5** | medium | API errors displayed as raw `ApiError.message` in toasts and route error states. | **Patched** - mapped `ApiError.code` / `status` / `details.field` to stable i18n keys (`contracts.errors.*`); generic localised fallback for unmapped codes. |
| **FE-C6** | low | `ChevronRight` in breadcrumb does not flip in RTL. | **Patched** - flipped via CSS `[dir=rtl]` transform. |

Round 2 / FE re-verify: 0 critical + 0 high; FE-C4 deferred with explicit M1b TODO.

---

## Test coverage

**Backend:** 139/139 tests passing on the dedicated Neon `test` branch (migrations 001..008 applied).

| File | Scope | Tests |
|---|---|---|
| `tests/integration/M1a-contracts.test.ts` | S1..S12 (all 11 endpoints + system trigger story) | 50 |
| `tests/unit/contracts.schemas.test.ts` | All Zod schemas (CreateContractDto, UpdateContractDto, etc.) | 36 |
| `tests/unit/db-client-translator.test.ts` | M1a STRUCTURED_RAISE_RE branches + RLS denial mapping | 9 |
| Pre-existing M0 suites (auth, health, jwt, password, uae-pass-state-store) | M0 carry-over | 38 (re-confirmed PASS) |
| Concurrency regression (BE-001/002/003) | Two-connection races | 6 |
| **Total** | | **139** |

**Coverage** (vitest gate thresholds: lines 60 / functions 60 / branches 50 / statements 60 - all PASS):

| Metric | Actual | Gate (PASS) | Aspirational (CLAUDE.md §11) |
|---|---|---|---|
| Lines | 73.09% | 60 | 90 |
| Statements | 73.09% | 60 | 90 |
| Functions | 75.28% | 60 | 90 |
| Branches | 65.28% | 50 | 80 |

**Frontend unit tests:** none added in M1a — explicit follow-up. The 11 components are exercised through the integration suite (BE) and Playwright smoke (FE-side). Component-level Vitest tests for Harden-checklist invariants are recommended for M1b.

Branch-coverage gap concentrated in: schema cross-field error paths, AC-S2-03 403-vs-404 branch, `translatePgError` SQLSTATE variants, `fn_contract_delete` GUC reset path. Recommended Testing Agent gap pass before M1b.

---

## Known M1a placeholders

The M1a slice ships placeholders that downstream modules will replace. They are explicitly called out so M1b/M2/Parties developers do not mistake them for production-grade behaviour.

| Placeholder | Location | Replacement |
|---|---|---|
| Role-aware filtering uses `drafted_by` / `reviewed_by` / `approved_by` as a stand-in for party-membership and approval-pending. | `contract_select_role_aware` RLS policy; `fn_contract_list` and `fn_contract_get_by_id` role-aware WHERE clauses. | **Parties module:** join `party_member.user_id = current_user`. **M2 (approvals):** join `approvals` WHERE `status='pending' AND approver_id = current_user`. |
| `fn_contract_status_update` accepts any-from-any transition (only enum membership validated). | `fn_contract_status_update`. | **M2:** state-machine-aware fn variant that enforces the legal transition graph. |
| `template_id`, `our_party_id`, `counterparty_id`, `import_batch_id` are nullable BIGINT with no FK constraint in M1a. | `contract` table DDL (003). | **Templates module / Parties module / M1c** add `ALTER TABLE contract ADD CONSTRAINT ... FK ... ON DELETE ...` once those tables exist. |
| `attachmentCount` and `commentCount` are inline numeric fields in `fn_contract_get_by_id` payload. | `fn_contract_get_by_id`. | **Attachments module / Comments module:** wire real counts from `contract_attachment` / `contract_comment` joins. |
| AI fields (`ai_risk_score`, `ai_summary_*`) are read-only in M1a. | `contract` table. | **M4 (AI):** `fn_ai_*` writers populate from background jobs. |
| Import fields (`import_batch_id`, `import_confidence`, `import_filename`, `import_warnings`) are read-only in M1a. | `contract` table. | **M1c (Bulk Import):** `fn_contract_import_create` populates. |

Migration 006 (Super Admin grant) is also a placeholder for a future role consolidation: `platform_admin` was inserted alongside the M0 `Super Admin` row per Q2 / W1 (do not delete Super Admin); a future migration may consolidate them.

---

## Forward-FK strategy

For each forward-referenced table not yet created at M1a time, the M1a column is `BIGINT NULLABLE` with **no FK constraint**. The owning module's migration adds the FK via `ALTER TABLE contract ADD CONSTRAINT ... FOREIGN KEY (col) REFERENCES other_table(id) ON DELETE ...`. This avoids a hard-ordering dependency between M1a and `Parties` / `Templates` / `M1c` / `Attachments` / `Comments`.

| Column | Future FK |
|---|---|
| `template_id` | `contract_template(id) ON DELETE SET NULL` (M1b / Templates module). |
| `our_party_id` | `party(id) ON DELETE RESTRICT` (Parties module). |
| `counterparty_id` | `party(id) ON DELETE RESTRICT` (Parties module). |
| `import_batch_id` | `import_batch(id) ON DELETE SET NULL` (M1c). |

Indexes for these columns already exist (`idx_contract_template_id`, `idx_contract_our_party_id`, `idx_contract_counterparty_id`, `idx_contract_import_batch_id`) so the FK ALTER will not require an index build.

---

## How to extend M1a

**To add a new contract field** (e.g. `payment_term_days INTEGER`):

1. New migration `database/migrations/NNN_*.sql` with `-- ROLLBACK BEGIN` / `-- ROLLBACK END` markers. `ALTER TABLE contract ADD COLUMN payment_term_days INTEGER`.
2. Update `fn_contract_create`, `fn_contract_update` (COALESCE pattern) and `fn_contract_get_by_id`, `fn_contract_list` (JSONB output).
3. Update TS types: `src/types/contracts.types.ts` (Contract, CreateContractDto, UpdateContractDto, ContractListItem).
4. Update Zod schemas: `src/schemas/contracts.schemas.ts`.
5. Update FE: `src/types/entities/contract.types.ts`; add field to `ContractFormFields.tsx` (shared by create + edit).
6. Add i18n keys for the field label + form helper text.
7. Run `/state-update` from the framework root.

**To add a new contract operation** (e.g. duplicate-as-amendment):

1. New `fn_contract_*` function in a fresh migration.
2. Add controller method + route + Zod schema following `contracts.controller.ts` / `contracts.routes.ts` patterns.
3. Add FE service method + React Query hook in `contracts.service.ts` / `useContracts.ts`.
4. Add a UI affordance (button + dialog) in the appropriate Harden component.
5. Tests: integration test against the new endpoint + unit tests on new schema branches.

**To add a new activity_type:**

1. `ALTER TABLE contract_activity DROP CONSTRAINT ... ADD CONSTRAINT ... CHECK (activity_type IN (... new value))` — keep the order alphabetical to minimise diffs.
2. Add the corresponding `fn_contract_activity_create` call site (typically a new trigger or an explicit emission in a fn_).
3. Update FE: `ContractActivityLog.tsx` icon-per-type tone palette + i18n keys.

---

## File map (M1a-owned)

**Backend (5 created + 5 modified):**
- Created: `src/types/contracts.types.ts`, `src/schemas/contracts.schemas.ts`, `src/controllers/contracts.controller.ts`, `src/routes/v1/contracts.routes.ts`.
- Modified: `src/database/client.ts` (translator + `db.checkActiveRowExists` helper), `src/utils/errors.util.ts` (extended `NotFoundError` with optional details), `src/middleware/auth.middleware.ts` (`authoriseAnyOf` OR-semantics middleware), `src/utils/logger.util.ts` (M1a redact paths), `src/routes/v1/index.ts` (mount).
- Migrations: `database/migrations/003_m1a_contracts.sql`, `004_m1a_extend_sensitive_fields.sql`, `005_m1a_contract_functions.sql`, `006_m1a_grant_super_admin_contract_permissions.sql`, `007_m1a_fix_total_pages_zero.sql`, `008_m1a_concurrency_fixes.sql`.

**Frontend (21 created + 4 modified):**
- Types / services / hooks: `src/types/entities/contract.types.ts`, `src/services/api/contracts.service.ts`, `src/features/contracts/hooks/useContracts.ts`.
- Components: `ContractStatusBadge`, `ContractListView`, `ContractDetail`, `ContractCreateForm`, `ContractEditForm`, `ContractDeleteDialog`, `ContractStatusDialog`, `ContractTreeTimeline`, `ContractTagsEditor`, `ContractVersionList`, `ContractVersionCreateDialog`, `ContractActivityLog`, `ContractFormFields`, `contract-form-schema.ts`.
- Routes: `src/routes/app/contracts.index.tsx`, `contracts.$id.tsx`, `contracts.new.tsx`.
- Modified: `src/components/common/index.ts` (export ErrorBoundary), `src/i18n/en.json` + `ar.json` (~127 keys per locale), `src/routeTree.gen.ts` (auto).

---

*Generated by Documentation Generator from M1a workspace specs + implementation summaries + QA Stage 4 + Codex review reports.*

---

# M1b Implementation Notes — Compose Wizard, Payment Schedules & Exports

> **Module:** M1b (second sub-module of split M1).
> **Generated:** 2026-05-03.
> **Verdict:** APPROVED (Codex BE rounds 1+2 + Codex FE rounds 1+2; QA Stage 4 41 PASS / 3 WARN / 0 FAIL; 218/218 BE tests + 28/28 FE tests = 246 total). Migration head = 15.

---

## Architecture summary

- **1 new table:** `payment_schedule` (17 columns: 13 Lovable after dropping `is_seed` + 4 audit/soft-delete; 4 RLS policies — 3 PERMISSIVE + 1 RESTRICTIVE deny-direct-DELETE).
- **5 new fn_ functions** (4 user-facing + 1 SECURITY DEFINER audit helper):
  - `fn_payment_schedule_list` (INVOKER STABLE)
  - `fn_payment_schedule_create_bulk` (INVOKER + SELECT FOR UPDATE on parent — Codex BE-001 pattern)
  - `fn_contract_export_pdf` (INVOKER STABLE post-migration 015 — controller is the sole `exported` activity emitter)
  - `fn_contract_export_xlsx` (INVOKER STABLE)
  - `fn_audit_log_record` (DEFINER, REVOKE PUBLIC, GRANT neondb_owner only — sole insertion point for the XLSX `audit_log` row)
- **4 new HTTP endpoints** (under `/api/v1/contracts*`) — total contracts surface now 11 M1a + 4 M1b = 15:
  - `GET /contracts/export.xlsx` (literal — declared FIRST in routes file per W1)
  - `GET /contracts/:id/payment-schedules`
  - `PUT /contracts/:id/payment-schedules`
  - `GET /contracts/:id/export.pdf`
- **11 new FE files (compose wizard + payment schedule + exports + shared utils)** + 2 modified M1a dialogs (focus-trap backfill — closes M1a deferred FE-C4):
  - 5 wizard step / shell files (`ComposeWizard.tsx`, `Step1Type.tsx`, `Step2Parties.tsx`, `Step3Terms.tsx`, `Step5Review.tsx`)
  - 2 payment-schedule UI components (`PaymentScheduleTab.tsx`, `PaymentScheduleEditor.tsx`)
  - 2 export UI components (`ExportPdfDialog.tsx`, `ExportXlsxButton.tsx`)
  - 2 shared utilities (`useFocusTrap.ts`, `format-blob-download.ts`)
- **7 migrations applied** (009..015): 009 (table+indexes+RLS), 010 (CMW-1 enum extend + CMW-2 drafter export grant), 011 (5 fn_'s), 012 (DB Impl patch — `text[] <@ varchar[]` operator-resolution fix), 013 (Smoke patch — `fn_contract_activity_create` whitelist extension), 014 (Codex BE-M1b-006 — RLS WITH CHECK), 015 (Codex BE-M1b-004 — strip PDF activity emit).
- **Cross-module write:** `contract.export` permission grant added to `contract_drafter` role (CMW-2, idempotent).
- **Sequential implementation:** DB → BE → tsc → FE → tsc → Integration Verifier (0 mismatches) → Smoke (+2 patches) → Testing (218/218 BE + 28/28 FE) → QA Stage 4 (41 PASS / 3 WARN) → Codex BE round 1 (6 findings, all patched in 014/015 + controllers/services) → Codex BE round 2 (APPROVED) → Codex FE round 1 (5 findings, all patched) → Codex FE round 2 (APPROVED with FE-R2-001 micro-fix) → Documentation.

---

## 13-item Harden checklist results

| Item | Description | Result |
|---|---|---|
| T1 | Data layer extraction (services + apiClient — F-FE-001 ensures Axios 401-refresh applies to exports) | PASS |
| T2 | React Query wrapping (queries + mutations + invalidation) | PASS |
| T3 | i18n keys (no hardcoded strings — 5 new namespaces, en/ar parity preserved at 3262 keys post-FE patches) | PASS |
| T4 | Three data states (loading skeleton, error+retry, empty+CTA) — verified across PaymentScheduleTab, ExportPdfDialog, ExportXlsxButton | PASS |
| T5 | Token replacement (no inline colors) | PASS |
| T6 | Accessibility (WCAG 2.1 AA) — `aria-live="polite"` on wizard step body; `role="alert"` on 403 branch; `useFocusTrap` applied to all 5 dialogs | PASS |
| T7 | Type safety (no `any`) | PASS |
| T8 | Form hygiene (zod + react-hook-form) | PASS |
| T9 | Destructive confirmation | **N/A** — M1b has no destructive ops; bulk replace on payment schedule uses Save-button confirmation rather than typed-confirm modal. |
| T10 | Debounce (search inputs — wizard state localStorage save debounced 300ms per CLAUDE.md §5) | PASS |
| T11 | Error boundary (ComposeWizard route wrapped in M0 ErrorBoundary + lazy-loaded) | PASS |
| T12 | Date/time handling (`formatDate` / `formatDateTime` from `@/utils/datetime` in PaymentScheduleTab L189-192; no inline `toLocale*`) | PASS |
| T13 | Sensitive field protection — `bodyEn`/`bodyAr` cleared from React state on ComposeWizard unmount (FE-C1 pattern); localStorage retention guarded by 24h TTL envelope (F-FE-M1 fix) | PASS |

3-cycle rule honoured. No developer waivers. Approximately 5 new i18n key namespaces added under existing `contracts.*`: `contracts.compose`, `contracts.paymentSchedule`, `contracts.export.pdf`, `contracts.export.xlsx`, `contracts.detail.tabs.payments`.

### useFocusTrap shared utility (closes M1a FE-C4)

`src/components/common/useFocusTrap.ts` (180 lines) introduced in M1b and applied to **all** dialogs in the contracts surface — the 3 M1a dialogs that flagged FE-C4 (ContractDeleteDialog, ContractStatusDialog, ContractVersionCreateDialog) plus the 2 new M1b dialogs (PaymentScheduleEditor, ExportPdfDialog). M1a's deferred trivial finding is fully closed in M1b.

---

## Compose Wizard — FE-only orchestration (Q2)

The Compose Wizard is **pure FE orchestration** — there is **NO** new BE wrapper endpoint (`fn_contract_create_with_schedule` was rejected at HITL Gate 2 / Q2 in favour of Option (b)). Submit handler is a single async function calling two existing endpoints in sequence:

| Step | Call | Module | DB function | Failure handling |
|---|---|---|---|---|
| 1 | `POST /api/v1/contracts` | M1a | `fn_contract_create` | Show error toast; keep wizard state in localStorage. NO partial cleanup needed — no rows written. |
| 2 | `PUT /api/v1/contracts/{newContractId}/payment-schedules` | M1b | `fn_payment_schedule_create_bulk` (with `p_replace_existing=true`) | AC-S1-08: KEEP localStorage draft. Retry button re-attempts STEP 2 ONLY (the contract already exists in draft state; drafts can validly exist without a payment schedule). DO NOT roll back the contract. |

Wizard state persists to `localStorage` per input change (debounced 300ms). Storage key: `compose-draft:{userId}:{composeDraftId}`. Submit handler shares a single React Query mutation envelope so loading/error states propagate to the Submit button. Wizard route is gated by `contract.draft` permission (AC-S1-09) — 403 page shown to users without it.

**Step 4 (Attachments) is SKIPPED** — wizard advances Step 3 → Step 5 directly. `ComposeWizardStep4Attachments` type reserved for the Attachments module. Party / Template / Clause pickers are DISABLED with deferred-banner notes (Q1 Option (d)) — see lovable-handoff for TODO markers.

**Double-submit guard (Codex F-FE-002 fix):** `useComposeSubmit.ts` introduces `submittingRef = useRef(false)` synchronously flipped on entry to both `submit()` and `retryStep2()` BEFORE any await. Lock held across the full POST→PUT sequence. Prevents duplicate-contract creation on rapid double-click.

---

## Puppeteer pool service architecture (Codex BE-M1b-003)

`src/services/export/puppeteer-pool.service.ts` is a singleton browser pool with three exports:

- `withPage(fn)` — acquires a page from the singleton browser via `p-limit(PUPPETEER_MAX_CONCURRENT)` semaphore (default 2, hard cap 16). Closes the page in a `finally`; the browser is reused.
- `closePuppeteerBrowser()` — idempotent shutdown helper invoked from `server.ts` graceful-shutdown handler between `closePool()` and `telemetry.shutdown()`.
- The original `puppeteer.launch()` call site in `contract-pdf.service.ts` is removed; `renderContractPdf` now calls `withPage(async (page) => …)`.

**Why:** before this patch, every `/export.pdf` request launched a new headless Chromium (~50–100 MB process spin-up). Concurrent requests under the export rate-limit could exhaust memory. The pool reuses one browser across all renders and bounds page-level concurrency.

Container shutdown is reaped by `dumb-init` (Dockerfile ENTRYPOINT) so the singleton Chromium child terminates cleanly on SIGTERM.

---

## W1 route-ordering constraint

**Critical:** `GET /api/v1/contracts/export.xlsx` is a literal path. In Express, route matching is order-sensitive. The literal route MUST be declared BEFORE any `/:id`-prefixed routes — otherwise the path binds `:id='export.xlsx'` and fails `PositiveBigIntSchema` with 400 instead of reaching the export controller.

Implementation: `src/routes/v1/contracts.routes.ts`
- L73-80: `GET /export.xlsx` (literal — declared FIRST).
- L109+: any `:id` matchers (M1a list/create through M1b PDF + payment schedules).
- L14-25: an inline comment block documents the rule explicitly.

**Smoke verification:** unauthenticated `GET /api/v1/contracts/export.xlsx` returns `401 Unauthenticated` (the router-level `authenticate` middleware fires first). If it returns `400 'Must be a positive integer'`, the route is ordered wrong.

---

## Codex review findings + how each was resolved

The Codex adversarial review caught 11 issues across two surfaces (BE round 1: 6 findings; FE round 1: 5 findings). All resolved before round 2; both round-2 verdicts: **APPROVED**.

### Backend round 1 findings

| ID | Severity | File | Issue | Fix |
|---|---|---|---|---|
| **BE-M1b-001** | HIGH | `contracts.controller.ts exportXlsx` | Audit row emitted before workbook renders → if render throws, audit row is committed without delivery. | Reorder: render first, then `fn_audit_log_record` (with own try/catch — non-fatal warn), then `res.send(buffer)`. |
| **BE-M1b-002** | HIGH | `services/export/contract-xlsx.service.ts` | Formula injection in dynamic XLSX cells (`=HYPERLINK(...)`, `+SUM(...)`, `@cmd|...`). | New `sanitizeCellValue` helper prefixes `\t` to dynamic strings whose first non-whitespace char is `= + - @`. Numbers/dates/booleans untouched. |
| **BE-M1b-003** | HIGH | `services/export/contract-pdf.service.ts` + new `puppeteer-pool.service.ts` | Per-request Puppeteer browser launch — DoS via memory exhaustion. | Singleton browser + `withPage()` + `p-limit(N)` semaphore (default 2). Graceful shutdown awaits `closePuppeteerBrowser()`. |
| **BE-M1b-004** | MEDIUM | `fn_contract_export_pdf` + `controllers/contracts.controller.ts exportPdf` | PDF audit emission inside the fn_ — incompatible with STABLE; ordering inconsistent with XLSX. | Migration 015 strips activity emit from fn_; controller emits `contract_activity('exported')` AFTER successful render. |
| **BE-M1b-005** | MEDIUM | `database/client.ts translatePgError` | SQLSTATE 23514 (check_violation) unmapped — leaked raw constraint name. | `case '23514' → ValidationError('Data violates database constraint', { check: 'invalid' })`. |
| **BE-M1b-006** | MEDIUM (DB) | RLS `payment_schedule_update_parent_writable` | `WITH CHECK (TRUE)` allowed privilege escalation by repointing `contract_id`. | Migration 014 DROP + CREATE with WITH CHECK mirroring USING. |

### Frontend round 1 findings

| ID | Severity | File | Issue | Fix |
|---|---|---|---|---|
| **F-FE-001** | HIGH | `services/api/contract-export.service.ts` | Direct `fetch` bypassed Axios 401-refresh interceptor. | Rewritten to `apiClient.get<Blob>` with `responseType: 'blob'`. |
| **F-FE-002** | HIGH | `wizard/useComposeSubmit.ts` | Double-submit created duplicate contracts. | `submittingRef = useRef(false)` synchronous guard. |
| **F-FE-M1** | MEDIUM | `wizard/useComposeDraft.ts` | Sensitive body retained in localStorage indefinitely. | `_savedAt` envelope + 24h TTL eviction; round-2 FE-R2-001 closed legacy-draft re-leak. |
| **F-FE-M2** | MEDIUM | `lib/translate-api-error.ts` + i18n | Export error toasts indistinguishable across 401/403/429. | Per-namespace lookup + RATE_LIMITED → CODE_TO_KEY; `errors.export.failed` fallback. |
| **F-FE-M3** | MEDIUM | `lib/format-blob-download.ts` | Blob downloads accepted any 200 Content-Type. | Optional `expectedContentType` parameter + `BlobContentTypeMismatchError`. |

### Round 2

- **BE round 2:** APPROVED. All 6 findings PASS. Round 2 added test coverage only (no behaviour changes).
- **FE round 2:** APPROVED (with one micro-fix FE-R2-001 — round-1 legacy-draft fallback re-leak in `useComposeDraft.ts`; closed in this round).

---

## Test coverage

**Backend:** 218/218 tests passing (139 M0+M1a baseline + 64 M1b new + 5 Codex regression + 10 round-2 additions).

| File | Scope | Tests |
|---|---|---|
| `tests/integration/M1b-contracts.test.ts` | All 5 stories. Locks DB-PATCH-1, BE-PATCH-1, migration 012/013 | 22 |
| `tests/unit/payment-schedule.schemas.test.ts` | All Zod schemas (enums, single-row, bulk replace superRefine, list/PDF/XLSX query, audit-log helper) | 32 |
| `tests/unit/contract-pdf.service.test.ts` | HTML template, RTL/LTR dir, env override, browser cleanup-on-throw, BE-M1b-003 pool reuse + closeBrowser idempotency | 4 + 2 |
| `tests/unit/contract-xlsx.service.test.ts` | Sheet + headers + row mapping, truncation footer, empty workbook, BE-M1b-002 formula-injection sanitiser | 3 + 2 |
| `tests/unit/db-client-jsonb-array.test.ts` | BE-PATCH-1 regression — arrays of objects vs primitives | 3 |
| `tests/unit/db-client-translator.test.ts` | BE-M1b-005 23514 mapping (+ M1a translations carried over) | +1 |
| Pre-existing M0+M1a suites | Carry-over | 139 (re-confirmed PASS) |
| **Total** | | **218** |

**Frontend:** 28/28 tests passing (M1b is the first module to ship FE unit tests — M1a deferred). Includes the new `tests/unit/contract-export-service.test.ts` for F-FE-001 regression (2 tests).

**Coverage** (vitest gate thresholds: lines 60 / functions 60 / branches 50 / statements 60 — all PASS):

| Metric | Actual | Gate (PASS) | Aspirational (CLAUDE.md §11) |
|---|---|---|---|
| Lines | 77.44% | 60 | 90 |
| Statements | 77.44% | 60 | 90 |
| Functions | 78.94% | 60 | 90 |
| Branches | 70.25% | 50 | 80 |

**M1b-authored files alone are at 99–100% lines / 88–96% branches.** The aggregate drag is M1a controller methods carried over. Per QA Stage 4 §F, WARN does not block.

Specific deferred coverage paths are documented in `m1b-test-coverage-gaps.md` (parallel to `m1a-test-coverage-gaps.md`):
- 403-forbidden ACs (S3-03, S4-04, S5-03, S5-04) — bootstrap admin holds all permissions; need fixture users.
- 429-rate-limit ACs (S4-09, S5-10) — `exportRateLimiter` short-circuits when `NODE_ENV=test`.
- HTTP-level `X-Export-Truncated` boundary (>50,000 contracts) — covered at renderer-unit level only.

---

## How to extend M1b

**To add a new payment-schedule field** (e.g. `currency CHAR(3) DEFAULT 'AED'`):

1. New migration `database/migrations/NNN_*.sql` with rollback markers. `ALTER TABLE payment_schedule ADD COLUMN currency CHAR(3) DEFAULT 'AED'`.
2. Update `fn_payment_schedule_create_bulk` per-row read + INSERT path.
3. Update `fn_payment_schedule_list` JSONB output.
4. Update TypeScript: `src/types/payment-schedule.types.ts` (`PaymentSchedule`, `PaymentScheduleCreateDto`).
5. Update Zod: `src/schemas/payment-schedule.schemas.ts`.
6. Update FE entity types + `PaymentScheduleEditor` + i18n keys.
7. Run `/state-update`.

**To add a new export format** (e.g. CSV):

1. New `fn_contract_export_csv` function in a fresh migration (or reuse `fn_contract_export_xlsx` data prep + new renderer service).
2. New `src/services/export/contract-csv.service.ts` renderer.
3. New controller method + route. **Critical:** if the route is a literal path (e.g. `/contracts/export.csv`), declare it BEFORE any `/:id` matcher — see W1.
4. Apply `exportRateLimiter` middleware.
5. Permission gate: `authoriseAnyOf(READ_ANY) + authorise(['contract.export'])`.
6. Add audit emission via `fn_audit_log_record` (XLSX pattern) OR a new `contract_activity` enum value (PDF pattern — requires migration 010-style CHECK extension + 013-style whitelist extension).

---

## Files owned by M1b

**Backend (5 created + 6 modified):**
- Created: `src/types/payment-schedule.types.ts`, `src/schemas/payment-schedule.schemas.ts`, `src/middleware/export-rate-limit.middleware.ts`, `src/services/export/contract-pdf.service.ts`, `src/services/export/contract-xlsx.service.ts`, `src/services/export/puppeteer-pool.service.ts` (Codex BE-M1b-003).
- Modified: `src/controllers/contracts.controller.ts` (+ 4 methods), `src/routes/v1/contracts.routes.ts` (+ 4 routes with W1 ordering), `src/database/client.ts` (BE-M1b-005 23514 mapping + BE-PATCH-1 JSONB array bind), `src/server.ts` (graceful-shutdown awaits puppeteer pool close), `package.json` (+ puppeteer ^24.42.0, exceljs ^4.4.0, p-limit ^3.1.0), `package-lock.json`, `.env.example`, `Dockerfile`.
- Migrations: 009, 010, 011, 012 (DB Impl patch), 013 (Smoke patch), 014 (BE-M1b-006), 015 (BE-M1b-004).
- Tests: `tests/integration/M1b-contracts.test.ts`, `tests/unit/payment-schedule.schemas.test.ts`, `tests/unit/contract-pdf.service.test.ts`, `tests/unit/contract-xlsx.service.test.ts`, `tests/unit/db-client-jsonb-array.test.ts`, `tests/helpers/m1b-helpers.ts`.

**Frontend (19 created + 8 modified):**
- Types / services / hooks: `src/types/entities/payment-schedule.types.ts`, `src/services/api/payment-schedule.service.ts`, `src/services/api/contract-export.service.ts`, `src/features/contracts/hooks/usePaymentSchedule.ts`.
- Wizard: `src/features/contracts/wizard/{ComposeWizard, useComposeDraft, useComposeSubmit, compose-wizard-schemas}.ts(x)` + 4 step files (`Step1Type`, `Step2Parties`, `Step3Terms`, `Step5Review`).
- Components: `PaymentScheduleTab.tsx`, `PaymentScheduleEditor.tsx`, `ExportPdfDialog.tsx`, `ExportXlsxButton.tsx`.
- Shared utilities: `src/components/common/useFocusTrap.ts`, `src/lib/format-blob-download.ts`.
- Routes: `src/routes/app/contracts.compose.tsx`.
- Modified: 3 M1a dialogs (focus-trap backfill — closes FE-C4: `ContractDeleteDialog`, `ContractStatusDialog`, `ContractVersionCreateDialog`) + `ContractListView.tsx` + `ContractDetail.tsx` (export buttons + payment schedule tab) + `i18n/en.json` + `i18n/ar.json` (3257 → 3262 keys post-FE-M2 patches; en/ar parity preserved) + `routeTree.gen.ts` (auto-regenerated by Vite).

---

*Generated by Documentation Generator from M1b workspace specs + implementation summaries + QA Stage 4 + Codex review reports (BE rounds 1+2; FE rounds 1+2).*

---

# M3 Implementation Notes — Signatures + Signer Q&A AI

> **Module:** M3 (sixth module; M0 + M1a + M1b + M1c + M2 shipped).
> **Generated:** 2026-05-04.
> **Verdict:** QA Stage 4 PASS-WITH-WARNINGS (40/40 standard + 17/17 active L1-L20 + 5/5 S2-16..S2-20 + 5/5 M3-specific including PUBLIC-grant enumeration; 1 WARN on Coverage instrumentation, non-blocking). 70/70 generated tests pass; 18 BE failures are pre-existing (CURRENT-PROJECT-STATE.md note 11). Migration head = 39. Codex adversarial review SKIPPED per Dexian decision 2026-05-04 (Stage 2 + Stage 4 absorb safety net via S2-16..S2-20 + L1-L20 lesson scan + new candidate S2-21 enumerate-PUBLIC-grants).

---

## Architecture summary

- **6 new tables** (4 transactional + 2 reference). 18 of 20 RLS policies are RESTRICTIVE deny-direct-write — all writes flow through fn_'s.
- **11 new fn_** (5 PUBLIC SECURITY DEFINER token-bearer + 5 INVOKER + 1 cron-only DEFINER neondb_owner-only). All 5 PUBLIC fn_'s authenticate by SHA-256 hashing the plaintext token from URL path inside the fn body.
- **3 extended fn_** (CC-1 fn_contract_status_update_internal, AE-1 fn_contract_activity_create, CC-2 fn_audit_trigger) — body byte-for-byte preserved vs canonical M0/M2 source except the cited diff (S2-19 mandate).
- **3 new permissions** + **10 role_permission rows** (drafter explicitly NOT granted `signature.cancel` per AC-S8-03).
- **35 indexes**, **20 RLS policies**, **4 audit triggers** (vs 6 designed — DB Impl I-1), **3 immutability/append-only triggers**.
- **10 new HTTP endpoints** across 4 routers — 5 JWT-authenticated, **5 verify_jwt=false** under `/api/v1/sign/*` (the FIRST verify_jwt=false namespace in the project).
- **1 cron driver:** `src/services/signature-expiration.cron.service.ts` (mirrors approval-escalation cron pattern). Env-driven schedule, disabled in `NODE_ENV=test`.
- **1 SSE endpoint:** `POST /sign/:invitationToken/qa/message` (`Content-Type: text/event-stream`) — the ONLY streaming endpoint in the project.
- **5 Lovable signing components regenerated** (none hardened) — see `lovable-handoff.md` M3 section for the regenerate-vs-harden decision matrix.
- **Sequential implementation:** DB → BE → tsc → FE → tsc → Integration Verifier R1 (FAIL → 038/039 patches) → R2 (PASS) → Smoke + Testing (70/70 generated PASS) → QA Stage 4 (PASS-WITH-WARNINGS) → Documentation. Codex review skipped (Dexian decision).

---

## How to test the public sign flow (no JWT)

The 5 endpoints under `/api/v1/sign/*` use `verify_jwt=false` middleware — there is no Authorization header. Authentication is server-side via SHA-256 hash-and-match of the `invitation_token` plaintext (and `session_token` for /qa/message).

### Local end-to-end smoke

```bash
# 1. As a drafter (JWT) — create signer roster + send for signature.
#    Capture invitationTokenPlaintext from the response (returned ONCE).
ACCESS_TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"admin@musanad.local","password":"ChangeMe@123"}' | jq -r .accessToken)

CONTRACT_ID=42  # an approved contract with an approved approval_chain

curl -s -X POST "http://localhost:4000/api/v1/contracts/$CONTRACT_ID/signature-parties" \
  -H "authorization: Bearer $ACCESS_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"signers":[{"signerSide":"employer","signerNameEn":"Faisal","signerEmail":"faisal@e.example","stepOrder":1,"isRequired":true}]}'

# Capture the invitationTokenPlaintext — pino-redacted in logs but in the JSON response body.
INVITATION_TOKEN=$(curl -s -X POST "http://localhost:4000/api/v1/contracts/$CONTRACT_ID/send-for-signature" \
  -H "authorization: Bearer $ACCESS_TOKEN" -H 'content-type: application/json' -d '{}' \
  | jq -r '.data.invitations[0].invitationTokenPlaintext')

# 2. PUBLIC — fetch the signer landing payload (no Authorization header).
curl -s "http://localhost:4000/api/v1/sign/$INVITATION_TOKEN" | jq
# Expect: signer.email is masked (j***@example.com); body truncated to 4000 chars; availableMethods[].

# 3. PUBLIC — sign with a typed signature.
curl -s -X POST "http://localhost:4000/api/v1/sign/$INVITATION_TOKEN/sign" \
  -H 'content-type: application/json' \
  -d '{"signatureMethod":"typed","signatureData":"Faisal Al Mazrouei"}' | jq

# 4. PUBLIC — start a Q&A session + post a message.
SESSION_TOKEN=$(curl -s -X POST "http://localhost:4000/api/v1/sign/$INVITATION_TOKEN/qa/session" \
  -H 'content-type: application/json' -d '{"language":"en"}' \
  | jq -r '.data.sessionTokenPlaintext')

curl -N -X POST "http://localhost:4000/api/v1/sign/$INVITATION_TOKEN/qa/message" \
  -H "x-session-token: $SESSION_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"mode":"GATE","tokensConsumed":0,"userMessage":"What is the cancellation clause?"}'
# Expect: text/event-stream response with `data: {"type":"token","delta":"..."}` chunks
# followed by terminal `data: {"type":"done","tokensConsumed":<int>}\n\n`.
```

### Errors to expect

- **410** `invitation_invalid_or_expired` — single generic message; does NOT distinguish unknown / expired / cancelled (AC-S3-04 / AC-S4-05 / AC-S5-04 / AC-S11-02 / AC-S12-10).
- **410** `session_invalid_or_expired` — only on /qa/message when X-Session-Token is unknown / inactive.
- **429** `rate_limit_exceeded` — per-session 20/h OR per-invitation 50/h (only on /qa/message). Response includes `retryAfterSeconds`. Note: when 429 happens AFTER the SSE header flip, it surfaces as a terminal SSE error chunk instead of HTTP 429.
- **409** `already_signed` — second sign on same invitation.
- **409** `already_decided` — sign or decline on already-final invitation.

### PUBLIC-grant enumeration check

After every M3+ deploy, run this query to verify exactly 5 fn_'s carry PUBLIC EXECUTE:

```sql
SELECT proname, array_to_string(proacl, E'\n') AS acl
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND proname LIKE 'fn_%'
  AND EXISTS (SELECT 1 FROM unnest(proacl) acl_item
              WHERE acl_item::text LIKE '=X%');
-- Expected exactly: fn_signature_decline, fn_signature_get_by_invitation_token,
-- fn_signature_sign, fn_signer_qa_session_record_message, fn_signer_qa_session_start.
-- Any other fn_ surfacing here is a regression — investigate immediately.
```

This is the **S2-21 candidate check** (gate2-decisions.md CC-4 follow-up; codified into Stage 4 §M3-1 — see qa-stage4-report.md).

---

## Cron driver — signature expiration

`src/services/signature-expiration.cron.service.ts` mirrors `approval-escalation.cron.service.ts` (M2):

- **Env var:** `SIGNATURE_EXPIRATION_INTERVAL_CRON` (default `*/15 * * * *` — every 15 minutes).
- **Disabled in `NODE_ENV=test`** to keep test runs deterministic.
- **System-actor sentinel:** the driver passes `SYSTEM_ACTOR_ID=0` via `db.callFunction(args, { actorId: 0 })` — the request middleware sets `SET LOCAL app.current_user_id='0'` before invoking the fn (S2-20). `fn_contract_activity_create` then coerces `v_actor IN (NULL, 0) → NULL` per the M2 031 canonical body (preserved verbatim in M3 032).
- **Batch loop:** `BATCH_SIZE=100`, `MAX_BATCHES_PER_SWEEP=50`. Loop until `result.expiredInvitations < BATCH_SIZE`. Aborts on error and logs at warn level (does NOT silently swallow per M2-031 lesson).
- **SKIP LOCKED:** `fn_signature_invitation_expire_due` uses `FOR UPDATE OF inv SKIP LOCKED` — concurrent cron workers cannot deadlock; live signers hold their own row and the cron skips.
- **Wired into:** `server.ts` — `startSignatureExpirationCron()` on `app.listen`; `stopSignatureExpirationCron()` in graceful shutdown (SIGTERM/SIGINT).

**To disable expiration without disabling other crons:** set `SIGNATURE_EXPIRATION_INTERVAL_CRON='0 0 31 2 *'` (Feb 31st — never fires) or any other far-future cron pattern.

---

## SSE flow on POST /qa/message

The signer Q&A AI endpoint is the only streaming endpoint in the project. The controller orchestration:

```
1. Validate Zod (mode='GATE', tokensConsumed=0, userMessage required).
2. fn_signer_qa_session_record_message(GATE) — RESERVES a slot.
   - 429 here arrives BEFORE the SSE header flip (translatePgError → 429 JSON).
3. fn_signature_get_by_invitation_token — load contract excerpt for the prompt.
   - 410 here arrives BEFORE the SSE header flip (NULL-check + GoneError).
4. Flip headers + flushHeaders. From here, all errors emit as SSE error chunks:
   - Content-Type: text/event-stream; charset=utf-8
   - Cache-Control: no-cache, no-transform
   - Connection: keep-alive
   - X-Accel-Buffering: no  (Nginx flush)
5. buildSystemPrompt(view) — load+interpolate prompts/ai-signer-qa.txt
   (verbatim from Lovable supabase/functions/ai-signer-qa/index.ts per G7;
    Mustache-style {{placeholder}} substitution, no auto-escaping).
6. streamSignerQa(...) — yield 'token' chunks for each delta.content.
   AbortController honours client disconnect (axios bypass + apiPublicClient).
7. fn_signer_qa_session_record_message(COMMIT, tokensConsumed). Failure logged
   at warn (non-fatal — the stream already delivered).
8. Emit terminal 'done' chunk + res.end().
```

**Token usage fallback (BE-OI-2):** OpenAI's `stream_options.include_usage=true` is documented to emit a final usage chunk; some pre-release model versions omit it. On missing usage, the AI service logs `usage_missing` at warn level + returns `tokensConsumed=0`. The controller defaults COMMIT tokens to 1 to satisfy the fn_'s `COMMIT mode requires tokensConsumed > 0` validation. If observed in production telemetry, switch to a deterministic token estimator (e.g., tiktoken).

**Frontend SSE consumer:** `src/features/signatures/hooks/useSignerQaSseStream.ts:138` uses native `fetch` + `ReadableStream` + `TextDecoder` (NOT native `EventSource` because we need a custom `X-Session-Token` header). This is a documented exception to the "no raw fetch" rule (L9 — Codex lesson) and is the ONLY non-axios fetch in the FE M3 surface.

---

## Step-2+ invitation issuance — manual drafter action (BE-OI-1 / DB Impl I-4)

`fn_signature_sign` transitions contract.status `awaiting_signature_employer` → `awaiting_signature_counterparty` when the LAST required employer signs. The BE does **NOT** auto-issue counterparty invitations — the drafter must manually re-invoke `POST /api/v1/contracts/:id/send-for-signature` at the new step.

**Why:** the public token-bearer (external signer) lacks JWT-level authority to issue new tokens. Auto-issuing from the public path would bypass the `signature.send` permission gate.

**Observability:** `signPublicController.sign` emits a structured log entry `signPublic.sign.next_step_required` with `{ contractId, signaturePartyId, contractNewStatus: 'awaiting_signature_counterparty' }` whenever `stepCompleted=true && contractNewStatus='awaiting_signature_counterparty'`. Operators can alert on this log line to nudge drafters.

**Future enhancement:** add `fn_signature_send_for_next_step` that runs as DEFINER so the public path can chain it. Defer to product.

---

## Frontend route registration — `npx tsr generate` prerequisite (FE-OI-4 carry-forward)

M3 added a new public route `src/routes/sign.$invitationToken.tsx`. TanStack Router uses file-based routing with a generated `routeTree.gen.ts` — adding a route requires either:

- Running `npx tsr generate` manually before `tsc --noEmit` passes, OR
- Letting the Vite dev plugin auto-regenerate on dev start.

**Symptom when forgotten:** `tsc` reports type errors on the route's component param signature ("'invitationToken' does not exist on type 'Record<string, never>'"). The fix is `npx tsr generate` — both the FE M3 implementation and any future module that adds a route hits this. Document this in the FE README contributing section.

---

## OpenAI gpt-4o usage

| Setting | Value | Notes |
|---|---|---|
| `OPENAI_MODEL_DEFAULT` | `gpt-4o` | Set via env. M3 reuses M0's AIProvider abstraction unchanged. |
| Max tokens | 200 | Hard cap per AI call to keep per-message cost bounded. |
| Temperature | 0.4 | Deterministic-leaning for compliance-related answers. |
| Streaming | true | `stream_options: { include_usage: true }`. |
| Abort on disconnect | true | AbortController closed on res.close. |

**Prompt source:** `prompts/ai-signer-qa.txt` — extracted VERBATIM from Lovable `supabase/functions/ai-signer-qa/index.ts` (G7 / AN-2). Read at runtime via `node:fs/promises readFile`, cached in-memory, Mustache-style `{{placeholder}}` substitution (no real templating library, no auto-escaping). The placeholders are filled from the `SignaturePublicView` returned by `fn_signature_get_by_invitation_token` (contract excerpt — body truncated to 4000 chars, signer-safe).

**Rate limit:** in addition to `publicSignerRateLimiter` (60 req/min/IP), the fn_ enforces:
- Per-session: 20 messages / rolling 1-hour window (AC-S12-05).
- Per-invitation: 50 messages / rolling 1-hour window — sum across all sessions for the invitation.

429s include `retryAfterSeconds` computed from window expiry.

---

## Files owned by M3

**Backend (16 created + 8 modified):**
- Created: `src/types/signature.types.ts`, `src/schemas/signature.schemas.ts`, `src/services/signature.service.ts`, `src/services/signer-qa.service.ts`, `src/services/ai/openai-signer-qa.service.ts`, `src/services/signature-expiration.cron.service.ts`, `src/controllers/signature.controller.ts`, `src/controllers/sign-public.controller.ts`, `src/controllers/signer-qa.controller.ts`, `src/routes/v1/sign.routes.ts`, `src/routes/v1/signature-parties.routes.ts`, `src/routes/v1/signature-invitations.routes.ts`, `prompts/ai-signer-qa.txt`. Plus 3 workspace artefacts.
- Modified: `src/utils/errors.util.ts` (added GoneError 410), `src/database/client.ts` (translatePgError extended for M3 P0001 codes), `src/utils/logger.util.ts` (+~80 pino redact paths for token plaintext / session token / signature payload / userMessage), `src/utils/env-validation.util.ts` (+SIGNATURE_EXPIRATION_INTERVAL_CRON), `src/types/contracts.types.ts` (ActivityType union 14 → 20), `src/middleware/rate-limit.middleware.ts` (added publicSignerRateLimiter), `src/routes/v1/contracts.routes.ts` (+3 M3 sub-routes BEFORE bare GET /:id — W1 ordering preserved), `src/routes/v1/index.ts` (+3 M3 routers), `src/server.ts` (start/stop signature-expiration cron in listen + graceful shutdown).
- Migrations: 032..039 (6 design + 2 patches).
- Tests: `tests/integration/M3-signature-ceremony.test.ts`, `tests/integration/M3-signer-qa.test.ts`, `tests/integration/M3-cron-and-system-actor.test.ts`, `tests/helpers/m3-helpers.ts`.

**Frontend (16 created + 5 modified + 1 auto-regenerated):**
- Created: `src/types/entities/signature.types.ts`, `src/services/api/signature.service.ts`, `src/features/signatures/hooks/useSignatures.ts`, `src/features/signatures/hooks/useSignerQaSseStream.ts`, plus 11 components in `src/features/signatures/components/` (ContractSignersConfigDialog, SendForSignatureConfirmDialog, SigningCeremony, SignatureMethodPicker, DeclineDrawer, ContractSignaturesTab, ResendInvitationConfirm, CancelInvitationConfirm, SignerQADrawer, VerificationGate, TokenOnceCopyPanel) + `src/routes/sign.$invitationToken.tsx`.
- Modified: `src/types/entities/contract.types.ts` (ActivityType union 14 → 20 + M3_ACTIVITY_TYPE_EXTENSIONS const), `ContractDetail.tsx` (Signatures tab added), `ContractActivityLog.tsx` (6 new icons/tones), `i18n/en.json` + `i18n/ar.json` (+188 keys each — parity match=true).
- Auto-regenerated: `src/routeTree.gen.ts` (`npx tsr generate` registers `/sign/$invitationToken`).

---

*Generated by Documentation Generator from M3 workspace specs + implementation summaries + integration verifier R2 + QA Stage 4 report. No Codex review run for M3 (Dexian decision 2026-05-04).*

---

# M4 Implementation Notes — AI Features

> **Module:** M4 (seventh module — AI Features).
> **Generated:** 2026-05-04.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Codex review:** SKIPPED per Dexian decision 2026-05-04. Stage 2 + Stage 4 absorbed safety net.

---

## Architecture summary

M4 adds the AI subsystem on top of M0-M3. The pattern across the project is unchanged: controllers stay thin, business logic lives in PostgreSQL `fn_*` functions, sensitive payloads are pino-redacted at controller entry/exit and JSONB-redacted by `fn_audit_trigger`. M4 introduces three first-time things in the codebase:

1. A **3rd in-process cron driver** (`ai-insight-eviction.cron.service.ts`) — every 15 minutes — for soft-deactivating expired `ai_insight` cache rows. After the M2 + M3 cron precedents, the 3-instance threshold is the canonical generalisation point; a shared cron-runner abstraction is a candidate refactor for M5+.
2. A **NEW auth mode** at the API layer: `signed-token` (alongside the prior `jwt` and `none`). One endpoint uses it: `POST /api/v1/ai/regulatory-impact-summary` (S5). The signed-PDF-token is HMAC-validated at Express middleware before invoking `neondb_owner`-only fn_'s — distinct from M3's `verify_jwt=false` pattern (which used PUBLIC EXECUTE on fn_'s).
3. A **polymorphic-dispatch RLS policy** (`ai_insight_select_scope`) — first in the codebase. Future modules adding new `ai_insight.entity_type` values MUST extend this policy with a matching subquery (no automatic dispatch).

**Endpoint count:** 10 new (6 AI invocation + 4 admin observability). 9 JWT + 1 signed-token. 3 of the 10 stream SSE.

**fn_ count:** 12 new + 2 extended (`fn_contract_activity_create`, `fn_audit_trigger`) + 1 trigger fn (`fn_trg_ai_request_log_deny_update`).

**Migrations applied:** 040..045 (5 designed + 1 DEFECT-1 patch). `schema_migrations.version=45` on both `test` and `m0-foundation` branches.

**S2-21 LIVE PUBLIC EXECUTE allowlist:** still exactly the 5 M3 names. M4 contributes 0 new PUBLIC fn_ grants — Q3 Option A.

---

## Per-prompt service modules (Q2 lock)

Six per-prompt service modules under `src/services/ai/`, each loading its prompt VERBATIM from `prompts/<prompt-id>.txt` at runtime (G7):

| Module | Story | Prompt file | TTL | Streaming | Tool-call |
|---|---|---|---|---|---|
| `openai-contract-insights.service.ts` | S1 | `prompts/ai-contract-insights.txt` (5,624 B) | 24 h | summary + rewrite modes | key_terms / risks / obligations / regulatory |
| `openai-drafting-assistant.service.ts` | S2 | `prompts/ai-drafting-assistant.txt` (3,645 B) | **0 (no cache)** | chat / explain / rewrite | suggest |
| `openai-executive-anomalies.service.ts` | S3 | `prompts/ai-executive-anomalies.txt` (1,059 B) | 1 h | — | tool-call only |
| `openai-regulatory-impact.service.ts` | S4 | `prompts/ai-regulatory-impact.txt` (1,917 B) | 24 h | explain + amendment | — |
| `openai-regulatory-impact-summary.service.ts` | S5 | `prompts/ai-regulatory-impact-summary.txt` (1,465 B) | 30 d | — | tool-call |
| `openai-version-diff-summary.service.ts` | S6 | `prompts/ai-version-diff-summary.txt` (996 B) | 7 d | — | — |

Total prompt-file payload: **14,706 B across 6 files**. Plus the M3 `ai-signer-qa.txt` (902 B) → 7 prompts / 15,608 B total in `[backend]/prompts/`. **Never edit a prompt file** — Mustache-style `{{placeholder}}` substitution at runtime only; no real templating, no auto-escaping. Prompts are read on first invocation per process, cached in-memory.

> **Why per-prompt instead of a generalized router?** Each service has subtly different needs (streaming vs not, tool-call vs not, cache TTL, provider model, max_tokens, system prompt structure). A generalized router would obscure these per-prompt nuances and make Stage 2/4 review harder. M3's `openai-signer-qa.service.ts` is the precedent. Each module < 300 lines.

---

## Shared AI utility modules (7 under `src/services/ai/_shared/`)

| Module | Purpose |
|---|---|
| `openai-client.ts` | Singleton `OpenAI` client constructor; reads `OPENAI_API_KEY` from env. Thin wrapper around `openai` v4 SDK. |
| `prompt-loader.ts` | `readFile` + in-memory cache of `prompts/<id>.txt`. Mustache-style placeholder substitution. |
| `tiktoken-estimator.ts` | Estimates `tokens_input` from prompt text + `tokens_output` from streamed deltas. Replaces M3's `+1` fallback for accurate cost telemetry — M3 used `usage.total_tokens` only when the SDK provided it; M4 uses tiktoken to estimate when streaming and reconciles with the SDK's terminal usage event when available. |
| `rate-limit-gate.ts` | Wraps `fn_ai_request_log_check_rate_limit` for the 5 JWT-authed AI invocation endpoints. Returns `{ allowed, retryAfterSeconds, ... }` to controller. |
| `telemetry-middleware.ts` | Wraps the controller `finally{}` block — emits a single `ai_request_log` row per invocation (success / error / cache_hit / rate_limited / timeout / cancelled). Latency captured from Express `req.startTime`. |
| `cache-layer.ts` | Wraps `fn_ai_insight_get_cached` + `fn_ai_insight_upsert`. Computes `payload_hash = SHA-256(canonicalised inputs)` for content-addressed lookups. Sets `X-AI-Cache: HIT|MISS`. |
| `signed-pdf-token-validator.ts` | HS256 JWT verifier for S5. Validates `aud + iss + exp + jti` (in-process nonce Set). Throws `UnauthorizedError` on any mismatch. |

---

## Cron driver — 3rd in codebase

`src/services/ai-insight-eviction.cron.service.ts` is the third in-process cron driver in the project (after M2 `approval-escalation.cron.service.ts` + M3 `signature-expiration.cron.service.ts`). Pattern:

- Schedule: `AI_INSIGHT_EVICTION_INTERVAL_CRON` env var, default `*/15 * * * *`.
- Disabled in `NODE_ENV=test` (per M2 + M3 precedent — tests drive the fn directly).
- **System-actor sentinel (S2-20):** the driver wraps the `db.callFunction('fn_ai_insight_evict_expired', ...)` call inside a `set_config('app.current_user_id', '0', true)` transaction-scoped GUC. The fn is `SECURITY DEFINER` + `GRANT EXECUTE TO neondb_owner` only.
- Wired in `src/server.ts` boot path + graceful shutdown.
- Defensively parses both `{ data: { evictedCount } }` and the inner `{ evictedCount }` fn return shapes (BE-IMPL-INFO-1) — recommend tightening to the canonical wrapped shape once a future spec audit confirms.

> **Pattern for adding a 4th cron** (M5+): copy the M4 file, change the schedule env var name, change the fn name, and add a one-line registration in `server.ts` `app.listen(...)` + `process.on('SIGTERM' / 'SIGINT', ...)`. The 3-instance threshold is the canonical generalisation point — extracting a shared `cron-runner.ts` is a defensible Phase 2 architectural decision when M5 adds the 4th driver.

---

## Signed-PDF-token middleware (Q3 Option A)

`src/middleware/signed-pdf-token.middleware.ts` — the FIRST middleware in the project that authenticates a non-JWT, non-session-token credential. Validates HS256 JWTs issued by the future PDF-generator pipeline; only mounted on `POST /api/v1/ai/regulatory-impact-summary`.

**Validation chain:**
1. Read token from `Authorization: Bearer <token>` OR `X-Signed-Pdf-Token` header.
2. `jsonwebtoken.verify(token, SIGNED_PDF_TOKEN_SECRET, { algorithms: ['HS256'], audience: SIGNED_PDF_TOKEN_AUDIENCE, issuer: SIGNED_PDF_TOKEN_ISSUER })` — throws on alg/aud/iss/exp mismatch.
3. Check `jti` against in-process nonce Set (single-use guard; per-replica only — switch to Redis when scaling beyond 1 replica).
4. On success, the request reaches the controller with NO actor user id (no `req.user`); `fn_ai_request_log_create` writes `actor_user_id=NULL`.

**Service unavailable when secret missing:** if `SIGNED_PDF_TOKEN_SECRET` is unset at boot, the S5 endpoint returns 503 (intentional — only S5 is affected). M4-SMOKE-BE-INFO-2 + the QA Stage 4 recommendation REC-4: upgrade env-validation.util.ts to require `SIGNED_PDF_TOKEN_SECRET` if the S5 route is mounted (currently it's optional).

**Per-token rate limit (BE-IMPL-INFO-2):** the controller enforces an in-memory `Map<jti, timestamps[]>` 10-calls-per-hour bucket. Substituted for `fn_ai_request_log_check_rate_limit` because the public path has no actor user id. **Single-replica only** — if you scale this BE beyond one process, the rate limit leaks. Switch to a Redis-backed bucket (or to a per-token DB table) at that point.

---

## DEFECT-1 retrospective + S2-22 codification

The Testing Agent caught a high-severity production-blocker that DB Implementation Step 4 + Smoke Test missed. Worth documenting because it directly informed the proposed Stage 2 lesson S2-22.

**The bug:** Migration 043's `fn_contract_version_diff_summary_persist` body contained:

```sql
UPDATE contract_version
  SET diff_summary = p_diff_summary,
      updated_at   = CURRENT_TIMESTAMP,    -- column doesn't exist
      updated_by   = p_actor_user_id       -- column doesn't exist
  WHERE id = p_contract_version_id
  RETURNING updated_at INTO v_new_at;      -- column doesn't exist
```

`contract_version` is append-only at the table level (M1a 003 reserved `diff_summary` for M4 AI persistence and intentionally did NOT add `updated_at`/`updated_by` columns). **Plpgsql lazy-compiles function bodies**, so:
- Migration 043 applied cleanly (no compile error at apply time).
- DB-Impl Step 4 functional probe only exercised the `NOT FOUND` branch — never reached the `UPDATE` clause.
- Smoke test `pg_proc`-presence check passed.
- First successful invocation (in `M4-persist-and-admin-fns.test.ts AC-S6-04`) hit `SQLSTATE 42703 column "updated_at" does not exist`.

**The fix (migration 045):** drop both nonexistent columns from the UPDATE clause; materialise `v_new_at TIMESTAMPTZ := CURRENT_TIMESTAMP` at function entry instead. JSONB return shape byte-identical to 043; signature unchanged; controller bindings unchanged.

**Stage 2 lesson S2-22 (recommended for codification at Stage 4 → MEMORY.md):**
- **Stage-2 design-time check:** for every `UPDATE` / `INSERT` clause in any fn_ body, verify EVERY referenced column exists in the active branch's table DDL (cross-reference against `project-artifacts/database/`).
- **DB-Impl Step 4 enhancement:** functional probe MUST exercise the **success path** of every `UPDATE` / `INSERT` branch in every new fn_, not just error/NOT FOUND paths. (`feedback_db_impl_report_dont_fix.md` is unchanged — Agent 6 still doesn't fix; the recommendation is to add success-path probes to the canonical Step 4 protocol.)

This kind of escape is exactly the Codex blind spot Stage 2+4 must absorb in the post-Codex-skip era.

---

## In-memory rate limiter caveat (BE-IMPL-INFO-2)

S5's per-token bucket lives in a process-local `Map`. The same caveat applies as M0-M3's `RateLimiterMemory` instances in `rate-limit.middleware.ts`: **single-replica only**. When this BE is scaled beyond 1 process — horizontally or vertically with worker forks — the rate limit leaks across replicas (each replica runs its own counter; an attacker can spread requests across replicas to multiply the effective limit). Fix: switch to `rate-limiter-flexible` Redis store, or to a per-token row in a small `pdf_token_rate_limit` table.

The same caveat applies to the in-process nonce Set in `signedPdfTokenMiddleware`. A determined attacker who learns a valid `jti` could replay it against a different replica. Mitigations: keep token TTLs short (recommended ≤ 5 minutes), and switch to a Redis-backed nonce store before scaling.

> **Recommend** documenting this caveat in the deployment readme and gating horizontal scale-out behind a Redis migration.

---

## Verbatim prompt preservation (G7)

The 6 prompt files in `[backend]/prompts/` were copied **verbatim** from the Lovable extraction workspace. **Never edit them by hand** — only Mustache-style `{{placeholder}}` substitution is applied at runtime. This is a non-negotiable contract per the Lovable Modernization G7 rule. If a prompt needs to change:
1. Edit the source file in the Lovable repo (or wherever the prompt lives now).
2. Re-extract via the L1 pipeline.
3. Copy the new file to `[backend]/prompts/`.
4. Re-test all affected endpoints + cache layers (cache rows keyed on `payload_hash` will be transparently miss-then-refill on first invocation post-deploy).

QA Stage 4 verifies byte-identity with `diff -q` against the extraction workspace.

---

## Pino redact extensions (M4)

`src/utils/logger.util.ts` extended with redact paths for the new sensitive keys. Defence-in-depth alongside the migration-041 audit-trigger redact list extension.

| Key | Source | Reason |
|---|---|---|
| `payload` | `ai_insight.payload` | AI output may contain contract excerpts. |
| `errorMessage` / `error_message` | `ai_request_log.error_message` | Provider error strings may echo prompt fragments. |
| `signedToken` / `x-signed-pdf-token` (header) | S5 request | Short-lived bearer; never leak. |
| `selectedText` | S1 / S2 request | Full clause text — sensitive contract content. |
| `chatHistory` | S2 request | Full conversation turns — sensitive. |
| `draftSummary` | S2 request | Free-form drafting context — sensitive. |
| `additions` / `deletions` / `modifiedClauses` | S6 request | Full diff content. |
| `summaryEn` | S4 request | Free-form regulatory summary text. |
| `ai_prompt_payload` | controller-only marker | The fully-rendered prompt — universal SENSITIVE marker per project.config. NEVER stored anywhere; never logged. |

---

## Test coverage (M4 — Section F WARN, not FAIL)

QA Stage 4 Section F coverage:
- Lines: **21.93%** (target ≥90%; WARN, not FAIL).
- Functions: **11.11%** (target ≥90%; WARN).
- Branches: **64.40%** (target ≥80%; WARN).

**Per-folder breakdown:**
- `controllers/admin/ai-*.controller.ts` — 80% lines, 62.5% branches — meets target.
- `middleware/signed-pdf-token.middleware.ts` — 92% lines — meets target.
- `schemas/ai.schemas.ts` — 98% lines — meets target.
- `services/ai/_shared/signed-pdf-token-validator.ts` — 66% lines.
- `controllers/ai/*.controller.ts` — 3-9% lines (only auth-rejection paths exercised).
- `services/ai/openai-*.service.ts` — 4-8% lines (provider stubs).

**Why aggregate is misleading.** The OpenAI provider services + invocation controllers are stubs that require either (1) live OpenAI API calls or (2) a deep provider mock harness to exercise the success path. M4 unit tests focus on auth + DB fn_ behaviour + cache layer + admin observability — exactly the layers that ARE in unit-test scope. **Recommend a follow-up testing pass once a provider-mock harness is built (M5+ candidate, REC-3).**

**M4 test files:**
- `tests/m4/M4-cache-layer.test.ts` — fn_ai_insight_get_cached / upsert / evict_expired.
- `tests/m4/M4-rate-limit-telemetry.test.ts` — fn_ai_request_log_check_rate_limit + fn_ai_request_log_create.
- `tests/m4/M4-persist-and-admin-fns.test.ts` — fn_contract_ai_summary_persist + fn_contract_version_diff_summary_persist + admin fn_'s.
- `tests/m4/M4-signed-pdf-token.test.ts` — middleware + S5 controller.
- `tests/m4/M4-cron.test.ts` — cron driver wiring + system-actor sentinel.

Total **115 tests; all pass post-DEFECT-1 patch (migration 045) + post-i18n nesting patch.**

---

## How to extend M4

**To add a new AI prompt** (e.g. M5 adds `ai-clause-rewriter`):
1. Add the prompt file VERBATIM to `[backend]/prompts/<prompt-id>.txt`.
2. Add a row to `ai_prompt` via a new migration (`INSERT ... ON CONFLICT DO NOTHING`).
3. Create a new service module under `src/services/ai/openai-<prompt-id>.service.ts` mirroring the M4 per-prompt structure.
4. Add a controller under `src/controllers/ai/<prompt-id>.controller.ts`.
5. Add a route to `src/routes/v1/ai.routes.ts`.
6. Add Zod schemas to `src/schemas/ai.schemas.ts`.
7. Add a hook + service-API method on the FE if it has a UI.

**To add a new `ai_insight.entity_type`** (e.g. M5 adds `template`):
1. Update the `AiInsightEntityType` TypeScript union (`src/types/ai.types.ts`).
2. Extend the `ai_insight_select_scope` RLS policy with a matching subquery — either an EXISTS clause against the new entity table, or a permission-gate (no automatic dispatch).
3. (Optional) Document the new entity_type in the data-dictionary M4 / M5 section.

**To add a new permission for AI access** (e.g. `ai.invoke.template`):
1. Add to `permission` table via migration.
2. Pre-emptively grant to Super Admin in the same migration (M1a 006 / M1c 018 / M2 028 / M3 037 / M4 044 lesson).
3. Update the controller permission gate.

---

## Files owned by M4

**Backend (28 created + 5 modified):**
- Created: `src/types/ai.types.ts`, `src/schemas/ai.schemas.ts`, 6 controllers under `src/controllers/ai/` (contract-insights / drafting-assistant / executive-anomalies / regulatory-impact / regulatory-impact-summary / version-diff-summary), 4 admin controllers under `src/controllers/admin/` (ai-insights / ai-requests / ai-cost-report / ai-prompts), `src/routes/v1/admin/ai.routes.ts`, 6 per-prompt service modules under `src/services/ai/openai-*.service.ts`, 7 shared utility modules under `src/services/ai/_shared/`, `src/services/ai-insight-eviction.cron.service.ts`, `src/middleware/signed-pdf-token.middleware.ts`, 6 prompt files under `[backend]/prompts/`.
- Modified: `src/server.ts` (cron wiring), `src/routes/v1/ai.routes.ts` (registers M4 AI routes alongside the M1c stub), `src/routes/v1/admin/index.ts` (mounts admin AI routes), `src/utils/logger.util.ts` (12 new pino redact paths), `src/utils/env-validation.util.ts` (4 new env vars).
- Migrations: 040..044 (5 designed) + 045 (DEFECT-1 patch).
- Tests: 5 files under `tests/m4/`.

**Frontend (16 created + 3 modified):**
- Created: `src/types/entities/ai.types.ts`, `src/services/api/ai.service.ts`, 5 hooks under `src/features/ai/hooks/` (useAi + 3 SSE stream hooks), `src/features/admin-ai/hooks/useAdminAi.ts`, 8 components (5 AI feature + 3 admin views), 3 admin route files under `src/routes/app/admin.ai.*.tsx`.
- Modified: `src/i18n/en.json` + `src/i18n/ar.json` (+133 keys per side; parity 3900/3900 → 3903/3903 post-i18n nesting patch), `src/routeTree.gen.ts` (auto-regenerated).

**Component fates:**
- 0 hardened, 5 regenerated (all 5 Lovable AI components — see `lovable-handoff.md` M4 section), 3 net-new admin views.

---

*Generated by Documentation Generator from M4 be-implementation-summary.json + fe-implementation-summary.json + 045-defect1-patch-summary.md + qa-stage4-report.md. No Codex review run for M4 (Dexian decision 2026-05-04).*

---
---

# M5 Implementation Notes — Regulatory Radar

> **Module:** M5 — Regulatory Radar (eighth module — UAE regulations master library + radar feed + per-contract impact analysis + impact-category taxonomy admin).
> **Generated:** 2026-05-05.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Status:** Complete. QA Stage 4 PASS. 15 endpoints across 4 namespaces. Migrations 046..052 + 053 (DEFECT-1 patch). `schema_migrations.version=53` on `test` and `m0-foundation`. Codex adversarial review SKIPPED (Dexian decision 2026-05-04 — 4th consecutive validation through M2/M3/M4/M5; pattern fully entrenched). All 78/78 M5 tests PASS.

For data-dictionary detail (tables / fn_'s / RLS / indexes) see [`data-dictionary.md`](data-dictionary.md) M5 section. For OpenAPI wire spec see [`api/openapi.yaml`](api/openapi.yaml). For the Lovable transformation log see [`lovable-handoff.md`](lovable-handoff.md) M5 section.

---

## Architecture summary

M5 introduces the Regulatory Radar surface — a 4-namespace API + 5-table schema covering UAE regulations master library, regulatory-update radar feed, per-contract impact analysis, and impact-category taxonomy admin. The core data flow:

```
[FE — TanStack Start + React 19]
              │
              │ apiClient (axios; Bearer JWT; X-Request-ID)
              ▼
   /regulations/*      /regulatory-updates/*    /regulatory-impacts/*    /impact-categories
       (CRUD + chain)        (CRUD + radar)            (bulk-detect /         (list /
                                                        list / resolve)        upsert)
              │                       │                       │                    │
              └───────────────────────┴────── thin Express controller → service → db.callFunction
                                                              │
                                                              ▼
[PostgreSQL — Neon, RLS-enabled]
       fn_regulation_*           fn_regulatory_update_*       fn_regulatory_impact_*   fn_impact_category_*
       (5 endpoints, INVOKER)    (5 endpoints, INVOKER)       (3 endpoints —           (2 endpoints —
                                                               1 DEFINER carve-out)     INVOKER)
                          │
                          ▼
         regulator (lookup) ←── regulation (master, self-ref supersession chain) ───┐
                ▲                                                                   │ regulation_id
                │                                                                   │ (RESTRICT)
                └── regulator_id ── regulatory_update (radar feed) ──── category_id │
                                          (CASCADE) │                  (SET NULL)   │
                                                    │                               │
                                                    └─── regulatory_impact ─────────┘
                                                         (G1-reconstituted; nullable
                                                          regulatory_update_id; COALESCE
                                                          sentinel UNIQUE for idempotent
                                                          bulk-detect)
                                                              │
                                                              │ contract_id (CASCADE)
                                                              ▼
                                                          contract (M1a)
```

**Key things to know:**

1. **NO new cron driver.** M5 is event-driven only. The 3 existing crons (M2 approval-escalation, M3 signature-expiration, M4 ai-insight-eviction) remain wired unchanged. The `regulatory_impact.created_by` column is NULLABLE for future-cron compatibility but no current path passes a system-actor sentinel.

2. **One DEFINER carve-out:** `fn_regulatory_impact_create_bulk` (S11). Legal_counsel writes impacts on contracts they don't directly own — RLS would block the legitimate bulk-detect path. The carve-out trades RLS defence for fn-body defence-in-depth: permission gate at fn body line 1 + S2-17 atomic gate+commit (SELECT FOR UPDATE on `regulatory_update` row before per-contract INSERT loop). See `data-dictionary.md` M5 § DEFINER carve-out for the full rationale.

3. **Polymorphic permission at the route layer.** `PATCH /regulatory-impacts/:id/resolve` uses `authoriseAnyOf(['regulations.read', 'regulations.manage'])` at the route — intentionally permissive. The fn body re-gates strictly: `regulations.manage` OR `contract.drafted_by = current_user` (AC-S13-05). `contract_recipient` (no `regulations.read` in the M5 grant matrix) is correctly rejected at the route gate.

4. **Zero new PUBLIC fn_ grants.** PUBLIC EXECUTE allowlist remains the M3 set of 5 names (S2-21 mandatory, 4th consecutive validation). `signed-token` and `verify_jwt=false` modes remain M3/M4-only.

5. **Q9 EMIT — contract_activity extended atomically.** Migration 047 atomically pairs the `contract_activity.activity_type` CHECK enum extension (23→25 values: +`regulatory_impact_detected`, +`regulatory_impact_resolved`) with the `fn_contract_activity_create` body whitelist extension. Body is byte-for-byte M4 040 except the IF NOT IN tuple. Mirrors M2 027 / M3 032 / M4 040 atomic precedent. The M5_ACTIVITY_TYPE_EXTENSIONS const + M5ActivityType alias live in M5's types file ONLY — M0..M4 type files are NOT modified (S2-19 byte-for-byte preservation).

---

## Locked Gate 2 decisions (Q1..Q11)

The developer accepted ALL Architect recommendations at HITL Gate 2 ("accept all"). Captured here for future reference:

| Q | Decision | Rationale |
|---|---|---|
| Q1 | CONFIRM zero new PUBLIC fn_'s | All 15 M5 fn_'s REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner only. Stage 4 enumerate-PUBLIC-grants verifies count = 5. |
| Q2 | 3 new permission codes (`regulations.read`, `regulations.manage`, `config.manage`) | Pre-emptive Super Admin grant + 12 role_permission rows. Without migration 046, every M5 endpoint 403s. |
| Q3 | (b) shared regulator lookup | One `regulator` table referenced by both `regulation.issuer_id` and `regulatory_update.regulator_id`. Avoids two parallel CHECK enums + admin lookup duplication. |
| Q4 | KEEP TEXT[] for `regulation.tags`, `impact_category.default_clause_categories`, `regulatory_update.affected_clause_categories` | Junction normalization deferred to M7+ (production gap acknowledged). GIN indexes on TEXT[] columns serve filter performance acceptably. |
| Q5 | `impact_category` PK is `id BIGSERIAL` + `key VARCHAR(60) UNIQUE` | Q5 explicitly opted out of the code-PK pattern that bit M3 `signature_party_side` / `signature_method` and M4 `ai_prompt` (DB-IMPL-I-1). All 5 M5 entities use BIGSERIAL — DB-IMPL-I-1 NOT recurring in M5. |
| Q6 | KEEP both `impact_note_*` (short) AND `impact_summary_*` (long) | Note = radar tooltip (AC-S6 surface); Summary = AI-generated long-form (BulkAmendmentSheet, RegulatoryImpactBanner). Wire shapes deserve the split. |
| Q7 | UNIQUE INDEX uses `COALESCE(regulatory_update_id, 0::BIGINT)` | M4 ai_insight precedent. PG NULLS-DISTINCT default workaround; PG15+ NULLS NOT DISTINCT was considered but COALESCE chosen for portability + intent-explicit + parity. |
| Q8 | ADD `resolution_note` TEXT — admin-bounded, NOT redacted | Free text; AC-S13-07 stored verbatim. No PII risk per Agent 2 sensitiveFields analysis. |
| Q9 | EMIT `regulatory_impact_detected` + `regulatory_impact_resolved` activities | Atomic CHECK enum + fn body extension in migration 047. M5_ACTIVITY_TYPE_EXTENSIONS const + M5ActivityType alias in M5 types file ONLY (S2-19). |
| Q10 | NOT EXTEND `fn_audit_trigger` redact list | `impact_payload` is a fn parameter only (never a column path). Pino redact at controller covers it semantically (`ai_prompt_payload` class — M4 precedent). |
| Q11 | NOT EXTEND `fn_contract_get_by_id` projection | Contract interface (M1a) UNCHANGED in M5. FE makes the second `fn_regulatory_impact_list` call to surface impact summary on contract detail; `idx_regulatory_impact_contract_resolved` partial index serves <1ms. |

---

## DEFECT-1 retrospective + S2-23 codification

The Testing Agent caught a high-severity production-blocker that DB Implementation Step 4 + Smoke Test missed. Same pattern as M4-DEFECT-1 — a column/error-mapping escape that lazy-compiles past Stage 2 and DB-Impl, surfaces only on first realistic test invocation.

**The bug:** `fn_regulation_update` returned HTTP 422 (UNPROCESSABLE_ENTITY) instead of the AC-S4-04 mandated HTTP 400 (VALIDATION_ERROR) when `p_patch.supersededById` pointed to a non-existent (or inactive) regulation.

- **Failing test:** `tests/integration/M5-regulatory-library.test.ts:413` — `S4 — fn_regulation_update / PATCH /api/v1/regulations/:id > AC-S4-04`.
- **Functional rejection of the bad supersession was preserved** (UPDATE didn't commit) — only the FE inline-error UX degraded.

**Root cause:** the `fn_regulation_update` body in migration 050 had no structured-raise pre-check on `supersededById`. When the FK was missing, Postgres raised raw `23503` FK violation with no `field:` prefix in the message. BE `translatePgError` (`src/database/client.ts`) `case '23503'` ordering is:
1. Constraint-name allowlist (only `fk_contract_import_batch_id` from M1c) — no match.
2. `STRUCTURED_RAISE_RE` against `field:message` body — no match (raw FK had no `field:` prefix).
3. Fallback `UnprocessableEntityError(422)` — fired.

The sibling fn `fn_regulatory_impact_create_bulk` in the SAME migration 050 (lines 499-505) had the canonical structured-raise pre-check on its FK params. **DEFECT-1 was a parity miss** — pattern was known and used elsewhere in the same migration.

**The fix (migration 053):** 9-line `IF v_new_superseded_by IS NOT NULL THEN PERFORM 1 FROM regulation WHERE id = v_new_superseded_by AND is_active = TRUE; IF NOT FOUND THEN RAISE EXCEPTION ... USING ERRCODE = '23503'` block, inserted INSIDE the existing `IF p_patch ? 'supersededById' THEN` branch, AFTER the self-supersede guard, BEFORE the UPDATE. The structured raise (`'fn_regulation_update: supersededById:Referenced regulation not found'`, ERRCODE `23503`) matches `STRUCTURED_RAISE_RE` in translatePgError, returning `ValidationError(msg, { supersededById: msg })` → HTTP 400 with the exact AC-S4-04 envelope.

Body byte-for-byte preserved otherwise (argument list, return type, LANGUAGE, SECURITY, search_path, DECLARE, permission gate, referenceCode immutability raise, FOR UPDATE row lock + P0002 not-found, self-supersede guard, full UPDATE block including auto-flip status='superseded', RETURN fn_regulation_get_by_id, REVOKE/GRANT envelope).

**Stage 2 lesson S2-23 (codified to MEMORY.md `feedback_stage2_checks_s2_16_to_s2_20.md` post-DEFECT-1):**
- For every fn_ accepting an FK id parameter (every BIGINT `p_*_id` param + every JSONB-extracted FK in patch DTOs), Stage 2 design-time check MUST verify a structured-raise PERFORM/IF NOT FOUND/RAISE 23503 pre-check exists before the UPDATE/INSERT clause.
- Canonical template:
  ```sql
  IF v_target_id IS NOT NULL THEN
    PERFORM 1 FROM <target_table>
      WHERE id = v_target_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_<x>: %', '<paramName>:Referenced <entity> not found'
        USING ERRCODE = '23503';
    END IF;
  END IF;
  ```
- DB-Impl Step 4 functional probe MUST include happy + negative path with regex match on the structured raise envelope.
- `translatePgError` 23503 branch ordering: constraint-name allowlist → STRUCTURED_RAISE_RE → fallback 422. Structured-raise preferred over more constraint-name overrides because constraint names are migration-scoped while structured raises are fn-body-scoped.

**MEMORY.md retitled** S2-16..S2-22 → S2-16..S2-23. Composition section updated: ERRCODE list expanded `(P0001/42501/P0002/23514/22023)` → `(P0001/42501/P0002/23514/22023/23503)`.

> **Forward-looking carry-forward (Stage 4 INFO):** 4 sibling M5 fn_'s currently lack the structured-raise pre-check on FK params — `fn_regulation_create.issuerId`, `fn_regulatory_update_create.regulator_id` + `categoryId`, `fn_regulatory_update_update.regulator_id` + `categoryId`. None currently fail tests (the cleaner-UX wins are defensive, not behaviour-changing for valid FKs). Captured as forward-looking carry-forward — patch when next AC requires the 400 envelope.

---

## How the regulatory radar surfaces in the UI

The radar is the FE's headline visualisation for M5. Implementation:

1. **Route entry:** `/app/regulatory-radar` (mounted in `src/routes/app/regulatory-radar.tsx`; new in M5).
2. **Dashboard component** (regenerated): `RegulatoryRadarDashboard` (`src/features/regulatory/components/`) — wraps the chart + filter panel + detail-on-select. Uses `useRegulatoryUpdateList` with debounced search (T10 — 300ms).
3. **Chart component (HARDENED):** `RegulatoryRadarChart` (the SVG visualization — formerly Lovable's `RegulatoryRadar.tsx` 543 LOC). Pure-props, no data layer; only T3 (i18n keys), T5 (semantic tokens), T6 (a11y — role='img', translated aria-label, prefers-reduced-motion-aware sweep + node-pop animations), T7 (type safety — camelCase prop renames), T11 (ErrorBoundary on parent route).
4. **Detail panel:** `RegulatoryUpdateDetailPanel` re-used inside the dashboard (regenerated; embeds `RegulatoryImpactPanel` from M4 with M5's freshly-wired `sampleContracts` prop — closes M4-FE-OI-3).
5. **Bulk amendment workflow:** `BulkAmendmentSheet` (regenerated; was Lovable's 912 LOC kitchen-sink wizard) — calls `POST /regulatory-impacts/bulk-detect` and routes downstream actions through M2 approvals + M4 AI summary instead of the original supabase `functions.invoke + approvalEngine + direct supabase.from() writes` chain.

The two impact-surfacing paths on a contract:
- **Inline contract-detail banner (`RegulatoryImpactBanner`):** regenerated; calls `useRegulatoryImpactList({ contractId })` with the pagination filter; renders amber strip + severity dots + "review" CTA; returns null when empty (Lovable parity).
- **Standalone impacts list (`RegulatoryImpactsList`):** new in M5; paginated impact list with scope filters; powers the `RegulatoryImpactResolveDialog` (T9 destructive — radio-action picker IS the explicit commitment).

---

## FE harden vs regenerate breakdown — extreme regenerate ratio

M5 follows the established M2 4/8 → M3 5/12 → M4 5/5 trend. **1 hardened + 5 regenerated + 14 net-new** of the 20 .tsx component files.

| Component | Lovable LOC | Fate | Cycles | Reason |
|---|---|---|---|---|
| `RegulatoryRadarChart` (SVG visualization) | 543 | hardened | 1 | Pure-props pass-through; ZERO supabase coupling. T3/T5/T6/T7/T11 only. The lone harden in M5. |
| `RegulationsListView` | 232 + slice of 1282 | regenerated | 0 | Lovable admin list was 3 supabase reads chained inline; the index was a 1282 LOC kitchen-sink route mixing list+detail+filter+banner. |
| `RegulationDetailDrawer` | inline in 1282 LOC | regenerated | 0 | Detail rendering tangled with parent route's filter state + impact-loading code. |
| `RegulatoryRadarDashboard` (wrapper) | 539 | regenerated | 0 | Tightly bound to non-existent supabase tables (per M4-FE-OI-3). Dashboard regenerated; the SVG chart inside hardened separately. |
| `BulkAmendmentSheet` | 912 | regenerated | 0 | 5-step wizard chained `supabase.functions.invoke` + `approvalEngine` + direct `supabase.from()` writes — none exist in v2.6 (M2 owns approval routing; the bulk-detect endpoint owns just detection). Hardening would replace ~85% of file content + violate M2/M3 separation of concerns. |
| `RegulatoryImpactBanner` | 172 | regenerated | 0 | Lovable banner reads from `regulatory_impacts → regulatory_updates` join via supabase; v2.6 fn_regulatory_impact_list returns a different (camelCase JSONB) shape. Visual silhouette preserved (amber strip, severity dots, review CTA). |
| 14 new components | n/a | net-new | n/a | No Lovable equivalent — admin-side surfaces (CRUD dialogs, delete confirms, impact-category admin, picker, resolve dialog). |

**Rationale for the extreme regenerate ratio (5 of 6 Lovable-bearing components — 83%):** when the Lovable wire shape is fundamentally different (or when source tables don't exist yet — M4 and the Q1 deferral; or when the component chains supabase writes that violate the v2.6 separation of concerns), regenerate is the right answer. Per memory `feedback_regenerate_when_lovable_too_coupled.md`. Cumulative across the project: M1a 0/11, M1b 0/4, M1c 0/3, M2 4/8, M3 5/12, M4 5/5, **M5 5/6**.

**The lone harden (`RegulatoryRadarChart`)** was selected because the Lovable file had ZERO supabase coupling — pure-props SVG visualisation, hardenable in 1 cycle with only the 5 transformations listed. The 13-item harden checklist explicitly skips T1 (data layer), T2 (React Query), T4 (3 data states), T8 (form hygiene), T9 (destructive), T10 (debounce), T12 (date), T13 (sensitive) for this component because each is N/A — props-only, no data, no fetching, no forms, no destructive ops, no debounce, no dates rendered, no sensitive fields.

---

## i18n parity (M5)

**+222 keys per locale** (en + ar — parity match=true; programmatically verified via `scripts/m5-i18n-inject.cjs`).

Pre-M5 totals: en=3,903 / ar=3,903 (post-M4 with i18n nesting patch). Post-M5 totals: en=4,125 / ar=4,125.

Namespaces added:
- `regulatory.regulation.*` — list / detail / form / delete dialog (S1..S5).
- `regulatory.regulatoryUpdate.*` — list / detail / form / delete dialog (S6..S10).
- `regulatory.impact.*` — banner / list / resolve dialog (S12..S13).
- `regulatory.bulkAmend.*` — bulk-detect wizard (S11).
- `regulatory.banner.*` — RegulatoryImpactBanner.
- `regulatory.impactCategory.*` — admin list / picker / form (S14..S15).
- `regulatory.radar.*` — radar chart (T3-shifted from Lovable's `regulations.radar.*` namespace).
- `regulatory.errors.*` — translateApiError fallback keys.

Namespaces extended:
- `common.{deleting, processing, actions}` — minor non-destructive additions.
- `common.pagination.{showing, previous, next}` — pagination UX tokens.

> Plural variants reduced to `_one` + `_other` on the AR side (matching English pluralization arity) to maintain leaf-count parity. AR plural categories (zero/two/few/many) deliberately left out of M5 keys because the script runner cannot synthesize realistic AR plurals at scale; downstream l10n pass would extend if needed.

---

## Testing Agent results (M5)

**Total: 78 / 78 PASS** post-DEFECT-1 patch (migration 053).

| File | Tests | Coverage |
|---|---|---|
| `tests/integration/M5-regulatory-library.test.ts` | 27 / 27 | S1..S5 (regulation CRUD + supersession chain) |
| `tests/integration/M5-regulatory-updates.test.ts` | ~22 | S6..S10 (regulatory update CRUD + impact summary aggregate + cascade-soft-delete) |
| `tests/integration/M5-regulatory-impacts.test.ts` | ~20 | S11..S13 (bulk-detect idempotency + list RLS narrowing + polymorphic resolve) |
| `tests/integration/M5-impact-categories.test.ts` | ~9 | S14..S15 (taxonomy list + upsert) |

Coverage targets met at PASS tier (file-scoped):
- Lines: **93.05%** (target ≥90%; PASS).
- Functions: **100%** (target ≥90%; PASS).
- Branches: **81%** (target ≥80%; PASS).

The 18 pre-existing TEST-DEBT-M1 carry-forward failures + M2-fixture-flake from prior modules remain unchanged — captured as carry-forward, NOT touched per orchestrator policy. Zero regressions introduced by M5.

---

## How to extend M5

**To add a new regulation field:**
1. New migration: `ALTER TABLE regulation ADD COLUMN <name> <type>`.
2. Update `fn_regulation_create` and `fn_regulation_update` to handle the field (camelCase patch key → snake_case column).
3. Update `fn_regulation_get_by_id` JSONB output to include the new field.
4. (If list-relevant) Update `fn_regulation_list` JSONB output and add an index.
5. Update `Regulation` + `CreateRegulationDto` + `UpdateRegulationDto` in `src/types/regulatory.types.ts` (FE counterpart in `src/types/entities/regulatory.types.ts`).
6. Update Zod schemas in `src/schemas/regulatory.schemas.ts`.
7. Run `/state-update` to refresh the artifact store.

**To add a new regulator:**
1. New migration: `INSERT INTO regulator (code, name_en, name_ar, jurisdiction, ...) VALUES (...) ON CONFLICT (code) DO NOTHING`.
2. No code changes — `RegulatorRef` is auto-embedded by the existing fn_'s.

**To add a new impact_category:**
1. Use the live API: `POST /api/v1/impact-categories` with `{ key, nameEn, nameAr, ... }` (idempotent upsert keyed on `key`).
2. Or migration seed: `INSERT INTO impact_category (key, name_en, name_ar, ...) ON CONFLICT (key) DO NOTHING`.

**To add a 4th cron driver (M6+ — when relevant):**
1. Copy M4's `ai-insight-eviction.cron.service.ts`, change the schedule env var name, change the fn name.
2. Add a one-line registration in `server.ts` `app.listen(...)` + `process.on('SIGTERM' / 'SIGINT', ...)` graceful-shutdown.
3. **The 3-cron threshold has been crossed by M4.** When M6 lands the 4th cron, extracting a shared `cron-runner.ts` becomes a defensible Phase 2 architectural decision (M4 carry-forward).

**To add a new activity_type (cumulative chain M5 25 → M6 N):**
1. Atomic migration extending `contract_activity.activity_type` CHECK enum AND `fn_contract_activity_create` body whitelist (mirror migration 047 pattern — same migration, dynamic constraint name lookup).
2. Extend the M-of-the-day types file's `M[N]_ACTIVITY_TYPE_EXTENSIONS` const literal-by-literal (S2-19 byte-for-byte preservation; M0..M5 type files NOT modified).
3. Whoever calls `PERFORM fn_contract_activity_create(..., '<new_type>', ...)` is responsible for atomic ordering (the CHECK enum extension MUST land in the same migration as the body whitelist extension — otherwise the call rejects on the first invocation).

**To add a new permission for regulatory access:**
1. Add to `permission` table via migration.
2. Pre-emptively grant to Super Admin in the same migration (M1a 006 / M1c 018 / M2 028 / M3 037 / M4 044 / M5 046 lesson).
3. Update the controller permission gate.

---

## Pino redact extensions (M5)

`src/utils/logger.util.ts` SENSITIVE_PATHS extended:
- `impactPayload` / `impact_payload` (full envelope per DN-5; AI-generated content; `ai_prompt_payload` class per M4 precedent).
- `summaryAr` / `summary_ar` (mirrors M4 `summaryEn` coverage).
- `noteEn` / `note_en` / `noteAr` / `note_ar` (inner per-contract payload fields).

**Q10 NOT EXTEND** — `fn_audit_trigger v_redact_fields` UNCHANGED in M5. `impact_payload` is a fn parameter only (never a column path); the destructured columns (`impact_score`, `impact_note_*`, `impact_summary_*`) are NOT in fn_audit_trigger redact list — their values appear verbatim in audit_log on INSERT. Acceptable per Agent 2 sensitiveFields analysis (regulatory impact text is not user PII).

**Intentional non-redacts:**
- `resolutionNote` — Q8 admin-bounded free text; AC-S13-07 stored verbatim.
- `impactScore` — numeric metric; not user PII.

---

## translatePgError extensions (M5)

`src/database/client.ts` `translatePgError` extended:

| ERRCODE | Branch | Maps to | AC |
|---|---|---|---|
| 23501 (restrict_violation) | structured raise → ValidationError(400) — `referenceCode` immutable | 400 with `{ referenceCode: <msg> }` | AC-S4-05 |
| 23503 (FK violation) — STRUCTURED_RAISE_RE | structured raise → ValidationError(400) — field-scoped FK miss | 400 with `{ <field>: <msg> }` | AC-S11-04, AC-S11-05, **AC-S4-04 (added in 053)** |
| 23503 (FK violation) — 'cannot delete' message family | ConflictError(409) — active-impact guard | 409 cleaner-UX | AC-S5-02 |
| 42501 (insufficient_privilege) | ForbiddenError(403) — polymorphic gate / platform_admin only | 403 | AC-S5-04, AC-S10-04, AC-S13-05, AC-S15-05 |

The M1c `fk_contract_import_batch_id` constraint-name shortcut is preserved verbatim above the new 23503 STRUCTURED_RAISE_RE branch. Branch ordering matters — constraint-name allowlist runs first, then STRUCTURED_RAISE_RE, then fallback 422 (S2-23 lesson).

---

## Files owned by M5

**Backend (5 created + 3 modified):**
- Created: `src/types/regulatory.types.ts` (624 lines), `src/schemas/regulatory.schemas.ts` (327 lines), `src/services/regulatory.service.ts` (363 lines), `src/controllers/regulatory.controller.ts` (695 lines), `src/routes/v1/regulatory.routes.ts` (261 lines).
- Modified: `src/routes/v1/index.ts` (+4 named imports + 4 `v1Router.use(...)` mounts for `/regulations`, `/regulatory-updates`, `/regulatory-impacts`, `/impact-categories`; M0..M4 mounts untouched), `src/utils/logger.util.ts` (M5 SENSITIVE_PATHS extensions lines 588-645), `src/database/client.ts` (translatePgError 23503/23501 M5 branches).
- Migrations: 046..052 (7 designed) + 053 (DEFECT-1 patch).
- Tests: 4 files under `tests/integration/M5-*.test.ts`.

**Frontend (24 created + 4 modified):**
- Created: `src/types/entities/regulatory.types.ts`, `src/services/api/regulatory.service.ts`, `src/features/regulatory/hooks/useRegulatory.ts` (15 hooks 1:1 with fn_'s), `src/features/regulatory/hooks/useRegulatorCatalog.ts`, 2 form-schema modules, 20 components under `src/features/regulatory/components/`, 3 routes under `src/routes/app/` (admin.regulations, admin.impact-categories, regulatory-radar), `scripts/m5-i18n-inject.cjs`.
- Modified: `src/routeTree.gen.ts` (manual patch; TanStack router-plugin overwrites on next vite dev/build — M5-FE-OI-4 = M4-FE-OI-1 recurrence), `src/i18n/en.json` (+222 leaves), `src/i18n/ar.json` (+222 leaves), `src/features/ai/components/RegulatoryImpactPanel.tsx` (surgical 2-line additive — `sampleContracts?: AiRegulatoryImpactSampleContract[]` prop wired; closes M4-FE-OI-3).

**Component fates (FE):**
- 1 hardened (`RegulatoryRadarChart` — pure-props SVG; the lone harden in M5).
- 5 regenerated (`RegulationsListView`, `RegulationDetailDrawer`, `RegulatoryRadarDashboard`, `BulkAmendmentSheet`, `RegulatoryImpactBanner`).
- 14 net-new (no Lovable equivalent — admin CRUD + delete confirms + impact-category admin + picker + resolve dialog + form-fields wrappers).

---

## Open issues / forward-looking

- **REG-OI-A** (LOW): `RegulationListItem` is a reduced shape vs `Regulation` (list omits summaryEn/Ar, sourceUrl, tags, supersededBy chain). Mirrors M1a Contract / ContractListItem split. FE that needs those columns in list views must call `fn_regulation_get_by_id` per-row.
- **REG-OI-B** (LOW): `regulator` entity has no list/CRUD endpoints in M5 (admin lookup management deferred). 9 rows seeded in migration 048; admin extends via DDL/migration. **M5-FE-OI-1 carry-forward:** the FE `useRegulatorCatalog` hook dedupes regulators from the first 100 regulatory_updates list rows. Brand-new tenants with zero regulatory_updates will see an empty issuer/regulator dropdown until at least one update is created. Resolution: future module adds `/api/v1/regulators` endpoint OR the FE eats the empty-state UX.
- **REG-OI-C** (INFO): S6 'AI explain' / 'AI amendment' / 'PDF export' actions consume M4 endpoints (`POST /api/v1/ai/regulatory-impact` + `POST /api/v1/ai/regulatory-impact-summary`). M5 wires the missing `sampleContracts` array population (closes M4-FE-OI-3). M4-owned endpoints UNCHANGED.
- **M5-FE-OI-2** (LOW): `RegulationEditDialog` does not expose `supersededById`. The polite supersession-pairing UX needs its own design cycle.
- **M5-FE-OI-3** (LOW): `BulkAmendmentSheet` derives `regulationId` from the first impact's regulation. If the impacts list becomes empty post-bulk-detect, the regulationId is unrecoverable from this context.
- **M5-FE-OI-5** (LOW): `RegulatoryImpactBanner` does not surface compliance deadlines. fn_regulatory_impact_list payload omits regulatory_update.complianceDeadline (only id/title/severity are embedded). To surface deadlines we'd need either (a) a BE projection extension or (b) a per-row second fetch.
- **S2-23 forward-looking carry-forward**: 4 sibling M5 fn_'s lack the canonical structured-raise FK pre-check on FK params (`fn_regulation_create.issuerId`, `fn_regulatory_update_create.regulator_id` + `categoryId`, `fn_regulatory_update_update.regulator_id` + `categoryId`). None currently fail tests. Patch when next AC requires the 400 envelope.

---

*Generated by Documentation Generator from M5 be-implementation-summary.json + fe-implementation-summary.json + 053-defect1-patch-summary.md + qa-stage4-report.json. No Codex review run for M5 (Dexian decision 2026-05-04; 4th consecutive validated).*

---

# M6 Implementation Notes — Dashboards & Reporting

> **Module:** M6 — Dashboards & Reporting (ninth module — 5 role-scoped dashboards + executive overview + AI cost summary + admin health probe).
> **Generated:** 2026-05-05.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Status:** Complete. QA Stage 4 PASS first-run. 10 endpoints across 2 namespaces. Migrations 054..056 + 057 (DEFECT-1 patch). `schema_migrations.version=57` on `test` and `m0-foundation`. Codex adversarial review SKIPPED (Dexian decision 2026-05-04 — **6th consecutive validation** through M2/M3/M4/M5/M6; pattern fully entrenched). 92/92 M6 net-new tests PASS; 18 pre-existing TEST-DEBT-M1 failures unchanged (no regressions).

For data-dictionary detail (views / fn_'s / RLS / permission codes) see [`data-dictionary.md`](data-dictionary.md) M6 section. For OpenAPI wire spec see [`api/openapi.yaml`](api/openapi.yaml). For the Lovable transformation log see [`lovable-handoff.md`](lovable-handoff.md) M6 section.

---

## What this module builds

M6 is the **first read-only module** in the project pipeline. It introduces 10 dashboard / observability endpoints that compose existing M0..M5 telemetry into role-shaped snapshots. There are **no new tables**, no ALTER TABLE, no new columns. The DB surface is 4 plain views + 10 fn_'s (all SECURITY INVOKER) + 1 new permission code + 1 new RLS SELECT policy on the borrowed `schema_migrations` table.

The 13 stories:
- S1 / S13: Admin dashboard (insights chart layout + tile-grid landing) — same backend, different FE shell.
- S2: Drafter dashboard.
- S3: Approver dashboard.
- S4: Legal counsel dashboard.
- S5: Recipient dashboard.
- S6: Dashboard router (decides where each user lands on `/app/dashboards/insights`).
- S7: Executive enterprise overview (with inline AI cost figure).
- S8: Cached executive anomalies history viewer.
- S9: ExecutiveAnomaliesCard mount inside ExecutiveDashboard (FE-only — closes M4-FE-OI-2 half 1).
- S10: VersionDiffSummaryPanel mount inside ContractVersionList (FE-only — closes M4-FE-OI-2 half 2).
- S11: Standalone AI cost summary endpoint (sidebar panel on admin dashboard).
- S12: Admin observability health probe.

---

## Architecture summary

```
[FE — TanStack Start + React 19]
              │
              │ apiClient (axios; Bearer JWT; X-Request-ID)
              ▼
   /dashboards/*               /admin/health
   (admin / drafter / approver / legal-counsel / recipient / router /
    executive / executive/anomalies-history / ai-cost-summary)
              │
              └── thin Express controller → service → db.callFunction
                                              │
                                              ▼
[PostgreSQL — Neon, RLS-enabled]
       fn_dashboard_*          fn_health_check
       (10 fn_'s; all SECURITY INVOKER; PUBLIC count stays at 5)
                          │
                          ▼
       4 plain VIEWs              M0..M5 source telemetry
       (vw_contract_status_summary,   contract / approval_step /
        vw_approval_queue_metrics,    approval_decision / signature_event /
        vw_signature_status_summary,  signature_invitation / regulatory_impact /
        vw_regulatory_impact_summary) ai_request_log / ai_insight / audit_log /
                                      schema_migrations
```

**Key things to know:**

1. **Read-only by design (Q11=DEFER).** Zero write paths. No new cron driver. The 3 existing crons (M2 approval-escalation, M3 signature-expiration, M4 ai-insight-eviction) stay as-is. Aggregates compute on demand at request time — there is no pre-warm or refresh scheduler.

2. **Single-source-of-compute (Q5 lock) for AI cost.** `vw_ai_cost_rollup` was intentionally NOT designed. Both `fn_dashboard_executive.kpis.aiCostUsdWindow` (S7 inline) and `fn_dashboard_ai_cost_summary` (S11 standalone) read from the same M4 fn_ai_request_log_cost_report. No duplicate compute path.

3. **Zero new PUBLIC EXECUTE grants.** PUBLIC EXECUTE allowlist remains the M3 set of 5 names — **6th consecutive validation** (S2-21 sustained). All 10 M6 fn_'s are `REVOKE ALL ... FROM PUBLIC; GRANT EXECUTE ... TO neondb_owner` only.

4. **ARCH-NEW-3 option (c) — `schema_migrations_select_admin` permissive RLS SELECT policy.** Migration 054 adds a narrow permissive SELECT policy on the M0-owned `schema_migrations` table. Without it, `fn_health_check.db.latestMigration` would force-NULL on any non-superuser pool connection (the existing deny-all RESTRICTIVE policy blocks all reads). The pre-existing deny-all is preserved and continues to block INSERT/UPDATE/DELETE for non-superusers. `fn_health_check` stays SECURITY INVOKER — no DEFINER carve-out.

5. **The router endpoint (S6) drives the FE shell choice.** `dashboardKey` decision tree per db-design.md §3.6 step 4: platform_admin / Super Admin → 'admin'; default fallback → 'recipient' (least-privilege view). Role extraction uses `COALESCE(v_user->'role'->>'name', v_user->>'roleName', 'unknown')` per S2-22-WARN-3-FIX — live `fn_user_get_by_id` returns nested `role:{id,name}`, NOT flat `roleName`.

---

## Locked Gate 2 decisions (Q1..Q12 + ARCH-NEW-1/2/3)

The developer accepted ALL 15 architect recommendations at HITL Gate 2 ("accept all"). Captured here for future reference:

| Q | Decision | Rationale |
|---|---|---|
| Q1 | CONFIRM zero new PUBLIC fn_'s | All 10 M6 fn_'s REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner only. Stage 4 enumerate-PUBLIC-grants verifies count = 5. |
| Q2 | 1 new permission code (`insights.executive`) + 3 grants | Pre-emptive Super Admin + platform_admin + executive grants seeded in migration 054. Without it, `fn_dashboard_executive` 403's universally. |
| Q3 | Plain VIEWs (4) — non-materialised | Query-time projection suitable for dashboards where freshness > pre-compute. Underlying tables already have the right indexes. |
| Q4 | Resolved in discovery — no separate decision | (resolved via earlier Phase 1 dependency mapping) |
| Q5 | DROP `vw_ai_cost_rollup` — single-source-of-compute | Both S7 inline and S11 standalone wrap M4 `fn_ai_request_log_cost_report`. No duplicate compute. |
| Q6 | windowDays caps: 1..365 (operational) / 1..90 (ai-cost) | Operational dashboards default 30; executive 90; ai-cost 30. AI sub-call truncates to last 90 via LEAST clause. |
| Q7 | LIMIT 5 hardcoded for list slots | `pendingQueue5`, `pendingSignatures5`, `myDrafts5`, etc. — no pagination on dashboard list slots. Tile-shaped UX. |
| Q8 | `insights.executive` grants (3 roles) | Super Admin + platform_admin + executive. Permission code is alternate gate path on `fn_dashboard_executive` (OR of role check). |
| Q9 | DEFER `dashboard_config` | No per-tenant dashboard config in M6. Deferred to a future module. |
| Q10 | Endpoint paths under `/api/v1/dashboards/*` + `/api/v1/admin/health` | New `/dashboards/` namespace (8 routes); admin/health under existing `/admin/` namespace (introduced in M2). |
| Q11 | DEFER sibling sweep (M5 4 sibling fn_ FK pre-checks) | M6 is read-only; bundling M5 write-fn patches confuses migration history and module attribution. Carry forward to a dedicated M5-patch slot. |
| Q12 | Keep `fn_health_check` tight | Pure observability probe. Audit block subsequently DROPPED in Patch Round 1 per S2-22-WARN-2-FIX (audit_log.action enum is INSERT/UPDATE/DELETE only — `'ERROR'` literal dead-on-arrival). |
| ARCH-NEW-1 | DEFER M4 `audit.read.all` drift fix | M4 RLS policies reference `'audit.read.all'` (4 sites) but only `'audit.read'` is seeded in M0. M6 `fn_dashboard_legal_counsel` uses `'audit.read'` (the live seeded code) per CRIT-4 lock. Schedule a dedicated M4-patch slot. |
| ARCH-NEW-2 | CONFIRM recipient email-match SQL plan | `lower(signature_party.signer_email) = lower(current_user.email)`. Case-insensitive; relies on existing functional index pattern. |
| ARCH-NEW-3 | Option (c) — permissive SELECT RLS policy on schema_migrations | Keeps `fn_health_check` SECURITY INVOKER; deny-all RLS continues to block writes; narrow permissive SELECT policy unlocks `MAX(version)` read for admin roles. |

---

## Stage 2 round 1 catch story — 6 column-existence + 3 WARN clarifications

QA Stage 2 (round 1) caught **6 column-existence FAILs + 3 WARN clarifications** that would have caused SQLSTATE 42703 or dead-on-arrival predicates at first runtime invocation. Per memory `feedback_db_impl_report_dont_fix.md` and S2-22 mandatory protocol, these were resolved at design time via in-place surgical edits to `db-design.md` (Patch Round 1; 2026-05-05). Stage 2 round 2 PASS.

| Fix | Severity | Symptom | Resolution |
|---|---|---|---|
| **S2-22-FIX-1** | CRITICAL | `fn_dashboard_recipient.signedByMeWindow` referenced `signature_event.signer_user_id` / `signed_at` / `outcome='signed'` — none exist on live `signature_event`. | Rewrote to `actor_user_id` / `created_at` / `event_type='signed' AND is_active=TRUE`. Added DN-19 documenting that `actor_user_id IS NULL` for external-only invitation signers (acceptable trade-off; internal/UAE-PASS signers are counted). |
| **S2-22-FIX-2a** | CRITICAL | `fn_dashboard_approver` referenced `approval_step.assigned_to` — column doesn't exist; live model is COALESCE(delegated_to, reassigned_to, approver_user_id) per M2 override-chain. | Rewrote effective-assignee predicate to `COALESCE(delegated_to, reassigned_to, approver_user_id) IS NOT DISTINCT FROM v_user_id` (preserves S2-18 NULL-safe equality). |
| **S2-22-FIX-2b** | CRITICAL | `assigned_at` referenced for velocity / requestedAt; doesn't exist. | Rewrote to `step.created_at` (rows are immutable post-create per `trg_approval_step_immutable_fields`). Both `vw_approval_queue_metrics` PERCENTILE_CONT clauses also corrected. |
| **S2-22-FIX-3** | CRITICAL | `decided_at >= NOW()` joined to non-existent `decider_user_id`. | Rewrote to `approval_decision.decided_by`. |
| **S2-22-FIX-4** | HIGH | `fn_dashboard_legal_counsel.auditSummary` aggregated by `audit_log.entity_type` — doesn't exist (audit_log columns are id/table_name/record_id/action/old_values/new_values/changed_by/changed_at). | Rewrote to `jsonb_object_agg(table_name, count)`. JSONB key was renamed `entityType` → `tableName` to keep camelCase faithful to the live source column. |
| **S2-22-FIX-5** | CRITICAL | `signature_invitation.sent_at` / `expires_at` referenced — doesn't exist (live columns are `invitation_sent_at` / `invitation_expires_at`). | Rewrote to `si.invitation_sent_at AS "sentAt"` and `si.invitation_expires_at AS "expiresAt"` — camelCase wire shape preserved via SQL aliases. `vw_signature_status_summary` PERCENTILE_CONT also corrected. |
| S2-22-FIX-6 | MEDIUM (doc-only) | PERFORMANCE NOTES referenced `idx_contract_status_active` / `idx_approval_step_status_active` — neither exists. | Replaced with the closest live partial indexes per `contract.sql` / `approval_step.sql`. No runtime impact. |
| S2-22-WARN-1-FIX | WARN | `decision IN ('approved','rejected')` past-tense literals — would always evaluate FALSE because `approval_decision.decision` CHECK enum is `'approve','reject',...`. | Rewrote to present-tense `decision='approve'` and `decision='reject'`. |
| **S2-22-WARN-2-FIX** | WARN | `fn_health_check` audit probe used `audit_log.action = 'ERROR'` — CHECK enum is `'INSERT','UPDATE','DELETE'` only; literal could never match. | DROPPED the entire `errorCountLastHour + lastErrorAt` audit block. Error signal sourced exclusively from `ai_request_log.outcome IN ('error','timeout','rate_limited','cancelled')`. JSONB output shape simplified accordingly. |
| **S2-22-WARN-3-FIX** | WARN | `fn_dashboard_router` extracted role via `v_user->>'roleName'` — flat-key shape; live `fn_user_get_by_id` returns nested `role:{id,name}`. Would silently fall through to default `'recipient'` for ALL users. | Rewrote to `COALESCE(v_user->'role'->>'name', v_user->>'roleName', 'unknown')` — primary path matches verified live shape; fallback preserved for forward-compat; literal `'unknown'` ensures the CASE deterministically lands on safe-default `'recipient'` branch instead of silent NULL-propagation. |

**Outcome:** Stage 2 round 2 PASS. All 9 corrections applied without Q1..Q12 + ARCH-NEW-1/2/3 regression. Live runtime probes during DB Implementation confirmed all corrections work as intended.

---

## DEFECT-1 retrospective + S2-22b codification recommendation

The DB Implementation Agent caught a CRITICAL escape that Stage 2 (round 2 PASS) did not — **JOIN-target column drift** that lazy-compiled past `pg_proc` registration and surfaced only on first realistic invocation.

**The bug:** `fn_dashboard_approver.lists.pendingQueue5` referenced `step.contract_id` in the inner join. Live `approval_step` has only `approval_chain_id` — the contract reference travels via `approval_chain.contract_id`. First runtime probe (`SET LOCAL app.current_user_id='11'; SELECT fn_dashboard_approver(30);`) raised PostgreSQL `42703 column step.contract_id does not exist`.

**Root cause:** Design (db-design.md §3.3) and Patch Round 1 both retained `step.contract_id` reference. The S2-22 column-existence sweep verifies columns on the NAMED tables — it did NOT trace through implicit JOIN-target references where a column is qualified with the target-side alias but conceptually belongs to a different table reachable through the FK graph.

**The fix (migration 057):** `CREATE OR REPLACE FUNCTION fn_dashboard_approver(INTEGER)` with corrected join chain `approval_step step JOIN approval_chain ch ON ch.id = step.approval_chain_id JOIN contract c ON c.id = ch.contract_id`. Signature unchanged; output JSONB shape unchanged. Mirrors M3 038/039 + M4 045 + M5 053 named-fix-migration precedent.

**Verification:** Re-probed with user 1262 (1 pending step) — returns full contract context: `contractId=4076, contractNumber='PROBE-031-E-1777885059', valueAed=100000, hoursWaiting=53.1`.

**S2-22b codification recommendation:** for every JOIN clause `<table_a> JOIN <table_b> ON <cond>`, every column referenced anywhere in the fn body that is QUALIFIED with the target-side alias MUST be verified against the live DDL of the target side, not just the source side. Where ambiguity exists, trace through the FK graph in `project-artifacts/database/tables/*.sql`.

This is the **third consecutive escape** in the family (M3 038/039, M4 045, M5 053, M6 057 — different shapes but same pattern: a column reference that LOOKED valid against the design's stated source but failed against live DDL on first invocation). The S2-22 sweep at design time + the `report-don't-fix` discipline at DB-Impl successfully escalated all four to named patch migrations rather than silent rewrites. The codification proposal extends S2-22 to also trace JOIN-target columns through the FK graph.

---

## How dashboards consume M0..M5 telemetry

M6 is intentionally a thin composition layer over existing telemetry. The data flow:

| Dashboard | M0..M5 sources |
|---|---|
| **Admin (S1)** | `contract` (status / value_aed / created_at), `approval_step` (status='pending'), `signature_invitation` (status='pending'), `regulatory_impact` (resolved=FALSE), `audit_log` (recent events 30d), `"user"` (active count), `approval_decision` (decisions per day window). Plus `vw_contract_status_summary`. |
| **Drafter (S2)** | `contract` filtered to `drafted_by = current_user_id`, `approval_step` status='request_resubmission' or rejected step pointing back to drafter, `approval_decision.decision_note` (lastDecisionNote — sensitive; M2 pino-redact applies). |
| **Approver (S3)** | `approval_step` filtered by COALESCE(delegated_to, reassigned_to, approver_user_id) override chain, `approval_decision` (caller's decisions in window via `decided_by`), peer-velocity AVG via approver_role match. **JOIN chain post-057:** approval_step → approval_chain → contract. |
| **Legal counsel (S4)** | `regulatory_update` (window count by `published_date` + critical severity), `regulatory_impact` (open count, resolved=FALSE), `regulation` (catalog size), `audit_log` (table_name aggregate — gated on audit.read; M0 permission). M5 `vw_regulatory_impact_summary`. |
| **Recipient (S5)** | `signature_party` (case-insensitive email match), `signature_invitation` (pending count), `signature_event` (signedByMeWindow — actor_user_id + event_type='signed'). |
| **Router (S6)** | M0 `fn_user_get_by_id` (nested `role:{id,name}` shape). |
| **Executive (S7)** | `contract` (active value AED, status, expiry cliffs), `regulatory_impact` × `regulatory_update.severity='critical'`, M4 `fn_ai_request_log_cost_report` (inline aiCostUsdWindow — 90-day cap via LEAST). Plus `vw_contract_status_summary`. |
| **Executive anomalies history (S8)** | M4 `ai_insight` cache where `entity_type='executive_anomalies'` via `fn_ai_insight_list`. |
| **AI cost summary (S11)** | M4 `fn_ai_request_log_cost_report` direct pass-through (windowDays 1..90 cap). |
| **Admin health (S12)** | `schema_migrations` (MAX version — requires the new ARCH-NEW-3 (c) policy), `ai_request_log` (last success / last failure / outcome enum). |

Each fn_ is INVOKER, so RLS at the underlying tables continues to apply (e.g., `contract_select_role_aware` narrows the executive's view per CRIT-3). M6 does NOT introduce new DEFINER carve-outs — every dashboard relies on the caller's own role-aware visibility.

---

## FE harden vs regenerate breakdown — extreme regenerate (6 / 6)

**0 / 13 components hardened. 6 / 6 Lovable insights/*.tsx components REGENERATED.**

The Lovable source had 6 dashboard components totalling ~5,470 lines:
- `AdminDashboard.tsx` (450L)
- `DrafterDashboard.tsx` (809L)
- `ApproverDashboard.tsx` (674L)
- `LegalCounselDashboard.tsx` (1236L)
- `RecipientDashboard.tsx` (476L)
- `ExecutiveDashboard.tsx` (1825L) — pre-flagged in Phase 1 as DASH-OI-B (heavily supabase-coupled).

All 6 imported `supabase` directly and queried non-existent tables (`audit_summary_admin`, `dashboard_admin_kpi`, `supabase.functions.invoke('executive-anomalies')`, etc.). Hardening cycles would have replaced ~85% of file content per component without preserving meaningful visual fidelity (the Lovable look-and-feel was driven by hand-built supabase queries, not by visual primitives).

Per the established `feedback_regenerate_when_lovable_too_coupled.md` escape hatch — and consistent with the M5 5/6 (83%) precedent + DASH-OI-B carry-forward — all 6 were regenerated up-front without burning 3 cycles each.

**Cumulative regenerate trend:** M2 4/8 → M3 5/12 → M4 5/5 → M5 5/6 → **M6 6/6 (100%)**.

**Plus 6 net-new components** with no Lovable precedent:
- `InsightsRouter` (S6) — auto-redirect entry route.
- `ExecutiveAnomaliesHistoryCard` (S8) — standalone cache history viewer.
- `AICostPanel` (S11) — admin sidebar panel (mounts independently per DASH-OI-G).
- `AdminHealth` (S12) — admin observability shell.
- `dashboard-primitives` (shared) — KpiTile / PlaceholderKpiTile / TimeRangeSelector / DashboardLoadingSkeleton / DashboardErrorState / DashboardEmptyState / DashboardSection.
- `dashboards.service` / `useDashboards.ts` / `dashboards.types.ts` (data layer).

**Plus 2 mount-only edits to existing M4 components:**
- `ExecutiveAnomaliesCard` mounted into the new `ExecutiveDashboard` (S9) — closes M4-FE-OI-2 half 1.
- `VersionDiffSummaryPanel` mounted into `ContractVersionList` (S10) — closes M4-FE-OI-2 half 2.

**Plus 1 reuse via variant prop:**
- `AdminDashboard` (S13) — reused with `variant='tile-grid'` at `/app/admin/index.tsx` for the admin landing tile grid. Same backend (`GET /api/v1/dashboards/admin`), different FE shell.

---

## M4-FE-OI-2 closure narrative

M4 left two FE follow-ups open: `ExecutiveAnomaliesCard` and `VersionDiffSummaryPanel` were built but had no host dashboard / dialog to mount into. M6 closes both:

**Half 1 — S9: ExecutiveAnomaliesCard mount.** The new M6 `ExecutiveDashboard` (regenerated) derives an `anomaliesStats` object via `useMemo` from its own KPIs (`totalActiveValueAed`, `contractsByStatus`, `expiryCliffs`, plus a counterparty-share derivation as supplierConcentration). The existing M4 `ExecutiveAnomaliesCard` is rendered with `autoFetch={true}` so it self-fires once stats arrive. `language` derived from i18next.language. **No modifications to the M4 card itself.**

**Half 2 — S10: VersionDiffSummaryPanel mount.** No standalone `VersionCompareDialog` component existed in v2.6; `ContractVersionList` was the closest mount point per the post-M1a frontend structure. Edited `src/features/contracts/components/ContractVersionList.tsx` to add a `VersionDiffSummaryPanel` slot inside the expanded version row when an adjacent older version exists (idx + 1 in newest-first list). `additions` = current.bodyEn, `deletions` = older.bodyEn (full-blob; M4-FE-OI-4 documents this simplification — a future iteration could add client-side diff via `diff-match-patch` for sharper prompts), `modifiedClauses` = []. `autoFetch={false}` — user clicks the regenerate button to fire the M4 AI call (avoids accidental cost).

Both halves close cleanly. The 2 edits to existing files were surgical additive — no M4 type files modified.

---

## How to extend M6

**To add a new role-scoped dashboard (e.g., `procurement_officer`):**

1. Define the role's KPI / list slot shape in `src/types/entities/dashboards.types.ts` (mirror M6's `Drafter` / `Approver` shapes — keep KPIs flat-typed and lists a small fixed-LIMIT projection).
2. Create migration `058_<slug>_dashboard_function.sql` adding `fn_dashboard_<role>(p_window_days)` — pattern: role gate at fn body line 1 (RAISE 42501), 1..365 windowDays validate (RAISE 22023), `kpis + lists` JSONB output, `RETURN jsonb_build_object(...)`, `REVOKE ALL FROM PUBLIC; GRANT EXECUTE TO neondb_owner`. Stage 2 mandatory: S2-22 column-existence + S2-22b JOIN-target tracing for any joined column references.
3. Add the route + controller method + service wrapper following M6's `dashboards.routes.ts` + `dashboards.controller.ts` + `dashboards.service.ts` pattern (one wrapper method per fn_).
4. Add the React Query hook in `src/features/dashboards/hooks/useDashboards.ts` (use the `authedReadRateLimiter` pattern from M6 — every dashboard query goes through the same limiter bucket).
5. Add the route view component under `src/features/dashboards/components/<Role>Dashboard.tsx` reusing the shared `dashboard-primitives` (KpiTile / DashboardLoadingSkeleton / etc.). Wrap in `<ErrorBoundary>` per T11.
6. Update `fn_dashboard_router` (migration `058_<slug>_dashboard_router_extend.sql`) — extend the CASE statement to map the new role to the new dashboard key. `CREATE OR REPLACE` only; do not modify the M6-original migration 056.
7. Add i18n keys under `dashboards.<roleKey>.*` namespace in en.json + ar.json (parity required — run `scripts/m6-i18n-inject.cjs` template).
8. Run `/state-update` to refresh the artifact store.

**To add a new fn-to-fn cross-module call (e.g., from `fn_dashboard_legal_counsel` to a future `fn_compliance_status`):**

1. Verify the callee fn signature live via `pg_proc.pg_get_function_arguments` — Stage 2 S2-19 mandatory.
2. Add the `PERFORM`/`SELECT INTO` in the caller body. Pass-through caller's permission context (caller is INVOKER; callee enforces its own gate).
3. Update the fn_ comment block + `db-design.md` §8 internal-calls table.

---

## Pino redact extensions (M6)

**None.** M6 dashboards return aggregates only. List projections include `id` / `contractNumber` / `titleEn` / `titleAr` / `status` / `valueAed` / `updatedAt` — none of which appear in `project.config.json` `sensitiveFields[15]`. The standing M0..M5 redact contract is sufficient. Verified in `be-implementation-summary.json` `extendedArtifacts: []`.

The S10 `ContractVersionList` mount passes `bodyEn` / `bodyAr` to `VersionDiffSummaryPanel` as `additions` / `deletions` props — these ARE sensitive but flow only through the M4 fetch body to the AI endpoint (no console.log, no zustand, no localStorage). M4 redact contract unchanged.

---

## translatePgError extensions (M6)

**None.** M6 fn_'s use existing PG ERRCODEs already mapped:
- `42501` (permission denied) → 403 `ForbiddenError`.
- `22023` (invalid_parameter_value, for `windowDays` out of range) → 400 `ValidationError`.

Zod also catches the `windowDays` case at the controller layer; fn body re-validation is defence-in-depth. No new error patterns to map. Verified in `be-implementation-summary.json`.

---

## Testing Agent results (M6)

| Metric | Value |
|---|---|
| M6 net-new tests | **92 PASS** |
| M6 net-new failures | 0 |
| Production blockers | 0 |
| Test-framework fixes | 1 (helper column-name bug, fixed cycle 1) |
| Full suite total | 762 |
| Full suite passed | 744 |
| Full suite failed | 18 ← matches expected TEST-DEBT-M1 carry-forward exactly |
| M6 contribution | +92 (no regressions) |

Coverage by story: S1..S8, S11, S12 each have their own integration test file under `tests/integration/M6-*.test.ts` with 6..8 ACs per file. S9 / S10 / S13 are FE-only mounts with thin BE markers (covered by smoke + integration verifier).

**Critical catches codified during testing:**
- S3 — verified post-057 join chain works against real test data (user 1262 returns the expected contract context).
- S5 — verified S2-22-FIX-1 (`actor_user_id`) and S2-22-FIX-5 (`sentAt`/`expiresAt` aliases) live.
- S6 — verified WARN-3-FIX nested role.name extraction across 6 different roles.
- S7 — verified Q5 inline AI cost gate (null vs number) by toggling `ai.observability.read`.
- S12 — verified `db.latestMigration = 57` for admin (ARCH-NEW-3 option c live verified) + audit block dropped (WARN-2-FIX live verified — no audit block in JSONB output).

QA Stage 4 — PASS first-run. 44/44 standard + 8/8 S2-16..S2-23 + 20/20 L1-L20 Codex-lesson scan + 15/15 M6-specific Gate 2 decision checks = **87/87 PASS**. Zero patch rounds.

---

## Files owned by M6

**Backend (6 created + 2 modified):**
- Created:
  - `src/types/dashboards.types.ts` — TS interfaces for all 11 response shapes + 14 embedded shapes + 4 enums.
  - `src/schemas/dashboards.schemas.ts` — Zod schemas for query params (operationalDashboardQuerySchema / executiveAnomaliesHistoryQuerySchema / aiCostSummaryQuerySchema).
  - `src/services/dashboards.service.ts` — 10 thin pass-through methods (one per fn_).
  - `src/controllers/dashboards.controller.ts` — 9 controller methods (S1..S8 + S11) + admin health controller (S12).
  - `src/routes/v1/dashboards.routes.ts` — 9 routes under `/api/v1/dashboards/*`.
  - `src/routes/v1/admin/health.routes.ts` — 1 route under `/api/v1/admin/health`.
- Modified:
  - `src/routes/v1/index.ts` — added `dashboardsRouter` mount under `/dashboards`. M0..M5 mounts untouched.
  - `src/routes/v1/admin/index.ts` — added `healthRouter` mount under `/health` (in admin sub-router). Existing M2 / M4 mounts untouched.

**Migrations (4 — 054..057):** see `data-dictionary.md` M6 migrations table.

**Tests:** 10 integration test files under `tests/integration/M6-*.test.ts` (one per dashboard endpoint + one for the admin health probe).

**Frontend (25 created + 4 modified):**
- Created (data layer): `src/types/entities/dashboards.types.ts`, `src/services/api/dashboards.service.ts`, `src/features/dashboards/hooks/useDashboards.ts`, `scripts/m6-i18n-inject.cjs`.
- Created (components): `dashboard-primitives.tsx`, `AdminDashboard.tsx`, `DrafterDashboard.tsx`, `ApproverDashboard.tsx`, `LegalCounselDashboard.tsx`, `RecipientDashboard.tsx`, `InsightsRouter.tsx`, `ExecutiveDashboard.tsx`, `ExecutiveAnomaliesHistoryCard.tsx`, `AICostPanel.tsx`, `AdminHealth.tsx`.
- Created (routes): `src/routes/app/dashboards.{admin,drafter,approver,legal-counsel,recipient,insights,executive}.tsx`, `dashboards.executive.anomalies.tsx`, `admin.health.tsx`, `admin.index.tsx`.
- Modified: `src/i18n/en.json` (+202 leaves), `src/i18n/ar.json` (+202 leaves; parity 4327/4327 verified programmatically), `src/routeTree.gen.ts` (manual patch — TanStack router-plugin overwrites on next vite dev/build), `src/features/contracts/components/ContractVersionList.tsx` (S10 mount).

---

## Open issues / forward-looking

- **DASH-OI-A** (FE): Lovable's S29 ACs reference 'parties counts' (AdminDashboard) and 'obligations overdue' (RecipientDashboard) — but party/obligation tables do NOT exist in M0..M5. M6 returns explicit `{value:0, placeholder:true}` envelopes for the affected slots (`templateUsageThisWindow`, `myObligationsCount`). FE renders disabled tiles with 'feature pending' tooltips.
- **DASH-OI-G** (FE): `AICostPanel` mounts independently into admin dashboard sidebar via React Query (separate query key); NOT bundled into `/admin` payload. Single-source compute preserved (both S7 inline and S11 standalone read from `fn_ai_request_log_cost_report`).
- **M6-FE-OI-1**: TimeRangeSelector custom-range fires immediate refetch on each digit. React Query `keepPreviousData` mitigates flash, but a 300ms debounce on the custom input would tighten this. Out of scope for M6 (no story explicitly calls for it).
- **M6-FE-OI-2**: `topCounterpartiesByValue5` renders `counterpartyId` only — no name (no parties table yet). FE shows `'ID #{id}'` with a small 'Name pending' chip per AC-S7-04.
- **M6-FE-OI-3**: TanStack `routeTree.gen.ts` manually patched (recurrence of M5-FE-OI-4 / M4-FE-OI-1). Re-emission is automatic on next vite dev/build because the .tsx files exist.
- **M6-FE-OI-4**: VersionDiffSummaryPanel S10 mount uses bodyEn for both additions and deletions (no client-side diff). The M4 AI prompt computes its own diff from the before/after blobs. A future iteration could add `diff-match-patch` for sharper prompts.
- **ARCH-NEW-1** carry-forward: M4 `audit.read.all` drift fix DEFERRED to a dedicated M4-patch slot. M6 `fn_dashboard_legal_counsel` uses the live-seeded `audit.read` per CRIT-4 lock.
- **Q11** carry-forward: 4 sibling M5 fn_'s lack the canonical FK pre-check (`fn_regulation_create.issuerId`, `fn_regulatory_update_create.regulator_id` + `categoryId`, `fn_regulatory_update_update.regulator_id` + `categoryId`). DEFERRED — apply the canonical S2-23 template when the next AC requires the 400 envelope.
- **S2-22b codification recommendation** (this module): JOIN-target-column tracing — promoted to memory follow-up at module close. M6 = third consecutive module where a column-existence escape was caught at runtime probe (M3 / M4 / M5 / M6 each had similar 'design references column that doesn't exist on the named table' patterns; M6 specifically a JOIN-target variant).

---

*Generated by Documentation Generator from M6 db-design.md (post Patch Round 1), db-design-patch-round1.md, db-implementation-summary.json (incl. DEFECT-1 fix migration 057), be-implementation-summary.json, fe-implementation-summary.json, integration-verifier-report.json, smoke-test-be-report.json, module-M6-test-report.json (92/92 PASS), and qa-stage4-report.json (PASS first-run). No Codex review run for M6 (Dexian decision 2026-05-04; **6th consecutive validated**).*