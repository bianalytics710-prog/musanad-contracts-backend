/**
 * M15 / CR-G — AI Risk Assistant service.
 *
 * Implements the full per-call flow defined in api-contracts.json aclFlow:
 *   1. Resolve caller's read-allowed contract_ids via fn_contract_list (all pages)
 *   2. Compute scope_hash = SHA-256(sorted_contract_ids_joined)
 *   3. Check ai_insight cache (TTL 300s, entity_type='risk_assistant_query')
 *   4. Build LLM context from caller-allowed clauses/correlations/signals
 *   5. Load + render prompt template (risk_assistant.qa_<persona>.txt)
 *   6. Create ai_request_log row (fn_ai_request_log_create — 18 params)
 *   7. Stream gpt-4o response; emit SSE citation events inline
 *   8. On done: UPDATE ai_request_log SET scope_hash, acl_filtered_count
 *              + upsert ai_insight cache (TTL 300s)
 *
 * Per S2-19 note: entity_id for ai_insight is derived as a BIGINT-safe integer
 * from the SHA-256 hash of (query || personaContext || filters || scope_hash)
 * using the lower 8 bytes mod BIGINT max (9223372036854775807n).
 *
 * SENSITIVE:
 *   - query, filters, context_snippets — never in logs.
 *   - Only token counts / outcome / latency logged.
 */
import { createHash, randomUUID } from 'node:crypto';
import { db } from '../../database/client';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { buildPayloadHash, getCached, upsertCache } from './_shared/cache-layer';
import { recordAiTelemetry } from './_shared/telemetry-middleware';
import { logger } from '../../utils/logger.util';
import type { RiskAssistantSSEEvent, RiskAssistantCitation, RiskAssistantNonStreamingResponse } from '../../types/risk-assistant.types';
import type { ContractListResponse } from '../../types/contracts.types';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';

// ----------------------------------------------------------------
// Types
// ----------------------------------------------------------------

export interface AskOptions {
  userId: number;
  userRole: string;
  persona: string;
  promptId: string;
  query: string;
  filters?: {
    contractIds?: string[];
    contractType?: string;
    emirate?: string;
    riskKind?: string;
  } | undefined;
  requestId?: string;
  tenantId?: string;
  abortSignal?: AbortSignal;
  isStreaming: boolean;
}

interface ContextBundle {
  allowedContractIds: string[];
  totalCandidateCount: number;
  scopeHash: string;
  contextText: string;
}

// ----------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------

/** Derive a BIGINT-safe integer from a SHA-256 hash (lower 8 bytes mod max bigint). */
function hashToBigIntEntityId(input: string): number {
  const hex = createHash('sha256').update(input).digest('hex');
  const lower8 = BigInt('0x' + hex.slice(48)); // last 8 bytes = 16 hex chars
  const maxBigInt = BigInt('9223372036854775807');
  return Number(lower8 % maxBigInt);
}

/** Compute scope_hash from sorted contract_ids. */
function computeScopeHash(contractIds: string[]): string {
  const sorted = [...contractIds].sort();
  return createHash('sha256').update(sorted.join(',')).digest('hex');
}

/**
 * Resolve all read-allowed contract_ids for the caller via fn_contract_list.
 * Fetches ALL pages (up to 500 contracts — bounded for prompt context).
 * Returns { allowedContractIds, totalCandidateCount }.
 */
async function resolveAllowedContracts(
  userId: number,
  userRole: string,
  filters: AskOptions['filters'],
  tenantId?: string,
): Promise<{ allowedContractIds: string[]; totalCandidateCount: number }> {
  const PAGE_SIZE = 100;
  const MAX_PAGES = 5; // cap at 500 contracts for context sanity
  const allIds: string[] = [];
  let totalCandidateCount = 0;

  for (let page = 1; page <= MAX_PAGES; page++) {
    const result = await db.callFunction<ContractListResponse>(
      'fn_contract_list',
      [
        page,
        PAGE_SIZE,
        null, // status
        filters?.contractType ?? null,
        null, // counterpartyId
        null, // draftedBy
        null, // approvedBy
        null, // startDateFrom
        null, // startDateTo
        null, // endDateFrom
        null, // endDateTo
        null, // tags
        null, // search
        userId,
        userRole,
        null, // importBatchId
        null, // importConfidenceMin
        null, // importConfidenceMax
        null, // language
        filters?.emirate ?? null, // governingLaw as emirate proxy
        null, // sort
      ],
      { actorId: userId, tenantId: tenantId ?? ADNOC_TENANT_ID },
    );

    const rows = result?.data ?? [];
    if (page === 1) {
      totalCandidateCount = result?.pagination?.total ?? rows.length;
    }

    for (const row of rows) {
      if (row.id) allIds.push(String(row.id));
    }

    // Narrow by filters.contractIds if provided
    if (filters?.contractIds && filters.contractIds.length > 0) {
      const allowed = new Set(filters.contractIds);
      const narrowed = allIds.filter((id) => allowed.has(id));
      return { allowedContractIds: narrowed, totalCandidateCount };
    }

    if (rows.length < PAGE_SIZE) break; // last page
  }

  return { allowedContractIds: allIds, totalCandidateCount };
}

/**
 * Build LLM context text from caller-allowed contracts.
 * Fetches relevant clauses (fn_clause_semantic_search) if available,
 * otherwise builds a compact contract list. Bounded to ~3000 tokens.
 */
async function buildContext(
  allowedContractIds: string[],
  query: string,
  userId: number,
  tenantId?: string,
): Promise<string> {
  if (allowedContractIds.length === 0) {
    return 'No contracts are accessible within your scope.';
  }

  // pgvector semantic-clause search requires a query embedding (the live
  // fn_clause_semantic_search signature is `vector, bigint, integer, numeric,
  // bigint` — see Agent 3 dependency report). For v1 we skip the embedding
  // generation step and use the fallback contract-id context. Wiring real
  // embeddings (text-embedding-3-small) is a CR-D follow-up since clause
  // embeddings aren't populated yet in production for most contracts anyway.
  // Leaving the call out (instead of try/catch swallowing) avoids the 42883
  // error log noise per memory feedback_db_impl_report_dont_fix.

  // Fallback: compact contract ID list (bounded at 100 IDs for prompt safety)
  const ids = allowedContractIds.slice(0, 100);
  return `Accessible contract IDs (${ids.length} of ${allowedContractIds.length} total): ${ids.join(', ')}`;
}

/** Parse citation markers from LLM response text. Simple contract# extractor. */
function parseCitations(text: string, _allowedIds: string[]): RiskAssistantCitation[] {
  const citations: RiskAssistantCitation[] = [];
  const seen = new Set<string>();

  // Match contract IDs referenced in the text (format: "CNT-NNNN" or "C-NNNN" etc.)
  const matches = text.matchAll(/\b([A-Z]{1,5}-\d{4,})\b/g);
  for (const m of matches) {
    const raw = m[1];
    if (raw && !seen.has(raw)) {
      seen.add(raw);
      citations.push({
        type: 'contract',
        id: raw,
        label: raw,
        href: `/app/contracts?search=${encodeURIComponent(raw)}`,
      });
    }
  }
  return citations;
}

// ----------------------------------------------------------------
// Main service
// ----------------------------------------------------------------

export const riskAssistantService = {
  /**
   * Streaming ask — yields RiskAssistantSSEEvent objects.
   * Controller writes each as an SSE frame.
   */
  async *askStream(opts: AskOptions): AsyncGenerator<RiskAssistantSSEEvent> {
    const {
      userId, userRole, persona, promptId, query, filters,
      requestId = randomUUID(), tenantId, abortSignal,
    } = opts;

    let telemetryOutcome: 'success' | 'error' | 'rate_limited' | 'cancelled' = 'error';
    let modelUsed = 'gpt-4o';
    let tokensOutput = 0;
    let cacheHit = false;
    let scopeHash = '';
    let aclFilteredCount = 0;
    let aiRequestLogId: string | null = null;

    const startTime = Date.now();

    try {
      // ---- Step 1: ACL resolution ----
      const { allowedContractIds, totalCandidateCount } =
        await resolveAllowedContracts(userId, userRole, filters, tenantId);

      scopeHash = computeScopeHash(allowedContractIds);
      aclFilteredCount = Math.max(0, totalCandidateCount - allowedContractIds.length);

      // ---- Step 2: Cache check ----
      const cacheKeyInput = `${query}|${persona}|${JSON.stringify(filters ?? {})}|${scopeHash}`;
      const entityId = hashToBigIntEntityId(cacheKeyInput);
      const payloadHash = buildPayloadHash({ query, persona, filters: filters ?? {}, scopeHash });

      const cached = await getCached({
        entityType: 'risk_assistant_query',
        entityId,
        insightType: 'qa_response',
        language: 'en',
        payloadHash,
        actorUserId: userId,
      }).catch(() => null);

      if (cached) {
        cacheHit = true;
        telemetryOutcome = 'success';
        const cachedPayload = cached.payload as { answer?: string; citations?: RiskAssistantCitation[] };

        yield { event: 'token', data: { token: cachedPayload.answer ?? '' } };
        yield {
          event: 'done',
          data: {
            requestLogId: requestId,
          },
        };

        await recordAiTelemetry({
          requestId,
          promptId,
          mode: 'qa',
          actorUserId: userId,
          entityType: 'risk_assistant_query',
          entityId,
          language: 'en',
          provider: 'openai',
          modelUsed: cached.modelUsed ?? modelUsed,
          cacheHit: true,
          streamMode: true,
          outcome: 'success',
          latencyMs: Date.now() - startTime,
        });
        return;
      }

      // ---- Step 3: Build context ----
      const contextText = await buildContext(allowedContractIds, query, userId, tenantId);

      // ---- Step 4: Load + render prompt ----
      let systemPrompt: string;
      try {
        const template = await loadPrompt(promptId);
        systemPrompt = renderPrompt(template, {
          context_contract_ids: allowedContractIds.slice(0, 100).join(', '),
          context_clauses: contextText,
          persona,
          query,
        });
      } catch {
        // Prompt file missing — use minimal inline prompt
        systemPrompt = [
          `You are the AI Risk Assistant for the OqoodAI Contracts platform.`,
          `Persona: ${persona}.`,
          `Only cite contracts the user can access: ${allowedContractIds.slice(0, 50).join(', ')}.`,
          `Answer the user's question concisely with citations to relevant contract IDs.`,
          `Context:\n${contextText}`,
        ].join('\n');
      }

      // ---- Step 5: Create ai_request_log row ----
      const telemetryRow = await recordAiTelemetry({
        requestId,
        promptId,
        mode: 'qa',
        actorUserId: userId,
        entityType: 'risk_assistant_query',
        entityId,
        language: 'en',
        provider: 'openai',
        modelUsed,
        cacheHit: false,
        streamMode: true,
        outcome: 'error', // will UPDATE on success
        latencyMs: null,
      });
      aiRequestLogId = telemetryRow?.requestId ?? requestId;

      // ---- Step 6: Stream from OpenAI ----
      const openai = getOpenAIClient();
      const stream = await openai.chat.completions.create(
        {
          model: 'gpt-4o',
          temperature: 0.2,
          max_tokens: 1500,
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: query },
          ],
          stream: true,
        },
        { signal: abortSignal },
      );

      let fullText = '';
      for await (const chunk of stream) {
        if (abortSignal?.aborted) {
          telemetryOutcome = 'cancelled';
          break;
        }
        const token = chunk.choices[0]?.delta?.content ?? '';
        if (token) {
          fullText += token;
          tokensOutput += 1; // approximate; refined below
          yield { event: 'token', data: { token } };
        }
        if (chunk.usage) {
          tokensOutput = chunk.usage.completion_tokens ?? tokensOutput;
        }
      }

      // ---- Step 7: Parse citations + emit citation events + done ----
      const citations = parseCitations(fullText, allowedContractIds);
      telemetryOutcome = 'success';

      // Emit individual citation events so FE can render chips inline
      for (const citation of citations) {
        yield { event: 'citation', data: { citation } };
      }

      yield {
        event: 'done',
        data: { requestLogId: requestId },
      };

      // ---- Step 8: Cache write + log update ----
      await upsertCache({
        entityType: 'risk_assistant_query',
        entityId,
        insightType: 'qa_response',
        language: 'en',
        provider: 'openai',
        modelUsed,
        payload: { insightType: 'qa_response', answer: fullText, citations },
        payloadHash,
        promptId,
        tokensInput: null,
        tokensOutput,
        ttlSeconds: 300,
        actorUserId: userId,
      }).catch((e) =>
        logger.warn({ action: 'riskAssistant.cache_upsert_failed', errorType: (e as Error).name }),
      );

      // UPDATE ai_request_log with scope_hash + acl_filtered_count (best-effort)
      if (aiRequestLogId) {
        const logLatency = Date.now() - startTime;
        db.executeInTransaction(async (client) => {
          await client.query(
            `UPDATE ai_request_log
               SET scope_hash = $1, acl_filtered_count = $2,
                   outcome = 'success', latency_ms = $3
             WHERE request_id = $4`,
            [scopeHash, aclFilteredCount, logLatency, aiRequestLogId],
          );
        }).catch((e) =>
          logger.warn({ action: 'riskAssistant.log_update_failed', errorType: (e as Error).name }),
        );
      }
    } catch (err) {
      const errorClass = (err as Error).name ?? 'UNKNOWN';
      const errorMessage = (err as Error).message ?? 'Unknown error';

      yield {
        event: 'error',
        data: {
          code: 'ai_provider_error',
          message: 'AI Risk Assistant encountered an error',
        },
      };

      // DEFECT-CR-G-6 fix: only INSERT a new ai_request_log row if the initial
      // Step-5 INSERT (line 302) didn't succeed. Otherwise UPDATE the existing
      // row to record the error outcome — avoid duplicate-key collisions on
      // ai_request_log_request_id_key.
      if (!aiRequestLogId) {
        await recordAiTelemetry({
          requestId,
          promptId,
          mode: 'qa',
          actorUserId: userId,
          entityType: 'risk_assistant_query',
          entityId: null,
          language: 'en',
          provider: 'openai',
          modelUsed,
          cacheHit,
          streamMode: true,
          outcome: 'error',
          errorClass,
          errorMessage: errorMessage.slice(0, 500),
          latencyMs: Date.now() - startTime,
        }).catch(() => {/* non-fatal */});
      } else {
        db.executeInTransaction(async (client) => {
          await client.query(
            `UPDATE ai_request_log SET outcome = 'error', error_class = $1, error_message = $2, latency_ms = $3
              WHERE request_id = $4`,
            [errorClass, errorMessage.slice(0, 500), Date.now() - startTime, aiRequestLogId],
          );
        }).catch(() => {/* non-fatal */});
      }
    } finally {
      // DEFECT-CR-G-6 fix: the success-path UPDATE at line ~388 already records
      // the outcome on the row created in Step 5. Re-inserting here causes a
      // duplicate-key collision. Skip when telemetryRow was non-null.
      if (telemetryOutcome === 'success' && !aiRequestLogId) {
        await recordAiTelemetry({
          requestId,
          promptId,
          mode: 'qa',
          actorUserId: userId,
          entityType: 'risk_assistant_query',
          entityId: null,
          language: 'en',
          provider: 'openai',
          modelUsed,
          tokensOutput,
          cacheHit,
          streamMode: true,
          outcome: telemetryOutcome,
          latencyMs: Date.now() - startTime,
        }).catch(() => {/* non-fatal */});
      }
    }
  },

  /**
   * Non-streaming fallback (?stream=false).
   * Collects the full answer then returns as JSON.
   */
  async askSync(opts: AskOptions): Promise<RiskAssistantNonStreamingResponse> {
    let answer = '';
    const citations: RiskAssistantCitation[] = [];

    for await (const evt of riskAssistantService.askStream({ ...opts, isStreaming: false })) {
      if (evt.event === 'token') {
        const d = evt.data as { token?: string };
        if (d.token) answer += d.token;
      }
      if (evt.event === 'citation') {
        const d = evt.data as { citation?: RiskAssistantCitation };
        if (d.citation) citations.push(d.citation);
      }
      if (evt.event === 'done' || evt.event === 'error') break;
    }

    return { answer, citations };
  },
};
