/**
 * M16 / CR-H — Zod validation schemas for advisory_draft endpoints.
 * All write schemas use .strict() per DD-1.
 */
import { z } from 'zod';

export const generateAdvisoryDraftSchema = z
  .object({
    correlationId: z.number().int().positive('correlationId must be a positive integer'),
    templateId: z.number().int().positive('templateId must be a positive integer'),
    contractId: z.number().int().positive().optional(),
  })
  .strict();

export const listAdvisoryDraftsSchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(20),
  approvalStatus: z
    .enum(['unapproved', 'approved', 'rejected', 'modified'])
    .optional(),
  contractId: z.coerce.number().int().positive().optional(),
  correlationId: z.coerce.number().int().positive().optional(),
  draftType: z.string().optional(),
  myQueue: z
    .string()
    .optional()
    .transform((v) => v === 'true'),
});

export const approveAdvisoryDraftSchema = z
  .object({
    finalTextEn: z.string().min(1).optional(),
    finalTextAr: z.string().min(1).optional(),
  })
  .strict();

export const rejectAdvisoryDraftSchema = z
  .object({
    rejectionReason: z.string().min(10, {
      message: 'rejection_reason must be at least 10 characters',
    }),
  })
  .strict();

export const modifyAdvisoryDraftSchema = z
  .object({
    finalTextEn: z.string().min(1, 'finalTextEn is required'),
    finalTextAr: z.string().min(1, 'finalTextAr is required'),
  })
  .strict();

export const dispatchAdvisoryDraftSchema = z
  .object({
    recipients: z
      .array(
        z.object({
          email: z.string().email('Invalid recipient email'),
          name: z.string().min(1, 'Recipient name is required'),
          userId: z.number().int().positive().optional(),
        }),
      )
      .min(1, 'At least one recipient is required'),
  })
  .strict();

export type GenerateAdvisoryDraftInput = z.infer<typeof generateAdvisoryDraftSchema>;
export type ListAdvisoryDraftsInput = z.infer<typeof listAdvisoryDraftsSchema>;
export type ApproveAdvisoryDraftInput = z.infer<typeof approveAdvisoryDraftSchema>;
export type RejectAdvisoryDraftInput = z.infer<typeof rejectAdvisoryDraftSchema>;
export type ModifyAdvisoryDraftInput = z.infer<typeof modifyAdvisoryDraftSchema>;
export type DispatchAdvisoryDraftInput = z.infer<typeof dispatchAdvisoryDraftSchema>;
