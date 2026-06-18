/**
 * party-intelligence.service.ts
 *
 * Counterparty drafting/review intelligence. The deterministic metrics come
 * from fn_party_drafting_intelligence (mig 707); on top of them we generate a
 * short, grounded AI note (gpt-4o-mini) that tells a drafter/reviewer what to
 * watch for with this counterparty.
 *
 * The AI summary is generated live (no ai_insight cache — the FE caches via
 * React Query) and every call is logged to ai_request_log for governance. If
 * the AI call fails, we still return the metrics with summary = null; the
 * intelligence is useful without the prose.
 */
import { db } from '../database/client';
import { env } from '../utils/env-validation.util';
import { logger } from '../utils/logger.util';
import { getOpenAIClient } from './ai/_shared/openai-client';
import { loadPrompt, renderPrompt } from './ai/_shared/prompt-loader';
import { recordAiTelemetry } from './ai/_shared/telemetry-middleware';

const PROMPT_ID = 'party_intelligence__drafting';

export interface PartyIntelligenceResult {
  metrics: Record<string, unknown>;
  summary: string | null;
}

type Lang = 'en' | 'ar';

const asArrayLabel = (
  arr: unknown,
  key: string,
): string => {
  if (!Array.isArray(arr) || arr.length === 0) return 'none';
  return arr
    .map((e) => {
      const o = e as Record<string, unknown>;
      const label = String(o[key] ?? '').replace(/_/g, ' ');
      const n = o['n'];
      return n ? `${label} (${n})` : label;
    })
    .filter(Boolean)
    .join(', ');
};

const buildSummary = async (
  metrics: Record<string, unknown>,
  language: Lang,
  actorId: number,
): Promise<string | null> => {
  const party = (metrics['party'] ?? {}) as Record<string, unknown>;
  const af = (metrics['approvalFriction'] ?? {}) as Record<string, unknown>;
  const rc = (metrics['riskCases'] ?? {}) as Record<string, unknown>;

  // No history → skip the AI call entirely; the card shows the empty state.
  if (Number(metrics['priorContracts'] ?? 0) === 0) return null;

  const tmpl = await loadPrompt(PROMPT_ID);
  const prompt = renderPrompt(tmpl, {
    partyName: String(party['nameEn'] ?? 'this counterparty'),
    langName: language === 'ar' ? 'Arabic' : 'English',
    priorContracts: metrics['priorContracts'] as number,
    activeContracts: metrics['activeContracts'] as number,
    avgVersions: metrics['avgVersions'] as number,
    portfolioAvgVersions: metrics['portfolioAvgVersions'] as number,
    rejected: af['rejected'] as number,
    resubmitted: af['resubmitted'] as number,
    avgNegotiationDays: metrics['avgNegotiationDays'] as number,
    riskTotal: rc['total'] as number,
    riskOpen: rc['open'] as number,
    riskTypes: asArrayLabel(rc['byType'], 'type'),
    redlineClauses: asArrayLabel(metrics['topRedlineClauses'], 'heading'),
  });

  const e = env();
  const model = e.OPENAI_MODEL_FAST;
  const started = Date.now();
  let outcome: 'success' | 'error' = 'success';
  let tokensInput: number | null = null;
  let tokensOutput: number | null = null;
  let errorMessage: string | null = null;
  try {
    const completion = await getOpenAIClient().chat.completions.create({
      model,
      temperature: 0.3,
      max_tokens: 240,
      messages: [{ role: 'user', content: prompt }],
    });
    tokensInput = completion.usage?.prompt_tokens ?? null;
    tokensOutput = completion.usage?.completion_tokens ?? null;
    const text = (completion.choices[0]?.message?.content ?? '').trim();
    return text.length > 0 ? text : null;
  } catch (err) {
    outcome = 'error';
    errorMessage = err instanceof Error ? err.name : 'UNKNOWN';
    logger.error(
      { action: 'partyIntelligence.summary_failed', errorType: errorMessage },
      'Party intelligence AI summary failed (non-fatal)',
    );
    return null;
  } finally {
    void recordAiTelemetry({
      promptId: PROMPT_ID,
      mode: 'fetch',
      actorUserId: actorId,
      entityType: 'party',
      entityId: Number(party['id']) || null,
      language,
      provider: 'openai',
      modelUsed: model,
      tokensInput,
      tokensOutput,
      latencyMs: Date.now() - started,
      cacheHit: false,
      streamMode: false,
      outcome,
      errorClass: outcome === 'error' ? errorMessage : null,
    });
  }
};

export const getPartyIntelligence = async (args: {
  actorId: number;
  partyId: number;
  excludeContractId?: number | null;
  language?: Lang;
}): Promise<PartyIntelligenceResult> => {
  const language: Lang = args.language === 'ar' ? 'ar' : 'en';
  const metrics = await db.callFunction<Record<string, unknown>>(
    'fn_party_drafting_intelligence',
    [args.partyId, args.excludeContractId ?? null],
    { actorId: args.actorId },
  );
  const summary = await buildSummary(metrics, language, args.actorId);
  return { metrics, summary };
};
