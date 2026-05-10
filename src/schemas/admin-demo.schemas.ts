/**
 * CR-C — Demo data purge Zod schemas (S6, S7).
 *
 * The confirmToken format is enforced both in the schema (shape) AND in the
 * controller (date-of-day match against server clock). Schema rejects shape
 * violations with 400 'double_confirmation_required'.
 */
import { z } from 'zod';

/**
 * confirmToken format: `PURGE_DEMO_DATA_YYYY-MM-DD`. Date validation against
 * today is performed in the controller (server clock per AC-S6-05).
 */
const CONFIRM_TOKEN_SHAPE_RE = /^PURGE_DEMO_DATA_\d{4}-\d{2}-\d{2}$/;

export const demoPurgeBodySchema = z
  .object({
    confirmToken: z.string().trim().min(1).optional(),
    dryRun: z.boolean().optional(),
  })
  .strict()
  .superRefine((val, ctx) => {
    const dryRun = val.dryRun === true;
    if (!dryRun) {
      if (!val.confirmToken) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: 'double_confirmation_required',
          path: ['confirmToken'],
        });
        return;
      }
      if (!CONFIRM_TOKEN_SHAPE_RE.test(val.confirmToken)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: 'double_confirmation_required',
          path: ['confirmToken'],
        });
      }
    }
  });

export type DemoPurgeBodyInferred = z.infer<typeof demoPurgeBodySchema>;
