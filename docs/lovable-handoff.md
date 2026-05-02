# Lovable-to-Production Handoff - M0 Foundation

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M0 - Foundation
> **Pipeline:** Lovable Modernization v3.0 (Mode A - Lovable only, no BRD)
> **Source repo (Lovable):** `C:/Users/azureadmin/projects/musanad-contracts-hub`
> **Target repos:** `musanad-contracts-backend`, `musanad-contracts-frontend`
> **Generated:** 2026-05-02

This document is for the developer who originally built the Musanad Contracts Hub Lovable prototype. It records what was preserved, what was rebuilt, what was discarded, and the action items that remain before production. It is the primary cross-reference between the Lovable extraction artifacts and the v2.6 production codebase.

---

## Section 1 - What was preserved (the win)

The v2.6 pipeline kept the Lovable frontend stack and design DNA intact. Per `project.config.json` `preserveStack: true`, the entire frontend stack is unchanged.

| What | How preserved | Confidence |
|---|---|---|
| **Frontend stack** | TanStack Start + React 19 + Tailwind 4 - kept as-is. Vite config uses `@tailwindcss/vite` and `@tanstack/router-plugin`. SSR runtime is Cloudflare Workers (`wrangler.jsonc`). | 1.0 |
| **Brand identity** | `src/config/brand.ts` ported verbatim. Musanad / مُسَنَد. UAE-focused (region AE, timezone Asia/Dubai, currency AED). Inter wordmark. | 1.0 |
| **Design tokens** | 100% extracted from `src/styles.css` `@theme inline`. OKLCH palette: ink, gold, sage, amber, terracotta, slate, plum. 35 colour tokens, 5 fonts, 6 radius levels, 4 animation tokens. Zero adjustments. | 1.0 |
| **Theme provider** | Dark mode via `.dark` class. RTL via `html[dir="rtl"]`. Bilingual font stack: Inter / IBM Plex Sans Arabic / Aref Ruqaa / JetBrains Mono. | 1.0 |
| **i18n catalogue** | 2,990 EN keys + 2,990 AR keys (parity verified) preserved verbatim. M0 added 12 `dashboard.*` keys to both locales (FE-5 patch). | 1.0 |
| **Design system files** | 4 files locked in M0: `src/styles.css`, `src/components/theme-provider.tsx`, `src/components/ui/*` (49 shadcn primitives - none imported yet but all available), and the design-tokens README. Lock timestamp: 2026-05-02. DS-1, DS-2, DS-3 quality checks: PASS. | 1.0 |
| **PWA assets** | `public/sw.js`, `public/manifest.webmanifest`, `public/icons/icon-512.png` ready for harden when feature modules need them. | 1.0 |

---

## Section 2 - What was rebuilt (and why)

The backend was regenerated entirely. Lovable's pattern (frontend writes directly to Supabase tables via `supabase-js`) does not scale to enterprise compliance. v2.6 enforces "Database Objects First" - all business logic in PostgreSQL `fn_*` functions, thin HTTP controllers, real RLS, native JWT auth.

### 2.1 Backend - all of it

- New stack: Express + TypeScript strict + PostgreSQL (Neon) + raw `pg` driver (no ORM).
- New auth: native JWT (15m access + 7d refresh) with refresh-token rotation, server-side blacklist, 5/15 lockout, bcrypt(12).
- New RLS: real per-tenant + per-role + per-ownership filtering via `app.current_user_id` GUC + `fn_current_user_has_permission`. **No `USING(true)` policies anywhere.**
- New observability: Pino + 37+ redact paths + correlation UUIDs + OpenTelemetry stub.
- New AI layer: env-selectable provider abstraction (OpenAI primary, Anthropic stub) replacing the Lovable AI Gateway.
- New mailer: Nodemailer + SMTP, provider-agnostic.

### 2.2 Frontend integration layer (refactor in feature modules, not M0)

- All **322** `supabase.from()` call sites in the Lovable code will be refactored in feature modules to call the new backend.
- The Supabase client (`src/integrations/supabase/client.ts`) is replaced by an axios-based API client in `src/lib/api-client.ts`.
- `AuthProvider.tsx` (Supabase Auth) is replaced by `src/store/auth.store.ts` (Zustand) + the new login flow.

M0 itself does not touch any feature-module business logic - it stops at user/role/permission CRUD plus the auth surface.

---

## Section 3 - HITL Gate 1 decisions (G1-G7)

You made these decisions at the extraction review gate. Each one is now landed in M0 (or scheduled for the relevant feature module). Cross-reference with `decisions.md`.

| ID | Decision | Status in M0 |
|---|---|---|
| **G1** Orphan tables (`payment_schedules`, `regulatory_impacts`) | Reconstitute, not drop. | Reconstituted in `entity-graph.json` with full CREATE TABLE SQL. **Not in M0** - they're feature-module concerns. DB Architect picks them up when the relevant module runs. |
| **G2** Multi-approver chain | Yes - N approvers in sequence + optional parallel groups. Multi-party signers (>2) NOT required. | Schema columns (`parallel_group`, `is_required`, `escalation_role`, `escalation_after_hours`, `reassigned_to`) added in `entity-graph.json`. **Not in M0** - feature module work. |
| **G3** UAE Pass | Mocked for dev, real integration deferred. | **Implemented in M0.** BE: `POST /api/v1/auth/uae-pass/initiate` + `/callback` with mock provider, in-memory state-store, CSRF state validation (CRX-3 hardened). FE: `auth.uae-pass.tsx` + `auth.uae-pass.callback.tsx` skeleton routes. Live integration checklist: `uae-pass-integration.md`. |
| **G4** Email - Nodemailer + SMTP | Provider-agnostic via env vars. | **Implemented in M0.** `src/integrations/mail/` with Nodemailer + Mailpit dev catcher. Production SMTP provider chosen at go-live. |
| **G5** Production-grade RLS | Mandatory rebuild. No `USING(true)`. | **Implemented in M0** for all 7 M0 tables. 16 RLS policies, real per-role + per-ownership filtering. Capability-lookup helper `fn_current_user_has_permission`. Session GUC `app.current_user_id` set per fn_ call. |
| **G6** Heavy bundles backend | Approved stack (Puppeteer / pdfkit / pdfmake / pdf-parse / pdfjs-dist / exceljs / mammoth / docx). | M0 has none of these in deps (no document processing in M0 itself). Stack is approved; feature modules add deps as needed. 6 frontend files reclassified to `backend-call` mode for the relevant feature module. |
| **G7** Lovable AI Gateway -> OpenAI primary + Anthropic stub | All 10 edge functions become backend endpoints. | **Implemented in M0** as the AIProvider abstraction (`src/integrations/ai/`). The 10 edge function migrations land in feature modules. Per-prompt OpenAI deltas captured in `prompts/_migration-notes.json`. |

---

## Section 4 - What carries forward to feature modules (the harden plan)

From `component-transformation-map.json`:

| Mode | Count | Description |
|---|---|---|
| **harden** | ~110 components | Apply 13-item Harden Checklist (T1-T13). Visual fidelity preserved; data layer + state management + quality bars replaced. |
| **regenerate** | ~12 components | Discard and rebuild. Includes `__root.tsx` (Lovable preview URL leak), `AuthProvider.tsx`, supabase client trio, supabase types.ts, and a few service files that wrote directly to Supabase tables (e.g., `approvalEngine.ts`, `signingService.ts`, `expiry-scheduler.ts`). |
| **backend-call** | 6 files | Heavy client bundles (jspdf / xlsx / html2canvas / mammoth used in lib/pdf, lib/exports, lib/contracts/import) become thin `fetch+download` stubs hitting backend `/api/exports/*` endpoints. UI shell stays harden. |

**Per-component flow** (for each `/new-module` run): the Component Transformer agent reads the Lovable source, applies the 13-item checklist, and produces the v2.6 target. Failures route to a 3-cycle retry; persistent failures escalate to `regenerate` mode or developer waiver.

The 13-item checklist:
- T1 Data layer extraction (replace Supabase calls with services)
- T2 React Query wrapping (queries + mutations + invalidation)
- T3 i18n keys (no hardcoded strings)
- T4 Three data states (loading / empty / error)
- T5 Token replacement (no inline colors)
- T6 Accessibility (WCAG 2.1 AA, keyboard nav, ARIA)
- T7 Type safety (no `any`)
- T8 Form hygiene (zod + react-hook-form)
- T9 Destructive confirmation (modal + typed confirmation)
- T10 Debounce (search inputs)
- T11 Error boundary
- T12 Date/time handling (formatDateTime + Asia/Dubai)
- T13 Sensitive field protection (no log, no persist, no expose)

---

## Section 5 - What was discarded (throwaway tax)

These elements of the Lovable codebase did not carry over. Listed for full transparency.

| Discarded item | Reason |
|---|---|
| Lovable preview URL in `__root.tsx` OG image (`og:image`, `twitter:image`) | Brand leak. Replaced with production assets in regenerated `__root.tsx`. |
| `// @ts-nocheck` directives on 9 of 10 edge function files | New backend services are TypeScript strict end-to-end. |
| All `RLS USING(true) WITH CHECK(true)` policies | Replaced with real per-role + per-ownership policies (G5). |
| All 322 direct `supabase.from()` call sites | Refactored to backend calls in feature modules. |
| Generic `package.json` name (`tanstack_start_ts`) | Renamed to `musanad-contracts-frontend` (matching `src/config/brand.ts`). |
| Generic `wrangler.jsonc` name (`tanstack-start-app`) | Renamed to project-specific. |
| `@lovable.dev/vite-tanstack-config` (the entire Lovable Vite plugin list) | Replaced with explicit `@tanstack/router-plugin` + `@cloudflare/vite-plugin` + `@tailwindcss/vite` + `@vitejs/plugin-react`. |
| Lovable AI Gateway (`https://ai.gateway.lovable.dev/v1/...`) + `LOVABLE_API_KEY` | Replaced with `AIProvider` abstraction (OpenAI primary). |
| Lovable's Supabase service-role usage paths | Backend itself is the trusted layer; service-role pattern eliminated. |
| `is_seed` boolean columns on 10+ tables | Dropped; seed data lives in migrations + `seed/<env>.sql` scripts. |
| Browser-side PDF / XLSX / DOCX generation (jspdf, html2canvas, xlsx, mammoth) | Moved to backend per G6. ~3-5 MB removed from FE bundle. |
| Browser-side expiry scheduler (`src/lib/contracts/expiry-scheduler.ts`) | Moves to a backend cron in feature module. |
| Auto-generated Supabase `types.ts` (1,715 lines) | Replaced by hand-written / OpenAPI-derived types. |

---

## Section 6 - Quality gates passed in M0

| Gate | Result | Notes |
|---|---|---|
| **DB design (QA Stage 2)** | 15/15 + micro-revision | Stage 2 added DOWN block to migration, partial self-FK indexes on `user`, paginated `fn_role_list` and `fn_permission_list`. |
| **Contracts (QA Stage 3)** | 14/14 + micro-revision | OpenAPI structure normalized; `.strict()` Zod throughout. |
| **Integration verification** | 105/109 alignment checks PASS | 4 acceptable variances documented; all critical alignments green. |
| **BE smoke test** | 13/13 endpoints + 14/14 tests | Zero sensitive-field leaks across all responses + logs. |
| **FE smoke test** | 5/5 HTTP + Playwright E2E | Zero leaks in console, network, or DOM. |
| **QA Stage 4** | 70/79 PASS, 7 warn, 2 fail (FE-5 and FE-7) | All 18 M0 acceptance criteria PASS. FE-5 (i18n keys) and FE-7 (dark mode contrast) patched in the same Phase 2 cycle. |
| **Codex adversarial review** | request-changes -> request-changes resolved | 1 critical (CRX-1) + 5 high (CRX-2/3/4/5/6) - all fixed in security patch. CRX-7 (Zustand localStorage) and CRX-8 (OpenAI timeout) deferred to feature-module sprints with explicit follow-up tracking. |
| **Final test counts** | BE 23/23, FE 16/16 - all green | After Codex security patch + FE-5/FE-7 patch. |

---

## Section 7 - TODOs you should be aware of

These items are **deferred from M0**. Track each as a GitHub issue or roadmap item.

### Before production (do this NOW)

- [ ] **Rotate the bootstrap admin password.** `admin@musanad.local` / `ChangeMe@123` is published in this doc and the migration. Log in once and change it via `PUT /api/v1/users/1` (currently FE has no UI for password change in M0 - direct API call required, or wait for the M1+ password reset story).
- [ ] **Implement real UAE Pass integration.** Mock provider returns synthetic identities. Live provider stub throws NotImplementedError. See `uae-pass-integration.md` for the 9-item integration checklist (env vars, state store, PKCE, SAML signature verification, certificate management, mock-to-live cutover).

### Before scaling beyond 1 replica

- [ ] **Swap in-memory rate limiter to Redis.** `rate-limiter-flexible` -> `RateLimiterRedis`. `ioredis`-compatible in deps; middleware shape stays the same.
- [ ] **Swap in-memory UAE Pass state-store** to Redis or a `uae_pass_state` DB table. Single-process Map will not survive process restart and will not work across replicas.

### Auth hardening sprint

- [ ] **Refactor Zustand auth to httpOnly cookies + CSRF (CRX-7).** Currently `src/store/auth.store.ts` persists `accessToken` + `refreshToken` to localStorage. localStorage is XSS-readable. Industry pattern for sensitive auth is httpOnly cookies + double-submit CSRF token. Out of scope for M0; required before production.

### AI hardening (when feature modules wire AI endpoints)

- [ ] **Add OpenAI 30s timeout + 429 backoff (CRX-8).** Currently the OpenAI provider has no explicit timeout or 429 retry. OpenAI hangs cascade into long-running backend requests. Cap at 3 retries, exponential backoff, translate persistent failure to 503 SERVICE_UNAVAILABLE.

### Test isolation

- [ ] **Provision Neon `test` branch + `TEST_DATABASE_URL` before M1.** M0 integration tests run against the dev `m0-foundation` branch (acceptable for a single-developer M0; not acceptable when multiple modules and multiple devs run in parallel). Procedure documented in `ops-runbook.md`.

### QA Stage 4 follow-ups (warnings, not blockers)

- [ ] **BE-11:** audit `.env.example` against code - add docs for any env vars that exist in code but not the example (FE-only var `VITE_DISPLAY_TIMEZONE` is documented; backend has 1 missing - track in next pass).
- [ ] **BE-16:** add unit test coverage for `env-validation.util.ts`, `errors.util.ts`, `logger.util.ts`. Currently integration-tested only.
- [ ] **FE-20:** SSR hydration mismatch on `<html dir>` - the server renders LTR by default, client may flip to RTL on locale detection. Use `suppressHydrationWarning` or render dir from a server-set cookie.
- [ ] **FE-22:** 753 prettier formatting issues - auto-fix with `npm run format`.

---

## Section 8 - Headline numbers (M0 delivery)

| Layer | Numbers |
|---|---|
| Database | 7 tables, 19 indexes, 14 fn_ functions (13 + 1 RLS helper), 1 atomic helper added in 002, 3 audit triggers, 16 RLS policies, 4 seed datasets. |
| Backend | 45 TS files, 5 controllers (auth, user, role, permission, plus health), 6 middlewares, 6 utilities, 4 schemas (auth + user), 3 integration packages (ai, mail, uae-pass). |
| Frontend | 36 TS/TSX files, 4 services, 1 Zustand store, 5 routes (login, uae-pass init/callback, app dashboard, root layout), 16 tests. 2 + 12 i18n keys added (dashboard.*). |
| Tests | BE 23 / FE 16 - all green. |
| Migrations | `001_foundation.sql` (1,218 lines) + `002_security_hardening.sql` (CRX-1 + CRX-4 patch). |
| External integrations | 4 first-class: ai-provider (replacing -> openai), email (new -> nodemailer), uae-pass (mocked), document-processing (deferred to feature modules). |
| Quality gates | DB 15/15, Contracts 14/14, Integration 105/109, BE smoke 13/13 + 14/14 tests, FE smoke 5/5 + Playwright, QA Stage 4 70/79 + 18/18 ACs, Codex review resolved. |

---

*Generated by Documentation Generator. For developer onboarding see `dev-handoff.md`. For ops procedures see `ops-runbook.md`. For UAE Pass live integration see `uae-pass-integration.md`. For DB schema see `data-dictionary.md`.*
