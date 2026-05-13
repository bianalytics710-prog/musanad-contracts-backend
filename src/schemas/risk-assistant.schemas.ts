/**
 * M15 / CR-G — AI Risk Assistant request body schema.
 *
 * Applied to POST /api/v1/ai/risk-assistant/ask body BEFORE SSE headers
 * are sent, so Zod validation errors return 400 JSON (not SSE stream).
 *
 * SENSITIVE: query and filters are Pino-redacted from all logs.
 * Non-streaming fallback query param also validated here.
 */
import { z } from 'zod';

/** Valid persona values — must match ai_prompt.prompt_id suffix pattern. */
export const RISK_ASSISTANT_PERSONAS = [
  'executive',
  'legal_counsel',
  'compliance_esg',
  'operations',
  'finance_treasury',
  'procurement',
] as const;

export type RiskAssistantPersonaEnum = typeof RISK_ASSISTANT_PERSONAS[number];

/**
 * Main request body schema for POST /api/v1/ai/risk-assistant/ask.
 * Validates BEFORE any SSE headers are set so failures return 400 JSON.
 */
export const riskAssistantAskSchema = z.object({
  /**
   * Free-text natural-language question.
   * SENSITIVE — never log verbatim (Pino redact: req.body.query).
   */
  query: z
    .string({ required_error: 'query is required' })
    .min(1, 'query must not be empty')
    .max(2000, 'query must be at most 2000 characters'),

  /**
   * Optional persona context. Derived from caller's JWT role when omitted.
   * Maps to ai_prompt.prompt_id = 'risk_assistant.qa_<persona>'.
   */
  persona: z
    .enum(RISK_ASSISTANT_PERSONAS, {
      errorMap: () => ({
        message: `persona must be one of: ${RISK_ASSISTANT_PERSONAS.join(', ')}`,
      }),
    })
    .optional(),

  /**
   * Optional ACL-narrowing and dashboard filter context.
   * SENSITIVE — Pino-redacted (req.body.filters).
   */
  filters: z
    .object({
      contractIds: z.array(z.string()).optional(),
      contractType: z.string().optional(),
      emirate: z.string().optional(),
      riskKind: z.string().optional(),
    })
    .optional(),
});

export type RiskAssistantAskInput = z.infer<typeof riskAssistantAskSchema>;

/**
 * Query parameter schema for non-streaming fallback (stream=false).
 */
export const riskAssistantQuerySchema = z.object({
  stream: z
    .string()
    .optional()
    .transform((v) => v !== 'false'),
});

export type RiskAssistantQueryInput = z.infer<typeof riskAssistantQuerySchema>;
