/**
 * M16 / CR-H — Zod validation schemas for advisory_template endpoints.
 * All write schemas use .strict() per DD-1 (extra fields rejected with 400).
 */
import { z } from 'zod';

export const DRAFT_TYPE_ENUM = [
  'fm_invocation',
  'cure_notice',
  'sanctions_hold',
  'price_review',
  'icv_rectification',
  'insurance_renewal',
  'esg_concern',
  'custom',
] as const;

export const DISPATCH_CHANNEL_ENUM = ['email', 'teams_capture', 'slack_capture'] as const;

export const createAdvisoryTemplateSchema = z
  .object({
    templateId: z.string().min(1, 'templateId is required'),
    displayNameEn: z.string().min(1, 'displayNameEn is required'),
    displayNameAr: z.string().min(1, 'displayNameAr is required'),
    description: z.string().optional(),
    draftType: z.enum(DRAFT_TYPE_ENUM, {
      errorMap: () => ({ message: 'invalid_draft_type' }),
    }),
    bodyTemplateEn: z.string().min(1, 'bodyTemplateEn is required'),
    bodyTemplateAr: z.string().min(1, 'bodyTemplateAr is required'),
    parameterSchema: z.record(z.unknown()).optional(),
    assignedApproverRole: z.string().min(1, 'assignedApproverRole is required'),
    dispatchChannels: z
      .array(z.enum(DISPATCH_CHANNEL_ENUM))
      .min(1, 'At least one dispatch channel required')
      .optional(),
  })
  .strict();

export const updateAdvisoryTemplateSchema = z
  .object({
    displayNameEn: z.string().min(1).optional(),
    displayNameAr: z.string().min(1).optional(),
    description: z.string().optional(),
    bodyTemplateEn: z.string().min(1).optional(),
    bodyTemplateAr: z.string().min(1).optional(),
    parameterSchema: z.record(z.unknown()).optional(),
    assignedApproverRole: z.string().min(1).optional(),
    dispatchChannels: z
      .array(z.enum(DISPATCH_CHANNEL_ENUM))
      .min(1)
      .optional(),
  })
  .strict()
  .refine((data) => Object.keys(data).length > 0, {
    message: 'At least one field must be provided for update',
  });

export const listAdvisoryTemplatesSchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(20),
  draftType: z.enum(DRAFT_TYPE_ENUM).optional(),
  isActive: z
    .string()
    .optional()
    .transform((v) => {
      if (v === undefined) return true;
      return v !== 'false';
    }),
  search: z.string().optional(),
});

export type CreateAdvisoryTemplateInput = z.infer<typeof createAdvisoryTemplateSchema>;
export type UpdateAdvisoryTemplateInput = z.infer<typeof updateAdvisoryTemplateSchema>;
export type ListAdvisoryTemplatesInput = z.infer<typeof listAdvisoryTemplatesSchema>;

/** Immutable fields — rejected with 400 if present in PATCH body. */
export const IMMUTABLE_TEMPLATE_FIELDS = ['templateId', 'draftType', 'tenantId'] as const;
