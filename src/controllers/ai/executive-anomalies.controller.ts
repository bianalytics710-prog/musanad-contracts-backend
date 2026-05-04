/**
 * S3 — POST /api/v1/ai/executive-anomalies
 *
 * Non-streaming tool-call. Cache TTL 1h via fn_ai_insight_get_cached / _upsert
 * (entity_type='executive_dashboard', entity_id=NULL).
 *
 * Sensitive logging: stats may contain aggregated tenant data — pino
 * redact does not target it specifically (it's not a wire DTO sensitive
 * field), but the controller still avoids logging req.body.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, RateLimitError } from '../../utils/errors.util';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import { buildPayloadHash, getCached, upsertCache } from '../../services/ai/_shared/cache-layer';
import * as service from '../../services/ai/openai-executive-anomalies.service';
import type { AiExecutiveAnomaliesRequestInput } from '../../schemas/ai.schemas';
import type {
  AiExecutiveAnomaliesPayload,
  AiExecutiveAnomaliesResponse,
} from '../../types/ai.types';

const PROMPT_ID = service.PROMPT_ID;

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const executiveAnomaliesController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const body = req.body as AiExecutiveAnomaliesRequestInput;
    const userId = req.user!.id;
    const language = body.language;

    req.logger.info(
      {
        action: 'aiExecutiveAnomalies.invoke',
        userId,
        method: req.method,
        path: req.path,
        language,
        statsKeyCount: Object.keys(body.stats ?? {}).length,
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
        actorUserId: userId,
        entityType: 'executive_dashboard',
        entityId: null,
        language,
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: false,
        outcome: 'rate_limited',
        latencyMs: Date.now() - startTime,
      });
      next(new RateLimitError('AI rate limit exceeded'));
      return;
    }

    const payloadHash = buildPayloadHash({
      promptId: PROMPT_ID,
      language,
      stats: body.stats,
      dateRange: body.dateRange ?? null,
    });

    // Cache lookup
    try {
      const cached = await getCached({
        entityType: 'executive_dashboard',
        entityId: null,
        insightType: 'executive_anomalies',
        language,
        payloadHash,
        actorUserId: userId,
      });
      if (cached) {
        cacheHit = true;
        outcome = 'success';
        modelUsed = cached.modelUsed;
        res.setHeader('X-AI-Cache', 'HIT');
        const payload = cached.payload as AiExecutiveAnomaliesPayload;
        const response: AiExecutiveAnomaliesResponse = {
          anomalies: payload.anomalies,
          generatedAt: payload.generatedAt,
        };
        res.status(200).json({ success: true, data: response, requestId: req.requestId });
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          actorUserId: userId,
          entityType: 'executive_dashboard',
          entityId: null,
          language,
          provider: 'openai',
          modelUsed,
          cacheHit: true,
          streamMode: false,
          outcome: 'success',
          latencyMs: Date.now() - startTime,
        });
        req.logger.info(
          { action: 'aiExecutiveAnomalies.invoke', userId, cacheHit: true, duration: Date.now() - startTime, statusCode: 200 },
          'Controller exit (cache hit)',
        );
        return;
      }
    } catch (err) {
      req.logger.warn(
        { action: 'aiExecutiveAnomalies.cache_lookup_failed', userId, errorType: errorTypeOf(err) },
        'Cache lookup failed — proceeding to provider',
      );
    }
    res.setHeader('X-AI-Cache', 'MISS');

    try {
      const ctx: service.ExecutiveAnomaliesContext = {
        language,
        stats: body.stats,
        ...(body.dateRange ? { dateRange: body.dateRange } : {}),
      };
      const systemPrompt = await service.buildSystemPrompt(ctx);
      const userMessage = `Detect anomalies in the executive dashboard data. Return JSON with up to 4 anomalies.`;
      const result = await service.detectAnomalies({ systemPrompt, userMessage });
      modelUsed = result.modelUsed;
      tokensInput = result.tokensInput;
      tokensOutput = result.tokensOutput;
      outcome = 'success';

      try {
        await upsertCache({
          entityType: 'executive_dashboard',
          entityId: null,
          insightType: 'executive_anomalies',
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
          { action: 'aiExecutiveAnomalies.cache_upsert_failed', userId, errorType: errorTypeOf(upsertErr) },
          'Cache upsert failed (non-fatal)',
        );
      }

      const response: AiExecutiveAnomaliesResponse = {
        anomalies: result.payload.anomalies,
        generatedAt: result.payload.generatedAt,
      };
      res.status(200).json({ success: true, data: response, requestId: req.requestId });
      req.logger.info(
        {
          action: 'aiExecutiveAnomalies.invoke',
          userId,
          tokensInput,
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
          action: 'aiExecutiveAnomalies.invoke',
          userId,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    } finally {
      // outcome can be 'success' or 'error' here — rate_limited and
      // cacheHit branches return early. Always record.
      if (!cacheHit) {
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          actorUserId: userId,
          entityType: 'executive_dashboard',
          entityId: null,
          language,
          provider: 'openai',
          modelUsed: modelUsed || 'unknown',
          tokensInput,
          tokensOutput,
          cacheHit: false,
          streamMode: false,
          outcome,
          errorClass,
          errorMessage,
          latencyMs: Date.now() - startTime,
        });
      }
    }
  },
};
