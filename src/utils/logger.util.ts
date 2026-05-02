/**
 * Pino logger with sensitive-field redaction.
 * Redact paths cover all 17 sensitive fields from project.config.json,
 * the LoginUserRecord.passwordHash carrier (per Contract Generator handoff),
 * and the standard wire-level secrets (token / accessToken / refreshToken).
 *
 * Pretty print in development; JSON in production.
 */
import pino from 'pino';
import type { Logger } from 'pino';

const isDevelopment = process.env.NODE_ENV !== 'production';

/**
 * Sensitive-field redaction paths.
 *
 * Pino redaction supports `*.field` wildcard at any depth (single-segment
 * wildcard only). We list both common envelope shapes (req.body.password,
 * res.user.passwordHash) and a generic `*.field` pattern as a safety net.
 *
 * Mirrors:
 *   - project.config.json sensitiveFields (15 entries — both snake_case
 *     DB column names and conceptual sentinels)
 *   - LoginUserRecord.passwordHash (BE Impl handoff in
 *     contracts-summary.json `beImplementation`)
 *   - tokenHash (TokenBlacklistEntry @internal type)
 */
const SENSITIVE_PATHS: string[] = [
  // -- Wire-level (always present) --
  '*.password',
  '*.passwordHash',
  '*.password_hash',
  '*.refreshToken',
  '*.refresh_token',
  '*.accessToken',
  '*.access_token',
  '*.tokenHash',
  '*.token_hash',
  '*.jwtSecret',
  '*.jwt_secret',

  // -- Provider keys --
  '*.openaiApiKey',
  '*.openai_api_key',
  '*.anthropicApiKey',
  '*.anthropic_api_key',
  '*.smtpPassword',
  '*.smtp_password',
  '*.uaePassClientSecret',
  '*.uae_pass_client_secret',
  '*.supabaseServiceRoleKey',
  '*.supabase_service_role_key',

  // -- Project-specific contract fields --
  '*.contractBody',
  '*.contract_body',
  '*.signerEmail',
  '*.signer_email',
  '*.signerPhone',
  '*.signer_phone',
  '*.emiratesId',
  '*.emirates_id',
  '*.signatureImage',
  '*.signature_image',
  '*.aiPromptPayload',
  '*.ai_prompt_payload',

  // -- Common request/response top-level shapes --
  'req.body.password',
  'req.body.refreshToken',
  'req.body.accessToken',
  'res.body.passwordHash',
];

const baseConfig = {
  level: process.env.LOG_LEVEL || 'info',
  base: {
    service: process.env.SERVICE_NAME || 'musanad-contracts-backend',
    env: process.env.NODE_ENV || 'development',
  },
  redact: {
    paths: SENSITIVE_PATHS,
    censor: '[REDACTED]',
    remove: false,
  },
  timestamp: pino.stdTimeFunctions.isoTime,
};

let _logger: Logger | null = null;

const buildLogger = (): Logger => {
  if (isDevelopment) {
    return pino({
      ...baseConfig,
      transport: {
        target: 'pino-pretty',
        options: {
          colorize: true,
          translateTime: 'SYS:standard',
          ignore: 'pid,hostname',
        },
      },
    });
  }
  return pino(baseConfig);
};

export const logger: Logger = (() => {
  if (!_logger) _logger = buildLogger();
  return _logger;
})();

/** Sensitive paths (exported for test assertions / QA verification). */
export const SENSITIVE_REDACT_PATHS: ReadonlyArray<string> = SENSITIVE_PATHS;
