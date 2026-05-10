/**
 * CR-C — Notification Templates Zod schemas (S12, S13).
 *
 * AC-S12-05 (immutable_field) is enforced at the schema layer: if the FE ever
 * forwards templateId or channel on the PATCH body, we reject with 400 +
 * field-level error. The fn signature also silently ignores them (defence-
 * in-depth).
 */
import { z } from 'zod';
import { NOTIFICATION_TEMPLATE_CHANNELS, RENDER_LOCALES } from '../types/admin-notification-templates.types';

export const notificationTemplateListQuerySchema = z
  .object({
    page: z.coerce.number().int().min(1).max(100000).optional(),
    limit: z.coerce.number().int().min(1).max(200).optional(),
    channel: z.enum(NOTIFICATION_TEMPLATE_CHANNELS as unknown as [string, ...string[]]).optional(),
    search: z.string().trim().min(1).max(200).optional(),
  })
  .strict();

export const notificationTemplateIdParamSchema = z.object({
  id: z.coerce.number().int().positive(),
});

/**
 * PATCH body. templateId / channel ANY presence (even null) → 400
 * 'immutable_field' per AC-S12-05.
 */
export const notificationTemplateUpdateBodySchema = z
  .object({
    subjectEn: z.string().nullable().optional(),
    subjectAr: z.string().nullable().optional(),
    bodyEn: z
      .string()
      .min(1, 'body_en_required')
      .optional(),
    bodyAr: z
      .string()
      .min(1, 'body_ar_required')
      .optional(),
    parameterSchema: z
      .record(z.string())
      .refine(
        (val) =>
          val !== null &&
          typeof val === 'object' &&
          !Array.isArray(val),
        'parameter_schema_must_be_object',
      )
      .optional(),
    // Reject immutable fields with explicit 400 errors. We allow them in the
    // schema only so we can attach the AC-S12-05 message; passthrough for
    // downstream is blocked because superRefine emits a custom issue.
    templateId: z.unknown().optional(),
    channel: z.unknown().optional(),
  })
  .strict()
  .superRefine((val, ctx) => {
    if (Object.prototype.hasOwnProperty.call(val, 'templateId')) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'immutable_field',
        path: ['templateId'],
      });
    }
    if (Object.prototype.hasOwnProperty.call(val, 'channel')) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'immutable_field',
        path: ['channel'],
      });
    }
    // bodyEn / bodyAr empty-string check (after schema-level min(1) covers
    // the explicit string case; this catches whitespace-only strings).
    if (val.bodyEn !== undefined && val.bodyEn.trim().length === 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'body_en_required',
        path: ['bodyEn'],
      });
    }
    if (val.bodyAr !== undefined && val.bodyAr.trim().length === 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'body_ar_required',
        path: ['bodyAr'],
      });
    }
  });

export const notificationTemplateRenderBodySchema = z
  .object({
    templateId: z.string().trim().min(1).max(200),
    channel: z.enum(NOTIFICATION_TEMPLATE_CHANNELS as unknown as [string, ...string[]]),
    locale: z.enum(RENDER_LOCALES as unknown as [string, ...string[]], {
      errorMap: () => ({ message: 'invalid_locale' }),
    }),
    parameters: z.record(z.union([z.string(), z.number(), z.boolean()])),
  })
  .strict();

export type NotificationTemplateListQueryInferred = z.infer<
  typeof notificationTemplateListQuerySchema
>;
export type NotificationTemplateUpdateBodyInferred = z.infer<
  typeof notificationTemplateUpdateBodySchema
>;
export type NotificationTemplateRenderBodyInferred = z.infer<
  typeof notificationTemplateRenderBodySchema
>;
