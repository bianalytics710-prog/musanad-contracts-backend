/**
 * CR-C — Audit chain verify Zod schemas (S3).
 */
import { z } from 'zod';

export const auditChainVerifyBodySchema = z
  .object({
    startSeq: z.coerce.number().int().positive().nullable().optional(),
    endSeq: z.coerce.number().int().positive().nullable().optional(),
  })
  // strict() rejects unknown keys — small admin endpoint, no compatibility burden.
  .strict()
  .superRefine((val, ctx) => {
    const start =
      val.startSeq === null || val.startSeq === undefined ? null : val.startSeq;
    const end =
      val.endSeq === null || val.endSeq === undefined ? null : val.endSeq;
    if (start !== null && end !== null && start > end) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'invalid_range',
        path: ['startSeq'],
      });
    }
  });

export type AuditChainVerifyBodyInferred = z.infer<typeof auditChainVerifyBodySchema>;
