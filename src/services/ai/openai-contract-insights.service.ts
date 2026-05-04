/**
 * S1 — OpenAI integration for /api/v1/ai/contract-insights.
 *
 * Modes:
 *   - summary, rewrite        → SSE streaming (mirror M3 SignerQa)
 *   - key_terms, risks,
 *     obligations, regulatory → non-streaming tool-call JSON
 *
 * Cache TTL: 24h via fn_ai_insight_upsert (default_ttl_seconds from ai_prompt
 * — controller can override).
 *
 * Sensitive data:
 *   - selectedText (rewrite input) is part of ai_prompt_payload — pino redact
 *     intercepts at controller boundary. NEVER logged here.
 *   - System + user prompts NEVER stored to DB; only the response payload is
 *     persisted to ai_insight (which is itself redacted in audit trigger).
 */
import path from 'node:path';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError, ValidationError } from '../../utils/errors.util';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { estimateUsage } from './_shared/tiktoken-estimator';
import {
  aiContractKeyTermsToolSchema,
  aiContractObligationsToolSchema,
  aiContractRegulatoryToolSchema,
  aiContractRisksToolSchema,
} from '../../schemas/ai.schemas';
import type {
  AiContractInsightsMode,
  AiContractKeyTermsPayload,
  AiContractObligationsPayload,
  AiContractRegulatoryPayload,
  AiContractRisksPayload,
  AiLanguage,
} from '../../types/ai.types';

export const PROMPT_ID = 'ai-contract-insights' as const;
export const PROMPT_FILE = path.join('prompts', 'ai-contract-insights.txt');

// ------------------------------------------------------------
// Prompt context (used by both streaming + tool-call paths)
// ------------------------------------------------------------

export interface ContractInsightsContext {
  mode: AiContractInsightsMode;
  language: AiLanguage;
  contractNumber: string;
  contractType: string;
  titleEn: string;
  ourPartyName: string;
  counterpartyName: string;
  valueAed: number | null;
  startDate: string | null;
  endDate: string | null;
  bodyExcerpt: string;
  /** Required for mode='rewrite' only. SENSITIVE — NEVER log. */
  selectedText?: string;
}

/**
 * Build the rendered system prompt. The prompt body is loaded verbatim
 * from prompts/ai-contract-insights.txt and {{placeholders}} are
 * substituted; the prompt text itself is never edited.
 */
export const buildSystemPrompt = async (
  ctx: ContractInsightsContext,
): Promise<string> => {
  const tmpl = await loadPrompt(PROMPT_ID);
  return renderPrompt(tmpl, {
    mode: ctx.mode,
    language: ctx.language,
    langName: ctx.language === 'ar' ? 'Arabic' : ctx.language === 'bilingual' ? 'Bilingual' : 'English',
    contractNumber: ctx.contractNumber,
    contractType: ctx.contractType,
    titleEn: ctx.titleEn,
    ourPartyName: ctx.ourPartyName,
    counterpartyName: ctx.counterpartyName,
    valueAed: ctx.valueAed,
    startDate: ctx.startDate,
    endDate: ctx.endDate,
    bodyExcerpt: ctx.bodyExcerpt,
    selectedText: ctx.selectedText ?? '',
  });
};

// ------------------------------------------------------------
// Streaming (mode='summary' | 'rewrite')
// ------------------------------------------------------------

export interface StreamArgs {
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}

export interface StreamResult {
  stream: AsyncGenerator<string, void, void>;
  tokensConsumed: () => number;
  /** Best-effort accumulated text — used to populate ai_insight payload after stream end. */
  collectedText: () => string;
}

export const streamInsights = (args: StreamArgs): StreamResult => {
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
          max_tokens: 4000,
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
          action: 'aiContractInsights.stream_init_failed',
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

    // BE-OI-2 fallback — when upstream omits usage, estimate from text.
    if (totalTokens === 0) {
      const est = estimateUsage(args.systemPrompt + args.userMessage, collected);
      totalTokens = est.totalTokens;
      logger.warn(
        {
          action: 'aiContractInsights.usage_missing',
          model,
          estimatedTotal: totalTokens,
        },
        'OpenAI stream completed without usage chunk; using char-based estimator',
      );
    }
  }

  return { stream: iterate(), tokensConsumed, collectedText };
};

// ------------------------------------------------------------
// Tool-call (non-streaming) — modes: key_terms, risks, obligations, regulatory
// ------------------------------------------------------------

export type ToolCallPayload =
  | AiContractKeyTermsPayload
  | AiContractRisksPayload
  | AiContractObligationsPayload
  | AiContractRegulatoryPayload;

export interface ToolCallResult {
  payload: ToolCallPayload;
  tokensInput: number;
  tokensOutput: number;
  modelUsed: string;
}

const parseToolJson = (raw: string): unknown => {
  try {
    return JSON.parse(raw);
  } catch {
    throw new ValidationError('AI response was not valid JSON');
  }
};

export const callToolMode = async (args: {
  mode: 'key_terms' | 'risks' | 'obligations' | 'regulatory';
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}): Promise<ToolCallResult> => {
  const e = env();
  const model = e.OPENAI_MODEL_DEFAULT;
  const client = getOpenAIClient();
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model,
        temperature: 0.4,
        max_tokens: 4000,
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
        action: 'aiContractInsights.tool_call_failed',
        mode: args.mode,
        model,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'OpenAI tool call failed',
    );
    throw new InternalError('AI provider error');
  }
  const raw = completion.choices[0]?.message?.content ?? '';
  const parsed = parseToolJson(raw);

  let payload: ToolCallPayload;
  switch (args.mode) {
    case 'key_terms': {
      const validated = aiContractKeyTermsToolSchema.safeParse(parsed);
      if (!validated.success) throw new ValidationError('AI response did not match key_terms schema');
      payload = {
        insightType: 'contract_key_terms',
        keyTerms: validated.data.keyTerms.map((t) => ({
          label: t.label,
          value: t.value,
          clauseAnchor: t.clauseAnchor ?? null,
          clauseExcerpt: t.clauseExcerpt ?? null,
        })),
      };
      break;
    }
    case 'risks': {
      const validated = aiContractRisksToolSchema.safeParse(parsed);
      if (!validated.success) throw new ValidationError('AI response did not match risks schema');
      payload = { insightType: 'contract_risks', risks: validated.data.risks };
      break;
    }
    case 'obligations': {
      const validated = aiContractObligationsToolSchema.safeParse(parsed);
      if (!validated.success) throw new ValidationError('AI response did not match obligations schema');
      payload = {
        insightType: 'contract_obligations',
        obligations: validated.data.obligations.map((o) => ({
          party: o.party,
          obligation: o.obligation,
          deadline: o.deadline ?? null,
          clauseAnchor: o.clauseAnchor ?? null,
        })),
      };
      break;
    }
    case 'regulatory': {
      const validated = aiContractRegulatoryToolSchema.safeParse(parsed);
      if (!validated.success) throw new ValidationError('AI response did not match regulatory schema');
      payload = {
        insightType: 'contract_regulatory',
        regulations: validated.data.regulations.map((r) => ({
          citation: r.citation,
          relevance: r.relevance,
          clauseAnchor: r.clauseAnchor ?? null,
        })),
      };
      break;
    }
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

  return { payload, tokensInput, tokensOutput, modelUsed: model };
};
