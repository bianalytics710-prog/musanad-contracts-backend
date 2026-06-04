/**
 * S3 — OpenAI integration for /api/v1/ai/executive-anomalies.
 *
 * Non-streaming tool-call. Cache TTL 1h via fn_ai_insight_upsert (entity_type
 * = 'executive_dashboard', entity_id = NULL).
 *
 * Sensitive data: stats may contain aggregated values across the tenant —
 * not direct contract bodies, but still scoped through ai_prompt_payload.
 */
import path from 'node:path';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError, ValidationError } from '../../utils/errors.util';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { estimateUsage } from './_shared/tiktoken-estimator';
import { aiExecutiveAnomaliesToolSchema } from '../../schemas/ai.schemas';
import type {
  AiExecutiveAnomaliesPayload,
  AiExecutiveAnomaliesStats,
  AiLanguage,
} from '../../types/ai.types';

export const PROMPT_ID = 'ai-executive-anomalies' as const;
export const PROMPT_FILE = path.join('prompts', 'ai-executive-anomalies.txt');

export interface ExecutiveAnomaliesContext {
  language: AiLanguage;
  stats: AiExecutiveAnomaliesStats;
  dateRange?: { fromDate: string; toDate: string };
}

const stringifyStats = (stats: AiExecutiveAnomaliesStats): string => {
  // Open-shape — controller stringifies + slices to ≤8000 chars before prompt
  // substitution (per types.ts comment + AC-S3-04 size cap).
  const json = JSON.stringify(stats);
  return json.length > 8000 ? json.slice(0, 8000) : json;
};

export const buildSystemPrompt = async (
  ctx: ExecutiveAnomaliesContext,
): Promise<string> => {
  const tmpl = await loadPrompt(PROMPT_ID);
  return renderPrompt(tmpl, {
    language: ctx.language,
    langName: ctx.language === 'ar' ? 'Arabic' : ctx.language === 'bilingual' ? 'Bilingual' : 'English',
    stats: stringifyStats(ctx.stats),
    fromDate: ctx.dateRange?.fromDate ?? '',
    toDate: ctx.dateRange?.toDate ?? '',
    todayIso: new Date().toISOString().slice(0, 10),
  });
};

export interface AnomaliesResult {
  payload: AiExecutiveAnomaliesPayload;
  tokensInput: number;
  tokensOutput: number;
  modelUsed: string;
}

export const detectAnomalies = async (args: {
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}): Promise<AnomaliesResult> => {
  const e = env();
  // Cheaper model — anomaly detection is structural. Mirrors ai_prompt seed
  // (default_model='gpt-4o-mini').
  const model = e.OPENAI_MODEL_FAST;
  const client = getOpenAIClient();
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model,
        temperature: 0.4,
        max_tokens: 1500,
        response_format: {
          type: 'json_schema',
          json_schema: {
            name: 'executive_anomalies',
            strict: true,
            schema: {
              type: 'object',
              additionalProperties: false,
              required: ['anomalies'],
              properties: {
                anomalies: {
                  type: 'array',
                  items: {
                    type: 'object',
                    additionalProperties: false,
                    required: ['insight', 'severity', 'drillDownFilter'],
                    properties: {
                      insight: { type: 'string' },
                      severity: { type: 'string', enum: ['info', 'warning', 'critical'] },
                      drillDownFilter: { type: 'string' },
                    },
                  },
                },
              },
            },
          },
        },
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
        action: 'aiExecutiveAnomalies.tool_call_failed',
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
  const validated = aiExecutiveAnomaliesToolSchema.safeParse(parsed);
  if (!validated.success) {
    throw new ValidationError('AI response did not match anomalies schema');
  }
  // Trim to max 4 (defense-in-depth against any prompt-side regression).
  const trimmed = validated.data.anomalies.slice(0, 4);

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
      insightType: 'executive_anomalies',
      anomalies: trimmed,
      generatedAt: new Date().toISOString(),
    },
    tokensInput,
    tokensOutput,
    modelUsed: model,
  };
};
