/**
 * S1 — POST /api/v1/ai/contract-insights
 *
 * 6 modes:
 *   - summary, rewrite        → SSE streaming
 *   - key_terms, risks,
 *     obligations, regulatory → non-streaming tool-call JSON
 *
 * Cache: 24h via fn_ai_insight_get_cached / _upsert.
 * Persists summary/risk to contract.ai_summary_en / ai_summary_ar /
 * ai_risk_score via fn_contract_ai_summary_persist (DEFINER carve-out).
 *
 * Sensitive logging:
 *   - selectedText (rewrite mode) NEVER logged.
 *   - Pino redact treats selectedText / ai_prompt_payload as redacted.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import {
  ApiError,
  ForbiddenError,
  InternalError,
  NotFoundError,
  RateLimitError,
} from '../../utils/errors.util';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import { buildPayloadHash, getCached, upsertCache } from '../../services/ai/_shared/cache-layer';
import * as service from '../../services/ai/openai-contract-insights.service';
import type { AiContractInsightsRequestInput } from '../../schemas/ai.schemas';
import type {
  AiContractInsightsResponseBody,
  AiContractKeyTermsPayload,
  AiContractObligationsPayload,
  AiContractRegulatoryPayload,
  AiContractRewritePayload,
  AiContractRisksPayload,
  AiContractSummaryPayload,
  AiInsightType,
  AiInsightsStreamChunk,
  AiLanguage,
  ContractAiSummaryPersistData,
} from '../../types/ai.types';
import type { Contract as ContractEntity } from '../../types/contracts.types';

const PROMPT_ID = service.PROMPT_ID;
const MODE_TO_INSIGHT_TYPE: Record<
  AiContractInsightsRequestInput['mode'],
  AiInsightType
> = {
  summary: 'contract_summary',
  key_terms: 'contract_key_terms',
  risks: 'contract_risks',
  obligations: 'contract_obligations',
  regulatory: 'contract_regulatory',
  rewrite: 'contract_rewrite',
};

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const sseFrame = (chunk: AiInsightsStreamChunk): string =>
  `data: ${JSON.stringify(chunk)}\n\n`;

export const contractInsightsController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const body = req.body as AiContractInsightsRequestInput;
    const userId = req.user!.id;
    const language: AiLanguage = body.language;
    const insightType = MODE_TO_INSIGHT_TYPE[body.mode];

    req.logger.info(
      {
        action: 'aiContractInsights.invoke',
        userId,
        method: req.method,
        path: req.path,
        contractId: body.contractId,
        mode: body.mode,
        language,
        // selectedText NEVER logged (sensitive).
        selectedTextLen: body.selectedText?.length ?? 0,
      },
      'Controller entry',
    );

    let cacheHit = false;
    let outcome: 'success' | 'error' | 'timeout' | 'rate_limited' | 'cancelled' = 'error';
    let modelUsed = '';
    let tokensInput: number | null = null;
    let tokensOutput: number | null = null;
    let errorClass: string | null = null;
    let errorMessage: string | null = null;
    const isStreaming = body.mode === 'summary' || body.mode === 'rewrite';

    // ============================================================
    // Pre-flight: contract scope + rate limit
    // ============================================================
    let contract: ContractEntity | null;
    try {
      contract = await db.callFunction<ContractEntity | null>(
        'fn_contract_get_by_id',
        [body.contractId, userId, req.user!.role],
        { actorId: userId },
      );
      if (!contract) {
        const exists = await db.checkActiveRowExists('contract', body.contractId);
        if (exists) {
          throw new ForbiddenError('Forbidden');
        }
        throw new NotFoundError('Contract not found', { contractId: 'Contract not found' });
      }
    } catch (err) {
      errorClass = err instanceof Error ? err.name : 'UNKNOWN';
      errorMessage = err instanceof Error ? err.message : String(err);
      await recordAiTelemetry({
        promptId: PROMPT_ID,
        mode: body.mode,
        actorUserId: userId,
        entityType: 'contract',
        entityId: body.contractId,
        language,
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: isStreaming,
        outcome: 'error',
        errorClass,
        errorMessage,
        latencyMs: Date.now() - startTime,
      });
      next(err);
      return;
    }

    let limit;
    try {
      limit = await checkRateLimit(userId, PROMPT_ID);
    } catch (err) {
      next(err);
      return;
    }
    if (!limit.allowed) {
      res.setHeader('Retry-After', String(limit.retryAfterSeconds));
      await recordAiTelemetry({
        promptId: PROMPT_ID,
        mode: body.mode,
        actorUserId: userId,
        entityType: 'contract',
        entityId: body.contractId,
        language,
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: isStreaming,
        outcome: 'rate_limited',
        latencyMs: Date.now() - startTime,
      });
      next(new RateLimitError('AI rate limit exceeded'));
      return;
    }

    // ============================================================
    // Cache lookup
    // ============================================================
    // Body excerpt from fn_contract_get_by_id (bodyEn/bodyAr — sensitive; pino-redacted).
    // We slice to the first 4000 chars to bound prompt size; the prompt template
    // expects {{bodyExcerpt}}.
    const bodySource =
      language === 'ar' ? contract.bodyAr ?? contract.bodyEn ?? '' : contract.bodyEn ?? contract.bodyAr ?? '';
    const bodyExcerpt = bodySource.length > 4000 ? bodySource.slice(0, 4000) : bodySource;

    const ctx: service.ContractInsightsContext = {
      mode: body.mode,
      language,
      contractNumber: contract.contractNumber ?? '',
      contractType: contract.contractType ?? '',
      titleEn: contract.titleEn ?? '',
      // ourPartyName / counterpartyName not yet projected by fn_contract_get_by_id
      // (M1a entity surface). Prompt receives the IDs as a placeholder until M1a
      // extends the projection — flagged as carryover from AI-OI-A.
      ourPartyName: contract.ourPartyId !== null ? `party:${contract.ourPartyId}` : '',
      counterpartyName: contract.counterpartyId !== null ? `party:${contract.counterpartyId}` : '',
      valueAed: contract.valueAed ?? null,
      startDate: contract.startDate ?? null,
      endDate: contract.endDate ?? null,
      bodyExcerpt,
      ...(body.selectedText !== undefined ? { selectedText: body.selectedText } : {}),
    };

    const payloadHashSeed = {
      promptId: PROMPT_ID,
      mode: body.mode,
      language,
      contractId: body.contractId,
      contractUpdatedAt: contract.updatedAt ?? null,
      // selectedText IS part of the cache key for rewrite mode (different selections
      // legitimately produce different rewrites).
      ...(body.mode === 'rewrite' ? { selectedText: body.selectedText ?? '' } : {}),
    };
    const payloadHash = buildPayloadHash(payloadHashSeed);

    // For non-streaming modes attempt cache; streaming modes bypass cache
    // (different inputs → different output; persistence is the side effect).
    if (!isStreaming) {
      try {
        const cached = await getCached({
          entityType: 'contract',
          entityId: body.contractId,
          insightType,
          language,
          payloadHash,
          actorUserId: userId,
        });
        if (cached) {
          cacheHit = true;
          outcome = 'success';
          modelUsed = cached.modelUsed;
          res.setHeader('X-AI-Cache', 'HIT');
          // Build the response shape per AiContractInsightsResponseBody.
          const responseBody: AiContractInsightsResponseBody | null = (() => {
            switch (body.mode) {
              case 'key_terms':
                return { mode: 'key_terms', payload: cached.payload as AiContractKeyTermsPayload };
              case 'risks':
                return { mode: 'risks', payload: cached.payload as AiContractRisksPayload };
              case 'obligations':
                return { mode: 'obligations', payload: cached.payload as AiContractObligationsPayload };
              case 'regulatory':
                return { mode: 'regulatory', payload: cached.payload as AiContractRegulatoryPayload };
              default:
                return null;
            }
          })();
          if (responseBody) {
            res.status(200).json({ success: true, data: responseBody, requestId: req.requestId });
            await recordAiTelemetry({
              promptId: PROMPT_ID,
              mode: body.mode,
              actorUserId: userId,
              entityType: 'contract',
              entityId: body.contractId,
              language,
              provider: 'openai',
              modelUsed,
              cacheHit: true,
              streamMode: false,
              outcome: 'success',
              latencyMs: Date.now() - startTime,
            });
            req.logger.info(
              { action: 'aiContractInsights.invoke', userId, cacheHit: true, mode: body.mode, duration: Date.now() - startTime, statusCode: 200 },
              'Controller exit (cache hit)',
            );
            return;
          }
        }
      } catch (err) {
        // Cache lookup failure: log + fall through to provider call.
        req.logger.warn(
          { action: 'aiContractInsights.cache_lookup_failed', userId, errorType: errorTypeOf(err) },
          'Cache lookup failed — proceeding to provider',
        );
      }
      res.setHeader('X-AI-Cache', 'MISS');
    }

    // ============================================================
    // Provider call
    // ============================================================
    try {
      const systemPrompt = await service.buildSystemPrompt(ctx);
      const userMessage =
        body.mode === 'rewrite' && body.selectedText
          ? `Rewrite this clause:\n\n${body.selectedText}`
          : `Mode: ${body.mode}. Language: ${language}.`;

      if (isStreaming) {
        // ---------- SSE path (summary / rewrite) ----------
        res.status(200);
        res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
        res.setHeader('Cache-Control', 'no-cache, no-transform');
        res.setHeader('Connection', 'keep-alive');
        res.setHeader('X-Accel-Buffering', 'no');
        res.setHeader('X-AI-Cache', 'MISS');
        res.flushHeaders?.();

        const abortController = new AbortController();
        let stillOpen = true;
        req.on('close', () => {
          if (stillOpen) abortController.abort();
        });

        const { stream, tokensConsumed, collectedText } = service.streamInsights({
          systemPrompt,
          userMessage,
          abortSignal: abortController.signal,
        });
        try {
          for await (const delta of stream) {
            if (!stillOpen) break;
            res.write(sseFrame({ type: 'token', delta }));
          }
        } catch (streamErr) {
          stillOpen = false;
          const code = streamErr instanceof RateLimitError ? 'rate_limit_exceeded' : 'ai_provider_error';
          const message = streamErr instanceof Error ? streamErr.message : 'AI provider error';
          try {
            res.write(sseFrame({ type: 'error', code, message }));
          } catch {
            /* swallow */
          }
          outcome = 'error';
          errorClass = streamErr instanceof Error ? streamErr.name : 'UNKNOWN';
          errorMessage = message;
          throw streamErr;
        }

        // After stream completes — upsert cache + persist if summary
        const finalTokens = tokensConsumed();
        modelUsed = 'gpt-4o';
        tokensInput = null;
        tokensOutput = finalTokens;

        let persisted: ContractAiSummaryPersistData | null = null;
        if (body.mode === 'summary') {
          // Persist to contract.ai_summary_* via fn_contract_ai_summary_persist
          const summaryText = collectedText();
          const summaryEn = language === 'ar' ? null : summaryText;
          const summaryAr = language === 'ar' ? summaryText : null;
          try {
            const wrapper = await db.callFunction<{ data: ContractAiSummaryPersistData }>(
              'fn_contract_ai_summary_persist',
              [body.contractId, userId, summaryEn, summaryAr, null /* riskScore — separate prompt */],
              { actorId: userId },
            );
            persisted = wrapper?.data ?? null;
          } catch (persistErr) {
            req.logger.warn(
              { action: 'aiContractInsights.persist_failed', userId, errorType: errorTypeOf(persistErr) },
              'fn_contract_ai_summary_persist failed (non-fatal)',
            );
          }

          // Cache as contract_summary payload
          const payload: AiContractSummaryPayload = {
            insightType: 'contract_summary',
            summary: summaryText,
            language,
          };
          try {
            await upsertCache({
              entityType: 'contract',
              entityId: body.contractId,
              insightType: 'contract_summary',
              language,
              provider: 'openai',
              modelUsed,
              payload,
              payloadHash,
              promptId: PROMPT_ID,
              tokensInput: null,
              tokensOutput: finalTokens,
              actorUserId: userId,
            });
          } catch (upsertErr) {
            req.logger.warn(
              { action: 'aiContractInsights.cache_upsert_failed', userId, errorType: errorTypeOf(upsertErr) },
              'Cache upsert failed (non-fatal)',
            );
          }
        } else if (body.mode === 'rewrite') {
          const rewrittenText = collectedText();
          const payload: AiContractRewritePayload = {
            insightType: 'contract_rewrite',
            rewrittenText,
          };
          try {
            await upsertCache({
              entityType: 'contract',
              entityId: body.contractId,
              insightType: 'contract_rewrite',
              language,
              provider: 'openai',
              modelUsed,
              payload,
              payloadHash,
              promptId: PROMPT_ID,
              tokensInput: null,
              tokensOutput: finalTokens,
              actorUserId: userId,
            });
          } catch (upsertErr) {
            req.logger.warn(
              { action: 'aiContractInsights.cache_upsert_failed', userId, errorType: errorTypeOf(upsertErr) },
              'Cache upsert failed (non-fatal)',
            );
          }
        }

        outcome = 'success';
        try {
          res.write(sseFrame({ type: 'done', tokensConsumed: finalTokens, persisted }));
        } catch {
          /* swallow */
        }
        try {
          res.end();
        } catch {
          /* swallow */
        }
        stillOpen = false;
      } else {
        // ---------- Non-streaming tool-call path ----------
        const result = await service.callToolMode({
          mode: body.mode as 'key_terms' | 'risks' | 'obligations' | 'regulatory',
          systemPrompt,
          userMessage,
        });
        modelUsed = result.modelUsed;
        tokensInput = result.tokensInput;
        tokensOutput = result.tokensOutput;
        outcome = 'success';

        // Cache the response
        try {
          await upsertCache({
            entityType: 'contract',
            entityId: body.contractId,
            insightType,
            language,
            provider: 'openai',
            modelUsed,
            payload: result.payload,
            payloadHash,
            promptId: PROMPT_ID,
            tokensInput,
            tokensOutput,
            actorUserId: userId,
          });
        } catch (upsertErr) {
          req.logger.warn(
            { action: 'aiContractInsights.cache_upsert_failed', userId, errorType: errorTypeOf(upsertErr) },
            'Cache upsert failed (non-fatal)',
          );
        }

        const responseBody: AiContractInsightsResponseBody | null = (() => {
          switch (body.mode) {
            case 'key_terms':
              return { mode: 'key_terms', payload: result.payload as AiContractKeyTermsPayload };
            case 'risks':
              return { mode: 'risks', payload: result.payload as AiContractRisksPayload };
            case 'obligations':
              return { mode: 'obligations', payload: result.payload as AiContractObligationsPayload };
            case 'regulatory':
              return { mode: 'regulatory', payload: result.payload as AiContractRegulatoryPayload };
            default:
              return null;
          }
        })();
        if (!responseBody) {
          throw new InternalError('Unsupported mode');
        }
        res.status(200).json({ success: true, data: responseBody, requestId: req.requestId });
      }

      req.logger.info(
        {
          action: 'aiContractInsights.invoke',
          userId,
          mode: body.mode,
          cacheHit,
          tokensInput,
          tokensOutput,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
    } catch (err) {
      outcome = outcome === 'error' ? 'error' : 'error';
      errorClass = err instanceof Error ? err.name : 'UNKNOWN';
      errorMessage = err instanceof Error ? err.message : String(err);
      req.logger.error(
        {
          action: 'aiContractInsights.invoke',
          userId,
          mode: body.mode,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      // For non-streaming we can still next(error). For streaming the response
      // is already committed — just record telemetry.
      if (!isStreaming) {
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          mode: body.mode,
          actorUserId: userId,
          entityType: 'contract',
          entityId: body.contractId,
          language,
          provider: 'openai',
          modelUsed: modelUsed || 'unknown',
          tokensInput,
          tokensOutput,
          cacheHit,
          streamMode: false,
          outcome: 'error',
          errorClass,
          errorMessage,
          latencyMs: Date.now() - startTime,
        });
        next(err);
        return;
      }
    } finally {
      // Telemetry (every invocation — including streaming success path).
      if (isStreaming || outcome === 'success') {
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          mode: body.mode,
          actorUserId: userId,
          entityType: 'contract',
          entityId: body.contractId,
          language,
          provider: 'openai',
          modelUsed: modelUsed || 'unknown',
          tokensInput,
          tokensOutput,
          cacheHit,
          streamMode: isStreaming,
          outcome,
          errorClass,
          errorMessage,
          latencyMs: Date.now() - startTime,
        });
      }
    }
  },
};
