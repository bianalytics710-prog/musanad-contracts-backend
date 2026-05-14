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
import { createHash, randomUUID } from 'node:crypto';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { getOpenAIClient } from './ai/_shared/openai-client';
import { loadPrompt, renderPrompt } from './ai/_shared/prompt-loader';
import { recordAiTelemetry } from './ai/_shared/telemetry-middleware';

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

interface AiPromptConfig {
  promptId: string;          // composite: advisory_drafter__<draftType>
  modelVersion: string;      // from fn_ai_prompt_get.defaultModel, default 'gpt-4o'
  temperature: number;       // from defaultTemperature, default 0.2
  maxTokens: number;         // from defaultMaxTokens, default 2000
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
 * Fetch the ai_prompt config (model/temperature/maxTokens) for the composite
 * prompt_id `advisory_drafter__<draftType>`. The actual system+user prompt
 * text is loaded from disk via loadPrompt() — M4 G7-compliant pattern shared
 * with risk-assistant.service.ts and the 6 other openai-* services.
 *
 * DEBT-CRH-2 (fixed 2026-05-14): previously this fn expected systemPrompt /
 * userPromptTemplate columns on fn_ai_prompt_get, which does not return them.
 * The function returns config metadata only; prompt bodies live at
 * prompts/<promptId>.txt and are versioned with the codebase.
 */
interface FnAiPromptGetRow {
  promptId: string;
  defaultModel: string | null;
  defaultTemperature: number | string | null;
  defaultMaxTokens: number | string | null;
}
async function fetchAiPromptConfig(
  draftType: string,
  actorId: number,
  tenantId: string,
): Promise<AiPromptConfig | null> {
  const compositeId = `advisory_drafter__${draftType}`;
  let row = await db.callFunction<FnAiPromptGetRow | null>(
    'fn_ai_prompt_get',
    [compositeId],
    { actorId, tenantId },
  );
  if (!row) {
    row = await db.callFunction<FnAiPromptGetRow | null>(
      'fn_ai_prompt_get',
      ['advisory_drafter'],
      { actorId, tenantId },
    );
  }
  if (!row) return null;

  const parseNum = (v: number | string | null, fallback: number): number => {
    if (v === null || v === undefined) return fallback;
    const n = typeof v === 'number' ? v : Number(v);
    return Number.isFinite(n) ? n : fallback;
  };

  return {
    promptId: row.promptId ?? compositeId,
    modelVersion: row.defaultModel ?? 'gpt-4o',
    temperature: parseNum(row.defaultTemperature, 0.2),
    maxTokens: parseNum(row.defaultMaxTokens, 2000),
  };
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

interface LlmCallResult {
  textEn: string;
  textAr: string;
  promptHash: string;
  responseHash: string;
  tokensInput: number;
  tokensOutput: number;
}

async function callLlm(
  systemPrompt: string,
  renderedBodyEn: string,
  renderedBodyAr: string,
  cfg: AiPromptConfig,
): Promise<LlmCallResult> {
  const client = getOpenAIClient();

  // Hash the canonical prompt inputs (system + both pre-drafted bodies) for ai_request_log lineage.
  const promptHash = createHash('sha256')
    .update(systemPrompt + '\n---EN---\n' + renderedBodyEn + '\n---AR---\n' + renderedBodyAr)
    .digest('hex');

  // EN refinement
  const enResponse = await client.chat.completions.create({
    model: cfg.modelVersion,
    messages: [
      { role: 'system', content: systemPrompt },
      {
        role: 'user',
        content:
          'Refine the following pre-drafted English notice per the rules above. ' +
          'Return ONLY the refined notice text.\n\n---\n' +
          renderedBodyEn,
      },
    ],
    temperature: cfg.temperature,
    max_tokens: cfg.maxTokens,
  });
  const textEn = enResponse.choices[0]?.message?.content?.trim() || renderedBodyEn;

  // AR refinement — same system prompt + Arabic-only instruction
  const arSystemPrompt = systemPrompt + '\n\nIMPORTANT: Respond in formal Arabic (العربية الفصحى) only. Preserve Arabic placeholders and party names exactly.';
  const arResponse = await client.chat.completions.create({
    model: cfg.modelVersion,
    messages: [
      { role: 'system', content: arSystemPrompt },
      {
        role: 'user',
        content:
          'قم بصياغة الإشعار العربي المُسوَّد أدناه وفقاً للقواعد المذكورة. أعد فقط نص الإشعار المُصاغ.\n\n---\n' +
          renderedBodyAr,
      },
    ],
    temperature: cfg.temperature,
    max_tokens: cfg.maxTokens,
  });
  const textAr = arResponse.choices[0]?.message?.content?.trim() || renderedBodyAr;

  const responseHash = createHash('sha256').update(textEn + '\n' + textAr).digest('hex');

  // Sum token usage across both EN and AR calls (single advisory generation = one billable LLM invocation in audit).
  const tokensInput =
    (enResponse.usage?.prompt_tokens ?? 0) + (arResponse.usage?.prompt_tokens ?? 0);
  const tokensOutput =
    (enResponse.usage?.completion_tokens ?? 0) + (arResponse.usage?.completion_tokens ?? 0);

  return { textEn, textAr, promptHash, responseHash, tokensInput, tokensOutput };
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

  // 5. Fetch ai_prompt config (model/temperature/maxTokens). Prompt body lives on disk.
  let aiCfg: AiPromptConfig | null = null;
  try {
    aiCfg = await fetchAiPromptConfig(template.draftType, actorId, tenantId);
  } catch (err) {
    logger.warn(
      {
        action: 'advisoryDrafterService.aiPromptConfigFallback',
        draftType: template.draftType,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_ai_prompt_get unavailable — using default model config',
    );
  }
  if (!aiCfg) {
    aiCfg = {
      promptId: `advisory_drafter__${template.draftType}`,
      modelVersion: 'gpt-4o',
      temperature: 0.2,
      maxTokens: 2000,
    };
  }

  // 6. Load + render system prompt from disk. Missing file → fall back to Mustache-only.
  let generatedTextEn: string;
  let generatedTextAr: string;
  let promptHash: string;
  let responseHash: string;
  const modelVersion = aiCfg.modelVersion;
  let llmUsed = false;
  let llmTokensInput = 0;
  let llmTokensOutput = 0;
  let llmOutcome: 'success' | 'fallback' = 'fallback';
  let llmErrorClass: string | null = null;
  let llmErrorMessage: string | null = null;
  const llmStartMs = Date.now();
  try {
    const promptTemplate = await loadPrompt(aiCfg.promptId);
    const systemPrompt = renderPrompt(promptTemplate, mustacheCtx);

    // 7. Call LLM with the disk-loaded system prompt + the pre-drafted bodies.
    const llmResult = await callLlm(systemPrompt, renderedBodyEn, renderedBodyAr, aiCfg);
    generatedTextEn = llmResult.textEn;
    generatedTextAr = llmResult.textAr;
    promptHash = llmResult.promptHash;
    responseHash = llmResult.responseHash;
    llmTokensInput = llmResult.tokensInput;
    llmTokensOutput = llmResult.tokensOutput;
    llmUsed = true;
    llmOutcome = 'success';
  } catch (err) {
    llmErrorClass = err instanceof Error ? err.name : 'UNKNOWN';
    llmErrorMessage = err instanceof Error ? err.message : String(err);
    logger.warn(
      {
        action: 'advisoryDrafterService.llmFallback',
        promptId: aiCfg.promptId,
        errorType: llmErrorClass,
      },
      'LLM polish unavailable — using Mustache-rendered body directly',
    );
    generatedTextEn = renderedBodyEn;
    generatedTextAr = renderedBodyAr;
    promptHash = createHash('sha256').update(renderedBodyEn + '\n' + renderedBodyAr).digest('hex');
    responseHash = createHash('sha256').update(generatedTextEn + '\n' + generatedTextAr).digest('hex');
  }
  const llmLatencyMs = Date.now() - llmStartMs;
  logger.info(
    {
      action: 'advisoryDrafterService.llmPath',
      promptId: aiCfg.promptId,
      llmUsed,
      model: modelVersion,
      latencyMs: llmLatencyMs,
    },
    llmUsed ? 'LLM polish path' : 'Mustache-only path',
  );

  // 7b. Audit: record ai_request_log via fn_ai_request_log_create (production invariant #6 — no LLM call without audit).
  //     Best-effort — telemetry-middleware swallows failures so they don't block the user response.
  void recordAiTelemetry({
    requestId: randomUUID(),
    promptId: aiCfg.promptId,
    mode: 'advisory_drafter',
    actorUserId: actorId,
    entityType: 'advisory_draft',
    entityId: null, // draft id not yet assigned at this point — populated later via UPDATE if needed
    // Advisory drafts are bilingual (EN+AR) but ai_request_log.language is varchar(8) so 'bilingual' overflows.
    // Use 'en' as the primary locale tag; the draft itself carries both EN and AR text.
    language: 'en',
    provider: 'openai',
    modelUsed: modelVersion,
    tokensInput: llmUsed ? llmTokensInput : null,
    tokensOutput: llmUsed ? llmTokensOutput : null,
    costUsdMicros: null,
    latencyMs: llmLatencyMs,
    cacheHit: false,
    streamMode: false,
    outcome: llmOutcome === 'success' ? 'success' : 'error',
    errorClass: llmErrorClass,
    errorMessage: llmErrorMessage,
  });

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
