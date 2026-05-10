/**
 * CR-C — System Settings extended schemas (S10).
 *
 * Per-key value-shape validators applied at the API boundary. fn_system_setting_set
 * re-validates per-key inside the DB body; this layer fails fast with a 400 +
 * field-level error so the FE can render inline messages without a roundtrip.
 *
 * The settings.routes.ts file currently mounts a generic schema at PATCH /:key.
 * The extended schema below is consumed by the new /admin/settings PATCH path
 * for the 7-tab expansion (security / email / calendar / audit_retention /
 * extended branding) introduced by migration 126.
 */
import { z } from 'zod';
import { SYSTEM_SETTING_CATEGORIES } from './_setting-keys';

const SIMPLE_EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const HEX_COLOR_RE = /^#[0-9A-Fa-f]{6}$/;
const HHMM_RE = /^[0-2][0-9]:[0-5][0-9]$/;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const WEEKDAYS = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const;

/**
 * Generic body schema for the PATCH /admin/settings/:key endpoint. The actual
 * shape varies per key; we validate the wrapper here and route to per-key
 * validators in the controller.
 */
export const systemSettingPatchBodySchema = z
  .object({
    value: z.unknown(),
    description: z.string().nullable().optional(),
  })
  .strict()
  .refine((v) => v.value !== undefined, {
    message: 'value is required',
  });

export const systemSettingKeyParamSchema = z.object({
  key: z
    .string()
    .trim()
    .min(1)
    .max(120)
    // Dot-notation key e.g. email.smtp.port, branding.color_primary, OR
    // legacy camelCase e.g. brandingLogoUrl (R-PA0 097). Both schemes coexist.
    .regex(/^[a-zA-Z][a-zA-Z0-9_.]*$/u, 'key must be camelCase or dot-notation identifier'),
});

export const systemSettingListQuerySchema = z
  .object({
    category: z.enum(SYSTEM_SETTING_CATEGORIES as unknown as [string, ...string[]]).optional(),
  })
  .strict();

/**
 * Validate a setting `value` against its key. Throws Zod-style ZodError
 * compatible result. Returns { ok: true } | { ok: false, message: string }.
 *
 * Per-key validators per AC-S10-03..05 / db-design.md §2.10. Used by both
 * the system-settings controller AND the email-config controller (which
 * patches multiple email.* keys in a single transactional batch).
 */
export interface SettingValidationResult {
  ok: boolean;
  message?: string;
}

export function validateSettingValue(
  key: string,
  value: unknown,
): SettingValidationResult {
  switch (key) {
    case 'email.smtp.port': {
      if (
        typeof value !== 'number' ||
        !Number.isFinite(value) ||
        !Number.isInteger(value) ||
        value < 1 ||
        value > 65535
      ) {
        return { ok: false, message: 'port must be integer 1..65535' };
      }
      return { ok: true };
    }
    case 'email.smtp.encryption': {
      if (
        typeof value !== 'string' ||
        !['none', 'tls', 'ssl', 'starttls'].includes(value)
      ) {
        return { ok: false, message: 'encryption must be one of none/tls/ssl/starttls' };
      }
      return { ok: true };
    }
    case 'branding.color_primary':
    case 'branding.color_accent': {
      if (typeof value !== 'string' || !HEX_COLOR_RE.test(value)) {
        return { ok: false, message: 'must be a valid hex color' };
      }
      return { ok: true };
    }
    case 'calendar.weekend_days': {
      if (!Array.isArray(value)) {
        return { ok: false, message: 'must be an array of weekday names' };
      }
      for (const d of value) {
        if (typeof d !== 'string' || !WEEKDAYS.includes(d as (typeof WEEKDAYS)[number])) {
          return { ok: false, message: `unknown weekday: ${String(d)}` };
        }
      }
      return { ok: true };
    }
    case 'calendar.working_hours_start':
    case 'calendar.working_hours_end': {
      if (typeof value !== 'string' || !HHMM_RE.test(value)) {
        return { ok: false, message: 'must be HH:MM' };
      }
      return { ok: true };
    }
    case 'calendar.holidays': {
      if (!Array.isArray(value)) {
        return { ok: false, message: 'must be an array of YYYY-MM-DD strings' };
      }
      for (const d of value) {
        if (typeof d !== 'string' || !ISO_DATE_RE.test(d)) {
          return { ok: false, message: `invalid date: ${String(d)}` };
        }
      }
      return { ok: true };
    }
    case 'audit.retention_days': {
      if (
        typeof value !== 'number' ||
        !Number.isInteger(value) ||
        value < 1 ||
        value > 3650
      ) {
        return { ok: false, message: 'retention_days must be 1..3650' };
      }
      return { ok: true };
    }
    case 'email.daily_send_limit': {
      if (
        typeof value !== 'number' ||
        !Number.isInteger(value) ||
        value < 1 ||
        value > 1_000_000
      ) {
        return { ok: false, message: 'daily_send_limit must be 1..1000000' };
      }
      return { ok: true };
    }
    case 'email.from_address':
    case 'email.reply_to': {
      if (typeof value !== 'string' || !SIMPLE_EMAIL_RE.test(value)) {
        return { ok: false, message: 'invalid email address' };
      }
      return { ok: true };
    }
    case 'security.session_timeout_min': {
      if (
        typeof value !== 'number' ||
        !Number.isInteger(value) ||
        value < 1 ||
        value > 1440
      ) {
        return { ok: false, message: 'session_timeout_min must be 1..1440' };
      }
      return { ok: true };
    }
    case 'security.password_policy_min_length': {
      if (
        typeof value !== 'number' ||
        !Number.isInteger(value) ||
        value < 8 ||
        value > 128
      ) {
        return { ok: false, message: 'password_policy_min_length must be 8..128' };
      }
      return { ok: true };
    }
    case 'security.password_policy_require_special':
    case 'security.mfa_required':
    case 'email.enabled': {
      if (typeof value !== 'boolean') {
        return { ok: false, message: 'must be a boolean' };
      }
      return { ok: true };
    }
    case 'security.ip_allowlist': {
      if (!Array.isArray(value)) {
        return { ok: false, message: 'must be an array of CIDR/IP strings' };
      }
      for (const v of value) {
        if (typeof v !== 'string' || v.length === 0) {
          return { ok: false, message: 'each entry must be a non-empty string' };
        }
      }
      return { ok: true };
    }
    default:
      // Unknown keys pass through — server-side fn_system_setting_set will
      // reject unknown keys with 404 'setting_not_found'.
      return { ok: true };
  }
}

export type SystemSettingPatchBodyInferred = z.infer<
  typeof systemSettingPatchBodySchema
>;
export type SystemSettingKeyParamInferred = z.infer<
  typeof systemSettingKeyParamSchema
>;
export type SystemSettingListQueryInferred = z.infer<
  typeof systemSettingListQuerySchema
>;
