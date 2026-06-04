/**
 * Startup environment-variable validation. Fails fast if any required var
 * is missing — process.exit(1). Called as the first non-import line of
 * server.ts (before logger, before pool).
 *
 * Required vars are sourced from project.config.json envVars.backend (29).
 * A subset is OPTIONAL_FOR_LOCAL (provider stubs that don't apply to dev).
 */
import { z } from 'zod';

/**
 * Strict schema for all REQUIRED env vars at runtime.
 * Vars that are conditionally optional (e.g., OPENAI_API_KEY only when
 * AI_PROVIDER=openai) are validated post-parse below.
 */
const envSchema = z.object({
  // Server
  NODE_ENV: z.enum(['development', 'test', 'staging', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(4000),
  LOG_LEVEL: z
    .enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'])
    .default('info'),

  // Database
  DATABASE_URL: z.string().min(1, 'DATABASE_URL is required'),
  DATABASE_POOL_MAX: z.coerce.number().int().positive().default(20),

  // JWT (CLAUDE.md §8 — aud, iss, exp validated on every verify)
  JWT_SECRET: z
    .string()
    .min(32, 'JWT_SECRET must be at least 32 characters'),
  JWT_AUDIENCE: z.string().min(1),
  JWT_ISSUER: z.string().min(1),
  JWT_ACCESS_TTL: z.string().min(1).default('15m'),
  JWT_REFRESH_TTL: z.string().min(1).default('7d'),

  // AI provider (G7)
  AI_PROVIDER: z.enum(['openai', 'anthropic']).default('openai'),
  OPENAI_API_KEY: z.string().optional(),
  OPENAI_MODEL_DEFAULT: z.string().default('gpt-4o'),
  OPENAI_MODEL_FAST: z.string().default('gpt-4o-mini'),
  ANTHROPIC_API_KEY: z.string().optional(),
  ANTHROPIC_MODEL_DEFAULT: z.string().optional(),
  ANTHROPIC_MODEL_FAST: z.string().optional(),

  // SMTP / mailer (G4)
  SMTP_HOST: z.string().min(1),
  SMTP_PORT: z.coerce.number().int().positive(),
  SMTP_USER: z.string().optional().default(''),
  SMTP_PASS: z.string().optional().default(''),
  SMTP_FROM_NAME: z.string().min(1),
  SMTP_FROM_EMAIL: z.string().email(),

  // UAE Pass (G3)
  UAE_PASS_PROVIDER: z.enum(['mock', 'live']).default('mock'),
  UAE_PASS_REDIRECT_URI: z.string().url(),
  UAE_PASS_CLIENT_ID: z.string().optional(),
  UAE_PASS_CLIENT_SECRET: z.string().optional(),
  UAE_PASS_AUTHORIZE_URL: z.string().optional(),
  UAE_PASS_TOKEN_URL: z.string().optional(),
  UAE_PASS_USERINFO_URL: z.string().optional(),

  // Storage (Supabase transitional)
  SUPABASE_URL: z.string().optional(),
  SUPABASE_ANON_KEY: z.string().optional(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),
  SUPABASE_STORAGE_BUCKET: z.string().default('contracts'),

  // Frontend integration
  CORS_ORIGIN: z.string().min(1),
  REQUEST_ID_HEADER: z.string().default('X-Request-ID'),

  // Auth lockout (loaded from project.config.json, but env-overridable)
  AUTH_MAX_FAILED_ATTEMPTS: z.coerce.number().int().min(1).default(5),
  AUTH_LOCKOUT_MINUTES: z.coerce.number().int().min(1).default(15),

  // Service identity (used by Pino + OTel)
  SERVICE_NAME: z.string().default('musanad-contracts-backend'),

  // OpenTelemetry (optional — stub if not set)
  OTEL_EXPORTER_OTLP_ENDPOINT: z.string().optional(),
  OTEL_SERVICE_NAME: z.string().optional(),

  // M2 — Approval escalation cron (S9). Default '*/15 * * * *' (every 15
  // minutes). Disabled in NODE_ENV=test (smoke harness short-circuit).
  APPROVAL_ESCALATION_INTERVAL_CRON: z.string().min(1).default('*/15 * * * *'),

  // M3 — Signature invitation expiration cron (S9). Default '*/15 * * * *'
  // (every 15 minutes). Disabled in NODE_ENV=test (smoke harness owns scheduling).
  SIGNATURE_EXPIRATION_INTERVAL_CRON: z.string().min(1).default('*/15 * * * *'),

  // M4 — AI insight cache eviction cron (S8). Default '*/15 * * * *' (every
  // 15 minutes). Disabled in NODE_ENV=test. Sweep is system-actor (S2-20
  // sentinel) — fn_ai_insight_evict_expired is neondb_owner-only DEFINER.
  AI_INSIGHT_EVICTION_INTERVAL_CRON: z.string().min(1).default('*/15 * * * *'),

  // M4 / S5 — HMAC secret for the signed-PDF-token middleware. Token aud is
  // 'regulatory-impact-pdf'. Optional: when unset the public S5 endpoint
  // returns 503 (configuration not present). Required for production
  // PDF-export integrations.
  SIGNED_PDF_TOKEN_SECRET: z.string().optional(),
  SIGNED_PDF_TOKEN_ISSUER: z.string().default('musanad-contracts-pdf'),
  SIGNED_PDF_TOKEN_AUDIENCE: z.string().default('regulatory-impact-pdf'),

  // M22 / CR-MIG-DRIVE — Google Drive connector + token cipher
  GOOGLE_CLIENT_ID: z.string().optional(),
  GOOGLE_CLIENT_SECRET: z.string().optional(),
  GOOGLE_OAUTH_REDIRECT_URI: z
    .string()
    .url()
    .default('http://localhost:4000/api/v1/integrations/google-drive/callback'),
  TOKEN_CIPHER_KEY: z.string().optional(),
  OAUTH_STATE_HMAC_SECRET: z.string().optional(),
  MIGRATION_SYNC_WORKER_ENABLED: z
    .union([z.literal('true'), z.literal('false')])
    .default('false')
    .transform((v) => v === 'true'),
});

export type Env = z.infer<typeof envSchema>;

let cachedEnv: Env | null = null;

export const validateEnv = (): Env => {
  if (cachedEnv) return cachedEnv;

  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    // Use console.error: pino logger may not be initialised yet
    const issues = parsed.error.issues
      .map((i) => `  - ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    // eslint-disable-next-line no-console
    console.error(`FATAL: Environment validation failed:\n${issues}`);
    process.exit(1);
  }

  // Conditional checks (provider-specific)
  const env = parsed.data;
  if (env.AI_PROVIDER === 'openai' && !env.OPENAI_API_KEY) {
    // eslint-disable-next-line no-console
    console.error('FATAL: AI_PROVIDER=openai requires OPENAI_API_KEY to be set');
    process.exit(1);
  }
  if (env.AI_PROVIDER === 'anthropic' && !env.ANTHROPIC_API_KEY) {
    // eslint-disable-next-line no-console
    console.error('FATAL: AI_PROVIDER=anthropic requires ANTHROPIC_API_KEY to be set');
    process.exit(1);
  }
  if (env.UAE_PASS_PROVIDER === 'live') {
    const liveRequired: Array<keyof Env> = [
      'UAE_PASS_CLIENT_ID',
      'UAE_PASS_CLIENT_SECRET',
      'UAE_PASS_AUTHORIZE_URL',
      'UAE_PASS_TOKEN_URL',
      'UAE_PASS_USERINFO_URL',
    ];
    const missing = liveRequired.filter((k) => !env[k]);
    if (missing.length > 0) {
      // eslint-disable-next-line no-console
      console.error(
        `FATAL: UAE_PASS_PROVIDER=live requires: ${missing.join(', ')}`,
      );
      process.exit(1);
    }
  }

  cachedEnv = env;
  return env;
};

/**
 * Read once-cached env. Throws if validateEnv() has not run yet.
 * server.ts must call validateEnv() before any other module imports `env`.
 */
export const env = (): Env => {
  if (!cachedEnv) {
    throw new Error('env() called before validateEnv() — fix import order in server.ts');
  }
  return cachedEnv;
};
