/**
 * Zod schemas for the AI Chat mention typeahead endpoints.
 */
import { z } from 'zod';

export const mentionQuerySchema = z.object({
  q: z.string().max(120).optional().default(''),
  limit: z
    .union([z.string(), z.number()])
    .optional()
    .transform((v) => {
      if (v == null) return 8;
      const n = typeof v === 'number' ? v : parseInt(v, 10);
      if (!Number.isFinite(n) || n <= 0) return 8;
      return Math.min(25, Math.max(1, n));
    }),
});

export type MentionQuery = z.infer<typeof mentionQuerySchema>;
