# musanad-contracts-backend

Backend API for **Musanad Contracts Hub** — Express + TypeScript on PostgreSQL (Neon).
Database-objects-first architecture: all business logic lives in PostgreSQL `fn_*`
functions; controllers are thin HTTP passthroughs.

## Stack

| Layer | Choice |
|---|---|
| Runtime | Node.js 20+ |
| Framework | Express 4 |
| Language | TypeScript (strict) |
| Database | PostgreSQL 14 (Neon) |
| Driver | `pg` (native pool) |
| Auth | JWT (access 15m + refresh 7d) |
| Validation | Zod (`.strict()` on incoming DTOs) |
| Logging | Pino (with sensitive-field redaction) |
| Tracing | OpenTelemetry (auto-instrumentation) |
| Tests | Vitest + Supertest |

## Quick start

```bash
# 1. Install
npm install

# 2. Copy env template (only required once)
cp .env.example .env.local
# .env.local already has Neon DATABASE_URL + OPENAI_API_KEY for the m0-foundation branch.

# 3. (Optional) Mailpit local SMTP catcher for the Nodemailer transport:
docker run -d -p 1025:1025 -p 8025:8025 axllent/mailpit
# UI at http://localhost:8025

# 4. Migrations are already applied to Neon m0-foundation branch.
#    To re-run on a fresh branch:
npm run migrate

# 5. Dev server
npm run dev
```

### Health check

```
curl http://localhost:4000/api/health
# { "status": "ok", "uptime": 0.123, "version": "0.1.0", "timestamp": "..." }
```

### Bootstrap admin

```
email:    admin@musanad.local
password: ChangeMe@123
```

Rotate on first login (see Lovable handoff doc).

## Scripts

| Script | What it does |
|---|---|
| `npm run dev` | Watch mode via `tsx` |
| `npm run build` | TypeScript compile (`--max-old-space-size=512`). If OOM, use `npm run build:fallback` (`1024`). |
| `npm run typecheck` | `tsc --noEmit` (`512`). Fallback: `npm run typecheck:fallback`. |
| `npm start` | Runs compiled `dist/server.js` |
| `npm run lint` | ESLint over `src/**/*.ts` |
| `npm run format` | Prettier write |
| `npm test` | Vitest run (4 GB heap) |
| `npm run test:coverage` | Vitest with coverage |
| `npm run migrate` | Apply pending migrations |
| `npm run migrate:down` | Roll back the most recent migration (uses `-- ROLLBACK BEGIN`/`END` markers) |

## Memory note

Per the Lovable Modernization framework CLAUDE.md §9, `tsc` runs with
`--max-old-space-size=512`; if the build OOMs on a small VM, fall back to
`npm run build:fallback` (1 GB). Tests run with `NODE_OPTIONS=--max-old-space-size=4096`.

## Project layout

```
src/
├── server.ts              # Express app, middleware stack, graceful shutdown
├── routes/
│   ├── index.ts           # mounts /api/v1 + /api/health
│   └── v1/
│       ├── index.ts       # registers all v1 routers
│       ├── auth.routes.ts
│       ├── user.routes.ts
│       ├── role.routes.ts
│       └── permission.routes.ts
├── controllers/           # one file per entity, one db.callFunction() per method
├── middleware/            # correlation, auth, error, validation, rate-limit, rls
├── schemas/               # Zod schemas (validates incoming bodies, params, queries)
├── utils/                 # logger, telemetry, jwt, password, errors, env-validation
├── database/
│   ├── config.ts          # pg Pool config from DATABASE_URL
│   ├── client.ts          # callFunction(), executeInTransaction(), healthCheck()
│   └── migrate.ts         # reads schema_migrations, runs pending migrations
├── integrations/
│   ├── ai/                # AIProvider abstraction (OpenAI primary, Anthropic stub)
│   ├── mail/              # Nodemailer transport + bilingual EN/AR template support
│   └── uae-pass/          # Mock provider (default) + live stub w/ TODO markers
└── types/                 # api.types.ts (copy of workspace types.ts) + express.d.ts

tests/
├── unit/                  # jwt, password
├── integration/           # health, auth login/refresh/logout
└── helpers/               # test-db, test-auth helpers
```

## Critical rules

1. **No raw SQL in controllers.** Every DB interaction goes through
   `database/client.ts` `callFunction()`.
2. **JWT verification validates `aud`, `iss`, and `exp` on every call.**
3. **`SET LOCAL app.current_user_id`** is set before every authenticated DB call
   (see `src/middleware/rls.middleware.ts` and `database/client.ts`).
4. **bcrypt cost = 12** (matches DB-seeded admin hash).
5. **Sensitive fields never logged.** Pino redact paths cover all 17+ project
   sensitive fields plus `passwordHash`/`tokenHash`.
6. **No `any` type anywhere.** Strict TypeScript.

## Environment variables

See `.env.example` for the full list (29 vars). Values in `.env.local` (gitignored).
The startup env-validation utility fails fast if any required var is missing.

## License

UNLICENSED — Musanad Technologies FZ-LLC.
