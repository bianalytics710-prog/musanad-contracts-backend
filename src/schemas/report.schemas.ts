/**
 * M20 / CR-L — Zod validation schemas for /api/v1/reports + /admin/reports.
 *
 * All write shapes use .strict() per DD-1.
 * node-cron.validate() is enforced via a Zod .refine() on scheduleCron
 * fields (api-contracts §validationNote on ep_report_template_create).
 */
import { z } from 'zod';
import cron from 'node-cron';

// ----------------------------------------------------------------
// Shared enums
// ----------------------------------------------------------------

export const reportKindEnum = z.enum(['excel', 'pdf', 'both']);
export const reportRunFormatEnum = z.enum(['excel', 'pdf']);
export const reportRunTriggeredByEnum = z.enum(['manual', 'scheduled']);
export const reportRunCompleteStatusEnum = z.enum(['complete', 'failed']);

const templateIdSlugRegex = /^[a-z0-9_]+$/;

const scheduleCronField = z
  .string()
  .trim()
  .min(1)
  .max(200)
  .nullable()
  .optional()
  .refine(
    (v) => v == null || cron.validate(v),
    'scheduleCron must be a valid 5-field cron expression',
  );

// ----------------------------------------------------------------
// list — user-mode + admin-mode (single endpoint)
// ----------------------------------------------------------------

export const listReportTemplatesSchema = z.object({
  adminMode: z
    .string()
    .optional()
    .transform((v) => v === 'true'),
});

// ----------------------------------------------------------------
// create template
// ----------------------------------------------------------------

export const createReportTemplateSchema = z
  .object({
    templateId: z
      .string()
      .trim()
      .min(1)
      .max(200)
      .regex(templateIdSlugRegex, 'templateId must match /^[a-z0-9_]+$/'),
    displayNameEn: z.string().trim().min(1).max(500),
    displayNameAr: z.string().trim().min(1).max(500).nullable().optional(),
    description: z.string().trim().max(5000).nullable().optional(),
    reportKind: reportKindEnum,
    dataSource: z.string().trim().min(1).max(200),
    parameterSchema: z.record(z.unknown()).optional(),
    assignedRoles: z.array(z.string().trim().min(1)).min(1, 'assignedRoles must be non-empty'),
    isScheduled: z.boolean().optional(),
    scheduleCron: scheduleCronField,
    scheduleRecipients: z
      .array(z.string().trim().min(1))
      .min(1)
      .nullable()
      .optional(),
  })
  .strict()
  .refine(
    (data) => {
      if (!data.isScheduled) return true;
      const hasCron = typeof data.scheduleCron === 'string' && data.scheduleCron.trim().length > 0;
      const hasRecipients = Array.isArray(data.scheduleRecipients) && data.scheduleRecipients.length > 0;
      return hasCron && hasRecipients;
    },
    {
      message: 'If isScheduled=true, scheduleCron and scheduleRecipients are required',
    },
  );

// ----------------------------------------------------------------
// update template — partial
// ----------------------------------------------------------------

export const updateReportTemplateSchema = z
  .object({
    displayNameEn: z.string().trim().min(1).max(500).optional(),
    displayNameAr: z.string().trim().min(1).max(500).nullable().optional(),
    description: z.string().trim().max(5000).nullable().optional(),
    dataSource: z.string().trim().min(1).max(200).optional(),
    parameterSchema: z.record(z.unknown()).optional(),
    assignedRoles: z.array(z.string().trim().min(1)).min(1).optional(),
    isScheduled: z.boolean().optional(),
    scheduleCron: scheduleCronField,
    scheduleRecipients: z
      .array(z.string().trim().min(1))
      .min(1)
      .nullable()
      .optional(),
    enabled: z.boolean().optional(),
  })
  .strict();

// Immutable fields on the template — rejected at controller layer before fn_ call.
export const IMMUTABLE_REPORT_TEMPLATE_FIELDS = ['templateId', 'tenantId', 'reportKind'] as const;

// ----------------------------------------------------------------
// trigger run
// ----------------------------------------------------------------

export const triggerReportRunSchema = z
  .object({
    triggeredBy: reportRunTriggeredByEnum.optional(),
    parameters: z.record(z.unknown()).optional(),
    format: reportRunFormatEnum,
  })
  .strict();

// ----------------------------------------------------------------
// complete run (internal worker callback)
// ----------------------------------------------------------------

export const completeReportRunSchema = z
  .object({
    status: reportRunCompleteStatusEnum,
    outputUri: z.string().trim().min(1).optional(),
    outputSizeBytes: z.number().int().min(0).optional(),
    errorMessage: z.string().trim().min(1).max(10000).optional(),
  })
  .strict()
  .refine(
    (data) => {
      if (data.status === 'complete') {
        return typeof data.outputUri === 'string' && typeof data.outputSizeBytes === 'number';
      }
      if (data.status === 'failed') {
        return typeof data.errorMessage === 'string' && data.errorMessage.trim().length > 0;
      }
      return false;
    },
    {
      message: 'complete requires outputUri + outputSizeBytes; failed requires errorMessage',
    },
  );

// ----------------------------------------------------------------
// pending-get (internal worker pickup)
// ----------------------------------------------------------------

export const reportRunPendingQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(50).default(5),
});

// ----------------------------------------------------------------
// data-fn parameters (internal worker)
// ----------------------------------------------------------------

export const reportDataRequestSchema = z
  .object({
    parameters: z.record(z.unknown()).optional(),
  })
  .strict();

// ----------------------------------------------------------------
// Inferred types
// ----------------------------------------------------------------

export type ListReportTemplatesInput = z.infer<typeof listReportTemplatesSchema>;
export type CreateReportTemplateInput = z.infer<typeof createReportTemplateSchema>;
export type UpdateReportTemplateInput = z.infer<typeof updateReportTemplateSchema>;
export type TriggerReportRunInput = z.infer<typeof triggerReportRunSchema>;
export type CompleteReportRunInput = z.infer<typeof completeReportRunSchema>;
export type ReportDataRequestInput = z.infer<typeof reportDataRequestSchema>;
