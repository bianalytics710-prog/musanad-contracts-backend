/**
 * Unit-3 — persona action Zod schemas (R-OPS / R-FT / R-CES).
 *
 * Every action route validates body + params via validate() middleware
 * before the controller runs. These schemas are the single source of truth
 * for input shapes across all 12 new routes (11 action routes + 1 GET).
 *
 * Sources:
 *   unit3-api-contracts.md — canonical spec per persona action set.
 *   decisions AD-4 — audit_log enum codes per persona.
 */

import { z } from 'zod';

// ---------------------------------------------------------------------------
// Shared params
// ---------------------------------------------------------------------------

/**
 * Positive bigint for path params — mirrors PositiveBigIntSchema from contracts.schemas.ts.
 * Uses z.coerce.number() so Express string params are coerced to numbers without
 * .transform() (which would create ZodEffects with string input ≠ number output and
 * break the validate() middleware's ZodSchema<T> type constraint).
 */
const PositiveIdSchema = z.coerce
  .number()
  .int('must be an integer')
  .positive('must be a positive integer');

/** :correlationId path param — bigint id of correlation row */
export const CorrelationIdParamSchema = z.object({
  correlationId: PositiveIdSchema,
});

/** :contractId path param — bigint id of contract row */
export const ContractIdPersonaParamSchema = z.object({
  contractId: PositiveIdSchema,
});

// ---------------------------------------------------------------------------
// Operations action bodies
// ---------------------------------------------------------------------------

/** POST /api/v1/ops/events/:correlationId/acknowledge */
export const OpsAcknowledgeBodySchema = z.object({
  note: z.string().trim().max(500).optional(),
});

/** POST /api/v1/ops/events/:correlationId/link-remedy */
export const OpsLinkRemedyBodySchema = z.object({
  contractId: z.string().min(1, 'contractId is required'),
  clauseId: z.string().optional(),
  note: z.string().trim().max(500).optional(),
});

/** POST /api/v1/ops/events/:correlationId/escalate */
export const OpsEscalateBodySchema = z.object({
  toRole: z.enum(['procurement', 'legal', 'executive'], {
    errorMap: () => ({ message: 'toRole must be one of: procurement, legal, executive' }),
  }),
  note: z.string().trim().max(500).optional(),
});

// ---------------------------------------------------------------------------
// Finance & Treasury action bodies
// ---------------------------------------------------------------------------

/** POST /api/v1/finance/contracts/:contractId/price-review */
export const FinancePriceReviewBodySchema = z.object({
  correlationId: z.string().min(1, 'correlationId is required'),
  reason: z.enum(['index_crossed', 'escalation', 'manual'], {
    errorMap: () => ({ message: 'reason must be one of: index_crossed, escalation, manual' }),
  }),
  note: z.string().trim().max(500).optional(),
});

/** POST /api/v1/finance/contracts/:contractId/payment-hold */
export const FinancePaymentHoldBodySchema = z.object({
  invoiceRef: z.string().trim().max(100).optional(),
  amountAed: z.number().positive().optional(),
  note: z.string().trim().max(500).optional(),
});

/** POST /api/v1/finance/contracts/:contractId/hedge-review */
export const FinanceHedgeReviewBodySchema = z.object({
  pair: z
    .string()
    .regex(/^[A-Z]{3}\/[A-Z]{3}$/, 'pair must be in format XXX/YYY (e.g. USD/AED)')
    .optional(),
  exposureAed: z.number().positive().optional(),
  note: z.string().trim().max(500).optional(),
});

// ---------------------------------------------------------------------------
// Compliance & ESG action bodies
// ---------------------------------------------------------------------------

/** POST /api/v1/compliance/contracts/:contractId/raise-flag */
export const ComplianceRaiseFlagBodySchema = z.object({
  flagKind: z.enum(['sanctions', 'esg', 'audit_rights', 'other'], {
    errorMap: () => ({ message: 'flagKind must be one of: sanctions, esg, audit_rights, other' }),
  }),
  severity: z.enum(['low', 'medium', 'high', 'critical'], {
    errorMap: () => ({ message: 'severity must be one of: low, medium, high, critical' }),
  }),
  note: z.string().trim().max(1000).optional(),
});

/** POST /api/v1/compliance/contracts/:contractId/supplier-audit */
export const ComplianceSupplierAuditBodySchema = z.object({
  scope: z.enum(['financial', 'operational', 'esg', 'sanctions', 'full'], {
    errorMap: () => ({
      message: 'scope must be one of: financial, operational, esg, sanctions, full',
    }),
  }),
  targetDate: z.string().datetime().optional(),
  note: z.string().trim().max(1000).optional(),
});

/** POST /api/v1/compliance/contracts/:contractId/recommend-hold */
export const ComplianceRecommendHoldBodySchema = z.object({
  reason: z.string().trim().min(1, 'reason is required').max(1000),
  proposedHoldUntil: z.string().datetime().optional(),
});

/** POST /api/v1/compliance/contracts/:contractId/recommend-termination */
export const ComplianceRecommendTerminationBodySchema = z.object({
  reason: z.string().trim().min(1, 'reason is required').max(2000),
  grounds: z.enum(
    [
      'sanctions',
      'material_breach',
      'esg_violation',
      'non_performance',
      'regulatory_compliance',
      'other',
    ],
    {
      errorMap: () => ({
        message:
          'grounds must be one of: sanctions, material_breach, esg_violation, non_performance, regulatory_compliance, other',
      }),
    },
  ),
});

/** POST /api/v1/compliance/contracts/:contractId/icv-certificate — multipart body fields */
export const ComplianceIcvCertificateBodySchema = z.object({
  validUntil: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'validUntil must be in YYYY-MM-DD format')
    .optional(),
});

// ---------------------------------------------------------------------------
// Unit-4 / R-PROC — Procurement action bodies + params
// ---------------------------------------------------------------------------

/** :partyId path param — bigint id of party (vendor) row */
export const PartyIdParamSchema = z.object({
  partyId: PositiveIdSchema,
});

/** POST /api/v1/procurement/vendors/:partyId/activate-alternate */
export const ProcurementActivateAlternateBodySchema = z.object({
  /** id of the alternate party to activate (if known); free-form vendor name otherwise. */
  alternatePartyId: PositiveIdSchema.optional(),
  alternateVendorName: z.string().trim().max(200).optional(),
  forContractId: PositiveIdSchema.optional(),
  note: z.string().trim().max(1000).optional(),
});

/** POST /api/v1/procurement/vendors/:partyId/escalate */
export const ProcurementEscalateVendorBodySchema = z.object({
  reason: z.string().trim().min(1, 'reason is required').max(1000),
  toRole: z
    .enum(['legal', 'executive', 'compliance', 'finance_treasury'], {
      errorMap: () => ({
        message: 'toRole must be one of: legal, executive, compliance, finance_treasury',
      }),
    })
    .optional(),
});

/** POST /api/v1/procurement/contracts/:contractId/cure-notice-intent */
export const ProcurementCureNoticeIntentBodySchema = z.object({
  breachDescription: z.string().trim().min(1, 'breachDescription is required').max(2000),
  curePeriodDays: z.number().int().positive().max(365).optional(),
  note: z.string().trim().max(1000).optional(),
});

/** POST /api/v1/procurement/contracts/:contractId/icv-remediation */
export const ProcurementIcvRemediationBodySchema = z.object({
  shortfallDescription: z.string().trim().min(1, 'shortfallDescription is required').max(1000),
  proposedRemediationSteps: z.string().trim().max(2000).optional(),
  forwardToCompliance: z.boolean().optional(),
});

// ---------------------------------------------------------------------------
// Inferred types
// ---------------------------------------------------------------------------

export type CorrelationIdParam = z.infer<typeof CorrelationIdParamSchema>;
export type ContractIdPersonaParam = z.infer<typeof ContractIdPersonaParamSchema>;
export type PartyIdParam = z.infer<typeof PartyIdParamSchema>;
export type OpsAcknowledgeBody = z.infer<typeof OpsAcknowledgeBodySchema>;
export type OpsLinkRemedyBody = z.infer<typeof OpsLinkRemedyBodySchema>;
export type OpsEscalateBody = z.infer<typeof OpsEscalateBodySchema>;
export type FinancePriceReviewBody = z.infer<typeof FinancePriceReviewBodySchema>;
export type FinancePaymentHoldBody = z.infer<typeof FinancePaymentHoldBodySchema>;
export type FinanceHedgeReviewBody = z.infer<typeof FinanceHedgeReviewBodySchema>;
export type ComplianceRaiseFlagBody = z.infer<typeof ComplianceRaiseFlagBodySchema>;
export type ComplianceSupplierAuditBody = z.infer<typeof ComplianceSupplierAuditBodySchema>;
export type ComplianceRecommendHoldBody = z.infer<typeof ComplianceRecommendHoldBodySchema>;
export type ComplianceRecommendTerminationBody = z.infer<
  typeof ComplianceRecommendTerminationBodySchema
>;
export type ComplianceIcvCertificateBody = z.infer<typeof ComplianceIcvCertificateBodySchema>;
export type ProcurementActivateAlternateBody = z.infer<typeof ProcurementActivateAlternateBodySchema>;
export type ProcurementEscalateVendorBody = z.infer<typeof ProcurementEscalateVendorBodySchema>;
export type ProcurementCureNoticeIntentBody = z.infer<typeof ProcurementCureNoticeIntentBodySchema>;
export type ProcurementIcvRemediationBody = z.infer<typeof ProcurementIcvRemediationBodySchema>;
