/**
 * M16 / CR-H — Zod validation schemas for notification_subscription (preferences) endpoints.
 */
import { z } from 'zod';

export const setNotificationPreferenceSchema = z
  .object({
    notificationKind: z.enum(
      ['alert', 'advisory', 'approval_request', 'signature_request', 'system', 'risk_case', 'report'],
      { errorMap: () => ({ message: 'invalid_kind' }) },
    ),
    channel: z.enum(['email', 'in_app', 'teams_capture', 'slack_capture'], {
      errorMap: () => ({ message: 'invalid_channel' }),
    }),
    priorityMin: z
      .enum(['low', 'medium', 'high', 'critical'], {
        errorMap: () => ({ message: 'invalid_priority' }),
      })
      .optional(),
    enabled: z.boolean().optional(),
  })
  .strict();

export type SetNotificationPreferenceInput = z.infer<typeof setNotificationPreferenceSchema>;
