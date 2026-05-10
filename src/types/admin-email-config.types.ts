/**
 * CR-C — Email Server Config types (S14).
 *
 * Mirrors workspace types.ts §8. authPassRef is WRITE-ONLY at the API
 * boundary — never returned in subsequent GETs. The FE renders a binary
 * signal via `authPassRefSet`.
 */
import type { ApiResponse } from './api.types';

export type SmtpEncryption = 'none' | 'tls' | 'ssl' | 'starttls';

export const SMTP_ENCRYPTIONS: ReadonlyArray<SmtpEncryption> = [
  'none',
  'tls',
  'ssl',
  'starttls',
] as const;

/**
 * SmtpConfig — composed by the BE controller from email.* system_setting rows.
 * Returned by GET /api/v1/admin/email-config + PATCH /api/v1/admin/email-config.
 */
export interface SmtpConfig {
  smtpHost: string;
  smtpPort: number;
  smtpEncryption: SmtpEncryption;
  authUser: string;
  /** Indicator only — never the value itself. */
  authPassRefSet: boolean;
  fromAddress: string;
  fromNameEn: string;
  fromNameAr: string;
  replyTo: string;
  dailySendLimit: number;
  enabled: boolean;
}

/**
 * EmailConfigPatchDto — PATCH /api/v1/admin/email-config body.
 *
 * authPassRef is WRITE-ONLY: when present, replaces stored value;
 * when omitted (undefined), existing value is retained per AC-S14-07
 * "Existing password retained if left blank". Empty string clears the
 * stored value.
 *
 * All fields optional (partial update). BE applies the same per-key
 * validators as SystemSettingPatchDto via fn_system_setting_set.
 */
export interface EmailConfigPatchDto {
  smtpHost?: string;
  smtpPort?: number;
  smtpEncryption?: SmtpEncryption;
  authUser?: string;
  /** Write-only. Not returned. Empty string clears the stored value. */
  authPassRef?: string;
  fromAddress?: string;
  fromNameEn?: string;
  fromNameAr?: string;
  replyTo?: string;
  dailySendLimit?: number;
  enabled?: boolean;
}

/**
 * EmailTestSendRequest — POST /api/v1/admin/email-config/test-send body.
 *
 * `recipient` OPTIONAL — when omitted, BE sends to the calling admin's email
 * (Q5 default-to-admin). When present, requires explicit re-confirmation
 * modal at the FE layer.
 */
export interface EmailTestSendRequest {
  recipient?: string;
}

/**
 * EmailTestSendResult — POST /api/v1/admin/email-config/test-send response.
 * 200 with this shape on success; 504 with ErrorResponse on SMTP timeout
 * (AC-S14-04); 409 'email_disabled' when email.enabled = false (AC-S14-05).
 *
 * `latencyMs` mirrors deliveryMs — kept under both names for forward compat
 * (instructions called for `latencyMs`; design called for `deliveryMs`).
 */
export interface EmailTestSendResult {
  sent: boolean;
  /** Wall-clock SMTP round-trip in milliseconds. */
  deliveryMs: number;
  /** Alias for deliveryMs — covers both contract spellings. */
  latencyMs: number;
  /** Echo of the recipient that received the test email (success path). */
  recipient?: string;
  /** Optional human-readable error string (failure path). */
  error?: string;
}

export type SmtpConfigApiResponse = ApiResponse<SmtpConfig>;
export type EmailTestSendApiResponse = ApiResponse<EmailTestSendResult>;
