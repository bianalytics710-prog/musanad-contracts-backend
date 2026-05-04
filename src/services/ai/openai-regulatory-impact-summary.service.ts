/**
 * S5 — OpenAI integration for /api/v1/ai/regulatory-impact-summary.
 *
 * Non-streaming tool-call. PUBLIC endpoint (signed-PDF-token auth at
 * Express middleware). Cache TTL 30d, content-addressed by SHA-256 of
 * canonicalised inputs (entity_type='regulatory_update_summary',
 * entity_id=NULL).
 *
 * Sensitive data: contract titles + summary text flow through
 * ai_prompt_payload. signedToken is redacted at logger.util.ts.
 */
import path from 'node:path';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError, ValidationError } from '../../utils/errors.util';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { estimateUsage } from './_shared/tiktoken-estimator';
import { aiRegulatoryImpactSummaryToolSchema } from '../../schemas/ai.schemas';
import type {
  AiRegulatoryImpactSummaryContract,
  AiRegulatoryImpactSummaryPayload,
} from '../../types/ai.types';

export const PROMPT_ID = 'ai-regulatory-impact-summary' as const;
export const PROMPT_FILE = path.join('prompts', 'ai-regulatory-impact-summary.txt');

export interface RegulatoryImpactSummaryContext {
  language: 'en' | 'ar';
  regulator: string;
  title: string;
  severity: string;
  referenceNumber?: string;
  summary?: string;
  contracts: AiRegulatoryImpactSummaryContract[];
}

const stringifyContracts = (contracts: AiRegulatoryImpactSummaryContract[]): string =>
  contracts
    .map(
      (c) =>
        `- ${c.contractNumber} | ${c.type} | ${c.title} | AED ${c.valueAed ?? 'n/a'} | impact:${c.impactScore ?? 'n/a'}`,
    )
    .join('\n');

export const buildSystemPrompt = async (
  ctx: RegulatoryImpactSummaryContext,
): Promise<string> => {
  const tmpl = await loadPrompt(PROMPT_ID);
  return renderPrompt(tmpl, {
    language: ctx.language,
    langName: ctx.language === 'ar' ? 'Arabic' : 'English',
    regulator: ctx.regulator,
    title: ctx.title,
    severity: ctx.severity,
    referenceNumber: ctx.referenceNumber ?? '',
    summary: ctx.summary ?? '',
    contracts: stringifyContracts(ctx.contracts),
    contractCount: ctx.contracts.length,
  });
};

export interface SummaryResult {
  payload: AiRegulatoryImpactSummaryPayload;
  tokensInput: number;
  tokensOutput: number;
  modelUsed: string;
}

export const generateSummary = async (args: {
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}): Promise<SummaryResult> => {
  const e = env();
  const model = e.OPENAI_MODEL_DEFAULT;
  const client = getOpenAIClient();
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model,
        temperature: 0.3,
        max_tokens: 2000,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: args.systemPrompt },
          { role: 'user', content: args.userMessage },
        ],
      },
      args.abortSignal ? { signal: args.abortSignal } : undefined,
    );
  } catch (err) {
    logger.error(
      {
        action: 'aiRegulatoryImpactSummary.tool_call_failed',
        model,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'OpenAI tool call failed',
    );
    throw new InternalError('AI provider error');
  }
  const raw = completion.choices[0]?.message?.content ?? '';
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ValidationError('AI response was not valid JSON');
  }
  const validated = aiRegulatoryImpactSummaryToolSchema.safeParse(parsed);
  if (!validated.success) {
    throw new ValidationError('AI response did not match summary schema');
  }

  const promptTokens = completion.usage?.prompt_tokens;
  const completionTokens = completion.usage?.completion_tokens;
  const tokensInput =
    typeof promptTokens === 'number'
      ? promptTokens
      : estimateUsage(args.systemPrompt + args.userMessage, '').promptTokens;
  const tokensOutput =
    typeof completionTokens === 'number'
      ? completionTokens
      : estimateUsage('', raw).completionTokens;

  return {
    payload: {
      insightType: 'regulatory_impact_summary',
      executive: validated.data.executive,
      keyChanges: validated.data.keyChanges,
      recommendedActions: validated.data.recommendedActions,
    },
    tokensInput,
    tokensOutput,
    modelUsed: model,
  };
};
