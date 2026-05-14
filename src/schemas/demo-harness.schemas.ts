/**
 * CR-J — Demo Harness Zod schemas.
 *
 * All write DTOs use .strict() — unknown keys are rejected at the controller
 * validation layer before reaching the DB (DN-10).
 */
import { z } from 'zod';

/**
 * ResetDemoDto — POST /api/v1/admin/demo/reset body.
 * confirmToken is a user-typed acknowledgement string in the form
 * RESET_DEMO_YYYY-MM-DD (matches today's date in the FE modal). The controller
 * generates its own rolling UUID internally for the DB GUC; the body token is
 * purely a "are-you-sure" acknowledgement that the user typed the correct date.
 */
export const resetDemoBodySchema = z
  .object({
    confirmToken: z
      .string()
      .trim()
      .min(1, 'confirmToken is required')
      .regex(/^RESET_DEMO_\d{4}-\d{2}-\d{2}$/, 'confirmToken must match RESET_DEMO_YYYY-MM-DD'),
  })
  .strict();

export type ResetDemoBodyInferred = z.infer<typeof resetDemoBodySchema>;

/**
 * TimeFreezeSetDto — POST /api/v1/admin/demo/time-freeze body.
 * targetTimestamp must be a parseable ISO 8601 datetime string.
 */
export const timeFreezeSetBodySchema = z
  .object({
    targetTimestamp: z
      .string()
      .trim()
      .min(1, 'targetTimestamp is required')
      .refine(
        (v) => !isNaN(new Date(v).getTime()),
        'targetTimestamp must be a valid ISO 8601 datetime string',
      ),
  })
  .strict();

export type TimeFreezeSetBodyInferred = z.infer<typeof timeFreezeSetBodySchema>;
