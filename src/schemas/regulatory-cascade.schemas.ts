/**
 * CR-M — Zod validation schemas for regulatory cascade + party-workforce endpoints.
 */
import { z } from 'zod';

// ----------------------------------------------------------------
// Party-workforce schemas
// ----------------------------------------------------------------

export const setPartyWorkforceSchema = z.object({
  headcount: z.number({ required_error: 'headcount is required' }).int().min(0, 'headcount must be >= 0'),
  emiratisationTarget: z.number({ required_error: 'emiratisationTarget is required' }).int().min(0, 'emiratisationTarget must be >= 0'),
  emiratisationActual: z.number({ required_error: 'emiratisationActual is required' }).int().min(0, 'emiratisationActual must be >= 0'),
  category: z.enum(['drilling', 'logistics', 'epc', 'operational_support', 'other']).optional(),
  notes: z.string().max(2000).nullable().optional(),
});

export type SetPartyWorkforceInput = z.infer<typeof setPartyWorkforceSchema>;

export const partyWorkforceListQuerySchema = z.object({
  band: z.enum(['<20', '20-49', '50+']).optional(),
  compliant: z
    .string()
    .optional()
    .transform((v) => {
      if (v === undefined) return undefined;
      if (v === 'true') return true;
      if (v === 'false') return false;
      return undefined;
    }),
  search: z.string().optional(),
  limit: z.coerce.number().int().positive().max(200).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});

export type PartyWorkforceListQueryInput = z.infer<typeof partyWorkforceListQuerySchema>;

// ----------------------------------------------------------------
// Cascade schemas
// ----------------------------------------------------------------

export const runCascadeSchema = z
  .object({
    signalId: z.number().int().positive().optional(),
    impactSignalId: z.number().int().positive().optional(),
    params: z
      .object({
        employmentClauseTypes: z.array(z.string()).optional(),
      })
      .optional(),
  })
  .refine(
    (data) => data.signalId !== undefined || data.impactSignalId !== undefined,
    { message: 'signalId (or impactSignalId) is required', path: ['signalId'] },
  );

export type RunCascadeInput = z.infer<typeof runCascadeSchema>;

export const cascadeListQuerySchema = z.object({
  signalId: z.coerce.number().int().positive().optional(),
  limit: z.coerce.number().int().positive().max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

export type CascadeListQueryInput = z.infer<typeof cascadeListQuerySchema>;

export const setRemediationStatusSchema = z.object({
  status: z.enum(['pending', 'in_progress', 'amended', 'dismissed', 'resolved'], {
    required_error: 'status is required',
    invalid_type_error: 'status must be one of: pending, in_progress, amended, dismissed, resolved',
  }),
  note: z.string().max(2000).nullable().optional(),
});

export type SetRemediationStatusInput = z.infer<typeof setRemediationStatusSchema>;

export const draftAmendmentSchema = z.object({
  contractId: z.number().int().positive().optional(),
});

export type DraftAmendmentInput = z.infer<typeof draftAmendmentSchema>;
