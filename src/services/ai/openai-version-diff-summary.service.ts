/**
 * S6 — OpenAI integration for /api/v1/ai/version-diff-summary.
 *
 * Non-streaming. Cache TTL 7d via fn_ai_insight_upsert (entity_type =
 * 'contract_version', entity_id = rightVersionId). Persists summary to
 * contract_version.diff_summary via fn_contract_version_diff_summary_persist
 * (DEFINER carve-out — see DB design DN-3).
 *
 * Sensitive data: additions / deletions / modifiedClauses are full version
 * deltas — flow through ai_prompt_payload. NEVER logged.
 */
import path from 'node:path';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError } from '../../utils/errors.util';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { estimateUsage } from './_shared/tiktoken-estimator';
import type { AiLanguage, AiVersionDiffSummaryPayload } from '../../types/ai.types';

export const PROMPT_ID = 'ai-version-diff-summary' as const;
export const PROMPT_FILE = path.join('prompts', 'ai-version-diff-summary.txt');

export interface VersionDiffSummaryContext {
  language: AiLanguage;
  contractId: number;
  leftVersionId: number;
  rightVersionId: number;
  additions: string;
  deletions: string;
  modifiedClauses: Array<{ clauseName: string; before?: string; after?: string }>;
}

const sliceField = (s: string | undefined, max: number): string => {
  const v = s ?? '';
  return v.length > max ? v.slice(0, max) : v;
};

const stringifyModifiedClauses = (
  modifiedClauses: VersionDiffSummaryContext['modifiedClauses'],
): string =>
  modifiedClauses
    .map(
      (c) =>
        `### ${c.clauseName}\nBEFORE:\n${sliceField(c.before, 2000)}\nAFTER:\n${sliceField(c.after, 2000)}`,
    )
    .join('\n\n');

export const buildSystemPrompt = async (
  ctx: VersionDiffSummaryContext,
): Promise<string> => {
  const tmpl = await loadPrompt(PROMPT_ID);
  return renderPrompt(tmpl, {
    language: ctx.language,
    langName: ctx.language === 'ar' ? 'Arabic' : ctx.language === 'bilingual' ? 'Bilingual' : 'English',
    contractId: ctx.contractId,
    leftVersionId: ctx.leftVersionId,
    rightVersionId: ctx.rightVersionId,
    additions: sliceField(ctx.additions, 9000),
    deletions: sliceField(ctx.deletions, 9000),
    modifiedClauses: stringifyModifiedClauses(ctx.modifiedClauses),
  });
};

export interface DiffSummaryResult {
  payload: AiVersionDiffSummaryPayload;
  /** Post-processed summary text — 1-line headline + max 5 bullets prefixed with `•`. */
  summary: string;
  tokensInput: number;
  tokensOutput: number;
  modelUsed: string;
}

const postProcessSummary = (raw: string): string => {
  // 1-line headline + at most 5 bullets prefixed with `•`. Mirrors AC-S6 rule.
  const lines = raw.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) return '';
  const headline = lines[0] ?? '';
  const bullets = lines
    .slice(1)
    .map((l) => l.replace(/^[-*•]\s*/, ''))
    .filter(Boolean)
    .slice(0, 5);
  if (bullets.length === 0) return headline;
  return [headline, ...bullets.map((b) => `• ${b}`)].join('\n');
};

export const generateDiffSummary = async (args: {
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}): Promise<DiffSummaryResult> => {
  const e = env();
  const model = e.OPENAI_MODEL_FAST; // gpt-4o-mini per ai_prompt seed
  const client = getOpenAIClient();
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model,
        temperature: 0.4,
        max_tokens: 1200,
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
        action: 'aiVersionDiffSummary.failed',
        model,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'OpenAI call failed',
    );
    throw new InternalError('AI provider error');
  }
  const raw = completion.choices[0]?.message?.content ?? '';
  const summary = postProcessSummary(raw);

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
    payload: { insightType: 'version_diff_summary', summary },
    summary,
    tokensInput,
    tokensOutput,
    modelUsed: model,
  };
};
