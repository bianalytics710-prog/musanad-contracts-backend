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
