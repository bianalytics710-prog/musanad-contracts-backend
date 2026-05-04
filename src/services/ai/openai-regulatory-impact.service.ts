/**
 * S4 — OpenAI integration for /api/v1/ai/regulatory-impact.
 *
 * Streaming SSE. Cache TTL 24h via fn_ai_insight_upsert (entity_type =
 * 'regulatory_update', entity_id = NULL — STATELESS payload-driven).
 *
 * Sensitive data: summaryEn + sampleContracts may contain regulatory text /
 * contract titles — flow through ai_prompt_payload, never logged.
 */
import path from 'node:path';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError } from '../../utils/errors.util';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { estimateUsage } from './_shared/tiktoken-estimator';
import type {
  AiLanguage,
  AiRegulatoryImpactMode,
  AiRegulatoryImpactSampleContract,
} from '../../types/ai.types';

export const PROMPT_ID = 'ai-regulatory-impact' as const;
export const PROMPT_FILE = path.join('prompts', 'ai-regulatory-impact.txt');

export interface RegulatoryImpactContext {
  mode: AiRegulatoryImpactMode;
  language: AiLanguage;
  regulator: string;
  referenceNumber?: string;
  titleEn: string;
  summaryEn?: string;
  effectiveDate?: string;
  complianceDeadline?: string;
  affectedClauseCategories: string[];
  impactedCount?: number;
  sampleContracts: AiRegulatoryImpactSampleContract[];
  impactCategoryName?: string;
  impactCategoryGuidance?: string;
}

const stringifySamples = (samples: AiRegulatoryImpactSampleContract[]): string =>
  samples
    .map(
      (s) =>
        `- ${s.contractNumber} | ${s.contractType} | ${s.titleEn} | AED ${s.valueAed ?? 'n/a'}`,
    )
    .join('\n');

export const buildSystemPrompt = async (
  ctx: RegulatoryImpactContext,
): Promise<string> => {
  const tmpl = await loadPrompt(PROMPT_ID);
  return renderPrompt(tmpl, {
    mode: ctx.mode,
    language: ctx.language,
    langName: ctx.language === 'ar' ? 'Arabic' : ctx.language === 'bilingual' ? 'Bilingual' : 'English',
    regulator: ctx.regulator,
    referenceNumber: ctx.referenceNumber ?? '',
    titleEn: ctx.titleEn,
    summaryEn: ctx.summaryEn ?? '',
    effectiveDate: ctx.effectiveDate ?? '',
    complianceDeadline: ctx.complianceDeadline ?? '',
    affectedClauseCategories: ctx.affectedClauseCategories.join(', ') || '(none)',
    impactedCount: ctx.impactedCount ?? 0,
    sampleContracts: stringifySamples(ctx.sampleContracts),
    impactCategoryName: ctx.impactCategoryName ?? '',
    impactCategoryGuidance: ctx.impactCategoryGuidance ?? '',
  });
};

// ------------------------------------------------------------
// Streaming
// ------------------------------------------------------------

export interface StreamArgs {
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}

export interface StreamResult {
  stream: AsyncGenerator<string, void, void>;
  tokensConsumed: () => number;
  collectedText: () => string;
}

export const streamRegulatoryImpact = (args: StreamArgs): StreamResult => {
  let totalTokens = 0;
  let collected = '';
  const tokensConsumed = (): number => totalTokens;
  const collectedText = (): string => collected;

  async function* iterate(): AsyncGenerator<string, void, void> {
    const e = env();
    const model = e.OPENAI_MODEL_DEFAULT;
    const client = getOpenAIClient();
    let stream;
    try {
      stream = await client.chat.completions.create(
        {
          model,
          temperature: 0.4,
          max_tokens: 3000,
          stream: true,
          stream_options: { include_usage: true },
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
          action: 'aiRegulatoryImpact.stream_init_failed',
          model,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'OpenAI stream init failed',
      );
      throw new InternalError('AI provider error');
    }
    for await (const chunk of stream) {
      const delta = chunk.choices[0]?.delta?.content;
      if (typeof delta === 'string' && delta.length > 0) {
        collected += delta;
        yield delta;
      }
      const usage = (chunk as { usage?: { total_tokens?: number } }).usage;
      if (usage && typeof usage.total_tokens === 'number') {
        totalTokens = usage.total_tokens;
      }
    }
    if (totalTokens === 0) {
      const est = estimateUsage(args.systemPrompt + args.userMessage, collected);
      totalTokens = est.totalTokens;
    }
  }

  return { stream: iterate(), tokensConsumed, collectedText };
};
