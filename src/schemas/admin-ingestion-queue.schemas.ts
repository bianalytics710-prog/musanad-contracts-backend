/**
 * M11 — Zod schemas for Admin Ingestion Queue endpoints.
 *
 * Covers:
 *   - GET  /admin/ingestion-queue        (query params)
 *   - POST /admin/ingestion-queue/:id/resolve (body + path param)
 */

import { z } from 'zod';

const REVIEW_STATUS_VALUES = ['pending_auto', 'pending_human', 'resolved', 'rejected'] as const;
const REVIEW_ACTION_VALUES = ['confirm', 'correct', 'reject'] as const;

/**
 * AdminIngestionQueueListQuerySchema — query param validation for
 * GET /admin/ingestion-queue.
 */
export const AdminIngestionQueueListQuerySchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(20),
  reviewStatus: z.enum(REVIEW_STATUS_VALUES).optional(),
  contractVersionId: z.coerce.number().int().positive().optional(),
  gpt4oUsed: z
    .string()
    .toLowerCase()
    .transform((v) => v === 'true')
    .pipe(z.boolean())
    .optional(),
});

export type AdminIngestionQueueListQuery = z.infer<typeof AdminIngestionQueueListQuerySchema>;

/**
 * AdminIngestionQueueIdParamSchema — path param :id for resolve endpoint.
 */
export const AdminIngestionQueueIdParamSchema = z.object({
  id: z.coerce.number().int().positive({ message: 'id must be a positive integer' }),
});

/**
 * IngestionResolveBodySchema — request body for POST /:id/resolve.
 *
 * When action='correct', correctedText must be non-empty.
 * SENSITIVE: correctedText is Pino-redacted at controller boundary.
 */
export const IngestionResolveBodySchema = z
  .object({
    action: z.enum(REVIEW_ACTION_VALUES, {
      required_error: 'action is required',
      invalid_type_error: 'action must be one of: confirm, correct, reject',
    }),
    correctedText: z.string().optional(),
  })
  .superRefine((data, ctx) => {
    if (data.action === 'correct') {
      if (!data.correctedText || data.correctedText.trim().length === 0) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['correctedText'],
          message: 'correctedText is required when action is correct',
        });
      }
    }
  });

export type IngestionResolveBody = z.infer<typeof IngestionResolveBodySchema>;
