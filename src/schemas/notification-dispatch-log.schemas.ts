/**
 * M16 / CR-H — Zod validation schemas for notification_dispatch_log endpoints.
 */
import { z } from 'zod';

export const listNotificationDispatchLogSchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(200).default(50),
  channel: z
    .enum(['email', 'in_app', 'teams_capture', 'slack_capture'])
    .optional(),
  status: z
    .enum([
      'sent',
      'failed',
      'captured_only',
      'pending_retry',
      'final_failed',
      'suppressed_by_preference',
    ])
    .optional(),
  notificationKind: z
    .enum([
      'alert',
      'advisory',
      'approval_request',
      'signature_request',
      'system',
      'risk_case',
      'report',
    ])
    .optional(),
  priority: z.enum(['low', 'medium', 'high', 'critical']).optional(),
  recipientUserId: z.coerce.number().int().positive().optional(),
  from: z.string().optional(),
  to: z.string().optional(),
});

export type ListNotificationDispatchLogInput = z.infer<typeof listNotificationDispatchLogSchema>;
