/**
 * M4 — AI Features — Zod validation schemas (BE)
 *
 * Mirrors Agent 5 workspace schemas.ts. Used by:
 *   - controllers/ai/*  (body validation via validate middleware)
 *   - controllers/admin/ai-* (query validation via validate middleware)
 *
 * Sensitive fields (selectedText, additions, deletions, modifiedClauses,
 * draftSummary, chatHistory, summaryEn, signedToken) live ONLY on the request
 * body — never logged at the controller layer; pino redact catches as safety
 * net (logger.util.ts SENSITIVE_PATHS).
 */
import { z } from 'zod';

// ------------------------------------------------------------
// 1. Shared enum schemas (must match DB CHECK enums byte-for-byte)
// ------------------------------------------------------------

export const aiLanguageSchema = z.enum(['en', 'ar', 'bilingual']);
export const aiProviderSchema = z.enum(['openai', 'anthropic']);
export const aiRequestOutcomeSchema = z.enum([
  'success',
  'error',
  'timeout',
  'rate_limited',
  'cancelled',
]);

export const aiContractInsightsModeSchema = z.enum([
  'summary',
  'key_terms',
  'risks',
  'obligations',
  'regulatory',
  'rewrite',
]);

export const aiDraftingAssistantModeSchema = z.enum([
  'suggest',
  'explain',
  'rewrite',
  'chat',
]);
export const aiDraftingAssistantToneSchema = z.enum([
  'simpler',
  'formal',
  'stronger',
  'balanced',
]);
export const aiRegulatoryImpactModeSchema = z.enum(['explain', 'amendment']);

export const aiInsightEntityTypeSchema = z.enum([
  'contract',
  'contract_version',
  'regulatory_update',
  'regulatory_update_summary',
  'executive_dashboard',
]);

export const aiInsightTypeSchema = z.enum([
  'contract_summary',
  'contract_key_terms',
  'contract_risks',
  'contract_obligations',
  'contract_regulatory',
  'contract_rewrite',
  'version_diff_summary',
  'executive_anomalies',
  'regulatory_impact_explain',
  'regulatory_impact_amendment',
  'regulatory_impact_summary',
]);

export const m4PromptIdSchema = z.enum([
  'ai-contract-insights',
  'ai-drafting-assistant',
  'ai-executive-anomalies',
  'ai-regulatory-impact',
  'ai-regulatory-impact-summary',
  'ai-version-diff-summary',
]);

// ------------------------------------------------------------
// 2. Pagination / common
// ------------------------------------------------------------

const paginationQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50).optional(),
});

const isoDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Must be ISO date YYYY-MM-DD');

// ------------------------------------------------------------
// 3. ai_prompt — list query
// ------------------------------------------------------------

export const aiPromptListQuerySchema = z.object({
  includeInactive: z.coerce.boolean().default(false).optional(),
});

// ------------------------------------------------------------
// 4. ai_insight — admin list query
// ------------------------------------------------------------

export const aiInsightListQuerySchema = paginationQuerySchema.extend({
  entityType: aiInsightEntityTypeSchema.optional(),
  insightType: aiInsightTypeSchema.optional(),
  language: aiLanguageSchema.optional(),
  provider: aiProviderSchema.optional(),
  includeExpired: z.coerce.boolean().default(false).optional(),
});

// ------------------------------------------------------------
// 5. ai_request_log — admin list + cost report queries
// ------------------------------------------------------------

export const aiRequestLogListQuerySchema = paginationQuerySchema
  .extend({
    actorUserId: z.coerce.number().int().positive().optional(),
    promptId: m4PromptIdSchema.optional(),
    outcome: aiRequestOutcomeSchema.optional(),
    fromDate: isoDateSchema.optional(),
    toDate: isoDateSchema.optional(),
  })
  .superRefine((value, ctx) => {
    if (value.fromDate && value.toDate && value.fromDate > value.toDate) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['fromDate'],
        message: 'fromDate must be on or before toDate',
      });
    }
  });

export const aiCostReportQuerySchema = z
  .object({
    fromDate: isoDateSchema,
    toDate: isoDateSchema,
    groupByUser: z.coerce.boolean().default(false).optional(),
  })
  .superRefine((value, ctx) => {
    if (value.fromDate > value.toDate) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['fromDate'],
        message: 'fromDate must be on or before toDate',
      });
    }
    // 90-day window enforced (AC-S12-04)
    const from = new Date(value.fromDate);
    const to = new Date(value.toDate);
    const diffDays = Math.floor((to.getTime() - from.getTime()) / 86_400_000);
    if (diffDays > 90) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['date_range'],
        message: 'Date range must not exceed 90 days',
      });
    }
  });

// ============================================================
// 6. Per-prompt SERVICE REQUEST schemas
// ============================================================

// ----- 6.1 ai-contract-insights (S1) -----
export const aiContractInsightsRequestSchema = z
  .object({
    contractId: z.number().int().positive(),
    mode: aiContractInsightsModeSchema,
    language: aiLanguageSchema,
    selectedText: z.string().max(20_000).optional(),
  })
  .superRefine((value, ctx) => {
    if (
      value.mode === 'rewrite' &&
      (!value.selectedText || value.selectedText.trim().length === 0)
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['selectedText'],
        message: 'selectedText is required for rewrite mode',
      });
    }
  });

// ----- 6.2 ai-drafting-assistant (S2) -----
export const aiDraftingAssistantChatTurnSchema = z.object({
  role: z.enum(['user', 'assistant']),
  content: z.string().max(4000),
});

export const aiDraftingAssistantRequestSchema = z
  .object({
    mode: aiDraftingAssistantModeSchema,
    contractType: z.string().min(1).max(120),
    partyA: z.string().min(1).max(200),
    partyB: z.string().max(200).optional(),
    draftSummary: z.string().max(8000),
    existingClauseCategories: z.array(z.string().max(120)).max(60),
    language: aiLanguageSchema,
    selectedText: z.string().max(20_000).optional(),
    tone: aiDraftingAssistantToneSchema.optional(),
    chatHistory: z.array(aiDraftingAssistantChatTurnSchema).max(20).optional(),
  })
  .superRefine((value, ctx) => {
    if (value.mode === 'rewrite' && !value.tone) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['tone'],
        message: 'tone is required for rewrite mode',
      });
    }
    if (
      (value.mode === 'explain' || value.mode === 'rewrite') &&
      (!value.selectedText || value.selectedText.trim().length === 0)
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['selectedText'],
        message: 'selectedText is required',
      });
    }
  });

// ----- 6.3 ai-executive-anomalies (S3) -----
export const aiExecutiveAnomaliesStatsSchema = z
  .object({
    totalActiveValueAed: z.number().nonnegative().optional(),
    contractsByStatus: z.record(z.string(), z.number()).optional(),
    expiryCliffs: z
      .array(
        z.object({
          window: z.string(),
          count: z.number().int().nonnegative(),
        }),
      )
      .optional(),
    supplierConcentration: z
      .array(
        z.object({
          supplier: z.string(),
          share: z.number().min(0).max(1),
        }),
      )
      .optional(),
  })
  .passthrough();

export const aiExecutiveAnomaliesRequestSchema = z.object({
  stats: aiExecutiveAnomaliesStatsSchema,
  dateRange: z
    .object({
      fromDate: isoDateSchema,
      toDate: isoDateSchema,
    })
    .optional(),
  language: aiLanguageSchema,
});

// ----- 6.4 ai-regulatory-impact (S4) -----
export const aiRegulatoryImpactSampleContractSchema = z.object({
  contractNumber: z.string().min(1).max(120),
  titleEn: z.string().min(1).max(500),
  contractType: z.string().min(1).max(120),
  valueAed: z.number().nullable().optional(),
});

export const aiRegulatoryImpactRequestSchema = z.object({
  mode: aiRegulatoryImpactModeSchema,
  regulator: z.string().min(1).max(200),
  referenceNumber: z.string().max(120).optional(),
  titleEn: z.string().min(1).max(500),
  summaryEn: z.string().max(8000).optional(),
  effectiveDate: isoDateSchema.optional(),
  complianceDeadline: isoDateSchema.optional(),
  affectedClauseCategories: z.array(z.string().max(120)).max(60),
  impactedCount: z.number().int().nonnegative().optional(),
  sampleContracts: z.array(aiRegulatoryImpactSampleContractSchema).max(5),
  language: aiLanguageSchema,
  impactCategoryName: z.string().max(120).optional(),
  impactCategoryGuidance: z.string().max(8000).optional(),
});

// ----- 6.5 ai-regulatory-impact-summary (S5) -----
export const aiRegulatoryImpactSummaryContractSchema = z.object({
  contractNumber: z.string().min(1).max(120),
  title: z.string().min(1).max(500),
  type: z.string().min(1).max(120),
  valueAed: z.number().nullable().optional(),
  impactScore: z.number().nullable().optional(),
});

export const aiRegulatoryImpactSummaryRequestSchema = z.object({
  regulator: z.string().min(1).max(200),
  title: z.string().min(1).max(500),
  severity: z.string().min(1).max(40),
  referenceNumber: z.string().max(120).optional(),
  summary: z.string().max(8000).optional(),
  contracts: z
    .array(aiRegulatoryImpactSummaryContractSchema)
    .min(1, 'contracts must contain 1-20 entries')
    .max(20, 'contracts must contain 1-20 entries'),
  language: z.enum(['en', 'ar']),
  signedToken: z.string().min(20).max(4096).optional(),
});

// ----- 6.6 ai-version-diff-summary (S6) -----
export const aiVersionDiffSummaryRequestSchema = z
  .object({
    contractId: z.number().int().positive(),
    leftVersionId: z.number().int().positive(),
    rightVersionId: z.number().int().positive(),
    additions: z.string().max(9000),
    deletions: z.string().max(9000),
    modifiedClauses: z
      .array(
        z.object({
          clauseName: z.string().max(200),
          before: z.string().max(9000).optional(),
          after: z.string().max(9000).optional(),
        }),
      )
      .max(60),
    language: aiLanguageSchema,
  })
  .superRefine((value, ctx) => {
    if (value.leftVersionId === value.rightVersionId) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['leftVersionId'],
        message: 'leftVersionId must differ from rightVersionId',
      });
    }
  });

// ============================================================
// 7. Tool-call OUTPUT schemas (post-call validation guards)
// ============================================================

export const aiContractRisksToolSchema = z.object({
  risks: z
    .array(
      z.object({
        title: z.string().min(1).max(300),
        severity: z.enum(['high', 'medium', 'low']),
        // clauseAnchor / clauseExcerpt are best-effort — gpt-4o-mini often
        // returns null when the risk is about a missing clause. FE handles
        // null gracefully (no jump target). Mirror other tabs' leniency.
        clauseAnchor: z.string().max(300).nullable().optional(),
        clauseExcerpt: z.string().max(2000).nullable().optional(),
        rationale: z.string().min(1).max(2000),
      }),
    )
    .max(7),
});

export const aiContractKeyTermsToolSchema = z.object({
  keyTerms: z
    .array(
      z.object({
        label: z.string().min(1).max(200),
        value: z.string().min(1).max(2000),
        clauseAnchor: z.string().max(300).nullable().optional(),
        clauseExcerpt: z.string().max(2000).nullable().optional(),
      }),
    )
    .max(20),
});

export const aiContractObligationsToolSchema = z.object({
  obligations: z
    .array(
      z.object({
        party: z.string().min(1).max(200),
        obligation: z.string().min(1).max(2000),
        deadline: z.string().max(120).nullable().optional(),
        clauseAnchor: z.string().max(300).nullable().optional(),
      }),
    )
    .max(40),
});

export const aiContractRegulatoryToolSchema = z.object({
  regulations: z
    .array(
      z.object({
        citation: z.string().min(1).max(500),
        relevance: z.string().min(1).max(2000),
        clauseAnchor: z.string().max(300).nullable().optional(),
      }),
    )
    .max(20),
});

export const aiExecutiveAnomaliesToolSchema = z.object({
  anomalies: z
    .array(
      z.object({
        insight: z.string().min(1).max(300),
        severity: z.enum(['info', 'warning', 'critical']),
        drillDownFilter: z.string().max(500),
      }),
    )
    .max(4),
});

export const aiRegulatoryImpactSummaryToolSchema = z.object({
  executive: z.string().min(1).max(2000),
  keyChanges: z.array(z.string().min(1).max(500)).min(3).max(5),
  recommendedActions: z.array(z.string().min(1).max(500)).min(4).max(6),
});

export const aiDraftingAssistantSuggestToolSchema = z.object({
  suggestions: z
    .array(
      z.object({
        kind: z.enum(['missing_clause', 'weak_clause', 'regulatory']),
        title: z.string().min(1).max(300),
        rationale: z.string().min(1).max(2000),
        proposedText: z.string().min(1).max(8000),
      }),
    )
    .max(4),
});

// ============================================================
// 7b. R-LC7-D1 — Impact Watch AI request + tool schemas
// ============================================================

export const aiImpactSignalIdParamSchema = z.object({
  id: z.coerce.number().int().positive('Must be a positive integer'),
});
export type AiImpactSignalIdParamInferred = z.infer<typeof aiImpactSignalIdParamSchema>;

export const aiImpactSignalExplainRequestSchema = z.object({
  language: aiLanguageSchema.optional().default('en'),
});
export type AiImpactSignalExplainRequestInput = z.infer<
  typeof aiImpactSignalExplainRequestSchema
>;

export const aiImpactSignalSuggestAmendmentRequestSchema = z.object({
  language: aiLanguageSchema.optional().default('en'),
  contractId: z.coerce.number().int().positive().optional(),
});
export type AiImpactSignalSuggestAmendmentRequestInput = z.infer<
  typeof aiImpactSignalSuggestAmendmentRequestSchema
>;

/** Output shape for fn_impact_signal explain endpoint. */
export const aiImpactSignalExplainToolSchema = z.object({
  summary: z.string().min(1).max(2000),
  whyItMatters: z.string().min(1).max(2000),
  perContractImpacts: z
    .array(
      z.object({
        contractId: z.number().int().positive(),
        contractNumber: z.string().min(1).max(100),
        explanation: z.string().min(1).max(1000),
      }),
    )
    .max(20),
});
export type AiImpactSignalExplainPayload = z.infer<typeof aiImpactSignalExplainToolSchema>;

/** Output shape for fn_impact_signal suggest-amendment endpoint. */
export const aiImpactSignalSuggestAmendmentToolSchema = z.object({
  amendmentSnippets: z
    .array(
      z.object({
        clauseAnchor: z.string().min(1).max(80),
        rationale: z.string().min(1).max(1000),
        suggestedText: z.string().min(1).max(4000),
      }),
    )
    .min(1)
    .max(6),
});
export type AiImpactSignalSuggestAmendmentPayload = z.infer<
  typeof aiImpactSignalSuggestAmendmentToolSchema
>;

// ------------------------------------------------------------
// 7b. Title translate — POST /api/v1/ai/translate-title
// Compose Step 2 fires this on EN-title blur to auto-fill AR.
// ------------------------------------------------------------
export const aiTranslateTitleRequestSchema = z.object({
  text: z.string().trim().min(1).max(200),
  source: z.enum(['en', 'ar']),
  target: z.enum(['en', 'ar']),
});
export type AiTranslateTitleRequestInput = z.infer<typeof aiTranslateTitleRequestSchema>;

// ============================================================
// 8. Inferred types (re-exports for convenience)
// ============================================================

export type AiContractInsightsRequestInput = z.infer<typeof aiContractInsightsRequestSchema>;
export type AiDraftingAssistantRequestInput = z.infer<typeof aiDraftingAssistantRequestSchema>;
export type AiExecutiveAnomaliesRequestInput = z.infer<typeof aiExecutiveAnomaliesRequestSchema>;
export type AiRegulatoryImpactRequestInput = z.infer<typeof aiRegulatoryImpactRequestSchema>;
export type AiRegulatoryImpactSummaryRequestInput = z.infer<
  typeof aiRegulatoryImpactSummaryRequestSchema
>;
export type AiVersionDiffSummaryRequestInput = z.infer<typeof aiVersionDiffSummaryRequestSchema>;
export type AiPromptListQueryInput = z.infer<typeof aiPromptListQuerySchema>;
export type AiInsightListQueryInput = z.infer<typeof aiInsightListQuerySchema>;
export type AiRequestLogListQueryInput = z.infer<typeof aiRequestLogListQuerySchema>;
export type AiCostReportQueryInput = z.infer<typeof aiCostReportQuerySchema>;
