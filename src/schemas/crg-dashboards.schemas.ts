/**
 * M15 / CR-G — Dashboard query parameter schemas.
 *
 * Reusable across all 4 new persona dashboard endpoints.
 * windowDays validates BETWEEN 7 AND 365 at the Zod layer before the DB call
 * raises 22023 (belt-and-suspenders per feedback_translatePgError).
 *
 * Different endpoints have different defaults:
 *   operations / finance-treasury / compliance-esg → 30 (default)
 *   procurement                                    → 90 (default)
 */
import { z } from 'zod';

/**
 * Shared window parameter for CR-G dashboard endpoints.
 * BETWEEN 7 AND 365. Default is 30 — callers override per endpoint.
 */
export const dashboardWindowSchema = z.object({
  windowDays: z
    .coerce
    .number()
    .int('windowDays must be an integer')
    .min(7, 'windowDays must be at least 7')
    .max(365, 'windowDays must be at most 365'),
});

/**
 * Operations / Finance-Treasury / Compliance-ESG — default 30 days.
 */
export const dashboardWindowDays30Schema = dashboardWindowSchema.extend({
  windowDays: dashboardWindowSchema.shape.windowDays.default(30),
});

/**
 * Procurement — default 90 days (longer horizon for supplier-history aggregation).
 */
export const dashboardWindowDays90Schema = dashboardWindowSchema.extend({
  windowDays: dashboardWindowSchema.shape.windowDays.default(90),
});

export type DashboardWindowDays30Input = z.infer<typeof dashboardWindowDays30Schema>;
export type DashboardWindowDays90Input = z.infer<typeof dashboardWindowDays90Schema>;
