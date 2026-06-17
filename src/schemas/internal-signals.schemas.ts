// ============================================================
// M8 — Zod schemas for /api/v1/admin/internal-signals (POST ingest)
//                     /api/v1/admin/internal-signal-kinds (GET list)
//                     /api/v1/internal-signals (GET list + POST :id/resolve)
//
// Mirrors db-design.md §5 fn_ parameter specs + types.ts DTOs. Stage 4 BE-01
// / S2-25 alignment: every controller call validates body / query / params
// before db.callFunction(). Authoritative checks (parameter_schema required[],
// FK lookup, role mapping, idempotence) live in the fn_ bodies; Zod is the
// first-line defence (cheap, fast-fail).
// ============================================================
import { z } from 'zod';

// ------------------------------------------------------------
// Shared enums (mirror DB CHECK constraints + DDL §1.1)
// ------------------------------------------------------------

export const internalSignalTypeSchema = z.enum(
  [
    'milestone_slippage',
    'sla_breach',
    'payment_delay',
    'invoice_dispute',
    'vendor_incident',
    'ics_incident',
    'icv_status_change',
    'certificate_expiry',
  ],
  { errorMap: () => ({ message: 'Invalid signalType value' }) },
);

export const signalResolutionKindSchema = z.enum(
  ['cleared', 'superseded', 'mitigated', 'false_positive'],
  { errorMap: () => ({ message: 'Invalid resolutionKind value' }) },
);

export const internalSignalStatusFilterSchema = z.enum(['open', 'resolved', 'all'], {
  errorMap: () => ({ message: 'Invalid status value (must be open / resolved / all)' }),
});

const severityEnumSchema = z.enum(
  ['informational', 'low', 'medium', 'high', 'critical'],
  { errorMap: () => ({ message: 'Invalid severity value' }) },
);

const dataClassificationSchema = z.enum(['demo', 'pilot', 'production'], {
  errorMap: () => ({ message: 'Invalid dataClassification value' }),
});

// ------------------------------------------------------------
// Path params — :id
// ------------------------------------------------------------

export const internalSignalIdParamSchema = z.object({
  id: z.coerce.number().int().positive('id must be a positive integer'),
});
export type InternalSignalIdParamInferred = z.infer<typeof internalSignalIdParamSchema>;

// ------------------------------------------------------------
// POST /api/v1/admin/internal-signals body (ingest)
//
// Parameter-schema required-field checks live in the fn_ body (driven by
// internal_signal_kind.parameter_schema). Zod enforces the static shape:
// signalType + observedAt always required; conditional fields typed but
// optional.
// ------------------------------------------------------------

export const internalSignalIngestSchema = z.object({
  signalType: internalSignalTypeSchema,
  observedAt: z
    .string()
    .trim()
    .min(1, 'observedAt is required')
    .refine((s) => !Number.isNaN(Date.parse(s)), {
      message: 'observedAt must be an ISO 8601 datetime string',
    }),
  contractId: z.number().int().positive().optional(),
  vendorId: z.number().int().positive().optional(),
  milestoneRef: z.string().trim().min(1).max(200).optional(),
  invoiceRef: z.string().trim().min(1).max(200).optional(),
  daysOverdue: z.number().int().min(0).optional(),
  severityCalcInput: z.record(z.unknown()).optional(),
  severity: severityEnumSchema.optional(),
  dataClassification: dataClassificationSchema.optional(),
  // 689 — provenance. All optional: fn_internal_signal_ingest auto-derives the
  // system (from signalType) and record ref (from invoiceRef/milestoneRef/…)
  // when omitted. An explicitly-supplied unknown system code is rejected (400)
  // inside the fn body.
  sourceSystemCode: z.string().trim().min(1).max(120).optional(),
  sourceRecordRef: z.string().trim().min(1).max(200).optional(),
  sourceRecordUrl: z.string().trim().url('sourceRecordUrl must be a URL').max(2000).optional(),
});
export type InternalSignalIngestInferred = z.infer<typeof internalSignalIngestSchema>;

// ------------------------------------------------------------
// GET /api/v1/internal-signals query
// ------------------------------------------------------------

export const internalSignalListQuerySchema = z.object({
  signalType: internalSignalTypeSchema.optional(),
  contractId: z.coerce.number().int().positive().optional(),
  vendorId: z.coerce.number().int().positive().optional(),
  since: z
    .string()
    .trim()
    .min(1)
    .refine((s) => !Number.isNaN(Date.parse(s)), {
      message: 'since must be an ISO 8601 datetime string',
    })
    .optional(),
  status: internalSignalStatusFilterSchema.optional(),
  page: z.coerce.number().int().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
});
export type InternalSignalListQueryInferred = z.infer<typeof internalSignalListQuerySchema>;

// ------------------------------------------------------------
// POST /api/v1/internal-signals/:id/resolve body
// ------------------------------------------------------------

export const internalSignalResolveSchema = z.object({
  resolutionKind: signalResolutionKindSchema,
  resolutionNote: z.string().trim().max(2000).optional(),
});
export type InternalSignalResolveInferred = z.infer<typeof internalSignalResolveSchema>;
