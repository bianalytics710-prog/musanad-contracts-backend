/**
 * S4 — POST /api/v1/ai/regulatory-impact (SSE)
 *
 * Streaming. STATELESS payload-driven. Cache TTL 24h via fn_ai_insight cache
 * (entity_type='regulatory_update', entity_id=NULL, content-hash addressed).
 *
 * Sensitive logging: summaryEn / sampleContracts NEVER logged.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, RateLimitError } from '../../utils/errors.util';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import { buildPayloadHash, upsertCache } from '../../services/ai/_shared/cache-layer';
import * as service from '../../services/ai/openai-regulatory-impact.service';
import type { AiRegulatoryImpactRequestInput } from '../../schemas/ai.schemas';
import type {
  AiRegulatoryImpactPayload,
  AiRegulatoryImpactStreamChunk,
} from '../../types/ai.types';

const PROMPT_ID = service.PROMPT_ID;

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const sseFrame = (chunk: AiRegulatoryImpactStreamChunk): string =>
  `data: ${JSON.stringify(chunk)}\n\n`;

export const regulatoryImpactController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const body = req.body as AiRegulatoryImpactRequestInput;
    const userId = req.user!.id;
    const language = body.language;

    req.logger.info(
      {
        action: 'aiRegulatoryImpact.invoke',
        userId,
        method: req.method,
        path: req.path,
        mode: body.mode,
        regulator: body.regulator,
        language,
        sampleCount: body.sampleContracts?.length ?? 0,
      },
      'Controller entry',
    );

    let outcome: 'success' | 'error' | 'timeout' | 'rate_limited' | 'cancelled' = 'error';
    let modelUsed = '';
    let tokensInput: number | null = null;
    let tokensOutput: number | null = null;
    let errorClass: string | null = null;
    let errorMessage: string | null = null;

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
        entityType: 'regulatory_update',
        entityId: null,
        language,
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: true,
        outcome: 'rate_limited',
        latencyMs: Date.now() - startTime,
      });
      next(new RateLimitError('AI rate limit exceeded'));
      return;
    }

    const payloadHash = buildPayloadHash({
      promptId: PROMPT_ID,
      mode: body.mode,
      language,
      regulator: body.regulator,
      title: body.titleEn,
      referenceNumber: body.referenceNumber ?? null,
      sampleContracts: body.sampleContracts,
      affectedClauseCategories: body.affectedClauseCategories,
    });

    res.setHeader('X-AI-Cache', 'MISS');
    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    const abortController = new AbortController();
    let stillOpen = true;
    req.on('close', () => {
      if (stillOpen) abortController.abort();
    });

    try {
      const ctx: service.RegulatoryImpactContext = {
        mode: body.mode,
        language,
        regulator: body.regulator,
        ...(body.referenceNumber !== undefined ? { referenceNumber: body.referenceNumber } : {}),
        titleEn: body.titleEn,
        ...(body.summaryEn !== undefined ? { summaryEn: body.summaryEn } : {}),
        ...(body.effectiveDate !== undefined ? { effectiveDate: body.effectiveDate } : {}),
        ...(body.complianceDeadline !== undefined ? { complianceDeadline: body.complianceDeadline } : {}),
        affectedClauseCategories: body.affectedClauseCategories,
        ...(body.impactedCount !== undefined ? { impactedCount: body.impactedCount } : {}),
        sampleContracts: body.sampleContracts,
        ...(body.impactCategoryName !== undefined ? { impactCategoryName: body.impactCategoryName } : {}),
        ...(body.impactCategoryGuidance !== undefined ? { impactCategoryGuidance: body.impactCategoryGuidance } : {}),
      };
      const systemPrompt = await service.buildSystemPrompt(ctx);
      const userMessage = `Mode: ${body.mode}. Regulator: ${body.regulator}. Title: ${body.titleEn}.`;
      const { stream, tokensConsumed, collectedText } = service.streamRegulatoryImpact({
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
      const finalTokens = tokensConsumed();
      modelUsed = 'gpt-4o';
      tokensOutput = finalTokens;
      outcome = 'success';

      // Cache (entity_type='regulatory_update', entity_id=NULL, content-hash)
      const insightType = body.mode === 'amendment' ? 'regulatory_impact_amendment' : 'regulatory_impact_explain';
      const payload: AiRegulatoryImpactPayload = {
        insightType,
        text: collectedText(),
      };
      try {
        await upsertCache({
          entityType: 'regulatory_update',
          entityId: null,
          insightType,
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
          { action: 'aiRegulatoryImpact.cache_upsert_failed', userId, errorType: errorTypeOf(upsertErr) },
          'Cache upsert failed (non-fatal)',
        );
      }

      try {
        res.write(sseFrame({ type: 'done', tokensConsumed: finalTokens }));
      } catch {
        /* swallow */
      }
      try {
        res.end();
      } catch {
        /* swallow */
      }
      stillOpen = false;

      req.logger.info(
        {
          action: 'aiRegulatoryImpact.invoke',
          userId,
          mode: body.mode,
          tokensOutput,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
    } catch (err) {
      outcome = 'error';
      errorClass = err instanceof Error ? err.name : 'UNKNOWN';
      errorMessage = err instanceof Error ? err.message : String(err);
      req.logger.error(
        {
          action: 'aiRegulatoryImpact.invoke',
          userId,
          mode: body.mode,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      // Response already SSE — cannot next(err) usefully.
    } finally {
      // Cron-resolution: telemetry once per invocation (S10).
      void next; // satisfy lint — next is unused on the streaming path.
      await recordAiTelemetry({
        promptId: PROMPT_ID,
        mode: body.mode,
        actorUserId: userId,
        entityType: 'regulatory_update',
        entityId: null,
        language,
        provider: 'openai',
        modelUsed: modelUsed || 'unknown',
        tokensInput,
        tokensOutput,
        cacheHit: false,
        streamMode: true,
        outcome,
        errorClass,
        errorMessage,
        latencyMs: Date.now() - startTime,
      });
    }
  },
};
