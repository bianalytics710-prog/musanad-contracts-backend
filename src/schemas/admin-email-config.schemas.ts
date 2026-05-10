/**
 * CR-C — Email server config Zod schemas (S14).
 *
 * Per-key validators are also enforced server-side by fn_system_setting_set
 * (CHECK constraints + body validators). The schema layer fails fast with
 * 400 + field-level error so the FE can render inline messages without a
 * roundtrip.
 */
import { z } from 'zod';
import { SMTP_ENCRYPTIONS } from '../types/admin-email-config.types';

const SIMPLE_EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export const emailConfigPatchBodySchema = z
  .object({
    smtpHost: z.string().trim().min(1).max(255).optional(),
    smtpPort: z
      .number()
      .int()
      .min(1, 'port must be integer 1..65535')
      .max(65535, 'port must be integer 1..65535')
      .optional(),
    smtpEncryption: z
      .enum(SMTP_ENCRYPTIONS as unknown as [string, ...string[]])
      .optional(),
    authUser: z.string().max(255).optional(),
    /** Write-only. Empty string clears the stored value. */
    authPassRef: z.string().max(500).optional(),
    fromAddress: z
      .string()
      .trim()
      .regex(SIMPLE_EMAIL_RE, 'invalid_email')
      .max(255)
      .optional(),
    fromNameEn: z.string().max(200).optional(),
    fromNameAr: z.string().max(200).optional(),
    replyTo: z
      .string()
      .trim()
      .regex(SIMPLE_EMAIL_RE, 'invalid_email')
      .max(255)
      .optional(),
    dailySendLimit: z
      .number()
      .int()
      .min(1, 'daily_send_limit must be 1..1000000')
      .max(1_000_000, 'daily_send_limit must be 1..1000000')
      .optional(),
    enabled: z.boolean().optional(),
  })
  .strict()
  .refine(
    (val) => Object.keys(val).length > 0,
    'At least one field must be provided for update',
  );

export const emailTestSendBodySchema = z
  .object({
    recipient: z
      .string()
      .trim()
      .regex(SIMPLE_EMAIL_RE, 'invalid_email')
      .max(255)
      .optional(),
  })
  .strict()
  .or(
    // Allow an empty body — fall back to the calling admin's email per Q5.
    z.undefined(),
  );

export type EmailConfigPatchBodyInferred = z.infer<
  typeof emailConfigPatchBodySchema
>;
export type EmailTestSendBodyInferred = z.infer<typeof emailTestSendBodySchema>;
