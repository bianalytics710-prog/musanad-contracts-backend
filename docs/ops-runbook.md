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
