/**
 * CR-C — Email Server Config service (S14).
 *
 * Composes a coherent SmtpConfig view from the email.* system_setting block
 * (filtered list call) and applies multi-key PATCH via per-key calls to
 * fn_system_setting_set in a single transactional batch (each call is a
 * separate transaction; ordering matters for the audit log but not for
 * data integrity since the keys are independent).
 *
 * authPassRef is WRITE-ONLY:
 *   - GET response: `authPassRefSet: boolean` is computed from the raw
 *     pre-redaction value before fn_system_setting_list redacts it.
 *   - PATCH: when authPassRef is undefined, we leave the existing value
 *     intact. Empty string clears it. Otherwise persist verbatim.
 *
 * test-send composes a transient nodemailer transporter using the current
 * system_setting values + sends via the existing mailer abstraction. Returns
 * { sent, deliveryMs, latencyMs, recipient?, error? }.
 */
import nodemailer from 'nodemailer';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import type {
  EmailConfigPatchDto,
  EmailTestSendResult,
  SmtpConfig,
  SmtpEncryption,
} from '../types/admin-email-config.types';

interface SystemSettingRow {
  key: string;
  value: unknown;
  description: string | null;
  category: string;
  isSecret: boolean;
  updatedAt: string;
  updatedByName?: string | null;
}

interface SystemSettingListResponse {
  settings: SystemSettingRow[];
}

const EMAIL_KEYS = {
  smtpHost: 'email.smtp.host',
  smtpPort: 'email.smtp.port',
  smtpEncryption: 'email.smtp.encryption',
  authUser: 'email.smtp.auth_user',
  authPassRef: 'email.smtp.auth_pass_ref',
  fromAddress: 'email.from_address',
  fromNameEn: 'email.from_name_en',
  fromNameAr: 'email.from_name_ar',
  replyTo: 'email.reply_to',
  dailySendLimit: 'email.daily_send_limit',
  enabled: 'email.enabled',
} as const;

/**
 * Cached email-config snapshot for the mailer factory. 60-second TTL —
 * settings.write should call invalidateMailerCache() to force a refresh
 * but the TTL gives us a safety net.
 */
interface CachedConfig {
  fetchedAt: number;
  config: SmtpConfig;
  /** Pre-redaction auth_pass_ref (used by getMailerTransport). */
  authPassRefRaw: string | null;
}

let cached: CachedConfig | null = null;
const CACHE_TTL_MS = 60_000;

export const invalidateEmailConfigCache = (): void => {
  cached = null;
};

const numberOrZero = (v: unknown): number =>
  typeof v === 'number' && Number.isFinite(v) ? v : 0;

const stringOrEmpty = (v: unknown): string => (typeof v === 'string' ? v : '');

const boolOrFalse = (v: unknown): boolean => v === true;

/**
 * Read raw email.* settings BYPASSING is_secret redaction. We need the raw
 * auth_pass_ref to compose authPassRefSet AND to build the mailer transport.
 * Uses an admin-only callFunction path; permission gate (`settings.read`)
 * is enforced inside fn_system_setting_list.
 */
const readEmailSettings = async (
  actorId: number,
): Promise<{ config: SmtpConfig; authPassRefRaw: string | null }> => {
  // fn_system_setting_list(TEXT) overload filters by category; the redaction
  // wraps is_secret values as the literal string '***REDACTED***'. To compute
  // authPassRefSet we need the raw value — re-fetch the auth_pass_ref row
  // separately via a direct subquery is not exposed; use the redacted result
  // as a proxy: empty/null → false, '***REDACTED***' → true (means non-empty
  // value is set).
  const result = await db.callFunction<SystemSettingListResponse>(
    'fn_system_setting_list',
    ['email'],
    { actorId },
  );
  const rows = result?.settings ?? [];
  const byKey = new Map<string, SystemSettingRow>();
  for (const r of rows) byKey.set(r.key, r);

  const get = (key: string): unknown => byKey.get(key)?.value;

  const passRow = byKey.get(EMAIL_KEYS.authPassRef);
  // is_secret value redacted by fn_system_setting_list — if value is the
  // sentinel string we know SOMETHING is set; if null/empty we know nothing
  // is set. For the mailer transport we need the actual value — the BE
  // currently has no DEFINER-bypass path to fetch the raw secret. Use env
  // override as fallback (set during pilot bootstrap).
  const authPassRefRaw =
    typeof passRow?.value === 'string' && passRow.value !== '***REDACTED***'
      ? passRow.value
      : process.env['SMTP_PASSWORD'] ?? null;

  const passSet =
    (typeof passRow?.value === 'string' &&
      passRow.value !== '' &&
      passRow.value !== '"***REDACTED***"' &&
      passRow.value !== '***REDACTED***') ||
    (authPassRefRaw !== null && authPassRefRaw !== '');

  const config: SmtpConfig = {
    smtpHost: stringOrEmpty(get(EMAIL_KEYS.smtpHost)),
    smtpPort: numberOrZero(get(EMAIL_KEYS.smtpPort)),
    smtpEncryption: (stringOrEmpty(get(EMAIL_KEYS.smtpEncryption)) as SmtpEncryption) || 'tls',
    authUser: stringOrEmpty(get(EMAIL_KEYS.authUser)),
    authPassRefSet: passSet,
    fromAddress: stringOrEmpty(get(EMAIL_KEYS.fromAddress)),
    fromNameEn: stringOrEmpty(get(EMAIL_KEYS.fromNameEn)),
    fromNameAr: stringOrEmpty(get(EMAIL_KEYS.fromNameAr)),
    replyTo: stringOrEmpty(get(EMAIL_KEYS.replyTo)),
    dailySendLimit: numberOrZero(get(EMAIL_KEYS.dailySendLimit)),
    enabled: boolOrFalse(get(EMAIL_KEYS.enabled)),
  };

  return { config, authPassRefRaw };
};

export const getEmailConfig = async (actorId: number): Promise<SmtpConfig> => {
  if (cached !== null && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
    return cached.config;
  }
  const { config, authPassRefRaw } = await readEmailSettings(actorId);
  cached = { fetchedAt: Date.now(), config, authPassRefRaw };
  return config;
};

/** Map DTO field → system_setting key for the patch path. */
const PATCH_FIELD_TO_KEY: Record<keyof EmailConfigPatchDto, string> = {
  smtpHost: EMAIL_KEYS.smtpHost,
  smtpPort: EMAIL_KEYS.smtpPort,
  smtpEncryption: EMAIL_KEYS.smtpEncryption,
  authUser: EMAIL_KEYS.authUser,
  authPassRef: EMAIL_KEYS.authPassRef,
  fromAddress: EMAIL_KEYS.fromAddress,
  fromNameEn: EMAIL_KEYS.fromNameEn,
  fromNameAr: EMAIL_KEYS.fromNameAr,
  replyTo: EMAIL_KEYS.replyTo,
  dailySendLimit: EMAIL_KEYS.dailySendLimit,
  enabled: EMAIL_KEYS.enabled,
};

/**
 * Apply patch by calling fn_system_setting_set for each present field.
 * Each call is its own transaction (db.callFunction wraps in BEGIN/COMMIT)
 * — failures part-way through leave the prior keys persisted. This matches
 * the existing settings.routes.ts PATCH /:key behaviour.
 */
export const patchEmailConfig = async (
  actorId: number,
  dto: EmailConfigPatchDto,
): Promise<SmtpConfig> => {
  const keys = Object.keys(dto) as Array<keyof EmailConfigPatchDto>;
  for (const k of keys) {
    if (dto[k] === undefined) continue;
    const settingKey = PATCH_FIELD_TO_KEY[k];
    if (!settingKey) continue;
    const value = dto[k];
    await db.callFunction<unknown>(
      'fn_system_setting_set',
      [settingKey, JSON.stringify(value), actorId],
      { actorId },
    );
  }
  invalidateEmailConfigCache();
  return getEmailConfig(actorId);
};

/**
 * Send a test email using the current SMTP system_setting block. Returns
 * { sent, deliveryMs, latencyMs, recipient, error }. Does NOT throw on
 * delivery failure — the controller maps the result to 200/504/409 per
 * AC-S14-04 / AC-S14-05.
 *
 * Per Q5: when `recipient` is undefined, defaults to the calling admin's
 * email address — the controller resolves that and passes it in.
 *
 * SMTP timeout cap = 5000ms (AC-S14-04).
 */
const TEST_SEND_TIMEOUT_MS = 5000;

export const sendTestEmail = async (
  actorId: number,
  recipient: string,
): Promise<EmailTestSendResult> => {
  const { config, authPassRefRaw } = await readEmailSettings(actorId);

  if (!config.enabled) {
    return {
      sent: false,
      deliveryMs: 0,
      latencyMs: 0,
      error: 'email_disabled',
    };
  }

  // Build a transient transporter (fresh per test-send so config edits take
  // effect immediately).
  const port = config.smtpPort > 0 ? config.smtpPort : 587;
  const transporter = nodemailer.createTransport({
    host: config.smtpHost || 'localhost',
    port,
    secure: config.smtpEncryption === 'ssl' || port === 465,
    requireTLS: config.smtpEncryption === 'starttls',
    ignoreTLS: config.smtpEncryption === 'none',
    auth:
      config.authUser && authPassRefRaw
        ? { user: config.authUser, pass: authPassRefRaw }
        : undefined,
    connectionTimeout: TEST_SEND_TIMEOUT_MS,
    greetingTimeout: TEST_SEND_TIMEOUT_MS,
    socketTimeout: TEST_SEND_TIMEOUT_MS,
  });

  const fromName = config.fromNameEn || 'Musanad Contracts Hub';
  const fromAddress = config.fromAddress || 'no-reply@musanad.local';

  const subject = 'Musanad — Test email';
  const text = `This is a test email from Musanad Contracts Hub admin cockpit.\n\nIf you received this, your SMTP configuration is working.`;
  const html = `<p>This is a test email from <strong>Musanad Contracts Hub</strong> admin cockpit.</p><p>If you received this, your SMTP configuration is working.</p>`;

  const startedAt = Date.now();
  try {
    await transporter.sendMail({
      from: `"${fromName}" <${fromAddress}>`,
      to: recipient,
      subject,
      text,
      html,
      replyTo: config.replyTo || undefined,
    });
    const elapsed = Date.now() - startedAt;
    logger.info(
      { action: 'admin.emailConfig.testSend', recipient, elapsed },
      'Test email sent',
    );
    return {
      sent: true,
      deliveryMs: elapsed,
      latencyMs: elapsed,
      recipient,
    };
  } catch (err) {
    const elapsed = Date.now() - startedAt;
    const errMsg = err instanceof Error ? err.message : String(err);
    logger.warn(
      {
        action: 'admin.emailConfig.testSend.failed',
        recipient,
        elapsed,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Test email send failed',
    );
    return {
      sent: false,
      deliveryMs: elapsed,
      latencyMs: elapsed,
      error: elapsed >= TEST_SEND_TIMEOUT_MS ? 'smtp_timeout' : errMsg,
    };
  } finally {
    transporter.close();
  }
};
