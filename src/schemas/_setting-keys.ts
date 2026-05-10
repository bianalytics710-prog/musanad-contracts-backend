/**
 * CR-C — system_setting category enum (M10 migration 126 expansion).
 *
 * Lifted into a dedicated module to keep both the email-config and the
 * extended-settings schemas dependency-free of the system_setting types
 * file (which lives in workspace types.ts and is not part of the BE
 * tsconfig include root).
 */
export type SystemSettingCategory =
  | 'general'
  | 'uae_pass'
  | 'branding'
  | 'security'
  | 'email'
  | 'calendar'
  | 'audit_retention';

export const SYSTEM_SETTING_CATEGORIES: ReadonlyArray<SystemSettingCategory> = [
  'general',
  'uae_pass',
  'branding',
  'security',
  'email',
  'calendar',
  'audit_retention',
] as const;
