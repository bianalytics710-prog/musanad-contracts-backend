// ============================================================
// M7 — Zod schemas for /api/v1/signals
// ============================================================
import { z } from 'zod';

const signalKindSchema = z.enum(
  [
    'geopolitical',
    'sanctions',
    'weather',
    'commodity',
    'fx',
    'logistics',
    'esg',
    'regulatory',
    'news',
    'internal',
  ],
  { errorMap: () => ({ message: 'Invalid kind value' }) },
);

const severityMinSchema = z.enum(['informational', 'low', 'medium', 'high', 'critical'], {
  errorMap: () => ({ message: 'Invalid severityMin value' }),
});

export const osintSignalListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
  kind: signalKindSchema.optional(),
  sourceId: z.string().trim().min(1).max(200).optional(),
  severityMin: severityMinSchema.optional(),
  /** ISO 8601 UTC. */
  since: z
    .string()
    .trim()
    .min(1)
    .refine((s) => !Number.isNaN(Date.parse(s)), {
      message: 'since must be an ISO 8601 datetime string',
    })
    .optional(),
  /** ISO 3166-1 alpha-2 country code. */
  geographyIntersects: z
    .string()
    .trim()
    .regex(/^[A-Za-z]{2}$/, {
      message: 'geographyIntersects must be a 2-letter ISO country code',
    })
    .optional(),
  affectedEntityId: z.string().trim().min(1).max(200).optional(),
});
export type OsintSignalListQueryInferred = z.infer<typeof osintSignalListQuerySchema>;
