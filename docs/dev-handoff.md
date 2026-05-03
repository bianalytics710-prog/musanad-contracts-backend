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
