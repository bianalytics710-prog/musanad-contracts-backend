# M0 Foundation - Ops Runbook

> **Project:** Musanad Contracts Hub (`musanad-contracts`)
> **Module:** M0 - Foundation
> **Generated:** 2026-05-02
> **Audience:** Ops engineers / SREs running the system in dev, staging, or production.

For developer onboarding see `dev-handoff.md`. For DB schema details see `data-dictionary.md`. For UAE Pass production wiring see `uae-pass-integration.md`.

---

## 1. Environment setup

### Required env vars (backend)

Cross-reference `musanad-contracts-backend/.env.example`. All variables are validated at server startup by `src/utils/env-validation.util.ts` - the process exits with a clear error if any required value is missing or malformed.

| Var | Required | Default | Notes |
|---|---|---|---|
| `NODE_ENV` | Yes | `development` | `development`, `production`, or `test`. |
| `PORT` | Yes | `4000` | HTTP listen port. |
| `LOG_LEVEL` | Yes | `info` | Pino level. |
| `DATABASE_URL` | Yes | - | Neon pooler connection string with `sslmode=require`. |
| `DATABASE_POOL_MAX` | Yes | `20` | pg pool size. |
| `JWT_SECRET` | Yes | - | Min 32 chars random; rotate on suspected compromise. |
| `JWT_AUDIENCE` | Yes | `musanad-contracts` | Validated on every JWT verify. |
| `JWT_ISSUER` | Yes | `musanad-contracts-backend` | Validated on every JWT verify. |
| `JWT_ACCESS_TTL` | Yes | `15m` | Access token TTL. |
| `JWT_REFRESH_TTL` | Yes | `7d` | Refresh token TTL. |
| `AI_PROVIDER` | Yes | `openai` | `openai` or `anthropic` (anthropic is a stub). |
| `OPENAI_API_KEY` | If `AI_PROVIDER=openai` | - | Service-account key recommended (`sk-svcacct-...`). |
| `OPENAI_MODEL_DEFAULT` | Yes | `gpt-4o` | Default model for AI features. |
| `OPENAI_MODEL_FAST` | Yes | `gpt-4o-mini` | Cheaper model for low-stakes tasks. |
| `SMTP_HOST`, `SMTP_PORT` | Yes | `localhost`, `1025` | Mailpit dev defaults. |
| `SMTP_USER`, `SMTP_PASS` | Optional | - | Empty for Mailpit; required for hosted SMTP. |
| `SMTP_FROM_NAME`, `SMTP_FROM_EMAIL` | Yes | `Musanad Contracts`, `no-reply@musanad.local` | |
| `UAE_PASS_PROVIDER` | Yes | `mock` | `mock` or `live`. Live throws NotImplementedError until wired. |
| `UAE_PASS_*` (other) | Required when `live` | empty | Real client_id/secret/URLs - see `uae-pass-integration.md`. |
| `SUPABASE_*` | Optional | empty | Transitional - storage is still on Supabase per project config. |
| `CORS_ORIGIN` | Yes | `http://localhost:5173` | Frontend origin. |
| `REQUEST_ID_HEADER` | Yes | `X-Request-ID` | Correlation header name. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Optional | empty | When set, OpenTelemetry traces are exported. |

### Required env vars (frontend)

| Var | Required | Default | Notes |
|---|---|---|---|
| `VITE_API_BASE_URL` | Yes | `http://localhost:4000` | Backend origin. |
| `VITE_DISPLAY_TIMEZONE` | Yes | `Asia/Dubai` | Used by `formatDateTime`. |
| `VITE_DEFAULT_LOCALE` | Yes | `en` | Detector overrides at runtime. |

### Secrets management

- **Local dev:** `.env.local` in each repo. Both `.gitignore` files exclude `.env.local` and `.env.*` while keeping `.env.example` checked in. Never commit a populated `.env*`.
- **Production:** use a secret manager (AWS Secrets Manager / Azure Key Vault / GCP Secret Manager / HashiCorp Vault). Inject into the runtime as env vars at start.
- **Rotation policy:**
  - `JWT_SECRET`: rotate on suspected compromise. Rolling rotation requires a brief dual-secret window; document procedure when first feature module supports it.
  - `OPENAI_API_KEY`: rotate after dev work if security-sensitive (the key was pasted into chat during init - see decisions.md G7).
  - DB password: rotate via Neon dashboard; update `DATABASE_URL` in secret manager.

---

## 2. Database operations

- **Provider:** Neon Serverless Postgres.
- **Project:** `musanad-contracts` (id `patient-morning-04972561`), org `Baranidharan` (`org-cool-cherry-32960520`).
- **Region:** `us-east-2 (aws)`.
- **Branches:**
  - `main` - production-like default branch (`br-wispy-mud-ajs84sc9`).
  - `m0-foundation` - current dev branch (`br-snowy-brook-aje2ehtl`). M0 migrations applied here.
- **Pooler endpoint:** `ep-still-violet-aj0h962i-pooler.c-3.us-east-2.aws.neon.tech` (already in the connection string template).
- **Pool size:** `DATABASE_POOL_MAX=20` (driver-side).

### Migrations

```bash
# From musanad-contracts-backend/
npm run migrate         # apply pending migrations (UP)
npm run migrate:down    # rollback latest (DOWN, via -- ROLLBACK markers)
```

Currently applied: `001_foundation`, `002_security_hardening` (CRX-1 atomic blacklist + CRX-4 search_path pinning).

For ad-hoc / emergency apply: use the Neon MCP tool (`run_sql` / `run_sql_transaction`) or `psql $DATABASE_URL`. Always wrap multi-statement operations in `BEGIN/COMMIT`.

### Connection string format

```
postgresql://<role>:<password>@<host>-pooler.<region>.aws.neon.tech/<db>?channel_binding=require&sslmode=require
```

`sslmode=require` is mandatory. The driver validates the cert by default (per CRX-5 fix - `rejectUnauthorized: false` was removed from `src/database/config.ts`).

---

## 3. Logging and observability

- **Logger:** Pino. Structured JSON to stdout (suitable for container log collectors).
- **Log level:** `LOG_LEVEL` env var.
- **Correlation:** every request gets an `X-Request-ID` UUID (via `correlation.middleware.ts`). Propagated through controller -> `db.callFunction()` -> Pino `req.id` -> response header.
- **Redaction:** `src/utils/logger.util.ts` configures Pino with redact paths covering all 17 sensitive field names plus auth headers and known token-bearing properties (37+ paths in total).
- **Pretty printing in dev:** `pino-pretty` is enabled when `NODE_ENV=development`.

### OpenTelemetry (stub, opt-in)

`src/utils/telemetry.util.ts` initializes OpenTelemetry SDK with auto-instrumentation for express, http, and pg. **Disabled by default** - only initializes when `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

To enable in any environment:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://your-otel-collector.example.com:4318
export OTEL_SERVICE_NAME=musanad-contracts-backend
```

Traces include HTTP request spans, Express route spans, and pg query spans (with sanitized SQL).

---

## 4. Health checks

`GET /api/health` (no version prefix, no auth).

```json
{
  "status": "ok",
  "db": "reachable",
  "uptime": 1234.56,
  "version": "0.1.0",
  "timestamp": "2026-05-02T12:34:56.000Z",
  "requestId": "7d0c1d2e-7c0f-4d6f-9b6c-9b9b1f7c2d3e"
}
```

- 200 when the DB is reachable (a `SELECT 1` succeeds within the timeout).
- 503 with `db: "unreachable"` when the DB query fails or times out.

Suitable for **both** Kubernetes liveness and readiness probes. The body is small and the DB check is cheap (single round-trip).

---

## 5. Rate limiting

Implemented via `rate-limiter-flexible` in `src/middleware/rate-limit.middleware.ts`.

| Endpoint | Limit |
|---|---|
| `POST /auth/login` | 5 requests / 15 min / IP |
| `POST /auth/refresh` | 10 requests / 15 min / IP |
| `POST /auth/logout` | 10 requests / 5 min / IP |
| `/users` (CRUD) | 60 requests / min / authenticated user |
| `/roles`, `/permissions` (read) | 120 requests / min / authenticated user |

**Storage:** in-memory (`RateLimiterMemory`). Per-process. Acceptable for single-replica deployments.

**Multi-replica deployment requires Redis swap** to `RateLimiterRedis`. `ioredis`-compatible client wiring is straightforward; the middleware is structured to swap stores without changing call sites. Track this as a follow-up before scaling beyond 1 replica.

**Trust proxy** is configured: `app.set('trust proxy', 1)` in `src/server.ts` (CRX-6 fix). When deploying behind a reverse proxy / load balancer with a different hop count, update this value accordingly.

---

## 6. Auth incident response

### Forced-rotate all sessions

```sql
-- Empty the blacklist forces all clients to re-login on next refresh.
TRUNCATE token_blacklist;
-- Optionally invalidate by JWT_SECRET rotation - rotate the secret in env, restart the BE.
-- All issued JWTs will fail aud/iss/exp + signature verification on next request.
```

### Invalidate a single user

```sql
-- Soft-deactivate. fn_user_get_by_id returns NULL; refresh flow rejects on inactive user.
UPDATE "user" SET is_active = false, updated_at = now() WHERE id = <user_id>;

-- Optionally clear that user's blacklist (housekeeping).
DELETE FROM token_blacklist WHERE user_id = <user_id>;
```

### Detect refresh token replay

The atomic blacklist `fn_auth_blacklist_if_absent` is the primary protection (CRX-1 fix). When a stolen token is presented after rotation, the `inserted: false` path returns 401. Look for elevated 401s on `/auth/refresh` from the same user as a signal.

### Rotate JWT_SECRET

1. Generate a new 32+ char random string.
2. Update the secret manager / env var.
3. Restart the backend. ALL issued JWTs become invalid; clients must re-login.
4. Note: rolling rotation (dual-secret window) is NOT supported in M0 - track as enhancement when first feature module needs it.

### Bcrypt cost

`bcrypt cost = 12` (in `src/utils/password.util.ts`). Do NOT lower without a security review. Costs above 12 may exceed the 250ms budget for `/auth/login` under load.

---

## 7. Backup & disaster recovery

- **Database:** Neon's automatic snapshots cover the DB (every project gets PITR within retention). For dev, the `m0-foundation` branch is itself a copy-on-write fork of `main`.
- **Application code:** GitHub repos `disc-product/musanad-contracts-backend` and `disc-product/musanad-contracts-frontend`.
- **Secrets:** must be in a secret manager in production. Local `.env.local` is gitignored - if a dev machine is lost, the dev re-fills `.env.local` from `.env.example` + the secret manager.

### Restore procedure

1. **DB:** restore via Neon dashboard - create a new branch from a snapshot timestamp. Update `DATABASE_URL` to point at the restored branch's pooler endpoint.
2. **Code:** clone from GitHub.
3. **Secrets:** pull from secret manager.
4. **Verify:** run `GET /api/health`, hit `POST /auth/login` with the bootstrap admin (or any known user), confirm 200.

---

## 8. Deployment

**Status:** deployment target deferred per `project.config.json` `deployment._status: "deferred"`.

### Frontend

Preserved from Lovable:
- **Target:** Cloudflare Workers SSR (configured via `wrangler.jsonc`).
- **Deploy:** `npx wrangler deploy` once Cloudflare auth is set up (`wrangler login`).
- **Build:** `npm run build` produces a Workers-ready bundle.

The existing `wrangler.jsonc` is kept under `preserveStack: true`. Switching SSR runtime (e.g., to Vercel or self-hosted Node) is possible but requires a Vite plugin swap and is out of scope for M0.

### Backend

Deferred. Options:

| Option | Pros | Cons |
|---|---|---|
| Azure App Service / Container Apps | UAE region availability (UAE North), Microsoft enterprise alignment | Slightly more configuration than App Service of competitors |
| AWS ECS Fargate | Cheap for steady-state | UAE has only AWS Bahrain (me-south-1) - latency consideration |
| GCP Cloud Run | Generous free tier, scale-to-zero | UAE customers see latency from Bahrain region |
| Self-hosted (UAE DC) | Data residency | Ops overhead |

The repo includes a multi-stage `Dockerfile` ready for any container target (Node 20 base, builder stage runs `npm ci && npm run build`, final stage runs `npm start`). Decide before first feature module ships to production.

---

## 9. Common errors & remediation

### `ECONNREFUSED postgres` / `terminating connection due to administrator command`

- **Cause:** DB is unreachable, Neon branch sleeping, or pool exhausted.
- **Fix:** verify `DATABASE_URL` is current; check Neon dashboard - the branch may have auto-suspended (Neon free tier; first query takes a few seconds to wake). Consider increasing `DATABASE_POOL_MAX` if pool is exhausted under load.

### `JWT verification failed (aud)`

- **Cause:** access token was minted with a different `JWT_AUDIENCE` than the verifier expects (e.g., env mismatch between BE replicas, or after secret rotation).
- **Fix:** confirm all replicas share the same `JWT_AUDIENCE`, `JWT_ISSUER`, `JWT_SECRET`. After secret rotation, all clients must re-login.

### `Rate limit exceeded` (429)

- **Cause:** legitimate user hit `/auth/login` too many times, or a misbehaving client / bot is hammering an endpoint.
- **Fix:** check Pino logs for the offender's `requestId` + IP. If legitimate, the user must wait the lockout window (15 min for login, 5 min for logout, 1 min for /users). For multi-replica deployments where the limiter is per-process, swap to Redis (see Section 5).

### `bcrypt timeout` / slow `/auth/login`

- **Cause:** bcrypt cost is too high for the host CPU, or CPU is contended.
- **Fix:** measure - one bcrypt(12) compare should take ~80-120ms on a modern x86 core. If significantly slower, the host is under-provisioned. Do NOT lower the cost without a security review; instead, scale up CPU.

### `RLS policy denied access`

- **Cause:** the BE forgot to call `SET LOCAL app.current_user_id = <jwt.sub>` before a `fn_*` call. Typically a bug where a controller bypasses the RLS middleware.
- **Fix:** verify the route uses `auth.middleware.ts` + `rls.middleware.ts` in that order. The middleware sets the GUC inside an active transaction; `db.callFunction` must run in the same transaction.

### `CORS blocked`

- **Cause:** `CORS_ORIGIN` does not match the frontend origin.
- **Fix:** update `CORS_ORIGIN` env var. For multiple origins, the helmet/cors middleware accepts a comma-separated list (parser in `src/server.ts`).

---

## 10. Operational checklists

### Before deploying to production

- [ ] Rotate bootstrap admin password (`admin@musanad.local` / `ChangeMe@123`).
- [ ] Provision a `test` Neon branch + `TEST_DATABASE_URL` (M0 test runs hit `m0-foundation`; not isolated).
- [ ] Implement real UAE Pass integration - see `uae-pass-integration.md`.
- [ ] Refactor Zustand auth -> httpOnly cookies + CSRF (CRX-7).
- [ ] Add OpenAI 30s timeout + 429 backoff (CRX-8).
- [ ] Swap rate limiter to Redis if scaling beyond 1 replica.
- [ ] Move state-store (UAE Pass) to Redis or a `uae_pass_state` DB table.
- [ ] Configure secret manager - never deploy with secrets baked into images or env files.
- [ ] Verify `JWT_SECRET` is >= 32 random chars (validation enforces this at startup).
- [ ] Wire OpenTelemetry exporter (`OTEL_EXPORTER_OTLP_ENDPOINT`) - production needs traces.
- [ ] Document runbook for forced session rotation, JWT secret rotation, and bcrypt cost adjustment.

### Weekly housekeeping

- [ ] Run cleanup query: `DELETE FROM token_blacklist WHERE expires_at < now() - interval '1 day';` (rows past expiry are no longer relevant).
- [ ] Review `audit_log` size - if exceeding budget, define retention policy.
- [ ] Check Neon usage dashboard for compute / storage / bandwidth trends.

---

*Generated by Documentation Generator. For developer onboarding, see `dev-handoff.md`. For UAE Pass live-integration steps, see `uae-pass-integration.md`.*

---
---

# M1a Deployment — Contracts: Core CRUD & Lifecycle

> **Module:** M1a (first sub-module of split M1).
> **Generated:** 2026-05-03.
> **Migrations applied:** 003..008 (6 sequential migration files; idempotent).

---

## Migration order (UP)

Apply in numeric order via the migration runner:

```bash
# From musanad-contracts-backend/
npm run migrate          # applies all pending migrations in order
```

Internal order for M1a:

| Step | File | What it does |
|---|---|---|
| 1 | `003_m1a_contracts.sql` | Tables (4), indexes (~31), audit-trigger bindings (3 of 4 tables - NOT contract_activity), 12 RLS policies (3 RESTRICTIVE), 7 roles, 9 permissions, 20 role-permission grants. Creates `pg_trgm` extension if not present. |
| 2 | `004_m1a_extend_sensitive_fields.sql` | Rebuilds `fn_audit_trigger` (M0) with `body_en`, `body_ar` appended to its redact array (now 19 names). |
| 3 | `005_m1a_contract_functions.sql` | All 12 fn_ functions + 2 activity-emit trigger functions and their bindings. |
| 4 | `006_m1a_grant_super_admin_contract_permissions.sql` | Patch: grants the M0 `Super Admin` role all 9 contract.* permissions (smoke-test follow-up; bootstrap admin needs them). |
| 5 | `007_m1a_fix_total_pages_zero.sql` | Patch: removes `GREATEST(1, ...)` clamp from `totalPages` in the three list fn_'s; empty list now reports `totalPages=0`. |
| 6 | `008_m1a_concurrency_fixes.sql` | Codex BE-001/002/003 patch: SELECT FOR UPDATE on parent (and self for fn_contract_update) before reads in `fn_contract_create`, `fn_contract_update`, `fn_contract_set_tags`. |

After migration, both branches (`m0-foundation` dev, `test`) report rows 1..8 in `schema_migrations`. A second `npm run migrate` invocation reports "No pending migrations" - idempotency verified.

---

## Rollback order (DOWN)

Rollback **strictly in reverse**, one migration at a time:

```bash
npm run migrate:down     # rolls back the latest applied migration only
# Run repeatedly to walk further back; never skip.
```

| Step | File | What rollback does |
|---|---|---|
| 1 | `008_m1a_concurrency_fixes.sql` | Restores the pre-008 fn_ bodies (no FOR UPDATE locks). **Re-introduces BE-001/002/003 races - do not run on production data without a downtime window.** |
| 2 | `007_m1a_fix_total_pages_zero.sql` | Restores the pre-007 fn_ bodies (totalPages clamped to >= 1). FE pager may render "page 1 of 1" on empty lists. |
| 3 | `006_m1a_grant_super_admin_contract_permissions.sql` | Removes Super Admin's 9 contract.* role-permission grants. The M0 bootstrap admin will receive 403 on every `/api/v1/contracts*` call. Granted to other M1a roles is unaffected. |
| 4 | `005_m1a_contract_functions.sql` | DROP all 12 fn_ + 2 trigger functions and their triggers. The 4 tables remain but have no callable API surface. |
| 5 | `004_m1a_extend_sensitive_fields.sql` | Restores the M0 `fn_audit_trigger` (17-name redact array). `body_en` / `body_ar` will appear unredacted in subsequent `audit_log` rows until 004 is re-applied. |
| 6 | `003_m1a_contracts.sql` | DROP the 4 tables, all indexes, all RLS policies, the 7 new roles, the 9 new permissions, and the 20 grants. Idempotent (uses `DROP ... IF EXISTS` and `DELETE ... WHERE` on lookup rows). |

**Disaster-rollback rule:** stop the application server (`npm run dev` / `npm start`) before stepping back through 005 and 003 - they invalidate the BE controller bindings.

---

## Health check after deploy

After applying 003..008, verify the deployment with three quick checks:

### 1. Contracts list returns 200 + empty data

```bash
# Login as bootstrap admin to obtain an access token
curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@musanad.local","password":"ChangeMe@123"}' \
  | jq -r '.accessToken' > /tmp/at

# Hit GET /contracts
curl -s -H "Authorization: Bearer $(cat /tmp/at)" \
  http://localhost:4000/api/v1/contracts \
  | jq

# Expected (empty database):
# { "success": true,
#   "data": { "data": [], "pagination": { "total":0, "page":1, "limit":20, "totalPages":0 } },
#   "requestId": "..." }
```

If this returns 403, migration 006 was not applied (Super Admin lacks `contract.read.*` permissions). If it returns 200 with `totalPages: 1` despite `total: 0`, migration 007 was not applied. If it returns 500, check the server logs for missing `fn_contract_list` (migration 005 not applied).

### 2. Sensitive-field redaction in the trigger

```sql
INSERT INTO contract (contract_number, title_en, contract_type, body_en, body_ar, created_by)
VALUES ('CT-TEST-001', 'Smoke', 'employment', 'SECRET EN', 'SECRET AR', 1);
SELECT old_values, new_values
FROM audit_log
WHERE table_name = 'contract'
ORDER BY id DESC LIMIT 1;
-- Expect: new_values->>'body_en' = '[REDACTED]'  AND  new_values->>'body_ar' = '[REDACTED]'
DELETE FROM contract WHERE contract_number = 'CT-TEST-001';   -- cleanup; goes through fn_audit_trigger too
```

### 3. RESTRICTIVE deny-direct-INSERT on contract_activity

```sql
SET LOCAL app.current_user_id = '1';
INSERT INTO contract_activity (contract_id, activity_type) VALUES (1, 'created');
-- Expect: ERROR: new row violates row-level security policy for table "contract_activity"
```

---

## Sensitive-field redaction note

`body_en` and `body_ar` are added to the project sensitive list by migration 004 and must NEVER appear in:

- **Pino log lines** - configured paths in `src/utils/logger.util.ts`: `*.bodyEn`, `*.body_en`, `*.bodyAr`, `*.body_ar`. Defence-in-depth across camelCase (DTOs / response payloads) and snake_case (raw DB rows).
- **`audit_log` JSONB** - `fn_audit_trigger` (rebuilt by migration 004) replaces both keys with `"[REDACTED]"` in `old_values` / `new_values` before inserting.
- **API error envelopes** - the BE error translator (`src/database/client.ts` STRUCTURED_RAISE_RE) never echoes raw PostgreSQL message text or table names. RLS denials become a sanitized `403 FORBIDDEN`.
- **Activity metadata** - `contract_activity.metadata` is FORBIDDEN from holding body content; status/version/tag activities record only structural deltas (`fromStatus`/`toStatus`, `versionNumber`, `{added, removed}`).

Verification at deploy time: run `tail -f` on the backend pino output, then `curl POST /api/v1/contracts -d '{"titleEn":"x","contractType":"y","bodyEn":"SECRET MATERIAL"}'` and grep the log for `SECRET MATERIAL` - zero matches expected.

---

## M1a-specific operational concerns

### `pg_trgm` extension

Migration 003 creates `CREATE EXTENSION IF NOT EXISTS pg_trgm;` for the GIN trigram index that powers ILIKE search across `contract_number / title_en / title_ar`. This requires `CREATE EXTENSION` privilege at apply time. On Neon, the runtime user has this by default for ad-hoc extensions in the project's database. If a project policy disallows extensions, fall back to a plain `LOWER(coalesce(...))` BTREE index (slower but functionally correct) and remove the trigram index from migration 003 before applying.

### TOCTOU defence (Codex G2)

`fn_contract_delete` is SECURITY DEFINER. It sets the `app.fn_contract_delete='true'` GUC (transaction-local, auto-cleared on COMMIT/ROLLBACK), takes `SELECT ... FOR UPDATE` on the row, performs the active-children check inside the lock, then flips `is_active`. The companion RESTRICTIVE policy `contract_deny_direct_is_active_update` denies any UPDATE that touches `is_active` unless that GUC is set. **Never** issue a manual `UPDATE contract SET is_active = false ...` from psql or an admin script - it will be denied. Always go through `SELECT fn_contract_delete($1, $2)`.

### Concurrency hardening (migration 008)

Migration 008 adds `SELECT ... FOR UPDATE` locks to the parent contract row (and self row for `fn_contract_update`) before reads. This serialises:

- Concurrent child create/update against parent soft-delete (BE-001).
- Concurrent body updates against each other (BE-002).
- Concurrent tag-set replacements (BE-003).

The locks are **per contract row**, so high-throughput ops on different contracts remain parallel. Cross-row contention is bounded; no global locks introduced.

### Rate-limit middleware test escape hatch

`src/middleware/rate-limit.middleware.ts` has a `if (process.env.NODE_ENV === 'test') return next();` short-circuit so the integration suite (which writes hundreds of contracts) does not trip the per-user write limit. Production remains 60 / min / authenticated user for write endpoints and 120 / min for read endpoints.

---

*Generated by Documentation Generator from M1a workspace + applied migrations 003..008.*

---

# M1b Deployment — Compose Wizard, Payment Schedules & Exports

> **Module:** M1b. **Generated:** 2026-05-03. **Migration head:** 15.

## Migration order (UP)

```bash
# From musanad-contracts-backend/
npm run migrate         # applies pending migrations in numeric order
```

Applied in this exact sequence:

| # | File | Purpose |
|---|---|---|
| 009 | `009_m1b_payment_schedule.sql` | CREATE TABLE `payment_schedule` (17 cols + 7 indexes + audit trigger + ENABLE RLS + 4 policies — 3 PERMISSIVE + 1 RESTRICTIVE deny-direct-DELETE). |
| 010 | `010_m1b_extend_m1a.sql` | **CMW-1:** dynamic `pg_constraint` lookup (W3) + DROP + ADD `contract_activity_activity_type_check` (stable name, 9 values — adds `payment_schedule_replaced`, `exported`). **CMW-2:** INSERT `role_permission` granting `contract.export` to `contract_drafter` (idempotent). |
| 011 | `011_m1b_export_and_payment_functions.sql` | 5 fn_ bodies in dependency order: `fn_audit_log_record` (DEFINER + REVOKE PUBLIC + GRANT neondb_owner), `fn_payment_schedule_list`, `fn_payment_schedule_create_bulk` (SELECT FOR UPDATE on parent), `fn_contract_export_pdf`, `fn_contract_export_xlsx`. |
| 012 | `012_m1b_fix_export_xlsx_tags.sql` | DB Impl patch: fix `text[] <@ varchar[]` operator-resolution failure in `fn_contract_export_xlsx`. Casts `array_agg(t.tag::TEXT)` inside the EXISTS subquery. Required — without 012 every XLSX call returns 500. |
| 013 | `013_m1b_extend_activity_create_whitelist.sql` | Smoke patch: extends `fn_contract_activity_create`'s in-function activity-type whitelist to match the 9-value table CHECK. Without 013, every emission of the new types raises `activityType:Invalid activity type`. |
| 014 | `014_m1b_fix_payment_schedule_rls_with_check.sql` | Codex BE-M1b-006: DROP + recreate `payment_schedule_update_parent_writable` with `WITH CHECK` mirroring USING (excluding `is_active=TRUE`). Closes privilege-escalation via `contract_id` reassignment. |
| 015 | `015_m1b_export_pdf_strip_activity_emit.sql` | Codex BE-M1b-004: `CREATE OR REPLACE` `fn_contract_export_pdf` minus the activity emit. Function is now STABLE; controller emits `contract_activity('exported')` AFTER successful render. |

## Rollback order (DOWN)

Apply rollback markers in **strict reverse order, one migration at a time**:

```bash
npm run migrate:down   # rolls back the most recently applied migration
# then re-run for each preceding migration
```

| Step | Migration to roll back | Effect |
|---|---|---|
| 1 | 015 | Restores activity-emitting variant of `fn_contract_export_pdf` (NOT STABLE). Controller still emits the activity row in addition — DB will receive **two** `exported` rows per export until the controller is rolled back too. **Stop the application server before this step.** |
| 2 | 014 | Restores the original WITH CHECK (TRUE) policy. Re-opens the privilege-escalation surface; do not roll back without compensating controls. |
| 3 | 013 | Restores the 7-value activity-type whitelist in `fn_contract_activity_create`. M1b activity emissions will start raising. |
| 4 | 012 | Restores the broken `text[] <@ varchar[]` query. Every XLSX export will return 500. |
| 5 | 011 | DROPs all 5 fn_'s. The 4 M1b HTTP endpoints will return 500 (no callable function). Stop the application server BEFORE this step. |
| 6 | 010 | Restores anonymous CHECK on `contract_activity` with original 7 values; DELETEs the drafter export grant (CMW-2). Any `payment_schedule_replaced` / `exported` activity rows already written remain — but new emissions of those types will fail the CHECK. **Verify the activity table is clean of those types before rolling back, or expect cascading failures.** |
| 7 | 009 | DROPs `payment_schedule` (with all data) + indexes + RLS + audit trigger binding. The `audit_log` rows for the table remain (M0 design). Idempotent. |

**Disaster-rollback rule:** stop the application server (`npm run dev` / `npm start`) before steps 1, 5, 6 — they invalidate live BE controller bindings.

---

## Puppeteer system libraries (Dockerfile)

M1b adds Puppeteer (headless Chromium) for PDF rendering. Alpine-based image cannot run Puppeteer's bundled Chromium (musl vs glibc), so we install Alpine's system Chromium package + Arabic font support and point Puppeteer at it.

```dockerfile
# Builder + runtime — skip the bundled Chromium download (we use system chromium)
ENV PUPPETEER_SKIP_DOWNLOAD=true

# Runtime stage — system libraries
RUN apk add --no-cache \
      chromium \
      nss \
      freetype \
      freetype-dev \
      harfbuzz \
      ca-certificates \
      ttf-freefont \
      font-noto \
      font-noto-arabic \
      dumb-init

# Point Puppeteer at the system binary
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# dumb-init reaps Chromium child processes on container shutdown
ENTRYPOINT ["dumb-init", "--"]
```

**Image size impact:** approximately +200 MB (chromium + nss + freetype + harfbuzz + Noto Arabic font set). Acceptable for M1b's PDF rendering requirement; alternative is a sidecar Chromium service which the runbook does not currently support.

**Why dumb-init:** Puppeteer launches Chromium as a child process. Without dumb-init, on container SIGTERM the Chromium PID lingers as a zombie, preventing graceful shutdown and risking memory leaks across rolling deploys. dumb-init installs a proper init that reaps children. Verified: `closePuppeteerBrowser()` is awaited from the server.ts graceful-shutdown handler before `telemetry.shutdown()`.

**Fonts:** `font-noto-arabic` is required for the bilingual PDF path (`?language=ar` and `?language=bilingual`). Without it, Arabic glyphs render as tofu boxes in the PDF.

---

## New environment variables (M1b)

Cross-reference `.env.example` lines 80, 83.

| Var | Required | Default | Notes |
|---|---|---|---|
| `PUPPETEER_EXECUTABLE_PATH` | No (optional) | unset (uses bundled Chromium) | Set to `/usr/bin/chromium-browser` in container deployments. Local dev on macOS/Windows can leave unset to use Puppeteer's bundled binary. |
| `PUPPETEER_SKIP_DOWNLOAD` | No | unset | Set to `true` in Dockerfile builds so npm install doesn't download Chromium (we use the system package). |
| `PUPPETEER_MAX_CONCURRENT` | No | `2` | Concurrency cap on the singleton browser pool's `withPage()` semaphore. Hard cap 16. Tune up for higher-throughput PDF rendering — each concurrent page consumes ~30–50 MB headroom. |
| `EXPORT_RATE_LIMIT_PER_MIN` | No | `30` | `exportRateLimiter` middleware applies to BOTH `/export.pdf` and `/export.xlsx`. Per-user, per-minute. Short-circuited to no-op when `NODE_ENV=test`. |

`exportRateLimiter` is necessary because Puppeteer Chromium spin-up costs ~50–100 MB per request (mitigated by the singleton pool but still bounded), and exceljs streaming workbooks can run minutes for large filter sets. Sharing the read budget with regular GET endpoints would let an attacker exhaust resources cheaply.

---

## Health check after deploy (M1b additions)

After applying 009..015, verify the deployment with these checks:

### 1. XLSX export round-trip

```bash
# Login as bootstrap admin (Super Admin holds contract.export per M1a migration 006)
curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@musanad.local","password":"ChangeMe@123"}' \
  | jq -r '.accessToken' > /tmp/at

# Hit the literal export route
curl -sv -H "Authorization: Bearer $(cat /tmp/at)" \
  http://localhost:4000/api/v1/contracts/export.xlsx \
  -o /tmp/contracts.xlsx

# Expected: HTTP/1.1 200, Content-Type:
#   application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
# First 4 bytes of /tmp/contracts.xlsx are the XLSX (ZIP) magic: 50 4B 03 04
file /tmp/contracts.xlsx       # → "Microsoft Excel 2007+"
xxd /tmp/contracts.xlsx | head -1   # First bytes: 50 4b 03 04
```

If the response is 400 with message "Must be a positive integer", the W1 route ordering has regressed — `GET /contracts/export.xlsx` is being captured by `GET /contracts/:id`. Inspect `src/routes/v1/contracts.routes.ts` and ensure the literal route precedes any `:id` matcher.

If the response is 500, check that `fn_contract_export_xlsx` is present (`SELECT proname FROM pg_proc WHERE proname = 'fn_contract_export_xlsx'`) and migration 012 has been applied (`SELECT version FROM schema_migrations WHERE version = 12`).

### 2. PDF export round-trip

```bash
# Pick any active contract id (or create one first)
CONTRACT_ID=1

curl -sv -H "Authorization: Bearer $(cat /tmp/at)" \
  "http://localhost:4000/api/v1/contracts/${CONTRACT_ID}/export.pdf?language=bilingual" \
  -o /tmp/contract.pdf

# Expected: HTTP/1.1 200, Content-Type: application/pdf
# First 4 bytes are %PDF (25 50 44 46)
xxd /tmp/contract.pdf | head -1   # First bytes: 25 50 44 46
```

If the response is 500 with a Puppeteer error in logs, verify the Chromium binary is reachable: `docker exec <container> which chromium-browser` should return `/usr/bin/chromium-browser`. Check the system-libs apk install completed (`apk info -e chromium nss freetype harfbuzz`).

### 3. Puppeteer pool reuse smoke

```bash
# Issue 5 concurrent PDF requests; verify only ONE Chromium process is spawned
for i in {1..5}; do
  curl -s -H "Authorization: Bearer $(cat /tmp/at)" \
    "http://localhost:4000/api/v1/contracts/1/export.pdf?language=en" \
    -o /tmp/c$i.pdf &
done
wait

# In a separate shell: count Chromium processes inside the container
docker exec <container> sh -c 'ps -ef | grep -c "[c]hromium-browser"'
# Expected: a small number (browser + helper procs) — NOT 5.
```

If this surfaces 5+ browser parents, `PUPPETEER_MAX_CONCURRENT` and the pool wiring may have regressed; verify `withPage()` is called (not `puppeteer.launch()`) in `contract-pdf.service.ts`.

### 4. RLS WITH CHECK enforcement (post-014)

```sql
-- As contract_drafter (e.g. user id N) attempt to UPDATE a payment_schedule
-- row to point at another user's contract:
SET LOCAL app.current_user_id = 'N';
UPDATE payment_schedule
   SET contract_id = (SELECT id FROM contract WHERE drafted_by <> N LIMIT 1)
 WHERE contract_id = (SELECT id FROM contract WHERE drafted_by = N LIMIT 1);
-- Expect: ERROR: new row violates row-level security policy for table "payment_schedule"
```

If this UPDATE succeeds, migration 014 has not been applied — verify `SELECT version FROM schema_migrations WHERE version = 14`.

---

## Rate-limit and concurrency tuning

| Concern | Knob | Default | Tuning |
|---|---|---|---|
| Per-user export rate | `EXPORT_RATE_LIMIT_PER_MIN` | 30 | Increase for trusted internal automation; pair with `contract.export` permission scoping. |
| Browser pool concurrency | `PUPPETEER_MAX_CONCURRENT` | 2 | Budget ~30–50 MB headroom per concurrent page. Don't exceed `(RAM-budget - app baseline) / 50MB`. Hard cap 16. |
| XLSX truncation cap | `?maxRows=N` query param | 10000 (default), 50000 (max) | Hard-clamped 1..50000 in fn_; truncation footer + `X-Export-Truncated:true` header emitted when exceeded. |

---

## Sensitive-field redaction (M1b additions)

M1b introduces no new sensitive fields. However, `body_en` / `body_ar` (M1a-defined) reach the BE Puppeteer renderer via `ContractExportPdfHead`. Pino redact paths in `src/utils/logger.util.ts` extended for the export controller request lifecycle: `contract.bodyEn`, `contract.bodyAr`, `rows[*].bodyEn`, `rows[*].bodyAr` (Q5 decision).

Verification at deploy time: `tail -f` the backend pino output, then `curl GET /api/v1/contracts/1/export.pdf` for a contract with non-empty bodies, and grep the log for any substring of the body content — zero matches expected.

---

*Generated by Documentation Generator from M1b workspace + applied migrations 009..015 + Codex review reports.*

---

# M3 Deployment — Signatures + Signer Q&A AI

> **Module:** M3 (sixth module).
> **Generated:** 2026-05-04.
> **Migrations:** 032..039 (6 design + 2 mid-flight patches). Final `schema_migrations.version = 39` on both `test` and `m0-foundation` Neon branches.
> **gate2-decisions.md choices are ratified facts, not options.** AN-1 (SHA-256 token hashing), AN-12 (sliding-window soft-deactivate-oldest at 5+), AN-13 (M3 stops at fully_signed; fully_signed → active is a future contract-lifecycle concern), CC-4 Option A (5 PUBLIC EXECUTE grants).

---

## Migration order (UP)

Apply 032..039 in numerical order. Migrations are idempotent against fresh branches and no-op on already-applied branches.

```bash
# Verify current head
psql "$DATABASE_URL" -c "SELECT MAX(version) FROM schema_migrations;"
# Pre-M3: 31. Post-M3: 39.

# Apply
npm run db:migrate

# Verify tables
psql "$DATABASE_URL" -c "\\dt signature_*"
psql "$DATABASE_URL" -c "\\dt signer_qa_session"
# Expect 6 tables: signature_party, signature_invitation, signature_event,
# signer_qa_session, signature_party_side, signature_method.

# Verify the 5 PUBLIC EXECUTE grants — see "S2-21 candidate check" below.
```

**Important pre-flight on FRESH branches:** migration 035 includes `CREATE EXTENSION IF NOT EXISTS pgcrypto;` as its first statement. M3 is the first module to use `digest()` / `gen_random_bytes()` — pgcrypto is not present by default on Neon branches and was added mid-flight during DB Implementation (DB Impl I-2). Subsequent modules using pgcrypto helpers do NOT need to repeat the CREATE EXTENSION (it's already in M0-foundation lineage post-M3).

---

## New environment variables

| Variable | Default | Required? | Purpose |
|---|---|---|---|
| `SIGNATURE_EXPIRATION_INTERVAL_CRON` | `*/15 * * * *` | No (optional override) | node-cron schedule for `fn_signature_invitation_expire_due`. Driver in `src/services/signature-expiration.cron.service.ts`. |
| `OPENAI_API_KEY` | none | **Yes** in production | Required for the `/sign/:invitationToken/qa/message` SSE endpoint. M0 already declares this; M3 makes it conditional (gracefully fails individual Q&A requests if missing rather than blocking app boot). |
| `OPENAI_MODEL_DEFAULT` | `gpt-4o` | No | Override for AI signer Q&A. M3 uses gpt-4o; AIProvider abstraction is reusable. |

**To DISABLE the signature expiration cron** without disabling other crons: set the env var to a far-future cron pattern (e.g. `'0 0 31 2 *'` — Feb 31, never fires). The cron is automatically disabled in `NODE_ENV=test`.

---

## OpenAI gpt-4o — operational notes

- **Model:** `gpt-4o` (set via `OPENAI_MODEL_DEFAULT`). Rate-limit-tier and per-token cost depend on the API key's plan; check the OpenAI dashboard.
- **Per-call budget:** `max_tokens=200`, `temperature=0.4`, streamed. Short, deterministic-leaning answers for compliance.
- **Per-session cap:** 20 messages / rolling 1-hour window (AC-S12-05).
- **Per-invitation cap:** 50 messages / rolling 1-hour window — sum across sessions.
- **Coarse rate limit (per-IP):** `publicSignerRateLimiter` 60 req/min/IP across the entire `/sign/*` namespace.
- **System prompt:** loaded VERBATIM from `prompts/ai-signer-qa.txt` at request time. Mustache-style `{{placeholder}}` substitution; no auto-escaping. **Do not edit this file in production without coordinating with security review** — it is the only on-disk artefact gating what the model says to a public/unauthenticated audience.
- **No transcript persistence:** `signer_qa_session` stores only counters + last_activity + rate-limit-window. The `userMessage` and AI response NEVER touch durable storage (AN-2 transcriptStorage / DN-11; AC-S12-09). Pino redaction enforces this at the wire level via the `ai_prompt_payload` sensitive-field name.

**Operational alert:** if OpenAI usage costs exceed the plan, the rate limits provide a hard ceiling. Worst case at saturation: 50 messages/h/invitation × ~200 tokens/message ≈ 10K tokens/h/invitation. Tune the per-invitation cap in `fn_signer_qa_session_record_message` (the literal `50` in the rolling-window check) if the cap proves too generous in production telemetry.

---

## Token rotation — invitation tokens

- **TTL:** 14 days from `invitation_sent_at` (`invitation_expires_at = invitation_sent_at + INTERVAL '14 days'`).
- **Expiration:** automatic via `fn_signature_invitation_expire_due` (cron-driven, default `*/15 * * * *`). Sets `status='expired'`, emits an `expired` signature_event, and halts the contract (`status='expired'`) via `fn_contract_status_update_internal` when ALL required signers at the current step are exhausted (AC-S9-03).
- **Manual resend:** `POST /api/v1/signature-parties/:id/resend` issues a fresh token (NOW() + 14 days). The OLD invitation is soft-deactivated and gets a `resent` event with metadata pointing at the new invitation_id.
- **Manual cancel:** `POST /api/v1/signature-invitations/:id/cancel` sets `status='cancelled'`. When this was the last active invitation at the current step, the contract is rolled back to `approved` (drafter must re-send-for-signature).
- **Plaintext token lifecycle:** Generated server-side via `encode(gen_random_bytes(32), 'base64')` (43 base64 chars). The DB persists only `invitation_token_hash` (SHA-256 hex). The plaintext is returned ONCE in the JSONB response on creation, pino-redacted on egress logs. Mailer-bound only — never persisted on the FE side beyond transient component state for a copy-link UX.
- **Session token TTL:** ~1 hour effective (rate-limit window). No hard server-side TTL; session is invalidated by sliding-window deactivation (5+ active sessions on the same invitation).

---

## Audit triggers — gap remediation recommendation

**Issue (DB Impl I-1):** the canonical `fn_audit_trigger` references `NEW.id`. The 2 reference tables (`signature_party_side`, `signature_method`) use a code-PK (`code VARCHAR(20)`) and have no `id` column — attaching the audit trigger raises `42703 column NEW.id does not exist`. Mid-flight fix during the test-branch run: drop the audit trigger from the 2 reference tables.

**Net result:** M3 ships with **4 audit triggers (vs 6 designed)**. The dropped triggers are on admin-modify-only reference tables that rarely change, so the loss of audit coverage is acceptable for v1.

**Recommended remediation as M3 follow-up (one of):**
1. Add `id BIGSERIAL UNIQUE` column to both reference tables and re-add the audit triggers via a small follow-up migration.
2. Modify `fn_audit_trigger` to handle code-PK tables (e.g. fall back to `record_id = NULL` and put the code in `metadata`) — broader scope; affects M0 canonical body.
3. Codify a permanent QA Stage 2 check that audit triggers are only attached to tables with an `id` column (DB Impl F-1).

The recommendation is option (3) — it's the lowest-risk and surfaces this defect at design time across all future modules.

---

## Smoke tests post-deploy

### 1. PUBLIC-grant enumeration check (S2-21 candidate)

Run this query against the deployed database. **Any result other than the exact 5 fn_'s below is a regression — investigate immediately:**

```sql
SELECT proname, array_to_string(proacl, E'\n') AS acl
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND proname LIKE 'fn_%'
  AND EXISTS (SELECT 1 FROM unnest(proacl) acl_item
              WHERE acl_item::text LIKE '=X%');

-- Expected EXACTLY:
--   fn_signature_decline                    | =X/neondb_owner | neondb_owner=X/neondb_owner
--   fn_signature_get_by_invitation_token    | =X/neondb_owner | neondb_owner=X/neondb_owner
--   fn_signature_sign                       | =X/neondb_owner | neondb_owner=X/neondb_owner
--   fn_signer_qa_session_record_message     | =X/neondb_owner | neondb_owner=X/neondb_owner
--   fn_signer_qa_session_start              | =X/neondb_owner | neondb_owner=X/neondb_owner
```

This is the **L21 / S2-21 candidate** (gate2-decisions.md CC-4 follow-up; codified at Stage 4 §M3-1).

### 2. SSE smoke

```bash
INVITATION_TOKEN=...   # captured from a fresh send-for-signature
SESSION_TOKEN=$(curl -s -X POST "http://<HOST>/api/v1/sign/$INVITATION_TOKEN/qa/session" \
  -H 'content-type: application/json' -d '{"language":"en"}' | jq -r '.data.sessionTokenPlaintext')

curl -N -X POST "http://<HOST>/api/v1/sign/$INVITATION_TOKEN/qa/message" \
  -H "x-session-token: $SESSION_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"mode":"GATE","tokensConsumed":0,"userMessage":"What is the cancellation clause?"}' \
  -i | head -20

# Expect:
#   HTTP/1.1 200 OK
#   Content-Type: text/event-stream; charset=utf-8
#   Cache-Control: no-cache, no-transform
#   Connection: keep-alive
#   X-Accel-Buffering: no
#
#   data: {"type":"token","delta":"..."}
#   data: {"type":"token","delta":"..."}
#   ...
#   data: {"type":"done","tokensConsumed":<int>}
```

If the response is `application/json` instead of `text/event-stream`, the GATE call returned a 410/429 BEFORE the header flip — that's expected behaviour, not a bug. Use a fresh, valid session_token to test the streaming path.

### 3. Cron expiration smoke

```sql
-- Find an invitation with a backdated expiry (manually backdate one for the smoke test)
UPDATE signature_invitation
   SET invitation_expires_at = NOW() - INTERVAL '1 day'
 WHERE id = <id_of_test_invitation>;

-- Wait up to SIGNATURE_EXPIRATION_INTERVAL_CRON (default 15 min), then:
SELECT id, status, invitation_expires_at FROM signature_invitation WHERE id = <id>;
-- Expect: status='expired'.

SELECT event_type, actor_user_id FROM signature_event
 WHERE signature_invitation_id = <id> AND event_type='expired';
-- Expect: 1 row, actor_user_id IS NULL (system-actor sentinel).
```

For local quick-test, force the cron to run via `node -e "require('./src/services/signature-expiration.cron.service.ts').runOnce()"` (or invoke `fn_signature_invitation_expire_due` directly with admin pool credentials).

### 4. Pino redaction smoke (token plaintext)

`tail -f` the backend pino output, then `curl POST /api/v1/contracts/:id/send-for-signature`, and grep for the substring of the plaintext invitation token returned in the response — **zero matches expected**. Same check for `sessionTokenPlaintext` after `POST /qa/session`. If a match appears, pino's path-based redaction missed a path — extend `src/utils/logger.util.ts` redact paths.

---

## Rate-limit and concurrency tuning (M3)

| Concern | Knob | Default | Tuning |
|---|---|---|---|
| Per-IP across `/sign/*` | `publicSignerRateLimiter` (in `rate-limit.middleware.ts`) | 60 req/min/IP | Raise if signer landing-page bursts (e.g. multiple browser tabs); per-fn limits in fn_ provide the real ceiling for /qa/message. |
| Per-Q&A-session message cap | hardcoded literal `20` in `fn_signer_qa_session_record_message` | 20 / hour | Increase via DB migration if telemetry shows cap is too low. |
| Per-invitation message cap | hardcoded literal `50` in `fn_signer_qa_session_record_message` | 50 / hour | Increase via DB migration. Caps protect against OpenAI cost runaway. |
| Active sessions per invitation | hardcoded literal `5` in `fn_signer_qa_session_start` | 5 (sliding-window) | Increase if signers commonly switch devices mid-session; decrease if abuse observed. |
| Cron interval | `SIGNATURE_EXPIRATION_INTERVAL_CRON` | `*/15 * * * *` | Tighten to `*/5 * * * *` if expiry latency matters; loosen to hourly to reduce DB load. |

---

## Sensitive-field redaction (M3 additions)

`fn_audit_trigger.v_redact_fields` array final list = **25 names** (M2 029 had 21):

- M3 net-new: `invitation_token_hash`, `session_token_hash`, `signature_data`, `signature_image_url`.
- Already in M2 029 (M3 does NOT redeclare): `signer_email`, `signer_phone`, `signature_image`. (S2-19 byte-for-byte mandate — adding them again would fail the canonical-source diff.)

`logger.util.ts` pino redact paths extended +12 sensitive-field name groups (~80 path entries):
- `invitationToken`, `invitationTokenPlaintext`, `invitation_token`, plus `*.X / *.*.X / req.body.X / req.params.X / req.query.X` permutations.
- `sessionToken`, `sessionTokenPlaintext`, `session_token`, same permutations.
- `req.headers.x-session-token`.
- `signatureData`, `signature_data`.
- `signatureImageUrl`, `signature_image_url`.
- `userMessage`, `req.body.userMessage` (because `ai_prompt_payload` is project-config sensitive — AC-S12-09).

Verification at deploy time: see "Pino redaction smoke" §4 above.

---

*Generated by Documentation Generator from M3 db-design.md, db-implementation-summary.json, be-implementation-summary.json, qa-stage4-report.md, gate2-decisions.md, and applied migrations 032..039.*

---

# M4 Deployment — AI Features

> **Module:** M4 (seventh module — AI Features).
> **Generated:** 2026-05-04.
> **Codex review:** SKIPPED per Dexian decision 2026-05-04.

---

## Migration order (UP)

```bash
# From musanad-contracts-backend/

# Verify current head
npm run migrate:status
# Pre-M4: 39 (M3 final). Post-M4: 45 (5 designed + 1 DEFECT-1 patch).

# Apply against test branch FIRST per memory feedback_validate_runner_on_clean_db.md
TEST_DATABASE_URL=<br-billowing-boat-ajq9m0g6 conn string> npm run migrate:test

# Then apply to m0-foundation
npm run migrate

# Verify tables
psql <m0-foundation conn> -c "\dt ai_*"
# Expect 3 tables: ai_prompt, ai_insight, ai_request_log.

# Verify the 5 PUBLIC EXECUTE grants — see "S2-21 invariant check" below.
```

> **Migration 045 is the DEFECT-1 patch.** It re-issues `CREATE OR REPLACE fn_contract_version_diff_summary_persist` with the UPDATE clause's nonexistent column references removed. The fn signature, GRANT matrix, and JSONB return shape are byte-identical to 043; controllers do not need updates. The migration's rollback block restores 043's broken body for emergency unwind only — DO NOT roll back unless absolutely necessary.

---

## Rollback order (DOWN)

```bash
npm run migrate:down
# Run repeatedly to walk further back; never skip.
```

Rollback chain (045 → 044 → 043 → 042 → 041 → 040): each migration's `-- DOWN` block is self-contained. Order matters because:
- 045 down restores 043's broken body — emergency only.
- 044 down DELETEs the 4 permission rows + 12 role_permission rows + 6 ai_prompt seed rows (cascading FK constraint on ai_insight.prompt_id and ai_request_log.prompt_id will block if any rows reference them — manually clear first).
- 043 down `DROP FUNCTION` for all 12 fn_'s; controllers will return 500 on AI invocation until re-applied.
- 042 down `DROP TABLE` ai_insight, ai_request_log, ai_prompt CASCADE.
- 041 down `CREATE OR REPLACE fn_audit_trigger` restoring M3's 25-name redact list.
- 040 down `CREATE OR REPLACE fn_contract_activity_create` restoring M3's 20-value whitelist + `DROP CONSTRAINT contract_activity_activity_type_check; ADD CONSTRAINT ... CHECK (activity_type IN (... 20 values ...))`.

---

## New environment variables (M4)

| Variable | Default | Required | Purpose |
|---|---|---|---|
| `AI_INSIGHT_EVICTION_INTERVAL_CRON` | `*/15 * * * *` | No | Cron schedule for `fn_ai_insight_evict_expired` sweep. 15 minutes is the default; tune up if cache eviction proves expensive, tune down if expired rows accumulate beyond admin observability tolerance. **Disabled in `NODE_ENV=test`.** |
| `SIGNED_PDF_TOKEN_SECRET` | (none) | **Required for S5 to operate** | HMAC secret (HS256) for signed-PDF-token validation. **If unset at boot, S5 returns 503** (intentional — only S5 is affected). The future PDF-generator pipeline must use the same secret to sign tokens. **Recommend env-validation upgrade** to require this whenever the AI route is mounted (currently optional; QA Stage 4 REC-4). |
| `SIGNED_PDF_TOKEN_ISSUER` | `musanad-contracts-pdf` | No | Expected `iss` claim. Override only if the PDF-generator pipeline uses a different issuer. |
| `SIGNED_PDF_TOKEN_AUDIENCE` | `regulatory-impact-pdf` | No | Expected `aud` claim. |
| `OPENAI_API_KEY` | (none) | Yes (already required by M3) | OpenAI API key. M4 reuses the M0 AIProvider abstraction unchanged. |

> **M4-SMOKE-BE-INFO-1 / REC-4:** `.env.example` is currently missing the M3 `SIGNATURE_EXPIRATION_INTERVAL_CRON` and the M4 `AI_INSIGHT_EVICTION_INTERVAL_CRON` + `SIGNED_PDF_TOKEN_SECRET` + `SIGNED_PDF_TOKEN_ISSUER` + `SIGNED_PDF_TOKEN_AUDIENCE` — recommend adding them with placeholder values and inline comments.

---

## OpenAI gpt-4o + tiktoken — operational notes

| Setting | Value | Notes |
|---|---|---|
| `OPENAI_MODEL_DEFAULT` | `gpt-4o` | Set via env. M4 reuses M0's AIProvider abstraction unchanged. |
| Per-prompt model | `gpt-4o` (4 prompts) + `gpt-4o-mini` (2 prompts) | `ai-executive-anomalies` + `ai-version-diff-summary` use the cheaper model. Configurable via `ai_prompt.default_model` rows; platform_admin can swap by INSERT/UPDATE. |
| Max tokens | per `ai_prompt.default_max_tokens` (1,200..4,000) | Hard cap per AI call. |
| Temperature | per `ai_prompt.default_temperature` (0.30..0.40) | Deterministic-leaning for compliance-related answers. |
| Streaming | per `ai_prompt.supports_streaming` | true for S1 (summary/rewrite), S2 (chat/explain/rewrite), S4 (explain/amendment); false otherwise. |
| Tool-call | per `ai_prompt.supports_tool_call` | Used for S1 (key_terms / risks / obligations / regulatory), S2 (suggest), S3, S5. |
| Abort on disconnect | true | AbortController closed on `res.close` for streaming endpoints. |

**Prompt sources:** 6 files in `[backend]/prompts/` — verbatim from Lovable extraction (G7). ~16 KB total. Read at runtime via `node:fs/promises readFile`, cached in-memory per process. Mustache-style `{{placeholder}}` substitution only — no real templating, no auto-escaping.

**tiktoken estimator (vs M3 `+1` fallback):** M4's `_shared/tiktoken-estimator.ts` provides accurate `tokens_input` and `tokens_output` estimates when streaming OR when the SDK does not surface `usage.total_tokens`. M3 used a `+1` fallback when usage was missing — M4 reconciles SDK terminal usage events with tiktoken estimates and prefers the SDK value when available. Net effect: cost telemetry in `ai_request_log.cost_usd_micros` is significantly more accurate.

---

## Cron driver — `fn_ai_insight_evict_expired`

3rd in-process cron driver in the codebase.

**Wiring:** `src/services/ai-insight-eviction.cron.service.ts` is started in `src/server.ts` `app.listen(...)` and stopped on `SIGTERM` / `SIGINT`. Uses `node-cron` (already a dependency from M2).

**System-actor sentinel (S2-20):** the driver wraps the fn call in `set_config('app.current_user_id', '0', true)` (transaction-local GUC). The fn is `SECURITY DEFINER` + `GRANT EXECUTE TO neondb_owner` — `REVOKE FROM PUBLIC` is explicit. Cron-only.

**Health check:**

```bash
# Check the recently-evicted-rows tail in audit_log
psql <m0-foundation conn> -c "
  SELECT changed_at, record_id, changed_by, new_values->>'is_active' AS new_active
    FROM audit_log
   WHERE table_name = 'ai_insight' AND action = 'UPDATE' AND changed_by = 0
   ORDER BY id DESC LIMIT 20;
"
# Expect rows showing is_active going TRUE -> FALSE with changed_by=0.
# (changed_by=0 because cron sets app.current_user_id='0'; fn_audit_trigger
#  records the value verbatim; coercion to NULL would require fn_audit_trigger
#  also coercing, which is a pending framework decision — see M4-DBI-NOTE-S2-20.)
```

**Tuning:** if eviction sweeps are too aggressive (high write load), increase the interval (`AI_INSIGHT_EVICTION_INTERVAL_CRON`). If expired rows accumulate, lower the interval. Default 15 minutes is balanced for the M4 cache TTL profile (1 h → 30 d).

---

## S2-21 invariant check — PUBLIC EXECUTE allowlist

**M4 contributes 0 net new PUBLIC EXECUTE grants on fn_'s.** Live invariant check (run post-deploy):

```bash
psql <m0-foundation conn> -c "
  SELECT proname FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND proname LIKE 'fn\\_%'
     AND EXISTS (
       SELECT 1 FROM unnest(proacl) acl
        WHERE acl::text LIKE '=X/%'
           OR acl::text LIKE 'public=X/%'
           OR acl::text LIKE 'PUBLIC=X/%')
   ORDER BY proname;
"
```

Expected output (exactly 5 rows; M3 baseline; no M4 additions):

```
proname
-------
fn_signature_decline
fn_signature_get_by_invitation_token
fn_signature_sign
fn_signer_qa_session_record_message
fn_signer_qa_session_start
(5 rows)
```

**Regression guard.** If any future fn_ accidentally gets `GRANT EXECUTE TO PUBLIC` (e.g. via a careless `ALTER ... OWNER TO ...` or a copy-paste GRANT line), this check will fail. Add this check to your post-deploy smoke suite — Stage 4 already runs it as a gate.

> **S2-21 PROMOTION recommended at QA Stage 4** — promote from CANDIDATE to MANDATORY in `feedback_stage2_checks_s2_16_to_s2_20.md` since M3 (introduced 5) + M4 (zero net new) satisfy the two-consecutive-modules criterion.

---

## DEFECT-1 retrospective — column-existence escape

**The escape:** `fn_contract_version_diff_summary_persist` (migration 043) referenced nonexistent columns `updated_at` / `updated_by` on `contract_version`. plpgsql lazy-compiles function bodies, so 043 applied cleanly. DB-Impl Step 4 functional probe only exercised the NOT FOUND branch — the UPDATE was never reached. Smoke test pg_proc-presence check passed. First successful invocation (in `M4-persist-and-admin-fns.test.ts` AC-S6-04) hit `SQLSTATE 42703`.

**The fix (migration 045):** drop the columns from the UPDATE clause; materialise `updatedAt` locally. Signature byte-identical; controller bindings unchanged.

**Operator action:** none — both branches are at v45 post-deployment of M4. The retrospective is documented here for situational awareness.

**Recommended Stage 2 codification (S2-22):**
- Stage 2 design check: for every UPDATE/INSERT clause in any fn_ body, verify EVERY referenced column exists in the active branch's table DDL.
- DB-Impl Step 4 enhancement: functional probe MUST exercise the success path of every UPDATE/INSERT branch — not just error/NOT FOUND paths.

---

## Smoke tests post-deploy

**Login + AI invocation (S1, JWT path):**

```bash
# Get a Super Admin access token (or any user with ai.invoke.contract)
TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@musanad.local","password":"<pwd>"}' \
  | jq -r '.data.tokens.accessToken')

# Pick an active contract id
CONTRACT_ID=<some active contract>

# S1 — non-streaming (mode=key_terms — tool-call JSON)
curl -s -X POST http://localhost:4000/api/v1/ai/contract-insights \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"contractId\":$CONTRACT_ID,\"mode\":\"key_terms\",\"language\":\"en\"}" \
  | jq '{success, dataMode: .data.mode, kt: (.data.payload.keyTerms | length), requestId}'

# Expect: success=true, dataMode='key_terms', kt > 0
```

**S1 streaming (mode=summary — SSE):**

```bash
curl -N -X POST http://localhost:4000/api/v1/ai/contract-insights \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"contractId\":$CONTRACT_ID,\"mode\":\"summary\",\"language\":\"en\"}"
# Expect:
#   HTTP/1.1 200 OK
#   Content-Type: text/event-stream; charset=utf-8
#   X-AI-Cache: HIT|MISS
#
#   data: {"type":"token","delta":"..."}
#   data: {"type":"token","delta":"..."}
#   ...
#   data: {"type":"done","tokensConsumed":<int>,"persisted":{"contractId":...,"updatedAt":"..."}}
```

**S6 (version diff summary — exercises the DEFECT-1 patch path):**

```bash
# Pick two distinct active versions on a contract
LEFT_VID=<left version id>
RIGHT_VID=<right version id>

curl -s -X POST http://localhost:4000/api/v1/ai/version-diff-summary \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"contractId\":$CONTRACT_ID,\"leftVersionId\":$LEFT_VID,\"rightVersionId\":$RIGHT_VID,\"additions\":\"...\",\"deletions\":\"...\",\"modifiedClauses\":[],\"language\":\"en\"}" \
  | jq '{success, persisted, cacheHit, requestId}'

# Expect: success=true, persisted.contractVersionId=$RIGHT_VID, persisted.updatedAt set.
# This exercises the migration-045 patched body — confirms the UPDATE branch
# executes cleanly (no SQLSTATE 42703).
```

**S5 signed-PDF-token endpoint:**

```bash
# Generate a token with the deployed secret (Node REPL)
node -e "
  const jwt = require('jsonwebtoken');
  const t = jwt.sign(
    { jti: 'smoke-' + Date.now() },
    process.env.SIGNED_PDF_TOKEN_SECRET,
    { algorithm: 'HS256', issuer: 'musanad-contracts-pdf', audience: 'regulatory-impact-pdf', expiresIn: '5m' }
  );
  console.log(t);
"
# (export SIGNED_PDF_TOKEN_SECRET=<same-as-be> first)

PDF_TOKEN=<paste token from above>

curl -s -X POST http://localhost:4000/api/v1/ai/regulatory-impact-summary \
  -H "Authorization: Bearer $PDF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"regulator":"DIFC","title":"Test","severity":"medium","contracts":[{"contractNumber":"X-1","title":"T","type":"service"}],"language":"en"}' \
  | jq '{success, executive, cacheHit, requestId}'

# Expect: success=true, executive=<string>, cacheHit=false on first call.
# If 503: SIGNED_PDF_TOKEN_SECRET is unset on the BE — fix the env var and restart.
```

**Admin observability (S11/S12/S13):**

```bash
# S13 — list prompts
curl -s http://localhost:4000/api/v1/admin/ai/prompts -H "Authorization: Bearer $TOKEN" | jq '.data.data | length'
# Expect: 6

# S11 — recent ai_request_log rows
curl -s "http://localhost:4000/api/v1/admin/ai/requests?limit=10" -H "Authorization: Bearer $TOKEN" | jq '.data.pagination'

# S12 — 30-day cost report
curl -s "http://localhost:4000/api/v1/admin/ai/cost-report?fromDate=2026-04-04&toDate=2026-05-04&groupByUser=true" -H "Authorization: Bearer $TOKEN" | jq '.data.data | length'
```

---

## Rate-limit and concurrency tuning (M4)

| Concern | Default | Tuning notes |
|---|---|---|
| Per-user/per-prompt rate limits | per `ai_prompt.rate_limit_per_user_per_hour` and `_per_day` (10..60/h, 40..300/d) | Adjust by UPDATEing the seed rows. Each AI invocation runs `fn_ai_request_log_check_rate_limit` as a pre-flight gate (NOT GATE/COMMIT — DN-4). |
| S5 per-token rate limit | 10/h in-process | **Single-replica only** (BE-IMPL-INFO-2). Switch to Redis-backed bucket when scaling beyond 1 replica. |
| Cache TTL per prompt | per `ai_prompt.default_ttl_seconds` (0..30 d) | Adjust by UPDATEing the seed rows. 0 disables caching. Cron evicts every 15 min by default. |
| Cron sweep batch size | 500 (default in `fn_ai_insight_evict_expired`) | Override via fn parameter `p_batch_size`. |
| Provider timeout | 120 s (streaming) | Set via `AbortController` in service modules. |

---

## Sensitive-field redaction (M4 additions)

DB-layer (migration 041 — `fn_audit_trigger v_redact_fields`):
- `payload` (ai_insight.payload — AI output may contain contract excerpts).
- `error_message` (ai_request_log.error_message — provider error strings may echo prompt fragments).

App-layer (Pino redact in `src/utils/logger.util.ts`):
- `payload` / `errorMessage` / `error_message`
- `signedToken` / `x-signed-pdf-token` (header)
- `selectedText` / `chatHistory` / `draftSummary` (S1 / S2 inputs)
- `additions` / `deletions` / `modifiedClauses` (S6 inputs)
- `summaryEn` (S4 input)
- `ai_prompt_payload` (universal SENSITIVE marker — fully-rendered prompt; never reaches DB)

> **Defence-in-depth rule:** if a payload reaches the DB, it must be in `v_redact_fields` AND in the Pino redact paths. If a payload is controller-only (never reaches DB), Pino redact is sufficient — but adding to `v_redact_fields` is harmless and recommended.

---

*Generated by Documentation Generator from M4 db-implementation-summary.json + be-implementation-summary.json + 045-defect1-patch-summary.md + qa-stage4-report.md. No Codex review run for M4 (Dexian decision 2026-05-04).*

---
---

# M5 Deployment — Regulatory Radar

> **Module:** M5 — Regulatory Radar (eighth module — UAE regulations master library + radar feed + per-contract impact analysis + impact-category taxonomy admin).
> **Generated:** 2026-05-05.
> **Migration window:** 046 → 052 (7 designed) + 053 (M5-PROD-DEFECT-1 patch). `schema_migrations.version=53` on `test` and `m0-foundation`.
> **Codex review:** SKIPPED (Dexian decision 2026-05-04; 4th consecutive validation — pattern fully entrenched).

---

## Migration order (UP)

| # | File | Type | Notes |
|---|---|---|---|
| 046 | `046_m5_regulatory_permissions_and_grants.sql` | SEED | **MANDATORY FIRST.** 3 new permission codes + 12 role_permission grants. Without this, every M5 endpoint 403s. |
| 047 | `047_m5_extend_contract_activity_check_and_whitelist.sql` | EXTEND (atomic) | Pairs `contract_activity.activity_type` CHECK enum 23→25 with `fn_contract_activity_create` body whitelist. Both land in same commit boundary. |
| 048 | `048_m5_regulator_lookup.sql` | CREATE NEW (lookup) | `regulator` lookup + RLS + audit + 9-row seed. |
| 049 | `049_m5_regulatory_tables.sql` | CREATE NEW | 4 tables: regulation, impact_category, regulatory_update, regulatory_impact (G1-reconstituted; nullable regulatory_update_id; COALESCE-sentinel UNIQUE). |
| 050 | `050_m5_regulatory_functions.sql` | CREATE NEW | All 15 `CREATE OR REPLACE FUNCTION` + per-fn EXECUTE GRANT/REVOKE. Zero new PUBLIC EXECUTE grants. |
| 051 | `051_m5_regulatory_rls_policies.sql` | RLS | ~16-20 policies (4-7 per entity). |
| 052 | `052_m5_regulatory_seed.sql` | SEED | 8 default `impact_category` rows. |
| 053 | `053_m5_fix_fn_regulation_update_supersede_pre_check.sql` | PATCH | **M5-PROD-DEFECT-1 patch** — structured-raise FK pre-check on `supersededById` so translatePgError returns 400 (was 422). Codifies S2-23. |

Apply order is strict: 046 must come before 049/050 because the 14 of 15 M5 fn_'s gate on the new permissions via RLS that calls `fn_current_user_has_permission`. 047 (CHECK + body atomic) must come before 050 (so `fn_regulatory_impact_create_bulk` doesn't emit a `regulatory_impact_detected` activity that the CHECK enum rejects). 048 must come before 049 (regulator FK target). 053 patches `fn_regulation_update` and is functionally equivalent to migration 050 + 9-line FK pre-check insertion.

```bash
# Standard runner
npm run migrate:test     # apply to test branch FIRST (memory feedback_validate_runner_on_clean_db.md)
# verify version=53 on test
npm run migrate          # apply to m0-foundation
```

---

## Rollback order (DOWN)

Apply ROLLBACK blocks in reverse: 053 → 052 → 051 → 050 → 049 → 048 → 047 → 046. Each migration ships a `-- ROLLBACK BEGIN / -- ROLLBACK END` block. 053's ROLLBACK restores the 050-original (pre-defect) `fn_regulation_update` body.

> **Cascade-soft-delete caveat (049 ROLLBACK):** dropping `regulatory_impact` after rows have been written is destructive. ROLLBACK assumes a clean test branch.

---

## New environment variables (M5)

**None.** M5 reuses M0..M4 env vars. No new secrets, no new schedule cron expressions, no new external integrations.

---

## Health check after deploy

```bash
# Verify schema_migrations version
psql <m0-foundation conn> -c "SELECT MAX(version) FROM schema_migrations;"
# Expect: 53

# Verify all 5 M5 tables exist
psql <m0-foundation conn> -c "
  SELECT table_name FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('regulator','regulation','impact_category','regulatory_update','regulatory_impact')
   ORDER BY table_name;
"
# Expect 5 rows.

# Verify all 15 M5 fn_'s exist
psql <m0-foundation conn> -c "
  SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND proname LIKE 'fn_regulation%'
      OR proname LIKE 'fn_regulatory_%'
      OR proname LIKE 'fn_impact_category_%'
   ORDER BY proname;
"
# Expect 15 rows.

# Verify the 3 new permissions seeded
psql <m0-foundation conn> -c "
  SELECT code FROM permission
   WHERE code IN ('regulations.read','regulations.manage','config.manage')
   ORDER BY code;
"
# Expect 3 rows.

# Verify regulator lookup seed (9 rows)
psql <m0-foundation conn> -c "SELECT COUNT(*) FROM regulator WHERE is_active = TRUE;"
# Expect: 9

# Verify impact_category seed (8 rows)
psql <m0-foundation conn> -c "SELECT COUNT(*) FROM impact_category WHERE is_active = TRUE;"
# Expect: 8
```

---

## S2-21 invariant check — PUBLIC EXECUTE allowlist (live verified)

**M5 contributes 0 net new PUBLIC EXECUTE grants on fn_'s.** Live invariant check (run post-deploy):

```bash
psql <m0-foundation conn> -c "
  SELECT proname FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND proname LIKE 'fn\\_%'
     AND EXISTS (
       SELECT 1 FROM unnest(proacl) acl
        WHERE acl::text LIKE '=X/%'
           OR acl::text LIKE 'public=X/%'
           OR acl::text LIKE 'PUBLIC=X/%')
   ORDER BY proname;
"
```

Expected output (exactly 5 rows; M3 baseline; 4th consecutive validation):

```
proname
-------
fn_signature_decline
fn_signature_get_by_invitation_token
fn_signature_sign
fn_signer_qa_session_record_message
fn_signer_qa_session_start
(5 rows)
```

S2-21 is MANDATORY (promoted at M4); add this check to your post-deploy smoke suite — Stage 4 already runs it as a gate.

---

## DEFECT-1 retrospective — FK-pre-validation parity

**The escape:** `fn_regulation_update.supersededById` (migration 050) had no structured-raise pre-check on the FK param. When `supersededById` pointed to a non-existent regulation, Postgres raised raw 23503 with no `field:` prefix, BE `translatePgError` STRUCTURED_RAISE_RE branch missed, fell through to fallback 422. Sibling `fn_regulatory_impact_create_bulk` in the SAME migration 050 had the canonical pre-check — DEFECT-1 was a parity miss.

**The fix (migration 053):** 9-line `IF v_new_superseded_by IS NOT NULL THEN PERFORM 1 ... ; IF NOT FOUND THEN RAISE EXCEPTION ... USING ERRCODE = '23503'` block, inserted INSIDE the existing `IF p_patch ? 'supersededById'` branch. `translatePgError` STRUCTURED_RAISE_RE now fires, returns 400 with `{ supersededById: 'Referenced regulation not found' }`. JSONB return shape byte-identical to 050; signature unchanged; controller bindings unchanged.

**Operator action:** none — both branches are at v53 post-deployment.

**Recommended Stage 2 codification (S2-23):** for every fn_ accepting an FK id parameter, Stage 2 design check MUST verify a structured-raise PERFORM/IF NOT FOUND/RAISE 23503 pre-check exists. Codified to MEMORY.md `feedback_stage2_checks_s2_16_to_s2_20.md` post-DEFECT-1.

---

## Bulk-detect endpoint monitoring (POST /regulatory-impacts/bulk-detect)

**The endpoint is potentially long-running** — bulk-create across N contracts can take seconds when N is large (no hard cap; FE typical batch ~50 contracts). Monitoring guidance:

```bash
# Tail recent bulk-detect activity from contract_activity
psql <m0-foundation conn> -c "
  SELECT created_at, contract_id, actor_id, metadata
    FROM contract_activity
   WHERE activity_type = 'regulatory_impact_detected'
   ORDER BY id DESC LIMIT 50;
"
# Each successful per-contract INSERT in the bulk batch emits one row here.
```

```bash
# Monitor bulk-detect call latency from request logs (Pino)
grep '"action":"regulatory_impact_bulk_detect"' /var/log/musanad-be/*.log | jq '
  select(.duration != null) | {ts, duration, createdCount, skippedDuplicateCount, requestId}
' | tail -20
# Each completed call emits an exit log with these fields.
```

**S2-17 atomic gate+commit:** `fn_regulatory_impact_create_bulk` acquires `SELECT FOR UPDATE` on the `regulatory_update` row before the per-contract INSERT loop. **Concurrent bulk-detect runs against the same regulatory_update will serialize**, not deadlock. If you see request-id pairs spending most of their time on `pg_locks` waits against `regulatory_update.id`, this is expected — the second caller is waiting for the first to commit. Tuning options:
- Reduce per-call batch size (FE-side change — more, smaller calls).
- Stagger calls when scripting bulk-detect from automation.

**`impactPayload` size:** the request body can be large (per-contract JSONB payload with EN+AR note + EN+AR summary + impactScore for each contract). Default Express body-parser limit (`100kb`) may be insufficient for batches >50 contracts with detailed AI-generated summaries. If you hit `PayloadTooLargeError`:
- Increase `BODY_PARSER_LIMIT` env var (default 100kb; recommended 1mb for bulk-detect).
- Reduce per-contract summary length.

**Sensitive payload — never log the body.** `impactPayload` is pino-redacted at controller (`ai_prompt_payload` class — M4 precedent). The destructured per-contract values (`impactScore`, `noteEn/Ar`, `summaryEn/Ar`) are NOT in fn_audit_trigger redact list (Q10 NOT EXTEND) and DO appear verbatim in `audit_log` on INSERT — acceptable per Agent 2 sensitiveFields analysis (regulatory impact text is not user PII).

---

## Permission codes added (M5 — 3 new)

| Code | Module | Action | Roles granted |
|---|---|---|---|
| `regulations.read` | regulations | read | Super Admin, platform_admin, legal_counsel, contract_drafter, contract_approver, contract_approver_2, executive |
| `regulations.manage` | regulations | manage | Super Admin, platform_admin, legal_counsel |
| `config.manage` | config | manage | Super Admin, platform_admin |

12 distinct (role, permission_code) pairs total. Super Admin gets all 3 pre-emptively (M1a 006 / M1c 018 / M2 028 / M3 037 / M4 044 / M5 046 lesson). `contract_recipient` is intentionally NOT granted any M5 permission — the lone exception is `GET /impact-categories` (AC-S14-05) which is JWT-only at the route gate.

To revoke a permission post-deploy:
```sql
UPDATE role_permission
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP,
       updated_by = <admin_user_id>
 WHERE role_id = <role>
   AND permission_id = (SELECT id FROM permission WHERE code = '<code>');
```

---

## NO new cron driver (M5)

M5 is event-driven only. The 3 existing crons (M2 approval-escalation, M3 signature-expiration, M4 ai-insight-eviction) remain wired in `server.ts` unchanged.

The `regulatory_impact.created_by` column is NULLABLE for future-cron compatibility (e.g., a future regulatory feed cron that scrapes regulator websites and bulk-creates impacts) but no current path passes a system-actor sentinel. When that 4th cron lands (M6+ candidate), the canonical generalisation point (3-cron threshold crossed by M4) becomes a defensible Phase 2 architectural decision: extract a shared `cron-runner.ts`.

---

## Sensitive-field redaction (M5 additions)

DB-layer (`fn_audit_trigger v_redact_fields`): **NOT EXTENDED** (Q10 NOT EXTEND). `impact_payload` is a fn parameter only, never a column path.

App-layer (Pino redact in `src/utils/logger.util.ts`):
- `impactPayload` / `impact_payload` (full envelope; AI-generated content; `ai_prompt_payload` class per M4 precedent).
- `summaryAr` / `summary_ar` (mirrors M4 `summaryEn` coverage).
- `noteEn` / `note_en` / `noteAr` / `note_ar`.

**Intentional non-redacts:**
- `resolutionNote` — Q8 admin-bounded free text; AC-S13-07 stored verbatim.
- `impactScore` — numeric metric; not user PII.

---

## Smoke tests post-deploy

```bash
# Get a Super Admin / legal_counsel access token
TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@musanad.local","password":"<pwd>"}' \
  | jq -r '.data.tokens.accessToken')

# S1 — list regulations (paginated)
curl -s "http://localhost:4000/api/v1/regulations?limit=5" \
  -H "Authorization: Bearer $TOKEN" | jq '.data.pagination'

# S6 — list regulatory updates
curl -s "http://localhost:4000/api/v1/regulatory-updates?limit=5" \
  -H "Authorization: Bearer $TOKEN" | jq '.data.pagination'

# S14 — list impact categories (no pagination — small ref table)
curl -s http://localhost:4000/api/v1/impact-categories \
  -H "Authorization: Bearer $TOKEN" | jq '.data.data | length'
# Expect: 8 (post-052 seed)

# S4 — exercise the DEFECT-1 patch path (negative — non-existent supersededById)
REG_ID=<existing regulation id>
curl -s -X PATCH "http://localhost:4000/api/v1/regulations/$REG_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"supersededById":99999999}' \
  -w "\nHTTP %{http_code}\n" | jq '.error.code, .error.fields'
# Expect HTTP 400, code "VALIDATION_ERROR", fields {supersededById: ["Referenced regulation not found"]}.
# This exercises the migration-053 patched body — confirms STRUCTURED_RAISE_RE returns 400 (was 422).

# S11 — bulk-detect (smoke; minimal payload)
REG_UPDATE_ID=<existing regulatory_update id>
CONTRACT_ID=<existing contract id>
curl -s -X POST http://localhost:4000/api/v1/regulatory-impacts/bulk-detect \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"regulatoryUpdateId\":$REG_UPDATE_ID,
    \"regulationId\":$REG_ID,
    \"contractIds\":[$CONTRACT_ID],
    \"impactPayload\":{\"$CONTRACT_ID\":{\"impactScore\":50,\"noteEn\":\"smoke\",\"summaryEn\":\"smoke summary\"}}
  }" | jq '{success, createdCount: .data.createdCount, skipped: .data.skippedDuplicateCount}'
# Expect: success=true, createdCount=1, skipped=0 (first call)
# Re-run identical: createdCount=0, skipped=1 (idempotent ON CONFLICT)

# S15 — upsert impact_category (idempotent)
curl -s -X POST http://localhost:4000/api/v1/impact-categories \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key":"smoke_test","nameEn":"Smoke","nameAr":"اختبار"}' \
  | jq '{success, createdOrUpdated: .data.createdOrUpdated}'
# First call: createdOrUpdated="created"
# Re-run: createdOrUpdated="updated"
```

---

## Rate-limit and concurrency tuning (M5)

| Concern | Default | Tuning notes |
|---|---|---|
| Read endpoints | `authedReadRateLimiter` (M0 default) | Reused unchanged. |
| Write endpoints | `authedWriteRateLimiter` (M0 default) | Reused unchanged. |
| Bulk-detect (POST /regulatory-impacts/bulk-detect) | `authedWriteRateLimiter` | Same bucket as other write endpoints; adjust by reducing per-call batch size if a single user runs many bulk-detects in a tight loop. |
| Concurrent bulk-detect against same regulatory_update | Serialized via `SELECT FOR UPDATE` | S2-17 atomic gate+commit. Concurrent callers wait for the first to commit; this is expected, not a bug. |

---

*Generated by Documentation Generator from M5 db-implementation-summary.json + be-implementation-summary.json + 053-defect1-patch-summary.md + qa-stage4-report.json. No Codex review run for M5 (Dexian decision 2026-05-04; 4th consecutive validated).*

---

# M6 Deployment — Dashboards & Reporting

> **Module:** M6 — Dashboards & Reporting (ninth module — 5 role-scoped dashboards + executive overview + AI cost summary + admin health probe).
> **Generated:** 2026-05-05.
> **Migration window:** 054 → 056 (3 designed) + 057 (M6-DB-IMPL-DEFECT-1 patch). `schema_migrations.version=57` on `test` and `m0-foundation`.
> **Codex review:** SKIPPED (Dexian decision 2026-05-04; **6th consecutive validation** — pattern fully entrenched).

---

## Migration order (UP)

| # | File | Type | Notes |
|---|---|---|---|
| 054 | `054_m6_insights_permissions_and_grants.sql` | SEED + RLS POLICY | **MANDATORY FIRST.** 1 new permission code (`insights.executive`) + 3 role_permission grants (Super Admin pre-emptive + platform_admin + executive). PLUS the `schema_migrations_select_admin` permissive SELECT RLS policy (ARCH-NEW-3 option c). Without this migration, `fn_dashboard_executive` 403s universally AND `fn_health_check.db.latestMigration` returns NULL. |
| 055 | `055_m6_dashboard_views.sql` | CREATE NEW | 4 plain VIEWs (`vw_contract_status_summary`, `vw_approval_queue_metrics`, `vw_signature_status_summary`, `vw_regulatory_impact_summary`). All non-materialised (Q3 lock). Idempotent via `CREATE OR REPLACE VIEW`. |
| 056 | `056_m6_dashboard_functions.sql` | CREATE NEW | All 10 `CREATE OR REPLACE FUNCTION` + per-fn EXECUTE GRANT/REVOKE. **Zero new PUBLIC EXECUTE grants** (S2-21 — count stays at 5; 6th consecutive). |
| 057 | `057_m6_fix_fn_dashboard_approver_contract_join.sql` | PATCH | **M6-DB-IMPL-DEFECT-1 patch.** `CREATE OR REPLACE FUNCTION fn_dashboard_approver(INTEGER)` correcting the JOIN-target column drift on `step.contract_id`. New chain: `approval_step JOIN approval_chain JOIN contract`. Signature unchanged; output JSONB shape unchanged. Mirrors M3 038/039 + M4 045 + M5 053 named-fix-migration precedent. |

Apply order is strict: 054 must come before 056 because (a) `fn_dashboard_executive` calls `fn_current_user_has_permission('insights.executive')` — without 054 the permission code doesn't exist; (b) `fn_health_check.db.latestMigration` reads `MAX(schema_migrations.version)` and requires the new RLS SELECT policy from 054 — without it, the deny-all policy returns NULL on the first probe. 055 must come before 056 because `fn_dashboard_admin` and `fn_dashboard_executive` SELECT from `vw_contract_status_summary`, and `fn_dashboard_legal_counsel` SELECTs from `vw_regulatory_impact_summary`. 057 patches `fn_dashboard_approver` and is functionally equivalent to migration 056 + corrected join chain.

```bash
# Standard runner
npm run migrate:test     # apply to test branch FIRST (memory feedback_validate_runner_on_clean_db.md)
# verify version=57 on test
npm run migrate          # apply to m0-foundation
```

---

## Rollback order (DOWN)

Apply ROLLBACK blocks in reverse: 057 → 056 → 055 → 054. Each migration ships a `-- ROLLBACK BEGIN / -- ROLLBACK END` block. 057's ROLLBACK restores the 056-original (pre-defect) `fn_dashboard_approver` body.

> **Permissive-policy caveat (054 ROLLBACK):** dropping `schema_migrations_select_admin` while `fn_health_check` is still in service will start returning `latestMigration=NULL` for admin callers. Coordinate ROLLBACK 054 with ROLLBACK 056 (which removes `fn_health_check`).

---

## New environment variables (M6)

**None.** M6 reuses M0..M5 env vars. No new secrets, no new schedule cron expressions, no new external integrations. M6 is read-only — there is no cron driver to wire.

---

## Health check after deploy

```bash
# Verify schema_migrations version
psql <m0-foundation conn> -c "SELECT MAX(version) FROM schema_migrations;"
# Expect: 57

# Verify all 4 M6 views exist
psql <m0-foundation conn> -c "
  SELECT table_name FROM information_schema.views
   WHERE table_schema = 'public'
     AND table_name IN (
       'vw_contract_status_summary',
       'vw_approval_queue_metrics',
       'vw_signature_status_summary',
       'vw_regulatory_impact_summary'
     )
   ORDER BY table_name;
"
# Expect 4 rows.

# Verify all 10 M6 fn_'s exist
psql <m0-foundation conn> -c "
  SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND proname IN (
       'fn_dashboard_admin',
       'fn_dashboard_drafter',
       'fn_dashboard_approver',
       'fn_dashboard_legal_counsel',
       'fn_dashboard_recipient',
       'fn_dashboard_router',
       'fn_dashboard_executive',
       'fn_dashboard_executive_anomalies_history',
       'fn_dashboard_ai_cost_summary',
       'fn_health_check'
     )
   ORDER BY proname;
"
# Expect 10 rows.

# Verify the 1 new permission seeded
psql <m0-foundation conn> -c "
  SELECT code FROM permission WHERE code = 'insights.executive';
"
# Expect 1 row.

# Verify the 3 role grants seeded
psql <m0-foundation conn> -c "
  SELECT r.name, p.code
    FROM role_permission rp
    JOIN role r ON r.id = rp.role_id
    JOIN permission p ON p.id = rp.permission_id
   WHERE p.code = 'insights.executive'
   ORDER BY r.name;
"
# Expect 3 rows: Super Admin, executive, platform_admin (alphabetical).

# Verify the new RLS SELECT policy exists alongside the pre-existing deny-all (ARCH-NEW-3 option c)
psql <m0-foundation conn> -c "
  SELECT polname, polcmd, polpermissive
    FROM pg_policy
   WHERE polrelid = 'schema_migrations'::regclass
   ORDER BY polname;
"
# Expect 2 rows: schema_migrations_deny_all (cmd='*', permissive='f') AND
#                schema_migrations_select_admin (cmd='r', permissive='t').
```

---

## S2-21 invariant check — PUBLIC EXECUTE allowlist (live verified)

PUBLIC EXECUTE on fn_'s remains at exactly the M3 set of 5 names — **6th consecutive validation** (M2/M3/M4/M5/M6). Run after deploy to verify:

```bash
psql <m0-foundation conn> -c "
  SELECT proname, proacl
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND proname LIKE 'fn_%'
     AND proacl::text LIKE '%=X/%'
   ORDER BY proname;
"
# Expect EXACTLY 5 rows:
#   fn_signature_decline                    (M3)
#   fn_signature_get_by_invitation_token    (M3)
#   fn_signature_sign                       (M3)
#   fn_signer_qa_session_record_message     (M3)
#   fn_signer_qa_session_start              (M3)
```

If the count differs from 5, **fail the deploy** — this is an S2-21 invariant breach. M6 contributes 0 new PUBLIC fn_ grants; any non-M3 fn_ in this list is a security incident.

---

## DEFECT-1 retrospective — JOIN-target column drift

The DB Implementation Agent caught a CRITICAL escape that Stage 2 (round 2 PASS) did not — a JOIN-target column reference that lazy-compiled past `pg_proc` registration and surfaced only on first realistic invocation. Migration 057 patches this — see `dev-handoff.md` M6 Implementation Notes section "DEFECT-1 retrospective + S2-22b codification recommendation" for the full narrative.

**Operational impact:** the patch (057) ships with the deploy bundle. Apply order 054 → 055 → 056 → 057 is strict. After 057, `fn_dashboard_approver` returns the correct contract context for pending approval steps. Re-running migrations idempotently (e.g., `npm run migrate` against an already-current branch) is safe — `CREATE OR REPLACE` semantics + `ON CONFLICT DO NOTHING` for the seed rows.

---

## Smoke tests post-deploy

```bash
# Get an admin access token (Super Admin holds insights.executive + audit.read + ai.observability.read)
ADMIN_TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@musanad.local","password":"<your-pw>"}' | jq -r '.accessToken')

# S6 — dashboard router (no params; returns user's dashboardKey)
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:4000/api/v1/dashboards/router | jq .
# Expect: success=true, data.dashboardKey='admin' (Super Admin), data.userId=1.

# S1 — admin dashboard (default windowDays=30)
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:4000/api/v1/dashboards/admin | jq .data.kpis
# Expect: success=true; kpis with totalContractsActive, totalContractsByStatus map,
# expiring buckets, pendingApprovals, etc.

# S7 — executive dashboard (default windowDays=90)
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:4000/api/v1/dashboards/executive?windowDays=90" | jq .data.kpis
# Expect: success=true; kpis with totalActiveValueAed, contractsByStatus, expiryCliffs,
# topCounterpartiesByValue5, valueDistribution, openRegulatoryImpactsCritical, aiCostUsdWindow.
# aiCostUsdWindow is a number for Super Admin (has ai.observability.read);
# would be null for an executive without that permission.

# S11 — AI cost summary (windowDays 1..90)
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:4000/api/v1/dashboards/ai-cost-summary?windowDays=30" | jq .data
# Expect: success=true; totalCostUsdWindow, totalRequestsWindow, cacheHitRatioOverall (null if 0 requests),
# topPromptsByCost5 (array length <= 5).

# S12 — admin health (no params; admin only)
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:4000/api/v1/admin/health | jq .data
# Expect: success=true; db.{status:'ok', latestMigration:57, currentTimestamp},
# ai.{lastSuccessfulRequestAt, lastFailureAt, estimatedHealthy},
# overall:'ok'|'degraded'|'unhealthy'.
# CRITICAL: db.latestMigration MUST be 57 — if NULL, the schema_migrations_select_admin
# policy is missing or not applied (ARCH-NEW-3 option c regression).

# S3 — approver dashboard (verify post-057 join chain)
APPROVER_TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"<approver-email>","password":"<pw>"}' | jq -r '.accessToken')

curl -s -H "Authorization: Bearer $APPROVER_TOKEN" \
  http://localhost:4000/api/v1/dashboards/approver | jq .data.lists.pendingQueue5
# Expect: array of objects each with stepId, contractId, contractNumber, titleEn,
# requestedAt, hoursWaiting. Empty array if no pending steps.
# This exercises migration 057 — confirms the fn executes cleanly without
# SQLSTATE 42703 column-does-not-exist on step.contract_id.

# Negative — non-admin caller hitting admin dashboard
DRAFTER_TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"<drafter-email>","password":"<pw>"}' | jq -r '.accessToken')

curl -s -i -H "Authorization: Bearer $DRAFTER_TOKEN" \
  http://localhost:4000/api/v1/dashboards/admin | head -1
# Expect HTTP/1.1 403 — drafter lacks platform_admin / Super Admin role gate.
```

---

## Monitoring guidance — dashboard query latency

M6 dashboards are **potentially heavy aggregations**. Each request runs `COUNT(*)` over filtered subsets of `contract`, `approval_step`, `signature_event`, `regulatory_impact`, `audit_log`, plus `fn_ai_request_log_cost_report` for executive / ai-cost-summary endpoints. Although every query has supporting indexes, dashboards that span large date windows (windowDays=365 on operational; AI cost cap=90) can take noticeable time on large datasets.

**Baseline observations on test data (after migration 057):**
- `fn_dashboard_admin` (windowDays=30) — 50..200ms on a sparsely-populated test branch.
- `fn_dashboard_executive` (windowDays=90) — 100..400ms (joins to `vw_contract_status_summary`, `regulatory_impact`, `fn_ai_request_log_cost_report`).
- `fn_dashboard_approver` (windowDays=30) — 50..150ms; includes peer-velocity AVG aggregation.
- `fn_dashboard_legal_counsel` — 80..300ms; `auditSummary` aggregate over `audit_log` is the dominant cost when `audit.read` is granted.
- `fn_dashboard_ai_cost_summary` (windowDays=30) — 30..100ms.
- `fn_health_check` — <50ms (single-row probes).

**Recommended monitoring at production scale:**

```bash
# Tail Pino exit logs for slow dashboard requests (> 500ms)
docker logs musanad-be 2>&1 | grep '"req":{"method":"GET","path":"/api/v1/dashboards' | \
  jq 'select(.duration > 500) | {time: .time, path: .req.path, duration: .duration, requestId: .requestId, userId: .req.user.id}'

# pg_stat_statements top dashboard fn_'s by total_exec_time (aggregated)
psql <prod conn> -c "
  SELECT substring(query for 100), calls, total_exec_time::int AS total_ms, mean_exec_time::int AS mean_ms
    FROM pg_stat_statements
   WHERE query LIKE '%fn_dashboard%' OR query LIKE '%fn_health_check%'
   ORDER BY total_exec_time DESC
   LIMIT 10;
"
```

**If a specific dashboard endpoint becomes a hotspot:**
1. Inspect the underlying view (`vw_*`) — view planner stats via `EXPLAIN ANALYZE` against a representative caller.
2. Verify all expected indexes exist on the source tables (M0..M5 indexes — none are M6-owned).
3. Consider materialising the heaviest view if read latency exceeds the dashboard SLA (currently no defined SLA; use 1s p95 as a soft target). Materialisation requires a refresh schedule (would introduce a 4th cron driver — see Q9 DEFER decision; revisit if needed).
4. The `windowDays` parameter is the operator's lever — narrower windows always run faster; FE clients can default to 30d for operational dashboards and let the user expand explicitly.

---

## Rate-limit and concurrency tuning (M6)

| Concern | Default | Tuning notes |
|---|---|---|
| Dashboard reads (all 9 endpoints under `/dashboards/*`) | `authedReadRateLimiter` (M0 default) | Reused unchanged. M6 added no new limiter buckets. |
| Admin health probe (`/admin/health`) | `authedReadRateLimiter` | Same bucket as other authed reads. The probe is idempotent and safe to call frequently. |
| Custom-range typing (FE) | M6-FE-OI-1 — no debounce on TimeRangeSelector custom input | Each digit triggers refetch; React Query `keepPreviousData` mitigates UX flash. Consider a 300ms debounce (T10) in a future polish pass; out of scope for M6. |
| Concurrent dashboard requests from the same user | No special handling | M6 is read-only; idempotent. React Query dedupes in-flight requests with the same query key. |

---

## Permission codes added (M6 — 1 new)

| Code | Module | Action | Granted to (3 roles) |
|---|---|---|---|
| `insights.executive` | insights | executive (alternate gate path on `fn_dashboard_executive`) | Super Admin, platform_admin, executive |

Cross-module permissions consumed (NOT seeded by M6 — referenced only):
- `audit.read` (M0) — gates `fn_dashboard_legal_counsel.auditSummary` slot. NULL when missing per CRIT-4.
- `ai.observability.read` (M4 044) — gates `fn_dashboard_executive.kpis.aiCostUsdWindow` (NULL when missing) AND `fn_dashboard_ai_cost_summary` entrypoint (defence-in-depth pre-gate at route + fn body).

---

## NO new cron driver (M6)

M6 is event-driven: dashboards compute on demand at request time. The 3 existing crons (M2 approval-escalation, M3 signature-expiration, M4 ai-insight-eviction) remain wired in `server.ts` unchanged. **Verify after deploy that all 3 are still running:**

```bash
docker logs musanad-be 2>&1 | grep -E 'approval-escalation|signature-expiration|ai-insight-eviction' | tail -20
# Expect periodic boot logs + sweep-completed logs from each cron.
```

If a future module needs a 4th cron (e.g., dashboard view materialisation refresh), consider extracting a shared `cron-runner.ts` — the 3-cron threshold is a defensible architectural-decision point per the M5 carry-forward note.

---

*Generated by Documentation Generator from M6 db-implementation-summary.json (incl. DEFECT-1 fix migration 057), be-implementation-summary.json, smoke-test-be-report.json, and qa-stage4-report.json. No Codex review run for M6 (Dexian decision 2026-05-04; **6th consecutive validated**).*

---

# M7 — OSINT Source Framework + Adapter Protocol — Operational notes

> **Module:** M7 (CR-A; CRIP Wave 1 chassis) | **Generated:** 2026-05-09 | **Schema version:** 107

## 1. Cron worker enable flags

M7 introduces two in-process workers, both **default-disabled**. Production deployments MUST set the enable env vars explicitly.

| Worker | Env flag | Default cron | Cadence override | Purpose |
|---|---|---|---|---|
| Source fetch | `SOURCE_FETCH_WORKER_ENABLED=true` | `* * * * *` (every 1 min) | `SOURCE_FETCH_CRON` | Per-source dispatch loop; calls `adapter.fetch(since)` then `fn_osint_signal_upsert` per RawSignal. ALSO registers `LISTEN osint_test_pull` for in-app test-pull dispatch. |
| Source health | `SOURCE_HEALTH_WORKER_ENABLED=true` | `*/5 * * * *` (every 5 min) | `SOURCE_HEALTH_CRON` | Per-source `adapter.health_check()`; updates `source_health` via `fn_source_health_record`; computes `signals_24h` rolling counter. |

**Both no-op in `NODE_ENV=test`.** This is intentional — CI runs the test suite without ticking adapters, which would hit live external endpoints. Test code that needs to exercise the workers does so via direct invocation, not via cron.

**Verify after deploy:**

```bash
docker logs musanad-be 2>&1 | grep -E 'source-fetch|source-health' | tail -20
# Expect periodic boot logs ("source-fetch worker started, cadence=...") + sweep-completed logs from each tick.
```

If you see `worker disabled — skipping startup` lines, the env flag is unset or set to a non-`true` value.

## 2. Neon direct endpoint requirement for LISTEN/NOTIFY (production)

**This is a hard production requirement, not a recommendation.**

The fetch worker registers `LISTEN osint_test_pull` at startup so admin in-app test-pulls (POST `/admin/sources/:id/test-pull` → 202) dispatch within ~10s. Neon's `-pooler` endpoint uses **PgBouncer in transaction pooling mode**, which **drops session-level state at every transaction boundary**. `LISTEN` is session-level state. On a `-pooler` connection, the LISTEN registration is effectively dropped after the next transaction commits, and notifies are silently never delivered.

**Required production setup:**

- Workers (and only workers) connect via the Neon **direct** endpoint — typical hostname pattern: `ep-<project>.<region>.aws.neon.tech` (no `-pooler` suffix).
- Application HTTP request connections continue to use `-pooler` (the pooled endpoint is correct for short-lived request-scoped queries; LISTEN is irrelevant there).

**Concretely** — your DATABASE_URL strategy:

| Connection class | Endpoint | Why |
|---|---|---|
| Express request handler pool (`src/database/client.ts`) | `-pooler` | Short-lived request-scoped queries; benefits from PgBouncer. |
| Worker pool (`src/workers/*.ts`) | **direct** | Maintains LISTEN registration across the worker lifetime. |

If you cannot operate two endpoints, the fall-back is to bypass pg_notify entirely and have the test-pull endpoint short-circuit straight into a queue (Redis / SQS / etc) — but that adds another infrastructure dependency. Direct endpoint is the cheaper path.

**Test environment caveat (F-3):** the test suite uses Neon's `-pooler` endpoint by default (cheaper / faster for transient test branches). The `M7-source-fetch.test.ts` test does NOT exercise pg_notify end-to-end — it exercises `fn_osint_signal_upsert` payload shape and idempotency directly. Production end-to-end LISTEN behaviour is verified post-deploy via the smoke playbook below.

## 3. Source health monitoring playbook

The 5-min health-check worker maintains one row per `(tenant_id, osint_source_id)` in `source_health`. The admin UI at `/app/admin/source-health` and `GET /api/v1/admin/source-health` surface this.

**State priorities (ordered for the FE list view):**

1. `failing` — adapter raised an unhandled error, OR upstream endpoint returned 5xx for ≥3 consecutive ticks
2. `unauthorised` — adapter returned 401/403 (credential rotation needed)
3. `degraded` — adapter returned 4xx/parsed-zero-rows for ≥1 tick within the window, or rate-limit headroom <20%
4. `healthy` — last `health_check()` returned `state=healthy`

**`signals_24h`** — rolling 24h count of signals from the source, computed each tick. Use this to spot-check that a healthy adapter is actually producing rows: if `state=healthy` but `signals_24h=0` for >24h, the adapter is parsing zero rows from a healthy upstream — investigate the parse logic.

**`last_error_message`** — truncated to 500 chars by `fn_source_health_record`. Listed in `project.config.json` sensitiveFields (AE3) AND `fn_audit_trigger` redact list (AE1) so it appears as `[REDACTED]` in logs and audit_log payloads. Surfaced verbatim in the admin UI for the platform_admin operator.

**Audit trigger deliberately OFF on source_health (Q-NEW6 / OQ-6).** 5-min × 8 sources × N tenants = ~2880 audit rows/day from health checks alone — would dominate the audit_log signal-to-noise. The table's own `checked_at + state` columns are its ledger; if compliance demands a state-transition history at pilot, consider adding a separate `source_health_state_change` table at that point.

## 4. Credential rotation playbook

`source_credential.credential_ref` stores **only an indirection** (Q3 + Q6 lock):

- `env:VARNAME` — adapter resolves at dispatch time via `process.env.VARNAME`
- `vault:path` — reserved for forward-compat with CR-I; not implemented in CR-A

Plain-text secrets are rejected by `fn_source_credential_set` (regex-checked + heuristic plain-text reject for free-form ≥20-char strings without an `env:`/`vault:` prefix).

**To rotate a credential:**

1. Generate the new secret upstream (e.g. issue a new oilpriceapi.com API key).
2. Update the env var on the BE host: `COMMODITY_API_KEY=newvalue`. Do NOT update the database — the env var is what's resolved at runtime; `credential_ref` stays `env:COMMODITY_API_KEY`.
3. Rolling restart the BE: `docker restart musanad-be`. Workers re-resolve credentials on first dispatch after restart.
4. Optionally call `POST /api/v1/admin/sources/:id/credential` with `{ credentialKind: 'api_key', credentialRef: 'env:COMMODITY_API_KEY' }` — this updates `last_rotated_at` so the admin UI shows the rotation timestamp. The credentialRef itself is unchanged (still indirection); the call is purely to bump the audit trail.
5. Test-pull the source via `POST /api/v1/admin/sources/:id/test-pull` and verify `source_health.state=healthy` after the next 5-min tick.

**`credential_ref` redaction is defence-in-depth across 3 layers:**

- DB layer: `fn_audit_trigger.v_redact_fields` includes `credential_ref` (migration 102; redact list 27 → 30 names)
- Pino layer: `src/utils/logger.util.ts` redact paths include `credentialRef`, `credential_ref` (request body, response body, error context)
- Application layer: `fn_source_credential_set` returns `{ id, credentialKind, lastRotatedAt }` only — credentialRef NEVER in the response (AC-S3-04 invariant verified by integration test absence-grep)

## 5. Source decommissioning playbook

`DELETE /api/v1/admin/sources/:id` (calling `fn_osint_source_delete`) is a **soft-delete**:

- `osint_source.is_active=false` AND `osint_source.enabled=false` set in a single UPDATE
- The fetch worker's source-list query filters on `is_active=true AND enabled=true`, so the source is no longer dispatched
- Existing `osint_signal` rows referencing the source via `osint_source_id` **remain queryable** (AC-S3-07 — Annex B.7.3 source decommissioning rule)
- The credential row in `source_credential` is left intact; cascade-delete the source row only if you want a hard purge of associated credential metadata

**To re-activate a decommissioned source:**

```sql
SET LOCAL app.current_user_id = '<platform_admin user id>';
SET LOCAL app.current_tenant_id = '00000000-0000-0000-0000-000000000001';
UPDATE osint_source
   SET is_active = TRUE, enabled = TRUE, updated_at = now()
 WHERE id = <source_id> AND tenant_id = '00000000-0000-0000-0000-000000000001';
```

The admin UI does not currently expose a re-activate button; surface this via SQL until a future module needs it.

## 6. PUBLIC EXECUTE invariant — S2-21 sustained at the M3 set of 5

M7 contributes **0 net-new PUBLIC EXECUTE grants**. The full allowlist remains exactly 5:

```
fn_signature_get_by_invitation_token, fn_signature_sign,
fn_signature_decline, fn_signer_qa_session_start,
fn_signer_qa_session_record_message
```

All 12 M7 fn_'s are owner-only — 10 with explicit `GRANT EXECUTE ... TO neondb_owner`; 2 DEFINER system-only (`fn_osint_signal_upsert`, `fn_source_health_record`) with `REVOKE FROM PUBLIC` only and **no role grant** (only the owner role neondb_owner can EXECUTE — these are invoked from the worker pool connection). **Verify post-deploy:**

```sql
-- Expect exactly 5 rows, all from M3.
SELECT n.nspname || '.' || p.proname AS fn,
       pg_catalog.pg_get_userbyid(unnest(p.proacl)::aclitem) AS grantee
  FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
 WHERE n.nspname = 'public' AND p.proname LIKE 'fn_%' AND p.proacl::text LIKE '%PUBLIC%';
```

## 7. Migration 102 — fn_audit_trigger CREATE OR REPLACE

Migration 102 extends `fn_audit_trigger.v_redact_fields` from 27 → 30 names (adds `credential_ref`, `raw_payload`, `last_error_message`). Per `feedback_fn_rewrites_lose_safety_guards.md`, `CREATE OR REPLACE FUNCTION` silently drops EXECUTE grants — the migration explicitly re-applies the trio:

```sql
COMMENT ON FUNCTION fn_audit_trigger() IS '...';
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;
```

**Stage 2 round 1 caught this** — the original design omitted the trio; it was patched in 3 SQL lines before DB Implementation ran.

---

*Generated 2026-05-09 by Documentation Generator from M7 db-implementation-summary.json (8 migrations applied 100..107; 0 impl-time patches; PUBLIC count baseline-5 preserved), be-implementation-summary.json (2 workers + 8 adapters), smoke-test-be-report.md (DEF-1 + DEF-2 fixed in flight), and qa-stage4-report.md (PASS first-run). No Codex review for M7 (Dexian decision 2026-05-04; **seventh consecutive validated**).*

---

# M8 — Internal Signal Data Path — Operational notes

> **Module:** M8 (CR-A2; CRIP Wave 1 follow-up to M7) | **Generated:** 2026-05-10 | **Schema version:** 113

## 1. Demo harness — `POST /api/v1/admin/internal-signals`

The internal-signal ingest endpoint is the **system-only debug harness** for this module — there is no FE form for it in CR-A2 (brief explicit: ingest UI deferred to CR-G dashboards). Admins drive it directly via the JWT debug route during demos and incident reproduction.

**Permission requirement.** The caller's JWT must carry `internal_signal.ingest`. Granted in v1 to **Super Admin + platform_admin only** — defence-in-depth at fn body line 1 raises 42501 if missing.

**System-only marker.** `fn_internal_signal_ingest` is `SECURITY DEFINER` with `REVOKE EXECUTE FROM PUBLIC` and **no role grant**. Only the `neondb_owner` pool connection invokes; the route handler runs as the platform_admin connection user which inherits OWNER capabilities. Mirrors M7 `fn_osint_signal_upsert` (system-only marker).

**Tenant scoping** is automatic via `app.current_tenant_id` GUC (rls.middleware sets it from JWT `tenantId` claim with hard-coded ADNOC UUID fallback per Q-DA4 from M7 — single-tenant demo posture; multi-tenant JWT claim wiring deferred to CR-C). **Caller never passes `tenantId`.**

**Idempotency.** Globally idempotent on `UNIQUE(tenant_id, dedup_hash)`. Dedup hash basis (deterministic SHA-256, AC-S7-01):

```
source_id || '|' || signal_type || '|' || COALESCE(contract_id::text, vendor_id::text, '') || '|' || observed_at_iso
```

Same payload posted twice yields `{ inserted: false, dedupHashHit: true }` with the same `signalId` — **201 in both cases (NOT 409)**, per AC-S2-02 + the M7 `fn_osint_signal_upsert` contract.

**Example — milestone_slippage (the EPC SLA hero scenario):**

```bash
TOKEN=$(curl -s http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@musanad.local","password":"<pwd>"}' | jq -r .data.accessToken)

curl -s -X POST http://localhost:4000/api/v1/admin/internal-signals \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "signalType": "milestone_slippage",
    "contractId": <epc_demo_contract_id>,
    "milestoneRef": "M-2026-Q2",
    "observedAt": "2026-04-15T10:00:00Z"
  }' | jq

# Response: { success: true, data: { signalId: 587314, inserted: true,
#   dedupHashHit: false, signalKindSubtype: "milestone_slippage" }, requestId: "..." }
```

**Required-field enforcement** is per the catalogue row's `parameter_schema.required[]`:

| signalType | Required keys (beyond signalType + observedAt) |
|---|---|
| `milestone_slippage` | `contractId`, `milestoneRef` |
| `sla_breach` | `contractId` |
| `payment_delay` | `contractId`, `invoiceRef`, `daysOverdue` |
| `invoice_dispute` | `contractId`, `invoiceRef` |
| `vendor_incident` | `vendorId` |
| `ics_incident` | (none) |
| `icv_status_change` | `vendorId` |
| `certificate_expiry` | (none) |

Severity override is OPTIONAL — `fn_internal_signal_ingest` defaults to the catalogue row's `defaultSeverity` if `severity` is omitted.

## 2. Resolution endpoint — `POST /api/v1/internal-signals/:id/resolve`

The resolution endpoint is the **single canonical resolution path** in v1 (Q-DA4 lock = ALWAYS-MANUAL). Auto-resolution is deferred to pilot (couples CR-A2 timing to CR-E rule engine landing).

**Permission requirement.** `internal_signal.resolve` AND a per-signal_type role allowlist (Q-DA3 hardcoded mapping in fn body). Super Admin + platform_admin always allowed across all 8 subtypes.

**Idempotency.** Re-resolve of an already-resolved signal returns the existing `{ signalId, resolvedAt, resolvedBy }` values unchanged AND **skips the pg_notify emission** (AC-S5-03; the fn detects this via `metadata->>'resolvedAt' IS NOT NULL`).

**`pg_notify('internal_signal_resolved')` emission.** First-resolve only. Payload `{ signalId, tenantId, signalKindSubtype, resolutionKind, resolvedBy, resolvedAt }`. CR-E rule engine LISTENs for downstream re-evaluation (future module).

**Production-direct-endpoint requirement** carries over from M7 F-3 — worker connections that subscribe to `internal_signal_resolved` MUST use Neon **direct** endpoint, not `-pooler`. PgBouncer transaction pooling drops session-level LISTEN. See ops-runbook M7 section 2.

**Example — resolve a milestone_slippage signal:**

```bash
curl -s -X POST http://localhost:4000/api/v1/internal-signals/587314/resolve \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "resolutionKind": "cleared",
    "resolutionNote": "Milestone M-2026-Q2 delivered on 2026-04-20."
  }' | jq

# First call:
# { success: true, data: { signalId: 587314, idempotent: false,
#   resolvedAt: "2026-05-09T23:35:10.611855+00:00", resolvedBy: 1,
#   resolutionKind: "cleared" }, requestId: "..." }

# Second call (idempotent re-resolve):
# { success: true, data: { signalId: 587314, idempotent: true,
#   resolvedAt: "2026-05-09T23:35:10.611855+00:00", resolvedBy: 1,
#   resolutionKind: "cleared" }, requestId: "..." }
# Note: same resolvedAt timestamp confirms idempotence path.
```

**Per-signal_type role allowlist (Q-DA3 hardcoded):**

| signal_type | Required role(s) (in addition to Super Admin + platform_admin always-allowed) |
|---|---|
| milestone_slippage / sla_breach | operations |
| payment_delay / invoice_dispute | finance_treasury |
| vendor_incident / ics_incident | operations OR procurement |
| icv_status_change | compliance_esg OR procurement |
| certificate_expiry | compliance_esg OR legal_counsel |

The 4 deferred CR-G persona roles (`operations`, `finance_treasury`, `procurement`, `compliance_esg`) are referenced in the CASE but absent from the role table in v1 — the EXISTS subquery returns FALSE for any caller carrying those role names today (admin-only resolution in v1).

## 3. EPC SLA hero scenario — production-like demo invariant

Migration 112(c) seeds a deterministic EPC scenario for demos. The scenario centres on:

- **EPC Pipeline Contractors LLC** — counterparty seeded with `party_type='company'`, `is_seed=TRUE`, `trade_license_number='EPC-CRA2-DEMO-001'`. Idempotent SELECT-then-INSERT-with-ON-CONFLICT on the trade_license_number unique key.
- **Contract `CRA2-EPC-2026-001`** — master_services contract at 4.5M AED, `counterparty_id=<v_counterparty_id>`. Idempotent on the `contract_number` UNIQUE key.
- **10 internal signals** seeded via 10 PERFORMs of `fn_internal_signal_ingest` against this counterparty + contract: 4 milestone_slippage + 2 sla_breach + 2 payment_delay + 2 icv_status_change.

**The hero invariant — `count_in_180_days >= 3` (AT-2 / AC-S3-01).** The 4 milestone_slippage rows are back-dated via `now() - interval 'N days'` with N values 30/60/120/170 (Q-DA5 RELATIVE lock). All 4 fall within the trailing 180-day window. **Verify post-deploy:**

```sql
SELECT count(*)
  FROM osint_signal s
  JOIN contract c ON c.contract_number = 'CRA2-EPC-2026-001'
 WHERE s.kind = 'internal'
   AND s.signal_kind_subtype = 'milestone_slippage'
   AND (s.raw_payload->>'contractId')::bigint = c.id
   AND s.fetched_at > now() - interval '180 days';
-- Expect: 4 (probe 3 of the DB Impl runtime probes — passes on both branches at schema_migrations.version=113)
```

**Why RELATIVE back-dating?** Absolute timestamps decay; the demo would silently break after the 180-day window passes. RELATIVE keeps the invariant TRUE forever and the demo always fresh on every redeploy.

**Demo-walk preflight checklist:**

1. `schema_migrations.version >= 113` on both branches.
2. `SELECT count(*) FROM internal_signal_kind WHERE tenant_id = '00000000-0000-0000-0000-000000000001';` returns 8.
3. `SELECT count(*) FROM osint_signal WHERE source_id = 'internal:harness';` returns 10 (or higher if demos ingested more during the session).
4. `SELECT count(*) FROM osint_signal WHERE signal_kind_subtype = 'milestone_slippage' AND fetched_at > now() - interval '180 days';` returns >= 4.
5. POST `/api/v1/admin/internal-signals` with the milestone_slippage payload → 201 with `inserted=true`.
6. POST the same payload again → 201 with `inserted=false, dedupHashHit=true` and the same `signalId`.
7. POST `/api/v1/internal-signals/<signalId>/resolve` with `{resolutionKind:"cleared"}` → 200 with `idempotent=false`.
8. Re-POST the same → 200 with `idempotent=true` and the same `resolvedAt` timestamp.
9. GET `/api/v1/internal-signals?signalType=milestone_slippage&since=<180d ago>` returns the 4 EPC seed rows + any demo-added rows.

## 4. Migration 113 patch context — the user_role junction table that doesn't exist

**Background.** The original `fn_internal_signal_resolve` shipped in migration 111 referenced a `user_role` junction table in its Q-DA3 hardcoded role-allowlist EXISTS subquery:

```sql
-- BROKEN (migration 111, lines ~245):
WHERE EXISTS (
  SELECT 1 FROM user_role ur
  JOIN role r ON r.id = ur.role_id
  WHERE ur.user_id = p_actor_id
    AND ur.is_active = TRUE
    AND r.name IN (...)
)
```

**The Musanad schema does not have `user_role`.** The schema is single-role-per-user via `"user".role_id BIGINT REFERENCES role(id)` (M0 migration 001 line 117). Smoke BE caught the bug at HTTP layer:

```
T8: POST /api/v1/internal-signals/587314/resolve → 500 INTERNAL_ERROR
    fn_internal_signal_resolve: relation "user_role" does not exist
```

Blocked AC-S5-01..S5-04 + AC-S8-04 (pg_notify never reached).

**Migration 113 fix.** Surgical `CREATE OR REPLACE FUNCTION fn_internal_signal_resolve` with the join swapped:

```sql
-- FIXED (migration 113):
WHERE EXISTS (
  SELECT 1 FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id
    AND u.is_active = TRUE
    AND r.name IN (...)
)
```

Q-DA3 per-signal_type role-name CASE/fallback list preserved verbatim. Standard tail block (`COMMENT ON FUNCTION` + `REVOKE EXECUTE FROM PUBLIC` + `GRANT EXECUTE TO neondb_owner`) re-applied per `feedback_fn_rewrites_lose_safety_guards.md` (B14) — `CREATE OR REPLACE FUNCTION` silently drops EXECUTE grants without explicit re-application.

**Verification post-113 (5 runtime probes per branch — all PASS):**

1. `proacl` clean (`{neondb_owner=X/neondb_owner}`; no `=X/` PUBLIC entry)
2. First call: `idempotent=false`, returns `signalId / resolvedAt / resolvedBy / resolutionKind`
3. Second call (same body): `idempotent=true`, **same resolvedAt timestamp**
4. metadata contains all 4 keys: `{ resolvedAt, resolvedBy, resolutionKind, resolutionNote }`
5. `schema_migrations.version=113` recorded

**Codification candidate S2-22c.** This is the project's first **TABLE-existence** miss within fn JOIN bodies. Agent 4 + QA Stage 2's S2-22b focused on column-existence within already-validated FROM/JOIN paths, not on whether the target relations themselves exist. Agent 6's apply-time runtime probes did not exercise the resolve fn (only count + ingest paths); Smoke caught it. **Lesson:** extend column-existence check to include FROM/JOIN-target TABLE-existence verification across every fn body, AND apply-time runtime probes for write fn_'s should include at least one happy-path execution against seed data, not just COUNT/structural queries.

## 5. PUBLIC EXECUTE invariant — S2-21 sustained at the M3 set of 5 (eighth consecutive)

M8 contributes **0 net-new PUBLIC EXECUTE grants**. The full allowlist remains exactly 5 (all from M3). All 4 M8 fn_'s end with the explicit `REVOKE FROM PUBLIC` trio per migrations 111 + 113.

```sql
-- Expect exactly 5 rows, all from M3.
SELECT n.nspname || '.' || p.proname AS fn,
       pg_catalog.pg_get_userbyid(unnest(p.proacl)::aclitem) AS grantee
  FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
 WHERE n.nspname = 'public' AND p.proname LIKE 'fn_%' AND p.proacl::text LIKE '%PUBLIC%';
```

---

*Generated 2026-05-10 by Documentation Generator from M8 db-implementation-summary.json (5 migrations applied 109..113; 1 patch round 113 — surgical fn_internal_signal_resolve user_role-junction-lookup fix; PUBLIC count baseline-5 preserved; 12 runtime probes PASS on both branches), be-implementation-summary.json (8 new files + 1 modified; 4 endpoints; tsc clean), smoke-be-report.md (M8-DBI-003 caught at T8/T9 → 500 → fixed via migration 113 → reconfirmed PASS), and qa-stage4-report.md (51/52 + F4 WARN; PASS-WITH-WARNINGS). No Codex review for M8 (Dexian decision 2026-05-04; **eighth consecutive validated**).*
