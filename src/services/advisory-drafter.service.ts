/**
 * M16 / CR-H — Advisory Drafter Service.
 *
 * Responsibilities:
 *   1. Build LLM context from correlation + contract_clause + risk_score + signal data.
 *   2. Sanitise context fields against prompt-injection (strip newlines from
 *      counterparty_name, escape control chars in clause_text per Stage 2 W3b).
 *   3. Render advisory_template body_template_en/ar via Mustache.
 *   4. Call AIProvider (M4 gpt-4o path) to generate EN+AR advisory text.
 *   5. Persist advisory_draft via fn_advisory_draft_generate (DEFINER fn).
 *      ai_request_log entry is inserted INSIDE the fn_ DB transaction (DD-4).
 *
 * SENSITIVE:
 *   - generatedTextEn, generatedTextAr, templateContext — never logged.
 *   - Pino redact list in logger.util.ts covers these fields as safety net.
 */
import Mustache from 'mustache';
import { createHash } from 'node:crypto';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { getOpenAIClient } from './ai/_shared/openai-client';

// ----------------------------------------------------------------
// Type definitions
// ----------------------------------------------------------------

export interface GenerateAdvisoryDraftInput {
  correlationId: number;
  templateId: number;
  contractId?: number | null;
  actorId: number;
  tenantId: string;
}

export interface GeneratedAdvisoryDraft {
  draftId: number;
  correlationId: number;
  templateId: number;
  contractId: number;
  templateVersion: number;
  approvalStatus: 'unapproved';
  generatedTextEn: string;
  generatedTextAr: string;
}

interface AdvisoryTemplateRow {
  id: number;
  templateId: string;
  displayNameEn: string;
  displayNameAr: string;
  draftType: string;
  bodyTemplateEn: string;
  bodyTemplateAr: string;
  parameterSchema: Record<string, unknown>;
  assignedApproverRole: string;
  version: number;
  isActive: boolean;
}

interface CorrelationContextRow {
  correlationId: number;
  contractId: number;
  correlationRuleDescription: string | null;
  matchExplanation: string | null;
  matchedClauseText: string | null;
  counterpartyName: string | null;
  contractReferenceNumber: string | null;
  signalDate: string | null;
  signalSummary: string | null;
  signalKind: string | null;
  riskHealthScore: number | null;
  riskCalculatedAt: string | null;
}

interface AiPromptRow {
  systemPrompt: string;
  userPromptTemplate: string;
  modelVersion: string;
}

// ----------------------------------------------------------------
// Prompt-injection sanitisation helpers (Stage 2 W3b)
// ----------------------------------------------------------------

/** Strip newlines and carriage returns from user-sourced strings. */
function stripNewlines(s: string | null | undefined): string {
  if (s === null || s === undefined) return '';
  return s.replace(/[\r\n]/g, ' ').trim();
}

/** Escape control characters (0x00–0x1F except space) from clause text. */
function escapeControlChars(s: string | null | undefined): string {
  if (s === null || s === undefined) return '';
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\x00-\x08\x0A-\x0D\x0E-\x1F]/g, '').trim();
}

// ----------------------------------------------------------------
// Context builder
// ----------------------------------------------------------------

/**
 * Fetch correlation context: correlation + matched clause + risk score + signal.
 * Uses fn_ read functions to respect RLS and tenant GUC.
 */
async function buildCorrelationContext(
  correlationId: number,
  actorId: number,
  tenantId: string,
): Promise<CorrelationContextRow | null> {
  type CtxResult = CorrelationContextRow | null;
  const result = await db.callFunction<CtxResult>(
    'fn_advisory_context_build',
    [actorId, correlationId],
    { actorId, tenantId },
  );
  return result;
}

/**
 * Fetch the advisory template by DB id.
 */
async function fetchTemplate(
  templateId: number,
  actorId: number,
  tenantId: string,
): Promise<AdvisoryTemplateRow | null> {
  const result = await db.callFunction<AdvisoryTemplateRow | null>(
    'fn_advisory_template_get_by_id',
    [actorId, templateId],
    { actorId, tenantId },
  );
  return result;
}

/**
 * Fetch the ai_prompt row keyed by composite prompt_id `advisory_drafter__<draftType>`
 * (matches the 3 seed rows in migration 213).
 * Falls back to plain `advisory_drafter` if the specific variant is missing.
 */
async function fetchAiPrompt(
  draftType: string,
  actorId: number,
  tenantId: string,
): Promise<AiPromptRow | null> {
  type PromptResult = AiPromptRow | null;
  const compositeId = `advisory_drafter__${draftType}`;
  let result = await db.callFunction<PromptResult>(
    'fn_ai_prompt_get',
    [compositeId],
    { actorId, tenantId },
  );
  if (!result) {
    result = await db.callFunction<PromptResult>(
      'fn_ai_prompt_get',
      ['advisory_drafter'],
      { actorId, tenantId },
    );
  }
  return result;
}

// ----------------------------------------------------------------
// Mustache render helpers
// ----------------------------------------------------------------

function buildMustacheContext(
  ctx: CorrelationContextRow,
): Record<string, string | number | null> {
  const noticeDateIso = new Date().toISOString().split('T')[0] ?? '';

  return {
    notice_date: noticeDateIso,
    contract_id: ctx.contractReferenceNumber ?? String(ctx.contractId),
    addressee: stripNewlines(ctx.counterpartyName) || 'Addressee',
    counterparty_name: stripNewlines(ctx.counterpartyName) || '',
    fm_clause_text: escapeControlChars(ctx.matchedClauseText) || 'Force Majeure Clause',
    notice_period_days: 14,
    signal_date: ctx.signalDate ? String(ctx.signalDate).split('T')[0] ?? '' : noticeDateIso,
    signal_summary: escapeControlChars(ctx.signalSummary) || '',
    sanctioning_authority: 'OFAC/EU/UN',
    designation_date: ctx.signalDate ? String(ctx.signalDate).split('T')[0] ?? '' : noticeDateIso,
    hold_basis: escapeControlChars(ctx.correlationRuleDescription) || escapeControlChars(ctx.matchExplanation) || '',
    breach_description: escapeControlChars(ctx.matchExplanation) || escapeControlChars(ctx.correlationRuleDescription) || '',
    cure_period_days: 14,
    cure_period_end_date: new Date(Date.now() + 14 * 86400000).toISOString().split('T')[0] ?? '',
    cure_address: stripNewlines(ctx.counterpartyName) || 'TBD — Legal Affairs will supply',
  };
}

// ----------------------------------------------------------------
// LLM call via OpenAI (gpt-4o)
// ----------------------------------------------------------------

async function callLlm(
  systemPrompt: string,
  userPrompt: string,
  modelVersion: string,
): Promise<{ textEn: string; textAr: string; promptHash: string; responseHash: string }> {
  const client = getOpenAIClient();

  const promptHash = createHash('sha256').update(systemPrompt + '\n' + userPrompt).digest('hex');

  // EN generation
  const enResponse = await client.chat.completions.create({
    model: modelVersion || 'gpt-4o',
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userPrompt },
    ],
    temperature: 0.2,
    max_tokens: 2000,
  });
  const textEn = enResponse.choices[0]?.message?.content ?? '';

  // AR generation — append AR instruction
  const arSystemPrompt = systemPrompt + ' Respond in formal Arabic only.';
  const arResponse = await client.chat.completions.create({
    model: modelVersion || 'gpt-4o',
    messages: [
      { role: 'system', content: arSystemPrompt },
      { role: 'user', content: userPrompt + '\n\nProvide the full text in Arabic.' },
    ],
    temperature: 0.2,
    max_tokens: 2000,
  });
  const textAr = arResponse.choices[0]?.message?.content ?? '';

  const responseHash = createHash('sha256').update(textEn + '\n' + textAr).digest('hex');

  return { textEn, textAr, promptHash, responseHash };
}

// ----------------------------------------------------------------
// Main entry point
// ----------------------------------------------------------------

/**
 * Generate an advisory draft:
 *   1. Fetch template + correlation context.
 *   2. Sanitise + build mustache context.
 *   3. Call LLM for EN + AR.
 *   4. Persist via fn_advisory_draft_generate (which also logs ai_request_log).
 *
 * DOES NOT build the ai_request_log separately — it is inserted inside
 * fn_advisory_draft_generate per DD-4 / api-contracts.json aiRequestLogContract.
 */
export async function generateAdvisoryDraft(
  input: GenerateAdvisoryDraftInput,
): Promise<GeneratedAdvisoryDraft> {
  const { correlationId, templateId, contractId: contractIdInput, actorId, tenantId } = input;

  logger.info(
    {
      action: 'advisoryDrafterService.generate',
      correlationId,
      templateId,
      actorId,
    },
    'Advisory draft generation started',
  );

  const startMs = Date.now();

  // 1. Fetch template
  const template = await fetchTemplate(templateId, actorId, tenantId);
  if (!template) {
    const { ApiError } = await import('../utils/errors.util');
    throw new ApiError(404, 'template_not_found', 'Advisory template not found');
  }

  // 2. Fetch correlation context (resolves correlation + matched clause + risk score + signal)
  // If fn_advisory_context_build not deployed, fall back to a minimal context
  let ctx: CorrelationContextRow | null = null;
  try {
    ctx = await buildCorrelationContext(correlationId, actorId, tenantId);
  } catch (err) {
    logger.warn(
      {
        action: 'advisoryDrafterService.contextBuildFallback',
        correlationId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_advisory_context_build not available — using minimal context',
    );
  }

  const resolvedContractId: number =
    ctx?.contractId ?? contractIdInput ?? 0;

  // 3. Build Mustache context (sanitised)
  const mustacheCtx = ctx
    ? buildMustacheContext(ctx)
    : {
        notice_date: new Date().toISOString().split('T')[0] ?? '',
        contract_id: resolvedContractId ? String(resolvedContractId) : 'N/A',
        addressee: '',
        counterparty_name: '',
        fm_clause_text: '',
        notice_period_days: 14,
        signal_date: '',
        signal_summary: '',
        sanctioning_authority: '',
        designation_date: '',
        hold_basis: '',
        breach_description: '',
        cure_period_days: 14,
        cure_period_end_date: '',
        cure_address: '',
      };

  // 4. Render body templates (Mustache)
  const renderedBodyEn = Mustache.render(template.bodyTemplateEn, mustacheCtx);
  const renderedBodyAr = Mustache.render(template.bodyTemplateAr, mustacheCtx);

  // 5. Fetch ai_prompt for system + user prompt
  let aiPrompt: AiPromptRow | null = null;
  try {
    aiPrompt = await fetchAiPrompt(template.draftType, actorId, tenantId);
  } catch {
    logger.warn(
      { action: 'advisoryDrafterService.aiPromptFallback', draftType: template.draftType },
      'fn_ai_prompt_get not available — using rendered template body directly',
    );
  }

  let generatedTextEn: string;
  let generatedTextAr: string;
  let promptHash: string;
  let responseHash: string;
  const modelVersion = aiPrompt?.modelVersion ?? 'gpt-4o';

  if (aiPrompt) {
    // 6. Render the ai_prompt user template with mustache context
    const renderedUserPrompt = Mustache.render(aiPrompt.userPromptTemplate, mustacheCtx);

    // 7. Call LLM
    const llmResult = await callLlm(aiPrompt.systemPrompt, renderedUserPrompt, modelVersion);
    generatedTextEn = llmResult.textEn;
    generatedTextAr = llmResult.textAr;
    promptHash = llmResult.promptHash;
    responseHash = llmResult.responseHash;
  } else {
    // Fallback: use rendered Mustache body directly (no LLM call)
    generatedTextEn = renderedBodyEn;
    generatedTextAr = renderedBodyAr;
    promptHash = createHash('sha256').update(renderedBodyEn).digest('hex');
    responseHash = createHash('sha256').update(generatedTextEn + generatedTextAr).digest('hex');
  }

  // 8. Persist via fn_advisory_draft_generate
  //    S2-19: parameter order matches fn_ signature exactly.
  //    ai_request_log is inserted INSIDE the fn_ transaction (DD-4).
  const result = await db.callFunction<GeneratedAdvisoryDraft>(
    'fn_advisory_draft_generate',
    [
      actorId,
      correlationId,
      templateId,
      resolvedContractId || null,
      generatedTextEn,
      generatedTextAr,
      modelVersion,
      promptHash,
      responseHash,
      JSON.stringify(mustacheCtx),
    ],
    { actorId, tenantId },
  );

  const durationMs = Date.now() - startMs;
  logger.info(
    {
      action: 'advisoryDrafterService.generateComplete',
      draftId: result?.draftId,
      correlationId,
      durationMs,
    },
    'Advisory draft generation complete',
  );

  return result;
}
