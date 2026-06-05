// ============================================================
// M6 — Dashboards & Reporting — Zod Validation Schemas (BE)
// Mirrors workspace/current-module/schemas.ts (canonical Agent 5 source).
// Local copy here so the backend repo is self-contained for tsc.
// Pattern: M5 regulatory schemas (z.coerce + .strict() + superRefine where
// cross-field invariants apply).
// ============================================================
//
// Coverage:
// - Request schemas (one per endpoint that accepts a query) — 8 schemas
//   (router + health-check have no parameters)
// - Response schemas (one per fn_ JSONB output) — 10 schemas
// - Embedded shape schemas — referenced by response schemas
//
// Validation guard rails (all derived from db-design.md error mappings):
//   - p_window_days BETWEEN 1 AND 365 for non-AI dashboards
//   - p_window_days BETWEEN 1 AND  90 for fn_dashboard_ai_cost_summary
//   - p_limit       BETWEEN 1 AND  50 for fn_dashboard_executive_anomalies_history
//
// Defence-in-depth: the fn_ body re-validates the same range and RAISEs
// ERRCODE 22023 with { field: 'windowDays', message: '...' } — Zod failures
// at the controller layer return 400 with the SAME error envelope shape so
// the FE handles them uniformly.
// ============================================================

import { z } from 'zod';

// ------------------------------------------------------------
// 1. Common primitives
// ------------------------------------------------------------

const isoDateTimeSchema = z
  .string()
  .regex(
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/,
    'Must be ISO 8601 timestamp',
  );

const isoDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Must be ISO date YYYY-MM-DD');

const isoYearMonthSchema = z
  .string()
  .regex(/^\d{4}-\d{2}$/, 'Must be ISO year-month YYYY-MM');

const decimalSchema = z.number().finite();
const nonNegativeIntSchema = z.coerce.number().int().min(0);

// ------------------------------------------------------------
// 2. Shared dashboard query — windowDays
// ------------------------------------------------------------
//
// Operational dashboards (admin/drafter/approver/legal-counsel/recipient/
// executive): windowDays default 30 (or 90 for executive), range 1..365.
// AI cost summary: windowDays default 30, range 1..90 (matches M4 cap).

export const windowDaysOperationalSchema = z.coerce
  .number()
  .int()
  .min(1, { message: 'windowDays must be between 1 and 365' })
  .max(365, { message: 'windowDays must be between 1 and 365' });

export const windowDaysAiSchema = z.coerce
  .number()
  .int()
  .min(1, { message: 'windowDays must be between 1 and 90' })
  .max(90, { message: 'windowDays must be between 1 and 90' });

/** Operational dashboards (admin/drafter/approver/legal-counsel/recipient/executive). */
export const operationalDashboardQuerySchema = z
  .object({
    windowDays: windowDaysOperationalSchema.optional(),
  })
  .strict();
export type OperationalDashboardQueryInput = z.infer<
  typeof operationalDashboardQuerySchema
>;

/** fn_dashboard_ai_cost_summary — 1..90 range. */
export const aiCostSummaryQuerySchema = z
  .object({
    windowDays: windowDaysAiSchema.optional(),
  })
  .strict();
export type AiCostSummaryQueryInput = z.infer<typeof aiCostSummaryQuerySchema>;

/** POST /executive/expiring-contracts/escalate — body validation. */
export const expiringContractsEscalateBodySchema = z
  .object({
    contractIds: z
      .array(z.coerce.number().int().positive())
      .min(1, { message: 'contractIds must contain at least one id' })
      .max(200, { message: 'contractIds capped at 200 per request' }),
    windowDays: z
      .union([z.literal(30), z.literal(60), z.literal(90)])
      .or(z.coerce.number().int().refine((n) => [30, 60, 90].includes(n), {
        message: 'windowDays must be 30, 60 or 90',
      })),
    note: z.string().max(500, { message: 'note must be 500 chars or fewer' }).optional(),
  })
  .strict();
export type ExpiringContractsEscalateBodyInput = z.infer<
  typeof expiringContractsEscalateBodySchema
>;

/** fn_dashboard_executive_anomalies_history — limit param 1..50. */
export const executiveAnomaliesHistoryQuerySchema = z
  .object({
    limit: z.coerce
      .number()
      .int()
      .min(1, { message: 'limit must be between 1 and 50' })
      .max(50, { message: 'limit must be between 1 and 50' })
      .optional(),
  })
  .strict();
export type ExecutiveAnomaliesHistoryQueryInput = z.infer<
  typeof executiveAnomaliesHistoryQuerySchema
>;

/** fn_dashboard_router — no parameters; empty body / empty query. */
export const dashboardRouterQuerySchema = z.object({}).strict();

/** fn_health_check — no parameters. */
export const healthCheckQuerySchema = z.object({}).strict();

// ------------------------------------------------------------
// 3. Common embedded shapes (response side)
// ------------------------------------------------------------

export const placeholderKpiSchema = z
  .object({
    value: z.literal(0),
    placeholder: z.literal(true),
  })
  .strict();

export const trendDayCountSchema = z
  .object({
    date: isoDateSchema,
    count: nonNegativeIntSchema,
  })
  .strict();

export const approvalDecisionDayPointSchema = z
  .object({
    date: isoDateSchema,
    approved: nonNegativeIntSchema,
    rejected: nonNegativeIntSchema,
  })
  .strict();

export const trendMonthCountSchema = z
  .object({
    month: isoYearMonthSchema,
    count: nonNegativeIntSchema,
  })
  .strict();

export const trendMonthValueAedSchema = z
  .object({
    month: isoYearMonthSchema,
    totalValueAed: decimalSchema,
  })
  .strict();

export const counterpartyConcentrationRowSchema = z
  .object({
    counterpartyId: z.number().int().positive(),
    totalValueAed: decimalSchema,
    contractCount: z.number().int().positive(),
  })
  .strict();

export const valueDistributionBucketSchema = z
  .object({
    bucket: z.string().min(1),
    count: nonNegativeIntSchema,
  })
  .strict();

export const aiCostTopPromptRowSchema = z
  .object({
    promptId: z.number().int().positive(),
    requestCount: nonNegativeIntSchema,
    totalCostUsd: decimalSchema,
    cacheHitRatio: decimalSchema.nullable(),
  })
  .strict();

const dashboardContractRowSchema = z
  .object({
    id: z.number().int().positive(),
    contractNumber: z.string(),
    titleEn: z.string(),
    titleAr: z.string().nullable(),
    status: z.string(),
    valueAed: decimalSchema.nullable(),
    updatedAt: isoDateTimeSchema,
  })
  .strict();

const drafterAwaitingActionRowSchema = z
  .object({
    id: z.number().int().positive(),
    contractNumber: z.string(),
    titleEn: z.string(),
    titleAr: z.string().nullable(),
    status: z.string(),
    lastDecisionNote: z.string().nullable(),
  })
  .strict();

const approverPendingQueueRowSchema = z
  .object({
    stepId: z.number().int().positive(),
    contractId: z.number().int().positive(),
    contractNumber: z.string(),
    titleEn: z.string(),
    titleAr: z.string().nullable(),
    valueAed: decimalSchema.nullable(),
    requestedAt: isoDateTimeSchema,
    hoursWaiting: decimalSchema,
  })
  .strict();

const recipientMyContractsRowSchema = z
  .object({
    id: z.number().int().positive(),
    contractNumber: z.string(),
    titleEn: z.string(),
    titleAr: z.string().nullable(),
    status: z.string(),
    ourPartyId: z.number().int().positive(),
    counterpartyId: z.null(),
  })
  .strict();

const recipientPendingSignatureRowSchema = z
  .object({
    invitationId: z.number().int().positive(),
    contractId: z.number().int().positive(),
    contractNumber: z.string(),
    sentAt: isoDateTimeSchema,
    expiresAt: isoDateTimeSchema.nullable(),
  })
  .strict();

const dashboardRegulatoryUpdateRowSchema = z
  .object({
    id: z.number().int().positive(),
    titleEn: z.string(),
    severity: z.string(),
    effectiveDate: isoDateSchema.nullable(),
    regulator: z
      .object({
        id: z.number().int().positive(),
        nameEn: z.string(),
      })
      .strict(),
  })
  .strict();

const dashboardOpenImpactRowSchema = z
  .object({
    id: z.number().int().positive(),
    contractId: z.number().int().positive(),
    contractNumber: z.string(),
    regulationTitleEn: z.string(),
    severity: z.string(),
    detectedAt: isoDateTimeSchema,
  })
  .strict();

// ------------------------------------------------------------
// 4. Response schemas — one per fn_ JSONB output
// ------------------------------------------------------------

// 4.1 fn_dashboard_admin (S1 / S13)
export const adminDashboardSnapshotSchema = z
  .object({
    kpis: z
      .object({
        totalContractsActive: nonNegativeIntSchema,
        totalContractsByStatus: z.record(z.string(), nonNegativeIntSchema),
        expiringWithin30d: nonNegativeIntSchema,
        expiringWithin90d: nonNegativeIntSchema,
        pendingApprovals: nonNegativeIntSchema,
        pendingSignatures: nonNegativeIntSchema,
        openRegulatoryImpacts: nonNegativeIntSchema,
        recentAuditEvents: nonNegativeIntSchema,
        totalActiveUsers: nonNegativeIntSchema,
      })
      .strict()
      .refine((k) => k.expiringWithin30d <= k.expiringWithin90d, {
        message:
          'AC-S1-04 monotonic: expiringWithin30d must be <= expiringWithin90d',
        path: ['expiringWithin30d'],
      }),
    trends: z
      .object({
        contractsCreatedByDay: z.array(trendDayCountSchema),
        approvalDecisionsByDay: z.array(approvalDecisionDayPointSchema),
      })
      .strict(),
  })
  .strict();

// 4.2 fn_dashboard_drafter (S2)
export const drafterDashboardSnapshotSchema = z
  .object({
    kpis: z
      .object({
        myDraftsCount: nonNegativeIntSchema,
        awaitingMyActionCount: nonNegativeIntSchema,
        readyToSendCount: nonNegativeIntSchema,
        myRecentlyApprovedCount: nonNegativeIntSchema,
      })
      .strict(),
    lists: z
      .object({
        myDrafts5: z.array(dashboardContractRowSchema).max(5),
        awaitingMyAction5: z.array(drafterAwaitingActionRowSchema).max(5),
      })
      .strict(),
  })
  .strict();

// 4.3 fn_dashboard_approver (S3)
export const approverDashboardSnapshotSchema = z
  .object({
    kpis: z
      .object({
        pendingMyApprovalCount: nonNegativeIntSchema,
        decidedByMeCount: nonNegativeIntSchema,
        averageDecisionHoursMine: decimalSchema.nullable(),
        averageDecisionHoursTeam: decimalSchema.nullable(),
      })
      .strict(),
    lists: z
      .object({
        pendingQueue5: z.array(approverPendingQueueRowSchema).max(5),
      })
      .strict(),
  })
  .strict();

// 4.4 fn_dashboard_legal_counsel (S4)
export const legalCounselDashboardSnapshotSchema = z
  .object({
    kpis: z
      .object({
        regulatoryUpdatesThisWindow: nonNegativeIntSchema,
        openRegulatoryImpacts: nonNegativeIntSchema,
        criticalSeverityCount: nonNegativeIntSchema,
        regulationCatalogSize: nonNegativeIntSchema,
        templateUsageThisWindow: placeholderKpiSchema,
        auditSummary: z.record(z.string(), nonNegativeIntSchema).nullable(),
      })
      .strict(),
    lists: z
      .object({
        recentRegulatoryUpdates5: z.array(dashboardRegulatoryUpdateRowSchema).max(5),
        openImpacts5: z.array(dashboardOpenImpactRowSchema).max(5),
      })
      .strict(),
  })
  .strict();

// 4.5 fn_dashboard_recipient (S5)
export const recipientDashboardSnapshotSchema = z
  .object({
    kpis: z
      .object({
        myContractsCount: nonNegativeIntSchema,
        pendingMySignatureCount: nonNegativeIntSchema,
        signedByMeWindow: nonNegativeIntSchema,
        myObligationsCount: placeholderKpiSchema,
      })
      .strict(),
    lists: z
      .object({
        myContracts5: z.array(recipientMyContractsRowSchema).max(5),
        pendingSignatures5: z.array(recipientPendingSignatureRowSchema).max(5),
      })
      .strict(),
  })
  .strict();

// 4.6 fn_dashboard_router (S6)
export const dashboardKeySchema = z.enum([
  'admin',
  'drafter',
  'approver',
  'legal_counsel',
  'recipient',
  'executive',
]);

export const dashboardRouterResponseSchema = z
  .object({
    userId: z.number().int().positive(),
    primaryRole: z.string(),
    dashboardKey: dashboardKeySchema,
    permissionsSummary: z
      .object({
        canViewAdminDashboard: z.boolean(),
        canViewExecutiveDashboard: z.boolean(),
      })
      .strict(),
  })
  .strict();

// 4.7 fn_dashboard_executive (S7)
export const executiveDashboardSnapshotSchema = z
  .object({
    kpis: z
      .object({
        totalActiveValueAed: decimalSchema,
        contractsByStatus: z.record(z.string(), nonNegativeIntSchema),
        expiryCliffs: z
          .object({
            next30d: nonNegativeIntSchema,
            next60d: nonNegativeIntSchema,
            next90d: nonNegativeIntSchema,
          })
          .strict()
          .refine(
            (e) => e.next30d <= e.next60d && e.next60d <= e.next90d,
            {
              message:
                'AC-S7-03 monotonic: next30d <= next60d <= next90d required',
              path: ['next30d'],
            },
          ),
        topCounterpartiesByValue5: z.array(counterpartyConcentrationRowSchema).max(5),
        valueDistribution: z.array(valueDistributionBucketSchema),
        openRegulatoryImpactsCritical: nonNegativeIntSchema,
        aiCostUsdWindow: decimalSchema.nullable(),
      })
      .strict(),
    trends: z
      .object({
        valueOverTimeByMonth: z.array(trendMonthValueAedSchema),
        contractsCreatedByMonth: z.array(trendMonthCountSchema),
      })
      .strict(),
  })
  .strict();

// 4.8 fn_dashboard_executive_anomalies_history (S8)
export const executiveAnomalySchema = z
  .object({
    id: z.number().int().positive(),
    summaryEn: z.string().nullable(),
    summaryAr: z.string().nullable(),
    severity: z.string(),
    detectedAt: isoDateTimeSchema,
    payload: z.record(z.string(), z.unknown()).nullable(),
  })
  .strict();

export const executiveAnomaliesHistoryResponseSchema = z
  .object({
    anomalies: z.array(executiveAnomalySchema),
  })
  .strict();

// 4.9 fn_dashboard_ai_cost_summary (S11)
export const aiCostSummarySchema = z
  .object({
    totalCostUsdWindow: decimalSchema,
    totalRequestsWindow: nonNegativeIntSchema,
    cacheHitRatioOverall: decimalSchema.nullable(),
    topPromptsByCost5: z.array(aiCostTopPromptRowSchema).max(5),
  })
  .strict()
  .superRefine((s, ctx) => {
    if (s.totalRequestsWindow === 0 && s.cacheHitRatioOverall !== null) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message:
          'cacheHitRatioOverall must be null when totalRequestsWindow = 0 (S2-18 NULL semantic)',
        path: ['cacheHitRatioOverall'],
      });
    }
  });

// 4.10 fn_health_check (S12)
export const healthCheckSnapshotSchema = z
  .object({
    db: z
      .object({
        status: z.enum(['ok', 'degraded']),
        latestMigration: z.number().int().nonnegative().nullable(),
        currentTimestamp: isoDateTimeSchema,
      })
      .strict(),
    ai: z
      .object({
        lastSuccessfulRequestAt: isoDateTimeSchema.nullable(),
        lastFailureAt: isoDateTimeSchema.nullable(),
        estimatedHealthy: z.boolean(),
      })
      .strict(),
    overall: z.enum(['ok', 'degraded', 'unhealthy']),
  })
  .strict();

// ------------------------------------------------------------
// 5. Type aliases mirroring the response schemas (for BE/FE inference)
// ------------------------------------------------------------

export type AdminDashboardSnapshotZ = z.infer<typeof adminDashboardSnapshotSchema>;
export type DrafterDashboardSnapshotZ = z.infer<typeof drafterDashboardSnapshotSchema>;
export type ApproverDashboardSnapshotZ = z.infer<typeof approverDashboardSnapshotSchema>;
export type LegalCounselDashboardSnapshotZ = z.infer<
  typeof legalCounselDashboardSnapshotSchema
>;
export type RecipientDashboardSnapshotZ = z.infer<typeof recipientDashboardSnapshotSchema>;
export type DashboardRouterResponseZ = z.infer<typeof dashboardRouterResponseSchema>;
export type ExecutiveDashboardSnapshotZ = z.infer<typeof executiveDashboardSnapshotSchema>;
export type ExecutiveAnomaliesHistoryResponseZ = z.infer<
  typeof executiveAnomaliesHistoryResponseSchema
>;
export type AiCostSummaryZ = z.infer<typeof aiCostSummarySchema>;
export type HealthCheckSnapshotZ = z.infer<typeof healthCheckSnapshotSchema>;
