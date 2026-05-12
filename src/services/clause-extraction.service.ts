/**
 * M12 / CR-D — Clause Extraction Service.
 *
 * Stage 1: Region detection — TS regex + heading-detection heuristics per Annex A.
 *   Reads contract_version.extracted_text_uri (populated by M11 ingestion worker).
 *   Segments text into candidate clause regions.
 *
 * Stage 2: LLM classification — OpenAI gpt-4o structured-output.
 *   Classifies each candidate region to a ClauseTypeV2.
 *   Extracts parameters per Annex A parameter schemas (single-clause-per-call per HITL Q5).
 *   Calls fn_clause_upsert per extracted clause.
 *   Generates embedding via text-embedding-3-small (HITL Q3).
 *   Logs ai_request_log per call (mode='clause_extract' and mode='clause_embed').
 *
 * DEFECT-1 from db-impl-report.md:
 *   fn_obligations_derive_from_clause cannot persist notice_period_days as a
 *   column on contract_obligation. Where obligation derivation depends on duration
 *   params (e.g. notice_period_days, renewal_notice_period_days), those values
 *   are stored in the obligation meta JSONB field. This is a known structural
 *   limitation of the current schema. No code fix needed here — fn_obligations_derive_from_clause
 *   handles it in the DB layer; this service just calls fn_clause_upsert which calls it.
 *
 * SENSITIVE: parameters, textExcerpts never logged — Pino redact covers them.
 */
import { createClient } from '@supabase/supabase-js';
import { getOpenAIClient } from './ai/_shared/openai-client';
import { recordAiTelemetry } from './ai/_shared/telemetry-middleware';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { InternalError, UnprocessableEntityError } from '../utils/errors.util';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const SYSTEM_ACTOR_ID = 1;

// ============================================================
// Stage 1 — Region detection patterns (Annex A)
// ============================================================

interface TextRegion {
  clauseTypeHint: string;
  rawText: string;
  headingMatch: string;
  pageHint: number | null;
  offsetStart: number;
  offsetEnd: number;
}

// Heading patterns per Annex A identification cues
const CLAUSE_HEADING_PATTERNS: Array<{ clauseTypeHint: string; pattern: RegExp }> = [
  // Force Majeure & Excusable Delay (A.3)
  { clauseTypeHint: 'force_majeure', pattern: /\b(?:force\s+majeure|fm\s+clause|act\s+of\s+god)\b/i },
  { clauseTypeHint: 'hardship', pattern: /\bhardship\b/i },
  { clauseTypeHint: 'excusable_delay', pattern: /\bexcusable\s+delay\b/i },
  { clauseTypeHint: 'weather_downtime', pattern: /\bweather\s+downtime\b/i },
  { clauseTypeHint: 'epidemic_pandemic', pattern: /\b(?:epidemic|pandemic|outbreak)\b/i },
  { clauseTypeHint: 'government_action', pattern: /\bgovernment(?:al)?\s+action\b/i },
  { clauseTypeHint: 'sanctions_disruption', pattern: /\bsanctions?\s+disruption\b/i },
  { clauseTypeHint: 'strike_lockout', pattern: /\b(?:strike|lockout|industrial\s+action)\b/i },
  // Termination & Suspension (A.4)
  { clauseTypeHint: 'termination_for_convenience', pattern: /\btermination\s+(?:for\s+)?convenience\b/i },
  { clauseTypeHint: 'termination_for_cause', pattern: /\btermination\s+(?:for\s+)?(?:cause|default|breach)\b/i },
  { clauseTypeHint: 'suspension', pattern: /\bsuspension\b/i },
  { clauseTypeHint: 'step_in_rights', pattern: /\bstep[\s-]in\s+rights?\b/i },
  { clauseTypeHint: 'termination_for_change_of_control', pattern: /\bchange\s+of\s+control\b/i },
  { clauseTypeHint: 'prolonged_force_majeure_termination', pattern: /\bprolonged\s+force\s+majeure\b/i },
  // Pricing & Adjustment (A.5)
  { clauseTypeHint: 'price_review', pattern: /\bprice\s+review\b/i },
  { clauseTypeHint: 'price_indexation', pattern: /\bprice\s+indexation\b/i },
  { clauseTypeHint: 'escalation', pattern: /\bescalation\b/i },
  { clauseTypeHint: 'most_favoured_pricing', pattern: /\bmost\s+favou?red\s+(?:nation|pricing|customer)\b/i },
  { clauseTypeHint: 'take_or_pay', pattern: /\btake[\s-]or[\s-]pay\b/i },
  // Performance & SLA (A.6)
  { clauseTypeHint: 'sla_performance', pattern: /\b(?:service\s+level|sla)\b/i },
  { clauseTypeHint: 'liquidated_damages', pattern: /\bliquidated\s+damages?\b/i },
  { clauseTypeHint: 'cure_period', pattern: /\bcure\s+period\b/i },
  { clauseTypeHint: 'performance_bond_guarantee', pattern: /\bperformance\s+(?:bond|guarantee)\b/i },
  { clauseTypeHint: 'key_personnel', pattern: /\bkey\s+personnel\b/i },
  { clauseTypeHint: 'acceptance_testing', pattern: /\bacceptance\s+test(?:ing)?\b/i },
  // Indemnity & Liability (A.7)
  { clauseTypeHint: 'indemnity', pattern: /\bindemnit(?:y|ies|ify)\b/i },
  { clauseTypeHint: 'liability_cap', pattern: /\bliability\s+cap\b/i },
  { clauseTypeHint: 'consequential_loss_exclusion', pattern: /\bconsequential\s+(?:loss|damage)\b/i },
  { clauseTypeHint: 'insurance', pattern: /\binsurance\b/i },
  { clauseTypeHint: 'mutual_hold_harmless', pattern: /\bhold\s+harmless\b/i },
  // Compliance & Regulatory (A.8)
  { clauseTypeHint: 'sanctions_compliance', pattern: /\bsanctions\s+compliance\b/i },
  { clauseTypeHint: 'anti_bribery_corruption', pattern: /\banti[\s-](?:bribery|corruption|bribery\s+and\s+corruption)\b/i },
  { clauseTypeHint: 'hse_compliance', pattern: /\b(?:hse|health\s+safety\s+environment)\b/i },
  { clauseTypeHint: 'icv_in_country_value', pattern: /\b(?:icv|in[\s-]country\s+value)\b/i },
  { clauseTypeHint: 'data_protection', pattern: /\bdata\s+protection\b/i },
  { clauseTypeHint: 'environmental', pattern: /\benvironmental\b/i },
  { clauseTypeHint: 'export_control', pattern: /\bexport\s+control\b/i },
  { clauseTypeHint: 'regulatory_change', pattern: /\bregulatory\s+change|change\s+in\s+law\b/i },
  // Governance & Disputes (A.9)
  { clauseTypeHint: 'governing_law', pattern: /\bgoverning\s+law\b/i },
  { clauseTypeHint: 'dispute_resolution', pattern: /\bdispute\s+resolution\b/i },
  { clauseTypeHint: 'notices', pattern: /\bnotices?\s+(?:and\s+communications?)?\b/i },
  { clauseTypeHint: 'entire_agreement', pattern: /\bentire\s+agreement\b/i },
  { clauseTypeHint: 'severability', pattern: /\bseverabilit(?:y|ies)\b/i },
  // Operational & Commercial (A.10)
  { clauseTypeHint: 'term_and_renewal', pattern: /\b(?:term\s+and\s+renewal|term\s+of\s+(?:the\s+)?agreement)\b/i },
  { clauseTypeHint: 'assignment_novation', pattern: /\b(?:assignment|novation)\b/i },
  { clauseTypeHint: 'change_order_variation', pattern: /\b(?:change\s+order|variation\s+order)\b/i },
  { clauseTypeHint: 'audit_rights', pattern: /\baudit\s+rights?\b/i },
  { clauseTypeHint: 'confidentiality', pattern: /\bconfidentialit(?:y|ies)\b/i },
  { clauseTypeHint: 'ip_rights', pattern: /\b(?:intellectual\s+property|ip\s+rights?)\b/i },
  { clauseTypeHint: 'subcontracting', pattern: /\bsubcontracting\b/i },
];

const SECTION_SPLIT_PATTERN = /(?=^\s*(?:\d+\.?\s+|[A-Z][A-Z\s]{2,}\n|\bARTICLE\b|\bSECTION\b|\bCLAUSE\b))/im;

/**
 * Stage 1: Detect candidate clause regions in extracted contract text.
 * Uses heading heuristics — no LLM.
 */
function detectRegions(text: string): TextRegion[] {
  const sections = text.split(SECTION_SPLIT_PATTERN).filter((s) => s.trim().length > 20);
  const regions: TextRegion[] = [];
  let offset = 0;

  for (const section of sections) {
    const sectionStart = text.indexOf(section, offset);
    const sectionEnd = sectionStart + section.length;

    for (const { clauseTypeHint, pattern } of CLAUSE_HEADING_PATTERNS) {
      if (pattern.test(section)) {
        regions.push({
          clauseTypeHint,
          rawText: section.trim(),
          headingMatch: (pattern.exec(section)?.[0]) ?? '',
          pageHint: null, // Page-level detection not available from plain text
          offsetStart: sectionStart,
          offsetEnd: sectionEnd,
        });
        break; // one hint per section (strongest match)
      }
    }

    offset = sectionEnd;
  }

  return regions;
}

// ============================================================
// Stage 2 — LLM classification
// ============================================================

interface ClauseExtractResult {
  clauseTypeV2: string;
  parameters: Record<string, unknown>;
  textExcerpts: Record<string, string>;
  confidence: number;
  summaryEn: string;
  summaryAr: string;
}

const CLAUSE_EXTRACTION_SYSTEM_PROMPT = `You are a legal clause extraction AI specialized in UAE and international commercial contracts.
Your task is to identify the clause type and extract structured parameters from the given contract text excerpt.

Extract parameters according to the Annex A parameter schema for the identified clause type.
Every parameter MUST have a corresponding text_excerpt — a verbatim quote from the contract text that supports the extracted value.
Do not invent parameters. Do not extract a parameter if you cannot find a verbatim text excerpt for it.

Return JSON with this structure:
{
  "clauseTypeV2": "<one of the 50 valid ClauseTypeV2 identifiers>",
  "confidence": <0.0 to 1.0>,
  "summaryEn": "<1-2 sentence English summary>",
  "summaryAr": "<placeholder: [AR] + English summary>",
  "parameters": { "<param_name>": <value>, ... },
  "textExcerpts": { "<param_name>": "<verbatim quote>", ... }
}`;

/**
 * Stage 2: Call gpt-4o to classify a region and extract parameters.
 * Per HITL Q5: single-clause-per-call.
 * SENSITIVE: text content not logged.
 */
async function classifyRegion(
  region: TextRegion,
  contractVersionId: number,
  actorId: number,
): Promise<ClauseExtractResult | null> {
  const openai = getOpenAIClient();
  const startMs = Date.now();
  let tokensInput: number | null = null;
  let tokensOutput: number | null = null;
  let outcome: 'success' | 'error' = 'success';
  let errorClass: string | null = null;

  try {
    const userContent = `Clause type hint: ${region.clauseTypeHint}\n\nContract text excerpt:\n${region.rawText.slice(0, 4000)}`;

    const response = await openai.chat.completions.create({
      model: 'gpt-4o',
      response_format: { type: 'json_object' },
      max_tokens: 1500,
      messages: [
        { role: 'system', content: CLAUSE_EXTRACTION_SYSTEM_PROMPT },
        { role: 'user', content: userContent },
      ],
    });

    tokensInput = response.usage?.prompt_tokens ?? null;
    tokensOutput = response.usage?.completion_tokens ?? null;

    const rawContent = response.choices[0]?.message?.content ?? '{}';
    const parsed = JSON.parse(rawContent) as ClauseExtractResult;

    // Validate: every parameter key must have a text_excerpt
    if (parsed.parameters && parsed.textExcerpts) {
      for (const key of Object.keys(parsed.parameters)) {
        if (!parsed.textExcerpts[key]) {
          logger.warn(
            { action: 'clauseExtraction.classifyRegion', paramKey: key, contractVersionId },
            'Dropping parameter with no text_excerpt (Annex A.1.2 discipline)',
          );
          delete parsed.parameters[key];
        }
      }
    }

    return parsed;
  } catch (err) {
    outcome = 'error';
    errorClass = err instanceof Error ? err.name : 'UNKNOWN';
    logger.warn(
      {
        action: 'clauseExtraction.classifyRegion',
        contractVersionId,
        clauseTypeHint: region.clauseTypeHint,
        errorType: errorClass,
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Stage 2 LLM classification failed for region',
    );
    return null;
  } finally {
    const latencyMs = Date.now() - startMs;
    await recordAiTelemetry({
      promptId: 'clause-extraction-stage-2',
      mode: 'clause_extract',
      actorUserId: actorId,
      entityType: 'contract_version',
      entityId: contractVersionId,
      language: 'en',
      provider: 'openai',
      modelUsed: 'gpt-4o',
      tokensInput,
      tokensOutput,
      costUsdMicros: tokensInput != null && tokensOutput != null
        ? Math.round((tokensInput * 5 + tokensOutput * 15) / 1_000_000 * 1_000_000)
        : null,
      latencyMs,
      cacheHit: false,
      streamMode: false,
      outcome,
      errorClass,
    });
  }
}

/**
 * Generate embedding for a clause using text-embedding-3-small (HITL Q3).
 * Returns null on failure (non-blocking — embedding failure doesn't stop extraction).
 * SENSITIVE: text content not logged.
 */
async function generateEmbedding(
  summaryEn: string,
  contractVersionId: number,
  actorId: number,
): Promise<number[] | null> {
  const openai = getOpenAIClient();
  const startMs = Date.now();
  let tokensInput: number | null = null;
  let outcome: 'success' | 'error' = 'success';
  let errorClass: string | null = null;

  try {
    const response = await openai.embeddings.create({
      model: 'text-embedding-3-small',
      input: summaryEn.slice(0, 8191), // token limit safety
    });

    tokensInput = response.usage?.prompt_tokens ?? null;
    return response.data[0]?.embedding ?? null;
  } catch (err) {
    outcome = 'error';
    errorClass = err instanceof Error ? err.name : 'UNKNOWN';
    logger.warn(
      {
        action: 'clauseExtraction.generateEmbedding',
        contractVersionId,
        errorType: errorClass,
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Embedding generation failed (non-blocking)',
    );
    return null;
  } finally {
    const latencyMs = Date.now() - startMs;
    await recordAiTelemetry({
      promptId: 'clause-extraction-stage-2',
      mode: 'clause_embed',
      actorUserId: actorId,
      entityType: 'contract_version',
      entityId: contractVersionId,
      language: 'en',
      provider: 'openai',
      modelUsed: 'text-embedding-3-small',
      tokensInput,
      tokensOutput: null,
      costUsdMicros: tokensInput != null ? Math.round(tokensInput * 0.02 / 1_000_000 * 1_000_000) : null,
      latencyMs,
      cacheHit: false,
      streamMode: false,
      outcome,
      errorClass,
    });
  }
}

// ============================================================
// Supabase storage helper
// ============================================================

function getStorageClient() {
  const url = process.env['SUPABASE_URL'];
  const serviceRoleKey = process.env['SUPABASE_SERVICE_ROLE_KEY'];
  if (!url || !serviceRoleKey) {
    throw new InternalError('Supabase storage is not configured');
  }
  return createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function fetchExtractedText(extractedTextUri: string): Promise<string> {
  const supabase = getStorageClient();
  const { data, error } = await supabase.storage.from('contract-attachments').download(extractedTextUri);
  if (error || !data) {
    throw new InternalError(`Cannot download extracted text: ${error?.message ?? 'no data'}`);
  }
  return await data.text();
}

// ============================================================
// Main extraction orchestrator
// ============================================================

export interface ExtractionSummary {
  contractVersionId: number;
  regionsDetected: number;
  clausesUpserted: number;
  clausesFailed: number;
  obligationsCreated: number;
}

/**
 * Run the full two-stage clause extraction pipeline for a contract version.
 * Called by clause-extraction.worker.ts.
 *
 * SENSITIVE: extracted text not logged.
 */
export async function extractClausesForVersion(
  contractVersionId: number,
  extractedTextUri: string,
  actorId: number = SYSTEM_ACTOR_ID,
): Promise<ExtractionSummary> {
  logger.info(
    { action: 'clauseExtraction.extractClausesForVersion', contractVersionId },
    'Starting clause extraction pipeline',
  );

  // Fetch extracted text from Supabase Storage
  const text = await fetchExtractedText(extractedTextUri);
  if (!text || text.trim().length < 50) {
    logger.warn(
      { action: 'clauseExtraction.extractClausesForVersion', contractVersionId },
      'Extracted text too short to process',
    );
    return { contractVersionId, regionsDetected: 0, clausesUpserted: 0, clausesFailed: 0, obligationsCreated: 0 };
  }

  // Stage 1: Detect regions
  const regions = detectRegions(text);
  logger.info(
    { action: 'clauseExtraction.stage1', contractVersionId, regionsDetected: regions.length },
    'Stage 1 complete',
  );

  // Stage 2: Classify + upsert each region
  let clausesUpserted = 0;
  let clausesFailed = 0;
  let totalObligationsCreated = 0;

  for (const region of regions) {
    try {
      const result = await classifyRegion(region, contractVersionId, actorId);
      if (!result) {
        clausesFailed++;
        continue;
      }

      // Generate embedding for the clause summary
      const embedding = await generateEmbedding(result.summaryEn, contractVersionId, actorId);

      // DB signature: fn_clause_upsert(p_contract_version_id, p_clause_type_v2, p_parameters, p_text_excerpts,
      //   p_page_no, p_source_offset_start, p_source_offset_end, p_confidence, p_extraction_model_version,
      //   p_extraction_prompt_hash, p_embedding, p_summary_en, p_summary_ar, p_actor_id) — 14 args
      const upsertResult = await db.callFunction<{
        clauseId: number;
        reviewStatus: string;
        obligationsCreated: number[];
        obligationsSkippedAsDup: number;
        obligationDerivationError: string | null;
      }>(
        'fn_clause_upsert',
        [
          contractVersionId,
          result.clauseTypeV2,
          result.parameters,
          result.textExcerpts,
          region.pageHint,
          region.offsetStart,
          region.offsetEnd,
          result.confidence,
          'gpt-4o',                              // p_extraction_model_version
          null,                                  // p_extraction_prompt_hash — deferred per M11 pattern
          embedding ? `[${embedding.join(',')}]` : null, // p_embedding
          result.summaryEn,
          result.summaryAr,
          actorId,
        ],
        { actorId, tenantId: ADNOC_TENANT_ID },
      );

      if (upsertResult) {
        clausesUpserted++;
        totalObligationsCreated += upsertResult.obligationsCreated?.length ?? 0;

        if (upsertResult.obligationDerivationError) {
          logger.warn(
            {
              action: 'clauseExtraction.upsert',
              contractVersionId,
              clauseId: upsertResult.clauseId,
              error: upsertResult.obligationDerivationError,
            },
            'Obligation derivation error (clause still persisted per OD-5 SAVEPOINT)',
          );
        }
      }
    } catch (err) {
      clausesFailed++;
      logger.warn(
        {
          action: 'clauseExtraction.upsertError',
          contractVersionId,
          clauseTypeHint: region.clauseTypeHint,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          errorMessage: err instanceof Error ? err.message : String(err),
        },
        'Failed to upsert clause',
      );
    }
  }

  const summary: ExtractionSummary = {
    contractVersionId,
    regionsDetected: regions.length,
    clausesUpserted,
    clausesFailed,
    obligationsCreated: totalObligationsCreated,
  };

  logger.info({ action: 'clauseExtraction.complete', ...summary }, 'Clause extraction complete');
  return summary;
}

/**
 * Trigger clause extraction via fn_clause_extraction_request.
 * Called from the HTTP controller — enqueues the request and returns immediately.
 * The actual work is done by clause-extraction.worker.ts.
 */
export async function triggerExtractionRequest(
  contractId: number,
  versionId: number | null,
  forceReprocess: boolean,
  actorId: number,
): Promise<{ queued: boolean; extractionRunId: number | null; reason?: string }> {
  // DB signature: fn_clause_extraction_request(p_contract_version_id, p_actor_id) — 2 args.
  // contractId + versionId resolution happens inside fn_; forceReprocess not a DB param.
  const result = await db.callFunction<{
    queued: boolean;
    extractionRunId: number | null;
    reason?: string;
  }>(
    'fn_clause_extraction_request',
    [versionId ?? contractId, actorId],
    { actorId, tenantId: ADNOC_TENANT_ID },
  );

  return result ?? { queued: false, extractionRunId: null, reason: 'no_result' };
}

/**
 * Generate embedding for a query text (used by semantic search endpoint).
 * Throws UnprocessableEntityError on failure (the HTTP controller surfaces this as 422).
 * SENSITIVE: queryText not logged.
 */
export async function embedQueryText(
  queryText: string,
  actorId: number,
): Promise<{ embedding: number[]; logId: number | null }> {
  const openai = getOpenAIClient();
  const startMs = Date.now();
  let tokensInput: number | null = null;
  let logResult: { id: number } | null = null;

  try {
    const response = await openai.embeddings.create({
      model: 'text-embedding-3-small',
      input: queryText.slice(0, 8191),
    });

    tokensInput = response.usage?.prompt_tokens ?? null;
    const embedding = response.data[0]?.embedding;

    if (!embedding) {
      throw new UnprocessableEntityError('Embedding API returned no vector');
    }

    // logResult is populated asynchronously in the finally block (after this return).
    // The caller receives logId=null; the telemetry row is persisted regardless.
    return { embedding, logId: null };
  } catch (err) {
    if (err instanceof UnprocessableEntityError) throw err;
    throw new UnprocessableEntityError(
      `Embedding generation failed: ${err instanceof Error ? err.message : String(err)}`,
    );
  } finally {
    const latencyMs = Date.now() - startMs;
    const telemetryResult = await recordAiTelemetry({
      promptId: 'clause-extraction-stage-2',
      mode: 'clause_embed',
      actorUserId: actorId,
      entityType: null,
      entityId: null,
      language: 'en',
      provider: 'openai',
      modelUsed: 'text-embedding-3-small',
      tokensInput,
      tokensOutput: null,
      costUsdMicros: tokensInput != null ? Math.round(tokensInput * 0.02 / 1_000_000 * 1_000_000) : null,
      latencyMs,
      cacheHit: false,
      streamMode: false,
      outcome: logResult === null ? 'error' : 'success',
    });
    if (telemetryResult) {
      logResult = telemetryResult as { id: number };
    }
  }
}
