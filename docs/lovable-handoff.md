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

---
---

# M3 Migration — Lovable Signing Surface → v2.6

> **Module:** M3 (sixth module — Signatures + Signer Q&A AI).
> **Generated:** 2026-05-04.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Source:** `C:/Users/azureadmin/projects/musanad-contracts-hub` (Lovable prototype).
> **Target:** `musanad-contracts-frontend` + `musanad-contracts-backend`.
> **Codex review:** SKIPPED per Dexian decision 2026-05-04. Stage 2 + Stage 4 absorbed safety net (S2-16..S2-20 + L1-L20 + new candidate S2-21 enumerate-PUBLIC-grants).

---

## Summary

This module was built using the Lovable Modernization pipeline. The backend was fully regenerated. **All 5 Lovable signing components were regenerated rather than hardened** — see the decision matrix below for the harden-vs-regenerate rationale (M2 precedent: `feedback_regenerate_when_lovable_too_coupled.md`).

---

## Component Transformation Log

| Component | Source (Lovable) | Target (v2.6) | Fate | Cycles | Transformations Applied |
|---|---|---|---|---|---|
| signingService.ts | `src/services/signingService.ts` (~520 LOC) | replaced by `src/services/api/signature.service.ts` + `src/features/signatures/hooks/useSignatures.ts` + `src/features/signatures/hooks/useSignerQaSseStream.ts` | regenerated | 0 (audit-report mandate) | T1, T2, T7 |
| SigningCeremony.tsx | `src/components/signing/SigningCeremony.tsx` (~280 LOC) | `src/features/signatures/components/SigningCeremony.tsx` (post-sign celebratory animation; 6.5s lock) | regenerated | 0 (different concern) | T3, T6, T7, T11 |
| VerificationGate.tsx | `src/components/signing/VerificationGate.tsx` (~170 LOC) | `src/features/signatures/components/VerificationGate.tsx` | regenerated | 0 (wire-shape change) | T1, T3, T6, T7 |
| SignerQADrawer.tsx | `src/components/signing/SignerQADrawer.tsx` (~410 LOC, supabase-edge-fn-coupled) | `src/features/signatures/components/SignerQADrawer.tsx` + `useSignerQaSseStream.ts` | regenerated | 0 (SSE wire-shape + missing UI deps) | T1, T2, T3, T4, T6, T7, T13 |
| DeclineDrawer.tsx | `src/components/signing/DeclineDrawer.tsx` (~190 LOC) | `src/features/signatures/components/DeclineDrawer.tsx` | regenerated | 0 (validation contract change) | T1, T2, T3, T6, T7, T8 |

**3-cycle rule outcome:** all 5 components hit zero cycles because the audit-report (Phase L1) recommended REGENERATE for `signingService.ts` (pervasively supabase-coupled) and the 4 view components couple either against `signingService.ts` directly or against UI deps not in the production stack (shadcn `Sheet`, `Textarea`, `react-markdown`). Regenerate is a valid escape hatch from the 3-cycle harden limit; this is precedent — see M2 (4 of 8 regenerated).

---

## Harden-vs-regenerate decision matrix

| Driver | Lovable signing components | Decision |
|---|---|---|
| Service imports | `signingService.ts` is REGENERATE per audit-report.md | All 4 dependent components forced to regenerate (you cannot harden a component whose data layer was rewritten). |
| Wire shape | M3 introduces `verify_jwt=false` namespace + plaintext invitation_token in URL path + GATE/COMMIT SSE pattern + masked email returned by API. | Lovable wire calls `supabase.functions.invoke('ai-signer-qa', ...)` with body `{ messages, invitationData, language }` — fundamentally different. Adapter layer would be > 50% of the code; faster to regenerate with the new contract directly. |
| Missing UI deps | Lovable uses shadcn `Sheet`, `Textarea`, `react-markdown` for SignerQADrawer + others. | Production stack has Tailwind tokens + ad-hoc components; pulling in shadcn at this point would be a parallel migration. |
| Behavioural delta | Lovable SigningCeremony is a 6.5s post-sign animation; the v2.6 page is the actual signer landing page (with VerificationGate at entry). | Different concern — the celebratory animation became a small transient state inside the new page rather than the page itself. |

When in doubt, prefer regenerate over forced-harden — the throwaway tax is real (Lovable signing surface ≈ 1500 LOC across 5 files) but the cost of fighting a fundamentally different wire shape across 3 cycles is higher.

---

## New components (7 — v2.6 native)

These have no Lovable source; they are net-new for v2.6 to support the M3 admin-side surface (which Lovable did not have):

| Component | Story | Notes |
|---|---|---|
| `ContractSignersConfigDialog` | S1 | Bulk-create signer roster from the ContractDetail Signatures tab. |
| `SendForSignatureConfirmDialog` | S2 | Confirms send-for-signature; surfaces invitationTokenPlaintext via `TokenOnceCopyPanel`. |
| `ResendInvitationConfirm` | S7 | Resend invitation with optional reason. |
| `CancelInvitationConfirm` | S8 | Type-to-confirm `CANCEL` gate per T9 destructive-confirmation pattern. |
| `SignatureMethodPicker` | S4 | Surface for typed/drawn/uae_pass/ds_otp on the public signer page. |
| `ContractSignaturesTab` | S6 | New tab on ContractDetail; consumes `fn_signature_list_for_contract`. |
| `TokenOnceCopyPanel` | shared | Reusable component for the @once-only invitation_token copy-link UX. |

---

## Preserved from Lovable

- The 5-step ceremony **UX shape** (gate → contract excerpt → method picker → signature confirm → success animation) is preserved in spirit, even though all 5 components were regenerated. The v2.6 page is recognizably the same flow.
- The **set of signature methods** (typed / drawn / uae_pass / ds_otp) is preserved verbatim — the v2.6 `signature_method` reference table mirrors the Lovable enum, and `is_enabled` provides the runtime feature-flag mechanism.
- The **AI signer Q&A system prompt** is preserved VERBATIM (G7 / AN-2). `prompts/ai-signer-qa.txt` in the BE repo is a byte-for-byte extraction from Lovable `supabase/functions/ai-signer-qa/index.ts`. Only Mustache-style `{{placeholder}}` substitution is applied at runtime (no real templating, no auto-escaping).
- The **idea** of a 5+ active session sliding window for Q&A is preserved (AN-12 Option A) — but the soft-deactivate-oldest semantics are new (Lovable did not enforce a session cap).

---

## Rebuilt from scratch

- The entire **backend** for M3 (database + fn_'s + controllers + routes + cron driver + AI service) — Lovable did not have a production backend.
- All **5 signing components** as enumerated above.
- The **invitation token lifecycle** (SHA-256 hash storage; 14-day TTL; cron expiration; resend/cancel) — Lovable used Supabase edge functions with a different storage shape.
- The **GATE/COMMIT SSE pattern** for /qa/message — Lovable's edge function called OpenAI directly without rate-limit accounting; v2.6 has the two-call rate-limit pattern enforced inside the fn_.

---

## Discarded from Lovable

| Discarded | Reason |
|---|---|
| `signingService.ts` (~520 LOC supabase wiring) | audit-report.md REGENERATE — pervasively `supabase-js` + `supabase.functions.invoke(...)` with no extractable data layer. |
| Lovable supabase edge function `supabase/functions/ai-signer-qa/index.ts` | Replaced by `src/services/ai/openai-signer-qa.service.ts` + `prompts/ai-signer-qa.txt` (verbatim prompt extraction per G7). |
| `react-markdown` usage in SignerQADrawer | Production stack does not include react-markdown; AI tokens stream into a plain `<div>` with whitespace-pre-wrap. |
| Lovable shadcn `Sheet`, `Textarea`, `Drawer` UI primitives | Production stack uses Tailwind + ad-hoc components; importing shadcn at this point is a parallel migration. |
| Lovable in-component supabase `.auth.session()` calls | Replaced by `apiPublicClient` (separate axios instance with NO auth interceptor; explicitly deletes Authorization header in request interceptor for defense-in-depth). |
| Lovable plaintext invitation_token storage in localStorage | Replaced by transient component-state-only — invitationTokenPlaintext is held only for the open lifetime of the dialog/drawer; sessionTokenPlaintext is held only in `SignerQADrawer` state and cleared on close. |

---

## Throwaway Tax Summary

| Layer | Lovable LOC discarded | Reason |
|---|---|---|
| signingService.ts | ~520 | supabase-js coupling, replaced by service.ts + 2 hooks |
| 4 signing components | ~1050 | wire-shape mismatch + UI dep mismatch (regenerated, not hardened) |
| supabase/functions/ai-signer-qa/ | ~180 | replaced by Node service + verbatim prompt file |
| Lovable supabase RLS policies on signing tables | (DB only — table schema replaced wholesale) | M3 introduces 6 net-new tables with v2.6-pattern RLS (20 policies). |

---

## Developer waivers

**No waivers.** All 5 hardened components moved straight to regenerate per the decision matrix above; no component shipped with failing harden checklist items requiring developer override. M3 follows the Dexian-precedent that regenerate is the right answer when the Lovable wire shape is fundamentally different — not a workaround.

---

## i18n keys added during M3

**+188 keys per locale** (en + ar — parity match=true).

Namespaces added:
- `signatures.*` — admin-side: toasts, status, list, progress, config, send, resend, cancel, tokenOnce, signerSide.
- `sign.m3.*` — public-side: heading, footer, toasts, error, contract, signer, actions, gate, method, qa, decline, terminal.
- `errors.signatures.*` — translateApiError fallback keys.

Namespaces extended:
- `common.{done, continue}`.
- `contracts.detail.tabs.signatures`.
- `contracts.activity.types.{sent_for_signature, signer_viewed, signer_signed, signer_declined, fully_executed, signature_invalidated}`.

Pre-M3 totals: en=3579 / ar=3579. Post-M3 totals: en=3767 / ar=3767.

---

## Design token adjustments

None. M3 reuses the existing M0-Foundation Design System tokens unchanged. The signer page (`/sign/$invitationToken`) inherits the standard semantic tokens; RTL handling is per-invitation via `invitation.language` (the `SigningCeremony` component locks `document.documentElement.{lang,dir}` via `useEffect` and restores on unmount).

---

## UAE Pass + AI provider notes (deferred docs)

- **UAE Pass live integration checklist** — already exists at `docs/uae-pass-integration.md` (created in M0). M3 does NOT change it (G3 mock continues; FE-OI-2 noted: `uae_pass` method submits `metadata.uaePassMock=true` after a 1.2s artificial delay; real federation SAML/OIDC/PKCE deferred until UAE Pass federation lands as a future module).
- **AI provider migration doc** — already exists from M0. M3 reuses the `AIProvider` abstraction unchanged (`OPENAI_MODEL_DEFAULT=gpt-4o`).

---

*Generated by Documentation Generator from M3 fe-implementation-summary.json + audit-report.md + gate2-decisions.md. No Codex FE review run for M3 (Dexian decision 2026-05-04).*

---

# M4 Migration — Lovable AI Surface → v2.6

> **Module:** M4 (seventh module — AI Features).
> **Generated:** 2026-05-04.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Source:** `C:/Users/azureadmin/projects/musanad-contracts-hub` (Lovable prototype).
> **Target:** `musanad-contracts-frontend` + `musanad-contracts-backend`.
> **Codex review:** SKIPPED per Dexian decision 2026-05-04. Stage 2 + Stage 4 absorbed safety net (S2-16..S2-20 + S2-21 PROMOTED + S2-22 codification recommended).

---

## Summary

This module was built using the Lovable Modernization pipeline. The backend was fully regenerated. **All 5 Lovable AI components in scope were REGENERATED rather than hardened** — heavier supabase coupling, custom OpenAI SSE shapes, and dependencies on tables that do not exist in this project (e.g. `regulatory_update`, `regulations`) made hardening a > 80% rewrite in every case. Per the M2 + M3 precedent (see `feedback_regenerate_when_lovable_too_coupled.md`), regenerate is a valid escape hatch from the 3-cycle harden limit — not a failure.

**M4 also introduces 3 brand-new admin views** (no Lovable precedent): observability + cost report + prompts list.

**Component fates:** 0 hardened, 5 regenerated, 3 net-new admin views.

---

## Component Transformation Log

| Component | Source (Lovable) | Target (v2.6) | Fate | Cycles | Transformations Applied |
|---|---|---|---|---|---|
| AIInsightsSidebar | `src/components/contract/AIInsightsSidebar.tsx` (~1,618 LOC) | `src/features/ai/components/AIInsightsSidebar.tsx` (regenerated) | regenerated | 0 (audit-report mandate) | T1, T2, T3, T4, T6, T7, T13 |
| AIDraftingPanel | `src/components/drafting/AIDraftingPanel.tsx` (~938 LOC) | `src/features/ai/components/AIDraftingPanel.tsx` + `useAiDraftingSseStream.ts` (regenerated) | regenerated | 0 (SSE wire-shape change) | T1, T2, T3, T4, T6, T7, T8, T13 |
| ExecutiveAnomaliesCard | section of `src/pages/ExecutiveDashboard.tsx` (~1,825 LOC; AI card slice only) | `src/features/ai/components/ExecutiveAnomaliesCard.tsx` (regenerated as slot-in section) | regenerated | 0 (section-level extract) | T1, T2, T3, T4, T6, T7, T11, T12 |
| RegulatoryImpactPanel | `src/components/regulatory/RegulatoryRadar.tsx` (~543 LOC) | `src/features/ai/components/RegulatoryImpactPanel.tsx` (regenerated as stateless paste-text-and-stream UI) | regenerated | 0 (missing source tables) | T1, T2, T3, T4, T6, T7 |
| VersionDiffSummaryPanel | section of `src/components/contracts/VersionCompareDialog.tsx` (~470 LOC; AI summary panel slice only) | `src/features/ai/components/VersionDiffSummaryPanel.tsx` (regenerated as slot-in section) | regenerated | 0 (section-level extract) | T1, T2, T3, T4, T6, T7, T12 |

**3-cycle rule outcome:** all 5 components hit zero cycles because the audit-report (Phase L1) recommended REGENERATE up-front. Net regenerate count across the project is now: M1a 0/11, M1b 0/4, M1c 0/3, M2 4/8, M3 5/12, M4 5/5. Trend reflects that the AI surface is the most heavily supabase-coupled and most table-dependent surface in the Lovable codebase — and the most likely to require regenerate.

---

## Harden-vs-regenerate decision matrix (M4)

| Driver | Lovable AI components | Decision |
|---|---|---|
| Service imports | All 5 components use `supabase.functions.invoke('ai-*', ...)` with custom OpenAI SSE shapes incompatible with v2.6 typed `{type, delta}` chunks. | All 5 forced to regenerate — adapter layer would be > 50% of each file. |
| Wire shape | M4 introduces JWT + SSE via fetch+ReadableStream (mirroring M3 useSignerQaSseStream); the FN_URL pattern is fundamentally different. | Faster to regenerate with the new contract directly. |
| Missing source tables | `RegulatoryRadar` reads `regulatory_update` + `regulations` + `obligations` tables that don't exist in this project (deferred to M5+ per Q1). `AIInsightsSidebar` reads `regulatory_impacts` similarly. | Cannot harden against tables that don't exist; built stateless paste-text replacements that exercise what IS implementable today. |
| Missing UI deps | Lovable uses `react-markdown` for streaming AI responses. | Production stack uses plain whitespace-pre-wrap divs + Tailwind tokens — pulling react-markdown in is a parallel migration. |
| Section-level extract | `ExecutiveDashboard` (1,825 LOC) and `VersionCompareDialog` (470 LOC) are out-of-scope for M4 except for the AI slice. | Built `ExecutiveAnomaliesCard` and `VersionDiffSummaryPanel` as slot-in sections that the existing dashboards / dialogs can mount when M5+ wires them up. The full parents stay with their owning modules. |
| Behavioural delta | Lovable AIInsightsSidebar carries hard-coded demo bilingual fixtures used as "loading state"; v2.6 uses real React Query state with proper skeleton/empty/error renderers. | Full skeleton/empty/error treatment is shorter to write fresh than to graft over hard-coded fixtures. |

When in doubt, prefer regenerate over forced-harden. M4 reaffirms the M2 + M3 precedent: when the Lovable wire shape is fundamentally different (or when source tables don't exist yet), regenerate is the right answer.

---

## New components (3 — v2.6 native, no Lovable precedent)

These M4 admin views have no Lovable source — Lovable did not have admin observability for AI:

| Component | Story | Route | Notes |
|---|---|---|---|
| `AdminAIRequestsList` | S11 | `/app/admin/ai/requests` | Paginated table of `ai_request_log` rows with filters (actor, prompt, outcome, date range). Uses `useDebounce(300)` on the actor filter. |
| `AdminAICostDashboard` | S12 | `/app/admin/ai/cost-report` | Aggregated cost report by promptId (and optionally by actor). 90-day max window. |
| `AdminAIPromptsList` | S13 | `/app/admin/ai/prompts` | Read-only list of registered AI prompts with default model + rate limits. |

All 3 admin routes wrap their view in `<ErrorBoundary>` (M2 admin.imports.tsx pattern).

> **Note:** `useAdminAiInsightsList` hook is exported and wired (BE has fn_ai_insight_list + endpoint), but no view consumes it in M4 — the visible-cache-contents view was not in the per-story FE scope (M4-FE-OI-5). A future admin tooling story can mount it as a tabs panel beside `AdminAIRequestsList`.

---

## Preserved from Lovable

- The **set of AI use cases** is preserved verbatim — the 6 prompt files in `[backend]/prompts/` were extracted byte-for-byte from the Lovable Supabase edge functions:
  - `ai-contract-insights.txt` ← Lovable `supabase/functions/ai-contract-insights/index.ts` (system prompt body extracted).
  - `ai-drafting-assistant.txt` ← Lovable `supabase/functions/ai-drafting-assistant/index.ts`.
  - `ai-executive-anomalies.txt` ← Lovable `supabase/functions/ai-executive-anomalies/index.ts`.
  - `ai-regulatory-impact.txt` ← Lovable `supabase/functions/ai-regulatory-impact/index.ts`.
  - `ai-regulatory-impact-summary.txt` ← Lovable `supabase/functions/ai-regulatory-impact-summary/index.ts`.
  - `ai-version-diff-summary.txt` ← Lovable `supabase/functions/ai-version-diff-summary/index.ts`.

  Total: 14,706 bytes across 6 files. Plus M3's `ai-signer-qa.txt` (902 B) → 7 prompts / 15,608 B in `[backend]/prompts/`. **G7 mandate:** Mustache-style `{{placeholder}}` substitution at runtime only; never edit prompt body.

- The **set of AI invocation modes** per prompt is preserved (e.g. `summary | key_terms | risks | obligations | regulatory | rewrite` for contract-insights). Streaming flags map 1:1 with Lovable behaviour.

- The **idea of caching AI insights for cost containment** is preserved, but reimplemented as a first-class DB cache (`ai_insight` + `fn_ai_insight_get_cached/upsert` + cron eviction) rather than Lovable's ad-hoc edge-function memoization.

---

## Rebuilt from scratch

- The entire **backend** for M4 (3 new tables + 12 fn_'s + 6 per-prompt service modules + 7 shared utility modules + 4 admin controllers + 1 cron driver + 1 signed-PDF-token middleware) — Lovable did not have a production backend for these AI features (Supabase edge functions only).
- All **5 AI components** as enumerated above.
- The **content-addressed cache layer** (`payload_hash = SHA-256(canonicalised inputs)`) — Lovable did not have caching beyond per-edge-function memoization.
- The **per-user rate limiter** (`fn_ai_request_log_check_rate_limit`) — Lovable had no rate limiting.
- The **append-only cost telemetry** (`ai_request_log` + S12 cost report) — Lovable had no cost observability.
- The **signed-PDF-token auth path** for S5 — Lovable's regulatory-impact-summary edge function was either fully public or session-JWT; v2.6 introduces a NEW auth mode (`signed-token`) for short-lived HMAC bearer authentication.

---

## Discarded from Lovable

| Discarded | Reason |
|---|---|
| 5 Lovable AI components (AIInsightsSidebar / AIDraftingPanel / ExecutiveDashboard.AI-card / RegulatoryRadar / VersionCompareDialog.AI-summary-panel) | Pervasively supabase-coupled + custom OpenAI SSE wire-shape + missing source tables. Regenerated. |
| All `supabase.functions.invoke('ai-*', ...)` calls | Replaced by `apiClient` (axios) for non-streaming endpoints; `fetch + ReadableStream + TextDecoder` for the 3 SSE consumers (mirrors M3 `useSignerQaSseStream`). |
| Lovable's custom OpenAI SSE chunk shape (`{ choices: [{ delta: { content } }] }` raw passthrough) | Replaced by typed `{type, delta} | {type, tokensConsumed} | {type, code, message?, retryAfterSeconds?}` discriminated union (mirrors M3 `SignerQaMessageStreamChunk`). One SSE parser handles all 4 streaming endpoints in the project. |
| Lovable's hard-coded bilingual demo fixtures inside `AIInsightsSidebar` | Replaced by skeleton/empty/error renderers backed by real React Query state. |
| Lovable's edge functions reading `regulatory_update / regulations / regulatory_impacts / obligations` tables | These tables don't exist in the v2.6 codebase. Per Q1, M4 ships AI endpoints **payload-driven / stateless** — caller passes the regulatory text + sample contracts in the request body. Cache row uses `entity_type='regulatory_update'` with `entity_id=NULL`. M5+ Regulatory Radar module will introduce the tables and wire FE to them. |
| Lovable's RegulatoryRadar 543-LOC component (with embedded chart components, regulatory-table integration, multi-step wizard) | Out of scope for M4. Built a stateless `RegulatoryImpactPanel` that exercises only what is implementable today (POST /ai/regulatory-impact). The full Regulatory Radar UX is deferred to M5+. |
| Lovable's `react-markdown` usage in AI streaming output | Production stack uses plain `<div>` with `whitespace-pre-wrap`; AI tokens stream in directly. |
| Lovable's per-component supabase auth `.auth.session()` calls | Replaced by `apiClient` with axios JWT interceptor (M0 baseline) + `AbortController` for SSE cancellation. |
| Lovable's lack of cost telemetry / usage tracking | Replaced by `ai_request_log` + S11 admin requests view + S12 cost report. Every invocation appends one row in a `finally{}` block (success / error / cache_hit / rate_limited / timeout / cancelled). |

---

## Throwaway Tax Summary

| Layer | Lovable LOC discarded | Reason |
|---|---|---|
| AIInsightsSidebar | ~1,618 | supabase coupling + hard-coded demos + missing tables |
| AIDraftingPanel | ~938 | supabase.functions.invoke + custom SSE shape |
| ExecutiveDashboard AI-card section | ~200 (slice of 1,825) | section-level extract; rest of dashboard out of scope |
| RegulatoryRadar | ~543 | missing source tables (regulatory_update etc.) |
| VersionCompareDialog AI-summary panel section | ~150 (slice of 470) | section-level extract; rest of dialog out of scope |
| 6 Lovable supabase edge functions (`supabase/functions/ai-*/index.ts`) | ~2,400 (combined) | Replaced by 6 Node service modules + 6 verbatim prompt files (G7) + 7 shared utility modules. |
| Lovable supabase RLS policies on regulatory tables | (DB only — table schema not migrated; tables don't exist in v2.6) | Deferred to M5+. |
| **Total discarded LOC (FE)** | **~3,449** | |
| **Total discarded LOC (BE edge fns)** | **~2,400** | Replaced by ~14,706 B verbatim prompts + Node services. |

This is the most regenerate-heavy module to date, but the throwaway is principled: every discarded line was either supabase-coupled (incompatible with v2.6 architecture) or dependent on tables that don't exist yet in this project.

---

## Developer waivers

**No waivers.** All 5 Lovable components moved straight to regenerate per the audit-report mandate; no component shipped with failing harden checklist items requiring developer override. M4 follows the M2 + M3 precedent: when the source is fundamentally incompatible, regenerate is the right answer — not a workaround.

---

## i18n keys added during M4

**+133 keys per locale** (en + ar — parity match=true).

Pre-M4 totals: en=3,767 / ar=3,767. Post-M4 totals: en=3,900 / ar=3,900. **Post-i18n-defect-patch (smoke-caught nesting fix):** en=3,903 / ar=3,903 (3-key nesting correction; same final per-side count from the smoke verifier perspective).

Namespaces added:
- `ai.*` — AI feature surfaces: insights, drafting, executive, regulatory, version-diff, common (toasts, errors, mode picker labels, language picker, severity badges).
- `admin.ai.*` — admin views: requests list, cost dashboard, prompts list.

Namespaces extended:
- `contracts.activity.types.{ai_summary_generated, ai_risk_score_updated, ai_diff_summary_generated}` — 3 new activity-type strings (mirrors the 3-value contract_activity CHECK enum extension in migration 040).
- `errors.ai.*` — translateApiError fallback keys.

---

## Design token adjustments

None. M4 reuses the existing M0-Foundation Design System tokens unchanged. AI severity badges use the existing `destructive` / `amber-500` / semantic foreground tokens already sanctioned by M2/M3 patterns.

---

## UAE Pass + AI provider notes (deferred docs — unchanged)

- **UAE Pass live integration checklist** — already exists at `docs/uae-pass-integration.md` (created in M0). M4 does NOT change it.
- **AI provider migration doc** — already covered by M0/M3. **M4 is a thick consumer of the AIProvider abstraction, but the abstraction itself is unchanged** — `OPENAI_MODEL_DEFAULT=gpt-4o`. M4 reuses the same singleton client + same config plumbing. Per-prompt `default_model` overrides (e.g. `gpt-4o-mini` for S3 + S6) are seeded in `ai_prompt`, not hard-coded.

---

## What carries forward (M5+ scope hints from M4)

- **Regulatory Radar (M5):** introduce `regulatory_update` + `regulations` + `regulatory_impacts` + `obligations` tables, replace M4's stateless `RegulatoryImpactPanel` with the full Lovable RegulatoryRadar UX, wire `ai_insight.entity_type='regulatory_update'` cache rows to actual entity ids (no more NULL entity_id placeholder).
- **Polymorphic dispatch extension:** when M5+ adds new `ai_insight.entity_type` values (e.g. `template`, `clause`, `obligation`), extend the `ai_insight_select_scope` RLS policy with matching subqueries — there is no automatic dispatch.
- **Redis migration:** when scaling beyond 1 replica, switch S5's per-token rate limiter + signed-PDF-token nonce Set to Redis (BE-IMPL-INFO-2).
- **Provider mock harness for Section F coverage uplift:** M4's coverage is WARN because OpenAI provider stubs aren't unit-tested. Build a deep provider mock (e.g. `nock`-based) so the success-path branches of all 6 service modules are exercised by unit tests. M5+ candidate.
- **Cron-runner abstraction:** with 3 in-process cron drivers (M2 escalation, M3 expiration, M4 eviction), the 3-instance threshold is the canonical generalisation point. Defer extracting a shared cron-runner to a Phase 2 architectural decision in M5 (when the 4th cron lands).
- **Contract entity surface extension (AI-OI-A):** `Contract.aiSummaryEn / aiSummaryAr / aiRiskScore` are persisted via M4 but NOT projected by `fn_contract_get_by_id`. Future M1a-extension migration would surface them on the read path.

---

*Generated by Documentation Generator from M4 fe-implementation-summary.json + audit-report.md (Phase L1) + gate2-decisions.md + qa-stage4-report.md. No Codex FE review run for M4 (Dexian decision 2026-05-04).*

---
---

# M5 Migration — Lovable Regulatory Surface → v2.6

> **Module:** M5 (eighth module — Regulatory Radar).
> **Generated:** 2026-05-05.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Source:** `C:/Users/azureadmin/projects/musanad-contracts-hub` (Lovable prototype).
> **Target:** `musanad-contracts-frontend` + `musanad-contracts-backend`.
> **Codex review:** SKIPPED per Dexian decision 2026-05-04. **4th consecutive validation** through M2/M3/M4/M5 — pattern fully entrenched. Stage 2 + Stage 4 absorb the safety net via S2-16..S2-23 (S2-23 NEW in M5 — see DEFECT-1 retrospective).

---

## Milestone — M5 complete

✅ **M5 milestone CHECKED.** All upstream gates PASS. DB live (both branches v53 incl. patch 053). BE+FE built and tsc clean. Integration Verifier, Smoke Test, Testing Agent (78/78), QA Stage 4 all PASS. Documentation generated (this run). Migrations 046..052 + 053 applied to both `test` and `m0-foundation` branches.

✅ **M4-FE-OI-3 CLOSED** — `RegulatoryImpactPanel.sampleContracts` prop wired. Surgical 2-line additive change to `src/features/ai/components/RegulatoryImpactPanel.tsx`: added optional `sampleContracts?: AiRegulatoryImpactSampleContract[]` prop; the existing internal hardcoded empty array now falls back to that prop when supplied. M5 `RegulatoryUpdateDetailPanel` + future call sites can now inject impacted contracts derived from `useRegulatoryImpactList`. Default behaviour unchanged (paste-text stateless mode still returns empty when no prop supplied). NO M0..M4 type files modified — only the M4 component prop signature; the `AiRegulatoryImpactSampleContract` type was already exported from M4's `ai.types.ts`.

---

## Summary

This module was built using the Lovable Modernization pipeline. The backend was fully regenerated. **5 of 6 Lovable-bearing components in scope were REGENERATED rather than hardened** — extreme regenerate ratio (83%) reaffirming the M2 4/8 → M3 5/12 → M4 5/5 → M5 5/6 trend. The lone harden was `RegulatoryRadarChart` (the SVG visualisation itself) — pure-props pass-through with ZERO supabase coupling.

**M5 also introduces 14 net-new components** (no Lovable precedent): admin CRUD dialogs, T9 destructive confirms, impact-category admin (config list + picker + form), regulatory-update detail/form/edit, regulatory-impact resolve dialog, regulatory-impacts list. Lovable did not have admin-side surfaces for these.

**Component fates:** 1 hardened, 5 regenerated, 14 net-new.

---

## Component Transformation Log

| Component | Source (Lovable) | Target (v2.6) | Fate | Cycles | Transformations Applied |
|---|---|---|---|---|---|
| RegulatoryRadarChart | `src/components/regulations/RegulatoryRadar.tsx` (543 LOC; pure SVG; ZERO supabase coupling) | `src/features/regulatory/components/RegulatoryRadarChart.tsx` (HARDENED) | hardened | 1 | T3, T5, T6, T7, T11 |
| RegulationsListView | `routes/_app/admin.regulations.tsx` (232 LOC) + `regulations.index.tsx` (1282 LOC slice) | `src/features/regulatory/components/RegulationsListView.tsx` (regenerated) | regenerated | 0 (audit-report mandate) | T1, T2, T3, T4, T5, T6, T7, T8, T10, T11, T12 |
| RegulationDetailDrawer | inline detail panel inside `regulations.index.tsx` (1282 LOC parent) | `src/features/regulatory/components/RegulationDetailDrawer.tsx` (regenerated) | regenerated | 0 (section-level extract) | T1, T2, T3, T4, T5, T6, T7, T11, T12 |
| RegulatoryRadarDashboard | `routes/_app/regulations.radar.tsx` (539 LOC) | `src/features/regulatory/components/RegulatoryRadarDashboard.tsx` (regenerated; the SVG chart inside hardened separately) | regenerated | 0 (missing source tables — M4-FE-OI-3 root) | T1, T2, T3, T4, T5, T6, T7, T10, T11, T12 |
| BulkAmendmentSheet | `src/components/regulations/BulkAmendmentSheet.tsx` (912 LOC; 5-step wizard; supabase + approvalEngine) | `src/features/regulatory/components/BulkAmendmentSheet.tsx` (regenerated) | regenerated | 0 (architectural mismatch — M2/M3 separation of concerns) | T1, T2, T3, T4, T5, T6, T7, T8, T9, T11, T13 |
| RegulatoryImpactBanner | `src/components/contracts/RegulatoryImpactBanner.tsx` (172 LOC; supabase reads) | `src/features/regulatory/components/RegulatoryImpactBanner.tsx` (regenerated) | regenerated | 0 (JSONB shape mismatch) | T1, T2, T3, T4, T5, T6, T7, T11 |

**3-cycle rule outcome:** the lone harden (RegulatoryRadarChart) completed in 1 cycle. The 5 regenerates hit zero cycles because the audit-report (Phase L1) recommended REGENERATE up-front. Net regenerate count across the project: M1a 0/11, M1b 0/4, M1c 0/3, M2 4/8, M3 5/12, M4 5/5, **M5 5/6 (83%)**. Every increment reaffirms `feedback_regenerate_when_lovable_too_coupled.md`.

---

## New components (14 — v2.6 native, no Lovable precedent)

Lovable did not have admin-side surfaces for regulations or impact_category management. M5 builds these net-new:

| Component | Story | Notes |
|---|---|---|
| `RegulationFormFields` | S3 + S4 shared | Shared field set used by Create + Edit dialogs. |
| `RegulationCreateDialog` | S3 | Modal — focus trap + ESC close + form hygiene. |
| `RegulationEditDialog` | S4 | Modal — does NOT expose supersededById (M5-FE-OI-2 — polite supersession-pairing UX deferred). |
| `RegulationDeleteConfirmDialog` | S5 | T9 destructive confirmation. |
| `RegulatoryUpdateDetailPanel` | S7 | Re-used inside the radar dashboard (S6) and the regulations list (admin context). |
| `RegulatoryUpdateFormFields` | S8 + S9 shared | Shared field set used by Create + Edit forms. |
| `RegulatoryUpdateCreateForm` | S8 | Standalone form (admin route). |
| `RegulatoryUpdateEditForm` | S9 | Includes the AC-S9-02 publishedDate floor guidance inline. |
| `RegulatoryUpdateDeleteConfirmDialog` | S10 | T9 destructive — surfaces the cascade-soft-delete count from the response. |
| `RegulatoryImpactsList` | S12 | Paginated list variant (in addition to the inline banner; admin context). |
| `RegulatoryImpactResolveDialog` | S13 | T9 destructive — radio-action picker IS the explicit commitment (the chosen action commits the resolve). |
| `ImpactCategoryConfigList` | S14 (admin variant) | Full payload list for admin picker management. |
| `ImpactCategoryPicker` | S14 (picker variant) | Lighter shape used inside `RegulatoryUpdateFormFields`. |
| `ImpactCategoryConfigForm` | S15 | Upsert form keyed on `key`. |

3 new admin routes mounted under `src/routes/app/`:
- `/app/admin/regulations` (S1..S5 admin entry).
- `/app/admin/impact-categories` (S14..S15 admin entry).
- `/app/regulatory-radar` (S6 dashboard entry).

All 3 routes wrap their view in `<ErrorBoundary>` (M2 admin.imports.tsx pattern).

> **M5-FE-OI-4 (recurring with M4-FE-OI-1):** `routeTree.gen.ts` was manually patched to register the 3 new routes. The TanStack router-plugin overwrites this on next vite dev/build because the .tsx files exist — re-emission is automatic; no operator action required.

---

## Harden-vs-regenerate decision matrix (M5)

| Driver | Lovable regulatory components | Decision |
|---|---|---|
| Service imports | 5 of 6 components use `supabase.from()` reads or `supabase.functions.invoke + approvalEngine + direct supabase.from()` writes incompatible with v2.6. | All 5 forced to regenerate — adapter layer would be > 50% of each file. |
| Wire shape | `fn_regulatory_impact_list` returns a different (camelCase JSONB) shape than the Lovable supabase JOIN. | Faster to regenerate with the new contract directly. |
| Missing source tables | M4 deferred `regulatory_update` + `regulations` + `regulatory_impacts` tables to M5 (M4-FE-OI-3 root). M5 introduces them but Lovable's `regulations.radar.tsx` was wired against the not-yet-existing tables. | Cannot harden against tables that don't exist; M5 reifies the data plane and rebuilds the dashboard fresh. |
| Architectural separation | Lovable `BulkAmendmentSheet` chained `supabase.functions.invoke` + `approvalEngine` + direct `supabase.from()` writes. v2.6 splits these: M2 owns approval routing, M4 owns AI insight, M5 owns just bulk-detect. | Hardening would replace ~85% of the file AND cross v2.6 module boundaries — regenerate is cleaner. |
| Pure-props pass-through | `RegulatoryRadar.tsx` (the SVG visualisation) is a pure-props component with ZERO supabase coupling. | The lone HARDEN — 1 cycle, 5 transformations applied, 8 skipped (N/A). |
| Net-new admin surfaces | Lovable had no admin-side surfaces for regulation CRUD or impact_category management. | 14 net-new components — no Lovable precedent. |

When in doubt, prefer regenerate over forced-harden. M5 reaffirms the M2/M3/M4 precedent emphatically: when the Lovable wire shape is fundamentally different OR when the component crosses v2.6 module boundaries OR when source tables don't exist yet, regenerate is the right answer — not a workaround.

---

## Preserved from Lovable

- **The visual silhouette of the regulatory radar** is preserved — `RegulatoryRadarChart` is a HARDEN (camelCase prop renames + i18n namespace shift `regulations.radar.* → regulatory.radar.*` + token preservation + a11y additions: `role='img'`, translated aria-label, `prefers-reduced-motion`-aware sweep + node-pop animations).
- **The visual silhouette of the impact banner** (`RegulatoryImpactBanner`) — amber strip, severity dots, "review" CTA, returns null when empty — preserved even though the underlying component was regenerated. The Lovable visual identity carries forward.
- **The 5-step bulk-amend workflow concept** is preserved (`BulkAmendmentSheet`) but the wire layer is fully reconstituted: instead of supabase.functions.invoke + approvalEngine, the new sheet calls `POST /regulatory-impacts/bulk-detect` and routes downstream actions through M2 approvals + M4 AI summary.
- **The radar's filter axes** (severity / regulator / category / effective-window / compliance-deadline-cliff) preserved verbatim — `fn_regulatory_update_list` exposes all of them.
- **The 8 default impact_category rows** were extracted byte-for-byte from the Lovable schema and seeded in migration 052.

---

## Rebuilt from scratch

- The entire **backend** for M5 (5 new tables + 15 fn_'s + 1 cross-module activity-type extension + 3 new permissions + ~18 RLS policies + 5 audit triggers + the M5-PROD-DEFECT-1 patch) — Lovable did not have a production backend for these features.
- All **5 regenerated FE components** as enumerated above.
- The **regulatory_impact schema** itself was orphan in Lovable (the FE component referenced an absent table). M5's G1 reconstitution rebuilt the schema from Phase L1 `entity-graph.json.reconstitutedCreateTable` + AC clarifications + the M5 types.ts ALTER chain.
- The **DEFINER carve-out** for `fn_regulatory_impact_create_bulk` — Lovable's bulk-detect ran in supabase edge functions with no equivalent fine-grained permission split.
- The **idempotent COALESCE-sentinel UNIQUE** for `regulatory_impact` (Q7) — Lovable had no idempotency guard for structural impacts.
- The **polymorphic permission at the resolve endpoint** — `regulations.manage` OR `contract.drafted_by = current_user` (AC-S13-05).
- The **impact-category taxonomy admin surface** (S14 list + S15 upsert) — Lovable had hard-coded categories.
- The **admin CRUD surfaces** for regulation + regulatory-update + impact-category — 14 net-new components.

---

## Discarded from Lovable

| Discarded | Reason |
|---|---|
| 5 Lovable regulatory components (RegulationsListView / RegulationDetailDrawer / RegulatoryRadarDashboard / BulkAmendmentSheet / RegulatoryImpactBanner) | Pervasively supabase-coupled OR architectural mismatch with v2.6 module boundaries OR missing source tables. Regenerated. |
| All `supabase.from()` reads on `regulatory_*` tables | Replaced by `apiClient` (axios) → `regulatory.service.ts` → `useRegulatory.ts` hooks. |
| All `supabase.functions.invoke` calls | Replaced by direct API calls to M5 endpoints (or M4 endpoints for AI explain / amendment / PDF export). |
| Lovable `BulkAmendmentSheet`'s direct `approvalEngine` import + `supabase.from()` writes | Replaced by clean separation: M5 owns just bulk-detect (POST /regulatory-impacts/bulk-detect); M2 owns approval routing; M4 owns AI summary. |
| Lovable's hardcoded impact-category list | Replaced by `impact_category` table + `fn_impact_category_list` + S15 upsert endpoint. |
| Lovable's regulation tag denormalization (no canonical taxonomy) | Replaced by `regulation.tags TEXT[]` (Q4 — junction normalization deferred to M7+) with GIN index + filter UI. |
| Lovable's missing supersession chain UI | Replaced by recursive CTE in `fn_regulation_get_by_id` (max 5 hops — AC-S2-02) + UI rendering. |
| Lovable's lack of bulk-detect idempotency | Replaced by COALESCE-sentinel UNIQUE + ON CONFLICT DO NOTHING (Q7); idempotent re-runs return `skippedDuplicateCount`. |
| Lovable's `RegulatoryRadar.tsx` 543 LOC props mixing snake_case and camelCase | Hardened to pure-camelCase props — `name_en → nameEn`, `name_ar → nameAr` (matches v2.6 JSONB conventions). |

---

## Throwaway Tax Summary

| Layer | Lovable LOC discarded | Reason |
|---|---|---|
| RegulationsListView (admin.regulations.tsx) | ~232 | supabase-coupled |
| regulations.index.tsx (slice — list + detail logic) | ~1282 | kitchen-sink route mixing list+detail+filter+banner |
| RegulationDetailDrawer (inline) | ~150 (slice of 1282) | tangled with parent route's filter/impact-loading state |
| regulations.radar.tsx (dashboard) | ~539 | bound to non-existent supabase tables |
| BulkAmendmentSheet | ~912 | architectural mismatch — supabase + approvalEngine + supabase.from() writes |
| RegulatoryImpactBanner | ~172 | JSONB shape mismatch |
| **Total discarded LOC (FE)** | **~3,287** | |
| RegulatoryRadarChart (HARDENED) | n/a (preserved) | the lone harden — 1 cycle |
| Lovable supabase RLS policies on regulatory tables | (DB only) | Replaced by M5 RLS policies. |

This is roughly equivalent to M4's ~3,449 LOC discarded, but principled in the same way: every discarded line was either supabase-coupled (incompatible with v2.6 architecture), dependent on tables that didn't exist, or crossed v2.6 module boundaries inappropriately.

---

## Developer waivers

**No waivers.** All 5 regenerated components moved straight to regenerate per the audit-report mandate; no component shipped with failing harden checklist items requiring developer override. The lone hardened component (`RegulatoryRadarChart`) passed all applicable transformations in 1 cycle.

M5 follows the M2 + M3 + M4 precedent: when the source is fundamentally incompatible (supabase coupling, missing tables, architectural mismatch), regenerate is the right answer — not a workaround.

---

## i18n keys added during M5

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

---

## Design token adjustments

None. M5 reuses the existing M0-Foundation Design System tokens unchanged. Severity badges use the existing `terracotta` / `amber` / `sage` / `gold` / `slate` semantic scales already sanctioned by M2/M3/M4 patterns. Radar chart uses `ink` / `ink-muted` / `border` / `card` foreground tokens — no raw hex codes.

---

## DEFECT-1 retrospective

The Testing Agent caught a high-severity production-blocker that DB Implementation Step 4 + Smoke Test missed. Same pattern as M4's DEFECT-1 — a column/error-mapping escape that lazy-compiles past Stage 2 and DB-Impl, surfaces only on first realistic test invocation.

**The bug:** `fn_regulation_update.supersededById` returned 422 (raw FK fallthrough) instead of the AC-S4-04 mandated 400 (with `{ supersededById: 'Referenced regulation not found' }` envelope). Functional rejection of the bad supersession was preserved (UPDATE didn't commit) — only the FE inline-error UX degraded.

**Root cause:** `fn_regulation_update` body in migration 050 had no structured-raise FK pre-check on `supersededById`. The sibling `fn_regulatory_impact_create_bulk` in the SAME migration 050 had the canonical pre-check — DEFECT-1 was a parity miss within the same migration file.

**The fix (migration 053):** 9-line `IF v_new_superseded_by IS NOT NULL THEN PERFORM 1 ... ; IF NOT FOUND THEN RAISE EXCEPTION ... USING ERRCODE = '23503'` block. JSONB return shape byte-identical to 050; signature unchanged; controller bindings unchanged.

**Stage 2 lesson S2-23 (codified post-DEFECT-1):** for every fn_ accepting an FK id parameter, Stage 2 design check MUST verify a structured-raise pre-check exists. Codified to MEMORY.md `feedback_stage2_checks_s2_16_to_s2_20.md`. Title retitled S2-16..S2-22 → S2-16..S2-23. Composition section ERRCODE list expanded `(P0001/42501/P0002/23514/22023)` → `(P0001/42501/P0002/23514/22023/23503)`.

This kind of escape is exactly the Codex blind spot Stage 2+4 must absorb in the post-Codex-skip era. The S2-23 codification is the canonical response — design-time verification + DB-Impl Step 4 functional probe extension to include the negative path with regex match on the structured raise envelope.

---

## What carries forward (M6+ scope hints from M5)

- **`/api/v1/regulators` admin CRUD endpoints (REG-OI-B / M5-FE-OI-1):** M5 ships no regulator admin surface; the FE `useRegulatorCatalog` hook dedupes from regulatory_updates list. Brand-new tenants will see an empty regulator dropdown until at least one update exists. Future module adds the endpoint OR the FE eats the empty-state UX.
- **Polite supersession-pairing UX (M5-FE-OI-2):** `RegulationEditDialog` does not expose `supersededById`. AC-S4-02 (auto-flip status to 'superseded') is preserved at the BE for whoever calls the endpoint with supersededById directly. The polite UX needs its own design cycle.
- **Compliance deadline on impact banner (M5-FE-OI-5):** `fn_regulatory_impact_list` payload omits `regulatory_update.complianceDeadline` (only id/title/severity are embedded). To surface deadlines we'd need either a BE projection extension or a per-row second fetch.
- **S2-23 forward-looking carry-forward:** 4 sibling M5 fn_'s lack the canonical FK pre-check (`fn_regulation_create.issuerId`, `fn_regulatory_update_create.regulator_id` + `categoryId`, `fn_regulatory_update_update.regulator_id` + `categoryId`). Patch when next AC requires the 400 envelope.
- **4th cron driver — generalisation point:** with 3 in-process cron drivers (M2 escalation, M3 expiration, M4 eviction) the threshold is crossed. M5 added zero new cron drivers (event-driven only). When M6+ lands the 4th cron, extracting a shared `cron-runner.ts` becomes a defensible Phase 2 architectural decision.
- **Junction normalization (Q4):** `regulation.tags`, `impact_category.default_clause_categories`, `regulatory_update.affected_clause_categories` are TEXT[] in M5 (production gap acknowledged). M7+ would normalize via junction tables.

---

# M6 Migration — Lovable Insights Surface → v2.6

> **Module:** M6 (ninth module — Dashboards & Reporting).
> **Generated:** 2026-05-05.
> **Pipeline:** Lovable Modernization v3.2 (Mode A — Lovable only).
> **Source:** `C:/Users/azureadmin/projects/musanad-contracts-hub` (Lovable prototype).
> **Target:** `musanad-contracts-frontend` + `musanad-contracts-backend`.
> **Codex review:** SKIPPED per Dexian decision 2026-05-04. **6th consecutive validation** through M2/M3/M4/M5/M6 — pattern fully entrenched. Stage 2 + Stage 4 absorb the safety net via S2-16..S2-23 (S2-22b JOIN-target-column tracing recommended for codification post M6-DB-IMPL-DEFECT-1).

---

## Milestone — M6 complete

✅ **M6 milestone CHECKED.** All upstream gates PASS. DB live (both branches v57 incl. patch 057). BE+FE built and tsc clean. Integration Verifier (PASS round 1, 10/10 endpoints), Smoke Test, Testing Agent (92/92 net-new + 18 pre-existing TEST-DEBT-M1 carry-forward), QA Stage 4 all PASS first-run. Documentation generated (this run). Migrations 054..056 + 057 applied to both `test` and `m0-foundation` branches.

✅ **M4-FE-OI-2 CLOSED — both halves.**
- **S9 (half 1) — `ExecutiveAnomaliesCard` mounted into `ExecutiveDashboard`.** The new M6 `ExecutiveDashboard` (regenerated) derives `anomaliesStats` via `useMemo` from its own KPIs (`totalActiveValueAed`, `contractsByStatus`, `expiryCliffs`, supplierConcentration as counterparty share). The existing M4 `ExecutiveAnomaliesCard` is rendered with `autoFetch={true}` so it self-fires once stats arrive. NO modifications to the M4 card itself.
- **S10 (half 2) — `VersionDiffSummaryPanel` mounted into `ContractVersionList`.** No standalone `VersionCompareDialog` component existed in v2.6 (`ContractVersionList` was the closest mount point per the post-M1a frontend structure). Edited `src/features/contracts/components/ContractVersionList.tsx` to add a `VersionDiffSummaryPanel` slot inside the expanded version row when an adjacent older version exists (idx + 1 in newest-first list). `additions` = current.bodyEn, `deletions` = older.bodyEn (full-blob — M6-FE-OI-4 documents the simplification; future iteration could add client-side diff via `diff-match-patch`). `modifiedClauses` = []. `autoFetch={false}` so the M4 AI call only fires when the user clicks regenerate (avoids accidental cost). NO modifications to the M4 panel itself.

---

## Summary

This module was built using the Lovable Modernization pipeline. The backend was fully regenerated. **6 of 6 Lovable insights/*.tsx components in scope were REGENERATED rather than hardened — the most extreme regenerate ratio yet (100%).** All 6 imported `supabase` directly and queried non-existent tables (`audit_summary_admin`, `dashboard_admin_kpi`, `supabase.functions.invoke('executive-anomalies')`, etc.). Pre-flagged in Phase 1 as DASH-OI-B; the Phase 2 inspection confirmed for the remaining 5 dashboards as well.

**M6 also introduces 6 net-new components** (no Lovable precedent): the dashboard router, executive anomalies history viewer, AI cost panel, admin health shell, shared dashboard primitives, and the data-layer service / hooks / types modules.

**Plus 2 mount-only edits to existing M4 components** (S9 + S10 — closes M4-FE-OI-2) and **1 reuse via variant prop** (S13 — admin tile-grid landing reuses the same backend as S1 with `variant='tile-grid'`).

**Component fates:** 0 hardened, 6 regenerated, 6 net-new, 2 mount-only edits, 1 reuse.

---

## Component Transformation Log

| Component | Source (Lovable) | Target (v2.6) | Fate | Cycles | Transformations Applied |
|---|---|---|---|---|---|
| AdminDashboard | `src/components/insights/AdminDashboard.tsx` (450L; supabase-coupled) | `src/features/dashboards/components/AdminDashboard.tsx` (regenerated; variant='insights'\|'tile-grid') | regenerated | 0 (audit-report mandate + supabase coupling) | T1, T2, T3, T4, T5, T6, T7, T11, T12 |
| DrafterDashboard | `src/components/insights/DrafterDashboard.tsx` (809L; supabase-coupled) | `src/features/dashboards/components/DrafterDashboard.tsx` (regenerated) | regenerated | 0 | T1, T2, T3, T4, T5, T6, T7, T11, T12 |
| ApproverDashboard | `src/components/insights/ApproverDashboard.tsx` (674L; supabase-coupled; assumed assigned_at column) | `src/features/dashboards/components/ApproverDashboard.tsx` (regenerated) | regenerated | 0 | T1, T2, T3, T4, T5, T6, T7, T11, T12 |
| LegalCounselDashboard | `src/components/insights/LegalCounselDashboard.tsx` (1236L; mixed regulation-list + impact-list + audit-summary into one supabase-coupled wall) | `src/features/dashboards/components/LegalCounselDashboard.tsx` (regenerated; lighter projection) | regenerated | 0 | T1, T2, T3, T4, T5, T6, T7, T11, T12 |
| RecipientDashboard | `src/components/insights/RecipientDashboard.tsx` (476L; referenced non-existent signer_user_id / signed_at / outcome) | `src/features/dashboards/components/RecipientDashboard.tsx` (regenerated) | regenerated | 0 | T1, T2, T3, T4, T5, T6, T7, T11, T12 |
| ExecutiveDashboard | `src/components/insights/ExecutiveDashboard.tsx` (1825L; heavily supabase-coupled — DASH-OI-B confirmed) | `src/features/dashboards/components/ExecutiveDashboard.tsx` (regenerated; mounts ExecutiveAnomaliesCard for S9 closure) | regenerated | 0 (DASH-OI-B carry-forward) | T1, T2, T3, T4, T5, T6, T7, T11, T12 |

**3-cycle rule outcome:** all 6 regenerates hit zero cycles because the audit-report (Phase L1) recommended REGENERATE for at least 1 (DASH-OI-B / ExecutiveDashboard) and Phase 2 inspection confirmed the same for the other 5. Net regenerate count across the project: M1a 0/11, M1b 0/4, M1c 0/3, M2 4/8, M3 5/12, M4 5/5, M5 5/6 (83%), **M6 6/6 (100%)**. Every increment reaffirms `feedback_regenerate_when_lovable_too_coupled.md`. M6 is the first module where ZERO Lovable insights/*.tsx components were retained.

---

## New components (6 — v2.6 native, no Lovable precedent)

Lovable did not have:
- A dashboard routing helper (Lovable rendered all dashboards from a single combined view).
- A standalone executive anomalies history viewer.
- An admin AI cost sidebar panel.
- An admin observability health shell distinct from M0's public liveness.
- Shared dashboard primitives (Lovable inlined KPI tile components in each dashboard file).
- A clean data layer (Lovable wired `supabase.from()` reads directly inside JSX `useEffect`s).

M6 builds these net-new:

| Component | Story | Notes |
|---|---|---|
| `InsightsRouter` | S6 | Auto-redirect entry route at `/app/dashboards/insights`. Calls `useDashboardRouter`, then navigates to the role's specific dashboard. Closed `DashboardKey` map drives the navigate path; one localised `as any` cast for the runtime-computed `to` (alternative is a switch statement compiling to the same router call). |
| `ExecutiveAnomaliesHistoryCard` | S8 | Standalone history viewer reading from M4 `ai_insight` cache via `fn_dashboard_executive_anomalies_history`. AC-S8-02 empty-array semantics (NOT 404). |
| `AICostPanel` | S11 | Per DASH-OI-G — mounts independently into admin dashboard sidebar via React Query (separate query key); NOT bundled into `/admin` payload. windowDays clamped to 1..90 (M4 cap). |
| `AdminHealth` | S12 | Distinct from M0 public liveness `/api/health`. Admin-scoped. `db.latestMigration` depends on `schema_migrations_select_admin` policy from migration 054. aria-live='polite' on overall banner. |
| `dashboard-primitives` | shared | Shared `KpiTile` / `PlaceholderKpiTile` / `TimeRangeSelector` / `DashboardLoadingSkeleton` / `DashboardErrorState` / `DashboardEmptyState` / `DashboardSection` + currency / percent / number formatters. |
| Data layer | shared | `dashboards.service.ts` (10 thin axios methods), `useDashboards.ts` (10 React Query hooks 1:1 with the endpoints), `dashboards.types.ts` (11 response interfaces + 14 embedded shapes + 4 enums). |

10 new routes mounted under `src/routes/app/`:
- `/app/dashboards/admin` (S1).
- `/app/dashboards/drafter` (S2).
- `/app/dashboards/approver` (S3).
- `/app/dashboards/legal-counsel` (S4).
- `/app/dashboards/recipient` (S5).
- `/app/dashboards/insights` (S6 — InsightsRouter).
- `/app/dashboards/executive` (S7).
- `/app/dashboards/executive/anomalies` (S8).
- `/app/admin/health` (S12).
- `/app/admin/index` (S13 — admin tile-grid landing reusing AdminDashboard with `variant='tile-grid'`).

All 10 routes wrap their view in `<ErrorBoundary>` (M5 admin.regulations.tsx pattern).

> **M6-FE-OI-3 (recurring with M5-FE-OI-4 / M4-FE-OI-1):** `routeTree.gen.ts` was manually patched to register the 10 new routes. The TanStack router-plugin overwrites this on next vite dev/build because the .tsx files exist — re-emission is automatic; no operator action required.

---

## Harden-vs-regenerate decision matrix (M6)

| Driver | Lovable insights components | Decision |
|---|---|---|
| Service imports | 6 of 6 components import `supabase` directly + reference non-existent tables (`audit_summary_admin`, `dashboard_admin_kpi`) and edge functions (`supabase.functions.invoke('executive-anomalies')`). | All 6 forced to regenerate — adapter layer would be > 50% of each file. |
| Wire shape | `fn_dashboard_*` returns role-specific `kpis + (trends \| lists)` shapes that are materially different from Lovable's view-driven projections. | Faster to regenerate with the new contract directly. |
| Missing source tables | Lovable assumed `audit_summary_admin` / `dashboard_admin_kpi` / `executive_anomalies` views/edge-fn that don't exist in v2.6 — those were "future" surfaces in the prototype. | Cannot harden against tables/views that don't exist; M6 ships the correct telemetry surface and rebuilds the dashboards fresh. |
| Architectural coupling | Lovable mixed query, transform, and render into single supabase-bound components. v2.6 splits these: data layer (service + React Query hook) → presentation (component) → route shell (ErrorBoundary). | Hardening would replace ~85% of file content per component without preserving meaningful visual fidelity (the Lovable look-and-feel was driven by hand-built supabase queries, not by visual primitives). Regenerate is cleaner. |
| Pre-flagged in Phase 1 | DASH-OI-B explicitly flagged `ExecutiveDashboard.tsx` (1825L) as REGENERATE — the largest of the 6 dashboards. | The audit-report mandate confirmed early; Phase 2 inspection confirmed the same for the other 5. |
| Net-new admin / observability surfaces | Lovable had no admin observability health probe (S12), no standalone AI cost panel (S11), no executive anomalies history viewer (S8), no dashboard router helper (S6). | 6 net-new components — no Lovable precedent. |

When in doubt, prefer regenerate over forced-harden. M6 reaffirms the M2/M3/M4/M5 precedent at maximum strength: when EVERY Lovable component in scope is supabase-coupled AND references non-existent tables AND ships a fundamentally different wire shape, regenerate is the right answer for ALL of them — not a workaround.

---

## Preserved from Lovable

- **The dashboard concept set** — the 5 role-scoped dashboards (admin / drafter / approver / legal-counsel / recipient) + executive overview were Lovable's idea. M6 preserves the role split; the wire layer + data plane are reconstituted.
- **The KPI tile UX** — "tile of headline number + small label + optional sparkline" is preserved across all 5 role dashboards. The `dashboard-primitives.KpiTile` component is the v2.6 canonical implementation.
- **The time-range selector pattern** — Lovable had a "Last 7d / 30d / 90d / Custom" pill set. M6's `TimeRangeSelector` preserves this UX with v2.6 a11y additions (`aria-pressed`, `aria-label` on custom-days input).
- **The expiry-cliff buckets** (next30d / next60d / next90d on executive dashboard) — preserved verbatim with the v2.6 monotonic invariant (AC-S7-03).
- **The value-distribution histogram buckets** (`<100k` / `100k-1M` / `1M-10M` / `10M+`) — preserved verbatim.
- **The admin landing tile-grid concept** (S13) — preserved as the `AdminDashboard variant='tile-grid'` reuse path.

---

## Rebuilt from scratch

- The entire **backend** for M6 (4 plain views + 10 fn_'s + 1 RLS policy + 1 permission code + 3 grants + the M6-DB-IMPL-DEFECT-1 patch) — Lovable had no production backend for these features (its dashboards queried views and edge functions that didn't exist).
- All **6 regenerated FE dashboards** as enumerated above.
- The **dashboard router helper** (S6) — Lovable's FE used a hand-rolled `if (role === 'admin') ...` ladder inside route shells; M6's `InsightsRouter` calls a backend fn to make the decision, reducing FE coupling to the role naming.
- The **single-source-of-compute AI cost path** (Q5 lock — `fn_ai_request_log_cost_report` wrapped by `fn_dashboard_ai_cost_summary`) — Lovable had `vw_ai_cost_rollup` planned but not implemented; M6 explicitly DROPS the view in favour of the wrapped fn_.
- The **ARCH-NEW-3 option (c) RLS SELECT policy** on `schema_migrations` — Lovable had no admin health probe of comparable depth.
- The **placeholder KPI envelope** (`{value:0, placeholder:true}`) — Lovable hardcoded 0 / "N/A" string for slots whose source tables didn't exist; M6 introduces an explicit envelope so the FE renders disabled tiles with "feature pending" tooltips, distinguishable from a real zero-value count.

---

## Discarded from Lovable

| Discarded | Reason |
|---|---|
| All 6 Lovable insights/*.tsx dashboards (~5,470 LOC total) | Pervasively supabase-coupled + referenced non-existent tables + assumed wire shapes that don't match v2.6 fn_ outputs. Regenerated. |
| `audit_summary_admin` view reference | Replaced by `fn_dashboard_legal_counsel.kpis.auditSummary` aggregating directly from `audit_log.table_name` (S2-22-FIX-4). |
| `dashboard_admin_kpi` view reference | Replaced by `fn_dashboard_admin` composing live `contract` / `approval_step` / `signature_invitation` / `regulatory_impact` / `audit_log` reads. |
| `supabase.functions.invoke('executive-anomalies')` | Replaced by GET `/api/v1/dashboards/executive/anomalies-history` reading the M4 `ai_insight` cache + the existing M4 POST `/api/v1/ai/executive-anomalies` for refresh (NOT redefined in M6). |
| Lovable's `signer_user_id` / `signed_at` / `outcome` references | Replaced by live `signature_event.actor_user_id + created_at + event_type='signed' AND is_active=TRUE` (S2-22-FIX-1). |
| Lovable's `assigned_to` / `assigned_at` references | Replaced by `COALESCE(delegated_to, reassigned_to, approver_user_id)` (S2-22-FIX-2a) and `step.created_at` (S2-22-FIX-2b). |
| Lovable's `audit_log.entity_type` reference | Replaced by `audit_log.table_name` (S2-22-FIX-4). |
| Lovable's flat `roleName` extraction | Replaced by COALESCE chain on nested `role:{id,name}` (S2-22-WARN-3-FIX). |
| Lovable's `decision IN ('approved','rejected')` past-tense literals | Replaced by present-tense `'approve'/'reject'` matching the live CHECK enum (S2-22-WARN-1-FIX). |
| Lovable's `audit_log.action='ERROR'` probe | DROPPED entirely (S2-22-WARN-2-FIX) — CHECK enum is INSERT/UPDATE/DELETE only; literal could never match. Error signal sourced exclusively from `ai_request_log.outcome`. |

---

## Throwaway Tax Summary

| Layer | Lovable LOC discarded | Reason |
|---|---|---|
| AdminDashboard | ~450 | supabase-coupled + non-existent dashboard_admin_kpi view |
| DrafterDashboard | ~809 | supabase-coupled |
| ApproverDashboard | ~674 | supabase-coupled + assumed non-existent assigned_at column |
| LegalCounselDashboard | ~1,236 | mixed concerns + supabase-coupled |
| RecipientDashboard | ~476 | supabase-coupled + referenced non-existent signature_event columns |
| ExecutiveDashboard | ~1,825 | DASH-OI-B (heavily supabase-coupled; Lovable's largest dashboard) |
| **Total discarded LOC (FE)** | **~5,470** | |
| Lovable supabase RLS policies on insights views | (DB only) | Replaced by M6 RLS on `schema_migrations` (1 new policy) + M0..M5 RLS unchanged. |

This is the largest throwaway tax for a single module to date (~5,470 LOC vs M5's ~3,287 / M4's ~3,449). Principled in the same way: every discarded line was either supabase-coupled (incompatible with v2.6 architecture), dependent on tables/views that didn't exist, or assumed wire shapes that don't match v2.6 fn_ outputs.

---

## Developer waivers

**No waivers.** All 6 regenerated components moved straight to regenerate per the audit-report mandate (DASH-OI-B for ExecutiveDashboard) + Phase 2 confirmation (the other 5); no component shipped with failing harden checklist items requiring developer override. There were no harden cycles to fail in the first place.

M6 follows the M2 + M3 + M4 + M5 precedent: when the source is fundamentally incompatible (supabase coupling, missing tables, materially-different wire shape), regenerate is the right answer — not a workaround.

---

## i18n keys added during M6

**+202 keys per locale** (en + ar — parity match=true; programmatically verified via `scripts/m6-i18n-inject.cjs` which aborts on mismatch).

Pre-M6 totals: en=4,125 / ar=4,125 (post-M5). Post-M6 totals: en=4,327 / ar=4,327.

Namespaces added (all under top-level `dashboards.*`):
- `dashboards.common.*` — shared UI strings (windowDays, time-range pills, severity labels, empty-state CTA, etc.).
- `dashboards.admin.*` — S1 admin dashboard (also serves S13 tile-grid).
- `dashboards.drafter.*` — S2.
- `dashboards.approver.*` — S3.
- `dashboards.legalCounsel.*` — S4.
- `dashboards.recipient.*` — S5.
- `dashboards.insightsRouter.*` — S6 (loading state + fallback).
- `dashboards.executive.*` — S7.
- `dashboards.executiveAnomalies.*` — S8.
- `dashboards.aiCost.*` — S11.
- `dashboards.adminHealth.*` — S12 (overall status banner + db / ai sections).

Namespaces extended: none. M6 added a single new top-level namespace (`dashboards.*`) with 11 sub-namespaces — minimised cross-talk with existing M0..M5 namespaces.

---

## Design token adjustments

None. M6 reuses the existing M0-Foundation Design System tokens unchanged. Severity badges use the established M5 pattern (`terracotta-tint` / `amber-tint` / `sage-tint` / `muted`). Status pills use the existing semantic scales already sanctioned by M2/M3/M4 patterns. KPI tiles use `ink` / `ink-muted` / `ink-subtle` / `gold` / `border` / `card` / `surface` foreground tokens — no raw hex codes; no Tailwind defaults.

---

## DEFECT-1 retrospective

The DB Implementation Agent caught a CRITICAL escape that Stage 2 (round 2 PASS) did not — **JOIN-target column drift** that lazy-compiled past `pg_proc` registration and surfaced only on first realistic invocation. See `dev-handoff.md` M6 Implementation Notes and `data-dictionary.md` M6 Key DB Impl outcomes for the full narrative.

**Same shape as M3-DEFECT / M4-DEFECT / M5-DEFECT — third consecutive escape in the column-existence family.** The S2-22 sweep at design time + the `report-don't-fix` discipline at DB-Impl successfully escalated all four to named patch migrations rather than silent rewrites. The codification proposal extends S2-22 with a new sub-rule (S2-22b) — JOIN-target-column tracing — which would have caught this earlier. Recommended for memory promotion at module close.

This kind of escape is exactly the Codex blind spot Stage 2+4 must absorb in the post-Codex-skip era. The S2-22b codification is the canonical response — design-time verification + DB-Impl Step 4 functional probe extension to include all qualified column references against live target-side DDL.

---

## What carries forward (M7+ scope hints from M6)

- **Counterparty / parties module** (M6-FE-OI-2 — DASH-OI-A): `topCounterpartiesByValue5` returns `counterpartyId` only — no name (no parties table yet). FE shows `'ID #{id}'` with a 'Name pending' chip per AC-S7-04. When the parties module ships, the BE projection should add `nameEn`/`nameAr` and the FE should render those preferentially. Same applies to `RecipientMyContractsRow.counterpartyId` (always null until parties module).
- **Templates module** (DASH-OI-A): `LegalCounselDashboardKpis.templateUsageThisWindow` is a `{value:0, placeholder:true}` envelope. When the templates module ships, replace the placeholder with the real count.
- **Obligations module** (DASH-OI-A): `RecipientDashboardKpis.myObligationsCount` is a `{value:0, placeholder:true}` envelope. When the obligations module ships, replace the placeholder.
- **TimeRangeSelector debounce** (M6-FE-OI-1): custom-range typing fires immediate refetch on each digit. A 300ms debounce would tighten this. Out of scope for M6; logged for future polish.
- **ContractVersionList client-side diff** (M6-FE-OI-4): S10 mount passes full bodyEn for both additions and deletions (no client-side diff). A future iteration could add `diff-match-patch` for sharper M4 prompts.
- **`/api/v1/regulators` admin CRUD** (M5 carry-forward / REG-OI-B): still open from M5. M6 didn't add it.
- **Polite supersession-pairing UX** (M5-FE-OI-2): still open.
- **Compliance deadline on impact banner** (M5-FE-OI-5): still open.
- **S2-22b codification** (M6 retrospective): JOIN-target-column tracing — promoted to memory follow-up at module close.
- **Q11 carry-forward**: 4 sibling M5 fn_'s lack the canonical FK pre-check. DEFERRED — apply the canonical S2-23 template when next AC requires the 400 envelope.
- **ARCH-NEW-1 carry-forward**: M4 `audit.read.all` drift fix still DEFERRED.
- **Materialise heaviest dashboard view if read latency exceeds SLA**: would introduce a 4th cron driver. M5 carry-forward note about extracting a shared `cron-runner.ts` becomes more pressing if M7+ adds a refresh scheduler.
- **Regenerate trend tracking**: cumulative — M2 4/8 → M3 5/12 → M4 5/5 → M5 5/6 → M6 6/6 (100%). The trend has plateaued at "everything Lovable-bearing in dashboard scope is incompatible." M7+ scope (likely adjacent to existing telemetry rather than building on Lovable surfaces) may break the trend or cement it further.

---

*Generated by Documentation Generator from M5 fe-implementation-summary.json + audit-report.md (Phase L1) + gate2-decisions.md + 053-defect1-patch-summary.md + qa-stage4-report.json. No Codex FE review run for M5 (Dexian decision 2026-05-04; 4th consecutive validated).*

---

## CR-C / M10 — Audit Hardening + Multi-Tenancy + Admin Cockpit Foundation (2026-05-10)

### BE↔FE Contract Notes

All 7 CR-C admin service modules follow the same service-layer pattern established in R-PA7: `src/services/api/admin/*.service.ts` is the sole `apiClient` consumer; components receive data via React Query hooks exported from the service files. Zero direct apiClient calls in components or route files (QA Stage 4 A6/A7 PASS).

**Envelope unwrap patch (BR1 — applied by FE Impl before Smoke):** All 7 services were initially written extracting `response.data.data` but the actual api response is `ApiResponse<T>` with `{ success, data, requestId }`. After Integration Verifier surfaced the mismatch, services were corrected to extract `response.data.data` correctly (axiosInstance returns the full `AxiosResponse`, not the unwrapped value). Verified clean in Smoke.

**Branding field-name patch (BR2 — applied by FE Impl before Smoke):** `fn_system_setting_set` returns `footerEn` (not `footerTextEn`) and `faviconUri` (present, not aliased). BrandingEditor updated to match actual BE shape.

**authPassRef write-only invariant:** `SmtpConfigForm` never surfaces `authPassRef` in a display field. GET response carries `authPassRefSet: boolean` (true if a value is stored). PATCH body may include `authPassRef` for updates; empty string clears the stored value. FE typecheck `tscPass: true` — no type holes around this invariant.

### Audit Canonical Helper

The BE utility module `src/utils/audit-canonical.util.ts` is the TypeScript mirror of PG `fn_audit_log_canonicalize(JSONB)`. Both must remain byte-identical. If you modify either:

1. Run the cross-platform parity fixtures in `tests/utils/audit-canonical.util.test.ts` (3 test vectors).
2. Do NOT change the alphabetical-sort order, NULL serialization (`'null'`), or timestamp format (`yyyy-MM-ddTHH:mm:ss.uuuuuuZ`).
3. Any divergence breaks the audit chain hash — `fn_audit_chain_verify` will report `verified: false` at the first row written after the divergence.

### Branding Upload Flow

1. FE: `BrandingEditor` calls `branding.service.ts → uploadBrandingAsset(kind, file)`.
2. BE: `POST /api/v1/admin/branding/upload` (multipart/form-data) — validated by Zod: kind = 'logo' | 'favicon', file = PNG or SVG, ≤ 2 MB.
3. BE: multer middleware receives the file buffer; controller calls `SupabaseStorageClient.upload('branding/<tenant_id>/<filename>')` (M_parity 061 attachment pattern).
4. BE: on upload success, calls `fn_system_setting_set('branding.logo_uri', uri)` or `fn_system_setting_set('branding.favicon_uri', uri)`.
5. BE: returns `{ kind, uri, storagePath }`.
6. FE: `invalidateQueries(['admin-branding'])` causes `BrandingEditor` to refetch and display the new logo.

Branding URIs are public Supabase Storage URLs (no signed-URL rotation needed — logos are not sensitive). If a tenant rotates their logo, the old URI becomes orphaned in storage (no cleanup automation in v1 — post-pilot follow-up).

### Demo Purge Double-Confirm Pattern

The `/app/admin/demo/purge` page implements a two-step confirmation UX:

1. **Step 1 — Dry run:** FE calls `POST /admin/demo/purge` with `{ dryRun: true }`. BE returns counts by table. DemoPurgePanel renders a summary card: "This will delete N demo rows across M tables."
2. **Step 2 — Confirm token:** FE renders a text input instructing the admin to type `PURGE_DEMO_DATA_<today's date>`. The token is computed client-side from `new Date()` formatted as `YYYY-MM-DD`.
3. **Step 3 — Purge:** FE calls `POST /admin/demo/purge` with `{ dryRun: false, confirmToken: '<typed-token>' }`. BE validates the token server-side against the server's UTC date — one-day tolerance to handle midnight edge cases.

`DemoPurgePanel` uses `useFocusTrap` in the confirmation modal. Submit button disabled during mutation (`isPending`). Toast on success: "Demo data purged — N rows removed."

Role gate: the purge button is hidden via `{ data.user?.role?.name === 'Super Admin' }` check in the FE component **in addition to** the BE permission gate. Defense-in-depth pattern consistent with existing destructive actions in the app.

### Role Admin UX Guidelines

The Roles editor page (`/app/admin/roles`) was previously read-only (R-PA0 — user could see the permission grid but not modify it). CR-C makes it fully editable for platform_admin and Super Admin.

**Built-in role protection:** The 8 built-in roles (`Super Admin`, `Admin`, `User`, `platform_admin`, `executive`, `legal_counsel`, `contract_drafter`, `contract_approver`) cannot be renamed or deleted. `RoleEditor` receives `isBuiltIn: boolean` from the role list response and hides the rename input + delete button accordingly — matching the fn_ body guard.

**Permission grant/revoke:** `RoleEditor` renders the full permission grid from `GET /api/v1/roles/:id` (existing read path) and posts changes via `POST /admin/roles/:id/permissions/:permId/grant` and `DELETE /admin/roles/:id/permissions/:permId/revoke`. Grant and revoke are both idempotent — no optimistic UI needed; `invalidateQueries(['admin-roles', id])` after each mutation is sufficient.

**Essential grant protection:** Super Admin's essential grants (8 hard-coded permission codes) cannot be revoked via the UI — BE returns 422 `cannot_revoke_system_grant` and FE renders it as a toast error. The revoke button is visually disabled for these specific combinations in `RoleEditor`.

### Post-Pilot Follow-Ups

- **Real audit chain TX-server timestamping:** Current `fn_audit_log_record_v2` uses `CURRENT_TIMESTAMP` (DB clock). Annex D.7.1 recommendation for a cryptographic TX-server timestamp (RFC 3161) is deferred to post-pilot hardening.
- **Microsoft Graph + Slack webhook integration:** `notification_template` channels `teams_capture` and `slack_capture` are seeded and render correctly, but the actual webhook dispatcher (Microsoft Graph API call / Slack incoming webhook) is not implemented in CR-C. Templates are ready; dispatcher is a post-pilot follow-up.
- **Multi-region audit replication:** `audit_log` hash chain ensures tamper-evidence within a single Neon branch. Cross-region replication of the chain to a read-only replica with independent verification is a post-pilot infrastructure concern.
- **D-CRC-1 fix:** `GET /admin/settings?category=X` ignores the category filter at the controller layer — `fn_system_setting_list` receives the param but the query-param binding in the settings controller is missing. Single-line fix; scheduled for next CR.
- **D-CRC-2 fix:** `PATCH /admin/settings/:key` Zod regex requires camelCase (`/^[a-zA-Z][a-zA-Z0-9]*$/`) but all setting keys use dot-notation. Regex widening to `/^[a-zA-Z][a-zA-Z0-9.]*$/` resolves this; scheduled for next CR.
- **D-CRC-6 fix:** `POST /admin/roles/:id/permissions/:permId/grant` with unknown permId returns generic NOT_FOUND body code instead of `permission_not_found`. Single remap() call in roles-mgmt.controller.ts; scheduled for next CR.

---

*CR-C section generated 2026-05-10 by Documentation Generator from api-contracts.json + fe-implementation-summary.json + qa-stage4-report.md + module-M10-test-report.md. Mode: REGENERATE (no Lovable components hardened in this CR — all surfaces are net-new admin cockpit pages).*

---

## CR-D0 — Document Ingestion Pipeline (M11)

*Generated 2026-05-12. Mode: REGENERATE (3 new components + 1 extended route — all net-new, no Lovable originals to harden).*

### BE↔FE Envelope Unwrap Contract (BR1-equivalent FIX-1 pattern)

The Musanad BE wraps all single-resource responses as `{ success: true, data: T, requestId: string }`. List endpoints that call fn_ functions returning `{ data: [...], pagination: {...} }` directly spread the pagination envelope without the wrapper (bare return pattern).

CR-D0 services exposed a critical defect during FE integration (BR1-equivalent): services used naked `return data` without unwrapping, so the FE received `{ success, data: {...}, requestId }` as the typed entity — polling never stopped because `response.ingestionStatus` was `undefined`.

**Fix pattern** (applied to 4 of 5 CR-D0 service methods):
```typescript
import { unwrap } from '../lib/api-client';
// ...
const response = await apiClient.get<ApiEnvelope<IngestionStatus>>(url);
return unwrap<IngestionStatus>(response.data);  // unwrap strips { success, data, requestId }
```

**Exception** — the admin ingestion-queue list endpoint correctly uses bare `return data` because the BE controller spreads the pagination envelope directly (not wrapped in a `data` key). The FE admin service reads `response.data` and `response.pagination` directly.

**Rule**: any endpoint whose BE controller calls `return res.json({ success: true, data: result })` requires `unwrap<T>()` in the FE service. Any endpoint that spreads fn_ pagination output directly does not.

### Document Ingestion Service Pipeline

File: `src/services/document-ingestion.service.ts`

The service implements a three-engine extraction cascade:

1. **MIME type detection** — `file-type` package detects whether the buffer is PDF or DOCX (MIME-based, not extension-based — prevents extension spoofing).

2. **PDF path**:
   - `pdf-parse` extracts the text layer from the raw PDF buffer. If `text.trim().length > 50` characters and no Arabic-heavy heuristic triggers, the document is classified as `digital_pdf` and extraction is complete.
   - If the text layer is sparse (scanned PDF), `tesseract.js` processes each page with `eng+ara` traineddata. Per-page confidence is recorded.
   - Pages where `confidence < ocr.confidence_threshold` (from system_setting, default 0.75) AND the daily Vision cap (`ai.daily_vision_cap_pages`) has not been reached are passed to gpt-4o Vision via AIProvider.
   - Pages over the daily cap are recorded in `ingestion_review_queue` with `review_status = 'pending_human'` (no Vision call made).

3. **DOCX path** — `mammoth` extracts paragraphs with structure preserved (headings, bold, lists). `extraction_engine = 'mammoth_docx'`. `ocr_used = FALSE`.

4. **`pdfjs-dist` DROP** — pdfjs-dist v5 is ESM-only and requires Node 22+. The import inside the service blew up at first call. `pdfjs-dist` was removed from BE runtime deps entirely. Page count and text-layer data come from `pdf-parse` (already a dependency). Tesseract.js processes the raw PDF buffer directly. This deviates from §4.11 SOT (which mentioned pdfjs-dist explicitly) and is documented as a CR-D0 deviation.

### Worker Pattern

File: `src/workers/ingestion.worker.ts`

The ingestion worker uses **node-cron** (same scheduler as M2 escalation and M7 source-health) with a configurable cron expression (`INGESTION_WORKER_CRON_EXPR`). Each tick:

1. Queries for up to `N` contract_version rows with `ingestion_status IN ('pending', 'failed')` via `SELECT FOR UPDATE SKIP LOCKED` (S2-17 concurrency primitive — prevents double-pickup across concurrent worker instances).

2. Runs extractions in parallel with **p-limit** concurrency 2 (N22 lock — same `pLimit(N)` pattern as M7 puppeteer-pool.service.ts; not Puppeteer-specific).

3. Before each `fn_ingestion_review_queue_record` INSERT, executes `SET LOCAL app.current_tenant_id = '<adnoc-uuid>'` (N18 — worker resolves tenant via singleton ADNOC tenant UUID for v1 single-tenant demo, matching M7 source_health pattern).

4. On success: calls `fn_contract_version_ingestion_complete`. On failure: calls `fn_contract_version_ingestion_fail`. On `attemptCount >= 2` (Q5): marks terminal failure and notifies admin.

### Supabase Storage Path Convention

Extracted text is stored in Supabase Storage at:
```
<tenantId>/<contractId>/v<n>/<uuid>.txt
```

Where `<uuid>` is a freshly generated UUID per extraction run (N12 — NAMING-CONFLICT-2). This prevents same-version retry overwrites from clobbering the original artifact, preserving the audit trail even when re-extraction is triggered via the manual ingest endpoint.

The `supabase-storage.service.ts` `signDownloadUrl` method is called with `expiresIn: 60` (seconds) for all extracted-text signed URL requests. The FE caches the signed URL response with `staleTime: 50_000` ms (10 s margin before TTL expiry).

### ai_request_log Scalar Mapping per Vision Call

Each gpt-4o Vision page call writes one row to `ai_request_log` via the existing M4 helper:

| Column | Value |
|---|---|
| entity_type | `'contract_version'` |
| entity_id | contract_version.id |
| mode | `'vision_extract'` |
| prompt_id | `'ai-document-ingestion-vision'` (seeded in migration 136) |
| provider | `'openai'` |
| model_used | `'gpt-4o'` |
| latency_ms | wall-clock extraction time for the page |
| cost_usd_estimate | estimated cost per Vision call |
| status | `'success'` or `'error'` |

`prompt_hash` and `page_no` are not stored (no `metadata JSONB` column on ai_request_log today). This is deferred per OPEN-DECISION N16/N17.

### Signed URL TTL (60 s)

All signed URLs for extracted-text artifacts have a **60-second TTL** (enforced in `supabase-storage.service.ts`). The FE service uses `staleTime: 50_000` in the React Query config so it will refetch before the URL expires. The `extractedTextUri` column on `contract_version` is never exposed directly to the client — the BE controller strips it from the `fn_contract_version_ingestion_status` response. Only the `/extracted-text` endpoint returns a signed URL.

### IngestionReviewPanel Design Notes

Component: `src/components/contracts/IngestionReviewPanel.tsx`

- `useFocusTrap` wired (consistent with all destructive/review modals in the app — same pattern as M3 SignatureDialog, CR-C DemoPurgePanel).
- `tesseract_text` and `gpt4o_text` are **excluded from the list endpoint response** (`fn_ingestion_review_queue_list` does not return these fields). Only the review panel UI triggers a separate fetch for the full row content when the reviewer opens a specific page — sensitivity-controlled exposure.
- Admin ingestion queue page (`/app/admin/ingestion-queue`) uses 5 filter chips (All / Pending auto / Pending human / Resolved / Rejected) mapping to `reviewStatus` query param values.

---

## M14 + M15 (CR-F + CR-G) — Unit 2A + 2B

> **Shipped:** 2026-05-13 (CR-F Unit 2A; CR-G Unit 2B in fresh session)
> **Schema version:** 177 after M14 → 190 after M15 (both Neon branches)
> **Modules:** M14 / CR-F (5-Dim Risk Scoring + MaR + AVaR) + M15 / CR-G (Executive Evolution + 4 Persona Dashboards + AI Risk Assistant)

---

### M14 / CR-F — 5-Dim Risk Scoring + MaR + AVaR

**TL;DR:** Ships the CRIP Wave 2 risk scoring engine. 1 append-only table (`risk_score`), 1 materialized view (`latest_risk_score` — project's first MV), 8 net-new fn_'s, 2 EXTEND fn_'s, score-recompute worker, 6 BE routes, full UI surface (Risk tab + AVaR dashboard section + scoring-weights admin page). +96 i18n keys.

**Migrations:** 10 total (168..177; 176 + 177 are in-flight defect-fix patches)

**Net-new vs EXTEND:**

| Type | Count | Names |
|---|---|---|
| Tables | 1 | risk_score |
| Materialized Views | 1 | latest_risk_score |
| Functions (new) | 8 | fn_risk_score_compute / explain / history / fn_avar_aggregate / fn_score_recompute_for_signal / fn_score_recompute_for_weight_change / fn_scoring_weights_get / fn_scoring_weights_set |
| Functions (extended) | 2 | fn_rule_evaluate (+pg_notify), fn_audit_trigger (41→43 redact) |
| Permissions | 3 | score.read / score.weights.manage / risk.acknowledge |
| system_setting rows | 3 | scoring.weights / scoring.exposure_fraction_defaults / scoring.impact_multipliers |
| BE routes | 6 | GET risk-score, GET history, GET avar, GET/PATCH/POST admin/scoring-weights |
| FE routes (new) | 1 | /app/admin/scoring-weights |
| FE tabs/sections (inject) | 2 | Risk tab on contract detail, AvarDashboardSection on executive dashboard |
| i18n keys | +96 | risk.score.* / risk.mar.* / risk.avar.* / admin.scoring.* |

**Key architectural decisions:**

#### Q1 — MaR currency conversion timing
**Locked:** locked-at-correlation. MaR is captured in AED at the moment the correlation is created. Avoids live-FX recalculation on every display request. Audit-consistent; the historical MaR record is immutable.

#### Q2 — Score recompute granularity
**Locked:** per-correlation v1. Each new correlation triggers an immediate recompute for the affected contract via PG NOTIFY + LISTEN worker. Batched 5-minute window deferred to pilot when AVaR contract count grows beyond ~100.

#### Q3 — Probability calculation method
**Locked:** weighted-by-source-reliability. Probability = weighted average of correlation confidence scores, weighted by `osint_source.reliability`. Source quality is the dominant variance in a single-tenant AED-base deployment.

#### Q4 — Score history retention
**Locked:** all snapshots forever (v1). Demo scale: <100 contracts × <30 recomputes/year = <3,000 rows. Tiered retention (90d full + monthly aggregates) deferred to pilot.

#### Q5 — MaR for NULL contract_value (SOWs)
**Locked:** MaR=NULL + UI placeholder. Preserves data semantics — SOWs contribute 0 AED to portfolio AVaR. FE shows "No monetary value — operational risk only" in the MaR tile.

**Defects caught + fixed in-flight:**

| ID | Stage | Description |
|---|---|---|
| DEFECT-3 | Agent 6 | contract.tenant_id column doesn't exist (single-tenant v1) — 4 fn_ body adaptations |
| DEFECT-CR-F-1 | Smoke + Integration Verifier | S2-22 miss in fn_risk_score_explain (sig.signal_kind → sig.kind; sig.occurred_at → sig.event_date_v2) + BIGINT::text casts on 4 fn_'s |
| DEFECT-DB-01 | Testing Agent | fn_scoring_weights_set manual audit_log INSERT missing prev_hash/this_hash NOT NULL columns — switched to fn_audit_log_record_v2 helper |
| DEFECT-DB-02 | Testing Agent | latest_risk_score MV column alias inconsistency between branches — normalized to `id` |

**S2-21 streak:** 13th consecutive clean module. Zero net-new PUBLIC EXECUTE. Live proacl verified at QA Stage 4 for all 10 fn_'s + 1 MV.

**Production-credibility-invariant compliance:**

- Database Objects First: All business logic in 8 net-new + 2 EXTEND fn_'s. Zero ORM. Zero business logic in controllers.
- Backend thin layer: 6 routes → 2 controllers → db.callFunction() → JSONB response.
- JWT + permission middleware on all 6 routes.
- FORCE RLS on risk_score. Explicit tenant-scoping invariant documented on latest_risk_score MV.
- Pino redact extended: 62 paths covering contributingCorrelations / explanation / marValue / dim_* / weightsApplied.
- Rollback blocks on all 10 migrations.

---

### M15 / CR-G — Executive Evolution + 4 Persona Dashboards + AI Risk Assistant

**TL;DR:** Ships the decision surface layer atop M14. Executive dashboard gains 3 new sections. 4 net-new persona dashboards (Operations, Finance & Treasury, Compliance & ESG, Procurement). AI Risk Assistant floating drawer with SSE streaming Q&A. 3 new ADNOC roles. +256 i18n keys. Zero net-new tables.

**Migrations:** 13 total (178..190; 189 + 190 are in-flight defect-fix patches)

**Net-new vs EXTEND:**

| Type | Count | Names |
|---|---|---|
| Tables (new) | 0 | — |
| Tables (extended) | 1 | ai_request_log (+scope_hash + acl_filtered_count) |
| Functions (new) | 4 | fn_dashboard_operations / finance_treasury / compliance_esg / procurement_supplier_risk |
| Functions (extended) | 1 | fn_dashboard_executive (+3 top-level keys) |
| Roles | 3 | operations / finance_treasury / compliance_esg |
| Permissions | 5 | insights.operations/finance_treasury/compliance_esg/procurement_supplier_risk + ai.invoke.risk_assistant |
| role_permission grants | ~57 | 30 native + 14 pre-emptive backfill + 13 final grants |
| ai_prompt rows | 6 | risk_assistant.qa_<persona> × 6 personas |
| BE routes (new) | 5 | 4 persona dashboard GET + 1 AI Risk Assistant POST (SSE) |
| FE routes (new) | 4 | /app/dashboards/operations|finance-treasury|compliance-esg|procurement |
| FE components (inject) | 2 | ExecutiveCrgExtension + RiskAssistantPanel (floating AppShell singleton) |
| i18n keys | +256 | dashboards.operations.* / .fintech.* / .compliance.* / .procurement.* / ai.riskAssistant.* |

**Key architectural decisions:**

#### Q1 — Role seeding strategy
**Locked:** seed AND demo live-create. Seed rows in migration 181 provide a reliable fallback for any demo environment. Platform Admin live-create flow is also demoable to showcase role management UX.

#### Q2 — AI Risk Assistant transport
**Locked:** SSE streaming with ?stream=false non-streaming fallback. SSE provides demo wow factor and better first-token latency. Fallback ensures resilience.

#### Q3 — Per-persona dashboard auto-refresh cadence
**Locked:** 60s polling v1 (React Query refetchInterval). Event-driven WebSocket deferred to pilot at current demo scale.

#### Q4 — Procurement supplier-risk surface scope
**Locked:** dashboard only in CR-G. List view + filter UI deferred to R-PROC persona round to keep CR-G ship-able and focused.

#### Q5 — Risk Assistant per-persona prompts
**Locked:** separate prompts per persona (6 ai_prompt rows). Allows per-persona tuning without cross-impact. Matches M4 6-prompt seeding pattern.

**Agent 3 dependency resolutions:**

- **A1 (AVaR coexistence):** `valueAtRisk` key NOT added to fn_dashboard_executive — M14 AvarDashboardSection already consumes /risk/avar. Adding it would create dual sources of truth. AC-S17-03 allows skipping.
- **A4 (per-party risk):** AVG(latest_risk_score.health_score) per party's active contracts.
- **A4b (backup-supplier categorization):** party.party_type pivot (industry + partner_role columns do not exist in live DB).
- **fn-name:** fn_ai_request_log_create (18-arg) — brief said _record; live DB has _create.
- **M13-projection:** assignedRoles is PLURAL ARRAY (matches correlation_rule.produce_yaml schema).

**Defects caught + fixed in-flight:**

| ID | Stage | Description |
|---|---|---|
| DEFECT-CR-G-1 | Post-impl | migration 188 omitted platform_admin's 3 insights perms |
| DEFECT-CR-G-2 (CRITICAL) | Post-impl | fn_dashboard_executive produce_yaml::jsonb cast on TEXT column → invalid_input_syntax |
| DEFECT-CR-G-3 | BE testing | executive controller missing tenantId GUC pass-through |
| DEFECT-CR-G-4 | Post-impl | same YAML cast in fn_dashboard_finance_treasury (1×) + fn_dashboard_compliance_esg (3×) |
| CRITICAL-2 (Verifier) | Integration Verifier | FE dashboards-crg.service.ts raw return data without envelope unwrap |

**Known open defects (post-ship):** DEFECT-CR-G-5 (fn_clause_semantic_search arg mismatch — degrades citations), DEFECT-CR-G-6 (ai_request_log duplicate request_id), DEFECT-CR-G-7 (CRITICAL — LLM stream silent; blocks AI Q&A demo).

**Deferred:** Agent 12 Testing Agent + QA Stage 4 deferred to post-ship sprint. 6/7 ACs verified via live walks.

**S2-21 streak:** 14th consecutive clean module. Zero net-new PUBLIC EXECUTE. All 5 fn_'s + 1 EXTEND verified.

**Production-credibility-invariant compliance:**

- DEFINER VOLATILE on all 4 dashboard fn_'s — explicit tenantId GUC set in BE controller before every call.
- ACL pre-filter on AI Risk Assistant: fn_contract_list narrows context + scope_hash computed for Annex D §15.3 audit.
- ai_request_log EXTEND with scope_hash + acl_filtered_count — audit fields per Annex D §15.3.
- Pino redact +4 paths: query / filters / contextText / token.
- Rollback blocks on all 13 migrations.
- Latest_risk_score MV tenant-scoping invariant correctly propagated to fn_dashboard_procurement_supplier_risk supplier scorecard join.

---

*M14 + M15 (CR-F + CR-G) section generated 2026-05-13 by Documentation Generator from M14-summary.md, M15-summary.md, decisions/M14.json, decisions/M15.json, migrations 168..190, and BE source types.*

*CR-D0 section generated 2026-05-12 by Documentation Generator from migrations 132..140, after-state.md, module-M11-test-report.md, decisions/M11.json.*
