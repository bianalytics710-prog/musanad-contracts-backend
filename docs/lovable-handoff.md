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

---
---

# M1a Migration — Lovable Components → v2.6 Production

> **Module:** M1a (Contracts: Core CRUD & Lifecycle).
> **Generated:** 2026-05-03.
> **Pipeline:** Lovable Modernization v3.0 (Mode A).
> **Source:** `C:/Users/azureadmin/projects/musanad-contracts-hub` (Lovable prototype).
> **Target:** `musanad-contracts-frontend` (production frontend) + `musanad-contracts-backend` (regenerated).

---

## Component fate map (11 of 11 contracts components)

The 11 user stories with HTTP-exposed operations (S1..S11) each ship one production frontend component. S12 (system story — auto-emit activity on triggers) has no FE component (`uiType='none'`, emitted via DB triggers). Three components were hardened (visual fidelity preserved; data layer + state + quality bars replaced); eight were regenerate-light (idiom preserved but shell rebuilt because the Lovable source was tightly coupled to out-of-scope features).

### Hardened (3 of 11)

| Component | Story | Lovable source | Production target | Why hardened |
|---|---|---|---|---|
| `ContractTreeTimeline` | S7 | `src/components/contracts/detail/ContractTimeline.tsx` (~153 lines) | `src/features/contracts/components/ContractTreeTimeline.tsx` | Self-contained vertical-rail timeline component. Gold-accent for current node, `FilePlus2` / `RefreshCw` / `FileText` icon set, plum-tint chips - all preserved verbatim. Data layer extracted to `useContractTree` hook calling `fn_contract_get_tree`. |
| `ContractVersionList` | S9 | `src/components/contracts/version/VersionCompareDialog.tsx` (~470 lines, list-only slice) | `src/features/contracts/components/ContractVersionList.tsx` | List ordering, version chip, byActor caption, expand/collapse-all idiom preserved. Diff/compare features (which are M4 with AI diff summary) excluded. |
| `ContractActivityLog` | S11 | Activity tab fragment from `src/components/contracts/center/ContractCenterTabs.tsx` (~1,443 lines parent) | `src/features/contracts/components/ContractActivityLog.tsx` | Icon-per-type tone palette (sage / slate / gold / plum / amber / terracotta), vertical rail, byActor caption, status-pair pill for status_changed metadata - all preserved. Activity tab rebuilt as a standalone component because its parent (ContractCenterTabs) was 1,443 lines covering 7 unrelated features. |

### Regenerate-light (8 of 11)

| Component | Story | Lovable source (lines) | Production target | Why regenerated |
|---|---|---|---|---|
| `ContractListView` | S1 | `src/routes/contracts.tsx` (1,730 lines) | `src/features/contracts/components/ContractListView.tsx` | Lovable file mixed list view, bulk export, archive dialog, signatory filter, and bulk-tag - all out of M1a scope. Visual idiom (toolbar + table + status badges) preserved. |
| `ContractDetail` | S2 | `src/routes/contracts.$id.tsx` (1,478) + `ContractCenterTabs.tsx` (1,443) | `src/features/contracts/components/ContractDetail.tsx` | Wired to supabase realtime + features (regulatory impact, exports, signing) outside M1a. Tab structure + header card retained as the visual blueprint. |
| `ContractCreateForm` | S3 | Compose-wizard fragment (multiple wizard steps) | `src/features/contracts/components/ContractCreateForm.tsx` | Per requirements-analysis: derived from compose-wizard fields without the wizard chrome (full wizard is M1b). |
| `ContractEditForm` | S4 | (no direct Lovable counterpart) | `src/features/contracts/components/ContractEditForm.tsx` | Shared field set with `ContractCreateForm`; partial-COALESCE update enforced via `react-hook-form` `dirtyFields` tracking so only changed fields ship to BE. |
| `ContractDeleteDialog` | S5 | (T9 destructive-confirmation pattern) | `src/features/contracts/components/ContractDeleteDialog.tsx` | Standard T9 confirmation modal — type-to-confirm gate. |
| `ContractStatusDialog` | S6 | (Lovable had inline status menu in detail page) | `src/features/contracts/components/ContractStatusDialog.tsx` | Per requirements-analysis: M1a placeholder; the full state-machine UX with reason capture per transition lands in M2. |
| `ContractTagsEditor` | S8 | `TagsField` was a bulk-tag dialog inside the list | `src/features/contracts/components/ContractTagsEditor.tsx` | Per-row chip-input editor; chip-input pattern preserved but the dialog → inline editor refactor was warranted because S8's API is per-contract atomic replace. |
| `ContractVersionCreateDialog` | S10 | Save-as-version slice from VersionCompareDialog | `src/features/contracts/components/ContractVersionCreateDialog.tsx` | Save-as-version slice; AI diff summary deferred to M4. |

### Why the 8 were regenerated, not hardened

Lovable's source files for the 8 components ranged 1,478..1,730 lines each and were tightly coupled to:

- The Supabase client (`supabase.from('contracts').select()` patterns, supabase realtime subscriptions, RLS-via-anon-key).
- Out-of-scope features (regulatory impact, signing flows, bulk export to PDF/XLSX, AI risk score display, payment schedules, compose-wizard chrome).
- Auto-generated supabase types (1,715-line `types.ts`) replaced wholesale.

The 3-cycle Harden rule would have required rewriting >70% of each file to extract the M1a slice. The Component Transformer escalated each to regenerate-light: the **visual idiom** (table layout, header card, tab structure, chip input, modal pattern, status menu) is preserved but the implementation is a fresh build against the v2.6 stack.

---

## supabase → fn_ migration map

Each Lovable supabase call site that fell within M1a scope has been replaced with a backend service call hitting an `fn_*` function via `db.callFunction()`. The mapping below is the source-of-truth for any future Lovable component carrying M1a contract logic.

| Lovable call (paraphrased) | v2.6 BE endpoint | DB function |
|---|---|---|
| `supabase.from('contracts').select('*').order('created_at', { ascending:false })` | GET /api/v1/contracts | `fn_contract_list` |
| `supabase.from('contracts').select('*, contract_attachments(count), contract_comments(count)').eq('id', id)` | GET /api/v1/contracts/:id | `fn_contract_get_by_id` |
| `supabase.from('contracts').insert({...}).select().single()` | POST /api/v1/contracts | `fn_contract_create` |
| `supabase.from('contracts').update({...}).eq('id', id).select().single()` | PUT /api/v1/contracts/:id | `fn_contract_update` |
| `supabase.from('contracts').update({ is_active: false }).eq('id', id)` | DELETE /api/v1/contracts/:id | `fn_contract_delete` (SECURITY DEFINER + GUC + FOR UPDATE) |
| `supabase.from('contracts').update({ status: newStatus }).eq('id', id)` | PATCH /api/v1/contracts/:id/status | `fn_contract_status_update` |
| Lovable parent/child fetch via `parent_contract_id` then recursive client-side walk | GET /api/v1/contracts/:id/tree | `fn_contract_get_tree` (recursive CTE both directions; depth cap 20) |
| `supabase.from('contract_tags').upsert(...)` + `delete().in('id', removed)` | PUT /api/v1/contracts/:id/tags | `fn_contract_set_tags` (atomic replace, idempotent) |
| `supabase.from('contract_versions').select('*').eq('contract_id', id).order('version_number', { ascending:false })` | GET /api/v1/contracts/:id/versions | `fn_contract_version_list` |
| `supabase.from('contract_versions').insert({...})` | POST /api/v1/contracts/:id/versions | `fn_contract_version_create` (SELECT FOR UPDATE on parent for atomic version_number) |
| `supabase.from('contract_activities').select('*').eq('contract_id', id).order('created_at',{ascending:false})` | GET /api/v1/contracts/:id/activity | `fn_contract_activity_list` |
| Lovable client-side `insert into contract_activities` from app code | (REMOVED - DN4) | `fn_contract_activity_create` (SECURITY DEFINER, trigger-only). Direct INSERT denied by RESTRICTIVE RLS. |

The Lovable `LOVABLE_API_KEY` / `supabase.auth.*` paths in contracts components are removed entirely. All authenticated calls go through `apiClient` (`src/lib/api-client.ts`) which carries the M0 JWT.

---

## What was preserved from Lovable

- 13-state status workflow (kept verbatim, plus `resubmission_requested` already present in source -> total 14).
- 4-icon activity-type palette idiom in `ContractActivityLog`.
- Vertical-rail timeline visual in `ContractTreeTimeline`.
- Per-locale governing-law / language / relationship-type label strings (added to `contracts.*` i18n namespace).
- Status badge tone mapping (sage / slate / gold / plum / amber / terracotta) - reused from the design system rather than redefined per component.

## What was discarded

- All 11 source files' Supabase wiring (replaced with v2.6 service hooks).
- Lovable's auto-generated supabase types for the contracts surface (1,715 lines project-wide; M1a's slice replaced by hand-typed `Contract` / `ContractListItem` / `ContractVersion` / `ContractActivity` / `ContractTreeNode`).
- Bulk export and bulk archive (M1b scope - explicitly removed from `ContractListView`).
- Browser-side PDF / XLSX generation in detail page (moved to backend per G6).
- AI diff summary in version creator (M4 scope).
- Realtime subscriptions on `contracts` / `contract_activities` (deferred; React Query polling on key invalidation is sufficient for M1a).

---

*Generated by Documentation Generator from M1a fe-implementation-summary.json + component fate map + Codex FE review.*

---
---

# M1b Migration — Lovable Compose Wizard, Payment Schedules & Exports → v2.6

> **Module:** M1b (Compose Wizard, Payment Schedules & Exports — second sub-module of split M1).
> **Generated:** 2026-05-03.
> **Pipeline:** Lovable Modernization v3.0 (Mode A).
> **Source:** `C:/Users/azureadmin/projects/musanad-contracts-hub` (Lovable prototype).
> **Target:** `musanad-contracts-frontend` + `musanad-contracts-backend`.

---

## What this submodule covers

M1b lifts three Lovable surfaces into the v2.6 production frontend:

1. **Compose Wizard** (5-step flow originally implemented as a multi-step `compose.tsx` route in the Lovable prototype).
2. **Payment Schedule** (the orphan `payment_schedules` table flagged at HITL Gate 1 G1 — reconstituted into a first-class entity, not dropped).
3. **PDF + XLSX exports** (originally browser-side via jspdf + xlsx — moved to backend per HITL Gate 1 G6).

---

## Compose Wizard component map

The Lovable prototype had a single ~1400-line `compose.tsx` mixing 5 wizard steps, AI drafting panel, clause picker, party picker, template picker, and attachments uploader. The M1b production target preserves the 5-step UX shape but splits implementation into a step-host + per-step components, and disables the four deferred pickers behind banners.

| M1b step | Production component | Lovable source | Notes |
|---|---|---|---|
| Step 1 — Type / metadata | `src/features/contracts/wizard/steps/Step1Type.tsx` | compose.tsx wizard step 1 fragment | **Templates picker DISABLED** — banner + TODO[m1b-pickers]. |
| Step 2 — Parties + payment | `src/features/contracts/wizard/steps/Step2Parties.tsx` | compose.tsx wizard step 2 fragment | **Party / counterparty pickers DISABLED** — free-text fallback only; not persisted as IDs. Payment-schedule sub-block IS active (writes through `PaymentScheduleEditor` shape). |
| Step 3 — Clauses + body | `src/features/contracts/wizard/steps/Step3Terms.tsx` | compose.tsx wizard step 3 fragment | **Clause library + AI Drafting Panel DISABLED** — banners + TODO[m1b-pickers]. Body is plain `<textarea>` for `bodyEn` / `bodyAr`. |
| Step 4 — Attachments | (SKIPPED) | compose.tsx wizard step 4 | Wizard advances Step 3 → Step 5 directly. `ComposeWizardStep4Attachments` type reserved for the Attachments module. |
| Step 5 — Review | `src/features/contracts/wizard/steps/Step5Review.tsx` | compose.tsx wizard step 5 fragment | Read-only summary + Submit button. Submit handler runs the FE-only orchestration (POST /contracts → PUT /payment-schedules). |

Wizard shell + state hooks:

| File | Responsibility |
|---|---|
| `src/features/contracts/wizard/ComposeWizard.tsx` | Step host. Renders the active step, handles navigation, gates the wizard route by `contract.draft` permission (AC-S1-09). Wrapped in M0 ErrorBoundary (T11) and lazy-loaded. |
| `src/features/contracts/wizard/useComposeDraft.ts` | localStorage persistence. `_savedAt` envelope + 24h TTL eviction (Codex F-FE-M1 fix; round-2 closed legacy-draft re-leak via FE-R2-001). Storage key: `compose-draft:{userId}:{composeDraftId}`. |
| `src/features/contracts/wizard/useComposeSubmit.ts` | Submit orchestration: POST → PUT sequence. `submittingRef = useRef(false)` synchronous double-submit guard (Codex F-FE-002 fix). |
| `src/features/contracts/wizard/compose-wizard-schemas.ts` | Per-step Zod schemas — react-hook-form bound. |
| `src/routes/app/contracts.compose.tsx` | TanStack route — lazy import + permission gate. |

---

## Compose orchestration — FE-only (Q2 decision)

HITL Gate 2 question Q2 asked whether to introduce a new BE wrapper endpoint (`fn_contract_create_with_schedule`) or orchestrate FE-only via the existing M1a POST + M1b PUT. The decision was **Option (b) — FE-only orchestration; NO new BE endpoint, NO fn_contract_create_with_schedule wrapper**.

| Step | Call | Module | DB function |
|---|---|---|---|
| 1 | `POST /api/v1/contracts` | M1a | `fn_contract_create` |
| 2 | `PUT /api/v1/contracts/{newContractId}/payment-schedules` | M1b | `fn_payment_schedule_create_bulk` (`p_replace_existing=true`) |

**Failure handling on Step 2 (AC-S1-08):** KEEP the localStorage draft. Show error toast with Retry. Retry re-attempts STEP 2 ONLY (the contract already exists in draft state; drafts can validly exist without a payment schedule). DO NOT roll back the contract.

**Why FE-only:** keeps the BE surface clean (no transactional wrapper that double-validates everything), avoids hiding the two-write semantics from the developer audience, and lets retry semantics live close to the UX (Retry button retries Step 2 only).

---

## Heavy-bundle migration (G6)

Per HITL Gate 1 G6, browser-side PDF/XLSX/DOCX generation moves to the backend. M1b is the first module to actually exercise this — both Lovable bundles are removed from the FE.

| Lovable file | Lines (Lovable) | Fate |
|---|---|---|
| `src/lib/pdf/contract-pdf.ts` | ~280 (jspdf + html2canvas) | **REMOVED from FE.** Backend `src/services/export/contract-pdf.service.ts` (Puppeteer-based) is the canonical path. FE now has only `ExportPdfDialog.tsx` — a thin GET stub that calls `apiClient.get<Blob>('/contracts/:id/export.pdf')` and triggers a browser download. |
| `src/lib/exports/contracts-xlsx.ts` | ~320 (xlsx 0.18.5) | **REMOVED from FE.** Backend `src/services/export/contract-xlsx.service.ts` (exceljs WorkbookWriter, streaming) is the canonical path. FE now has only `ExportXlsxButton.tsx` — a thin GET stub. |

FE bundle savings: approximately 1.8 MB minified (jspdf ~600 KB + html2canvas ~300 KB + xlsx ~900 KB).

The export Buffers come back through the new shared `src/lib/format-blob-download.ts` helper which (post-Codex F-FE-M3) accepts an optional `expectedContentType` and throws a typed `BlobContentTypeMismatchError` on mismatch — so a misconfigured server returning `text/html` for an export endpoint is caught at the FE rather than dumping an HTML "PDF" to the user's downloads.

The export service (`src/services/api/contract-export.service.ts`) goes through `apiClient.get<Blob>` (post-Codex F-FE-001 rewrite) so it inherits the Axios 401-refresh interceptor — exports work for users with expiring access tokens.

---

## Payment schedule reconstitution (G1)

The Lovable schema had a `payment_schedules` table with no fn_ accessors; it was flagged at HITL Gate 1 G1 (orphan table) — decision was to **reconstitute, not drop**. M1b lands the reconstituted table as a first-class entity:

- `payment_schedule` table (singular per CLAUDE.md naming) with full v2.6 audit columns + RLS (4 policies, 1 RESTRICTIVE).
- `fn_payment_schedule_list` + `fn_payment_schedule_create_bulk` (atomic replace, SELECT FOR UPDATE on parent for concurrency safety).
- 2 FE components (`PaymentScheduleTab` for read; `PaymentScheduleEditor` for the bulk-replace modal).

**Q6 — milestone label vs name:** the Lovable types.ts had BOTH `milestone_label_*` (short tag) AND `milestone_name_*` (descriptive title) per language. Q6 decision was to **retain both** rather than consolidate — the two serve distinct UX roles (label = quick-scan tag in chips/lists; name = full context in detail view) and consolidating would have forced migration of 14+ Lovable application files. Both column pairs are present in the v2.6 table with explicit `COMMENT ON COLUMN` documenting the distinction.

The Lovable `is_seed` boolean column was dropped (Agent 3 recommendation) — v2.6 seed mechanism is migration-based; no functional consumer exists in M1b application code. Re-add via additive migration if a future FE feature surfaces a need.

---

## Deferred pickers (TODO[m1b-pickers])

Four pickers from the Lovable wizard are DISABLED in M1b with deferred banners. Search the FE source for `TODO[m1b-pickers]` to find the call sites; each is gated by an inline disabled-banner component until the relevant module ships.

| Picker | Step | Future module |
|---|---|---|
| Templates picker | Step 1 | Templates |
| Our-party / counterparty pickers | Step 2 | Parties |
| Clause library | Step 3 | Clauses |
| AI Drafting Panel | Step 3 | AI Features (M4) |

The `Hijri date picker` is also deferred (Q1) — M1b uses the standard `<input type="date">` for due dates; future I18n/Calendar module adds a Hijri-aware picker.

---

## What was preserved from Lovable

- 5-step wizard UX shape (Step 1 type → Step 2 parties+payment → Step 3 clauses+body → Step 5 review; Step 4 attachments deferred).
- Status/recurrence enums on `payment_schedule` — preserved verbatim from Lovable types.ts.
- `milestone_label_*` + `milestone_name_*` dual columns (Q6 retention).
- Wizard's localStorage-as-draft idiom — kept, but hardened with an `_savedAt` envelope + 24h TTL eviction (Codex F-FE-M1) so sensitive body content isn't retained indefinitely.

---

## What was discarded

- All Lovable supabase wiring in the wizard / payment schedule / export call sites (replaced with v2.6 service hooks via `apiClient`).
- Browser-side jspdf / html2canvas / xlsx bundles (G6 — moved to backend).
- The `is_seed` Lovable column on payment_schedules (Agent 3 recommendation).
- Step 4 (Attachments) — deferred until the Attachments module ships.
- Lovable's Templates / Parties / Clauses / AI pickers — disabled with deferred banners until those modules ship.
- Lovable's `our_party_id` / `counterparty_id` ID-based linkage in the wizard step 2 — replaced with free-text fallback in M1b; ID-based linkage returns when Parties module lands.

---

## Codex FE review findings (M1b)

| ID | Severity | What | Fix |
|---|---|---|---|
| F-FE-001 | HIGH | Export service direct `fetch` bypassed Axios 401-refresh. | Rewrote to `apiClient.get<Blob>` with `responseType: 'blob'`. |
| F-FE-002 | HIGH | Compose Wizard double-submit created duplicate contracts. | `submittingRef = useRef(false)` synchronous guard. |
| F-FE-M1 | MEDIUM | Sensitive body retained in localStorage indefinitely. | `_savedAt` envelope + 24h TTL; round-2 FE-R2-001 closed legacy-draft re-leak. |
| F-FE-M2 | MEDIUM | Export error toasts indistinguishable across 401/403/429. | `translateApiError` per-namespace lookup + RATE_LIMITED → CODE_TO_KEY. |
| F-FE-M3 | MEDIUM | Blob downloads accepted any 200 Content-Type. | Optional `expectedContentType` + `BlobContentTypeMismatchError`. |

Codex FE round-2 verdict: **APPROVED** (with FE-R2-001 micro-fix landed in same round).

---

*Generated by Documentation Generator from M1b fe-implementation-summary.json + workspace decisions (Q1, Q2, Q4, Q5, Q6) + Codex FE rounds 1+2.*
