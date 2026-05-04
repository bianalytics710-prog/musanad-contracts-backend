/**
 * S5 — POST /api/v1/ai/regulatory-impact-summary
 *
 * PUBLIC endpoint (verify_jwt: false). Auth via signed-PDF-token middleware
 * (HMAC-validated at Express layer; fn_'s remain neondb_owner-only DEFINER —
 * Q3 Option A).
 *
 * Cache TTL 30d, content-addressed by SHA-256 of canonicalised inputs.
 *
 * Per-token rate-limit (10 calls/h) is enforced at controller level using the
 * token's `sub` claim as the identity (no actor user id available — the
 * fn_ai_request_log_check_rate_limit gate requires an actor, so we skip it
 * and use a tiny in-memory limiter keyed on the token sub).
 *
 * Sensitive logging:
 *   - signedToken NEVER logged (pino redact).
 *   - summary, contracts may contain regulatory text — NEVER logged.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, RateLimitError } from '../../utils/errors.util';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import { buildPayloadHash, getCached, upsertCache } from '../../services/ai/_shared/cache-layer';
import * as service from '../../services/ai/openai-regulatory-impact-summary.service';
import type { AiRegulatoryImpactSummaryRequestInput } from '../../schemas/ai.schemas';
import type {
  AiRegulatoryImpactSummaryPayload,
  AiRegulatoryImpactSummaryResponse,
} from '../../types/ai.types';

const PROMPT_ID = service.PROMPT_ID;

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

// Per-token in-memory rate limiter (10 calls/h).
const TOKEN_BUCKET_LIMIT = 10;
const TOKEN_BUCKET_WINDOW_MS = 60 * 60 * 1000;
const tokenCalls = new Map<string, number[]>(); // sub → epoch timestamps

const checkTokenRateLimit = (sub: string): { allowed: boolean; retryAfterSeconds: number } => {
  const now = Date.now();
  const cutoff = now - TOKEN_BUCKET_WINDOW_MS;
  const existing = (tokenCalls.get(sub) ?? []).filter((t) => t > cutoff);
  if (existing.length >= TOKEN_BUCKET_LIMIT) {
    const oldest = existing[0] ?? now;
    const retryAfter = Math.max(1, Math.ceil((oldest + TOKEN_BUCKET_WINDOW_MS - now) / 1000));
    tokenCalls.set(sub, existing);
    return { allowed: false, retryAfterSeconds: retryAfter };
  }
  existing.push(now);
  tokenCalls.set(sub, existing);
  return { allowed: true, retryAfterSeconds: 0 };
};

export const regulatoryImpactSummaryController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const body = req.body as AiRegulatoryImpactSummaryRequestInput;
    const tokenClaims = req.signedPdfToken;
    const language = body.language;

    if (!tokenClaims) {
      // Should never happen — middleware fires first. Defense.
      next(new ApiError(401, 'UNAUTHORIZED', 'Signed-PDF-token claims missing'));
      return;
    }

    req.logger.info(
      {
        action: 'aiRegulatoryImpactSummary.invoke',
        method: req.method,
        path: req.path,
        tokenSub: tokenClaims.sub,
        language,
        contractCount: body.contracts.length,
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

    // Per-token rate limit (10/h)
    const limit = checkTokenRateLimit(tokenClaims.sub);
    if (!limit.allowed) {
      res.setHeader('Retry-After', String(limit.retryAfterSeconds));
      await recordAiTelemetry({
        promptId: PROMPT_ID,
        actorUserId: null,
        entityType: 'regulatory_update_summary',
        entityId: null,
        language,
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: false,
        outcome: 'rate_limited',
        latencyMs: Date.now() - startTime,
      });
      next(new RateLimitError('Per-token rate limit exceeded'));
      return;
    }

    res.setHeader('Cache-Control', 'private, no-store');

    const payloadHash = buildPayloadHash({
      promptId: PROMPT_ID,
      language,
      regulator: body.regulator,
      title: body.title,
      severity: body.severity,
      referenceNumber: body.referenceNumber ?? null,
      summary: body.summary ?? null,
      contracts: body.contracts,
    });

    // Cache lookup (30d TTL, content-addressed)
    try {
      const cached = await getCached({
        entityType: 'regulatory_update_summary',
        entityId: null,
        insightType: 'regulatory_impact_summary',
        language,
        payloadHash,
        actorUserId: null,
      });
      if (cached) {
        cacheHit = true;
        outcome = 'success';
        modelUsed = cached.modelUsed;
        res.setHeader('X-AI-Cache', 'HIT');
        const payload = cached.payload as AiRegulatoryImpactSummaryPayload;
        const response: AiRegulatoryImpactSummaryResponse = {
          executive: payload.executive,
          keyChanges: payload.keyChanges,
          recommendedActions: payload.recommendedActions,
          cacheHit: true,
        };
        res.status(200).json({ success: true, data: response, requestId: req.requestId });
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          actorUserId: null,
          entityType: 'regulatory_update_summary',
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
          { action: 'aiRegulatoryImpactSummary.invoke', cacheHit: true, duration: Date.now() - startTime, statusCode: 200 },
          'Controller exit (cache hit)',
        );
        return;
      }
    } catch (err) {
      req.logger.warn(
        { action: 'aiRegulatoryImpactSummary.cache_lookup_failed', errorType: errorTypeOf(err) },
        'Cache lookup failed — proceeding to provider',
      );
    }
    res.setHeader('X-AI-Cache', 'MISS');

    try {
      const ctx: service.RegulatoryImpactSummaryContext = {
        language,
        regulator: body.regulator,
        title: body.title,
        severity: body.severity,
        ...(body.referenceNumber !== undefined ? { referenceNumber: body.referenceNumber } : {}),
        ...(body.summary !== undefined ? { summary: body.summary } : {}),
        contracts: body.contracts,
      };
      const systemPrompt = await service.buildSystemPrompt(ctx);
      const userMessage = `Generate the regulatory impact summary for ${body.contracts.length} contract(s). Return JSON.`;
      const result = await service.generateSummary({ systemPrompt, userMessage });
      modelUsed = result.modelUsed;
      tokensInput = result.tokensInput;
      tokensOutput = result.tokensOutput;
      outcome = 'success';

      try {
        await upsertCache({
          entityType: 'regulatory_update_summary',
          entityId: null,
          insightType: 'regulatory_impact_summary',
          language,
          provider: 'openai',
          modelUsed,
          payload: result.payload,
          payloadHash,
          promptId: PROMPT_ID,
          tokensInput,
          tokensOutput,
          // ttlSeconds null → use ai_prompt.default_ttl_seconds (30d).
          actorUserId: null,
        });
      } catch (upsertErr) {
        req.logger.warn(
          { action: 'aiRegulatoryImpactSummary.cache_upsert_failed', errorType: errorTypeOf(upsertErr) },
          'Cache upsert failed (non-fatal)',
        );
      }

      const response: AiRegulatoryImpactSummaryResponse = {
        executive: result.payload.executive,
        keyChanges: result.payload.keyChanges,
        recommendedActions: result.payload.recommendedActions,
        cacheHit: false,
      };
      res.status(200).json({ success: true, data: response, requestId: req.requestId });
      req.logger.info(
        {
          action: 'aiRegulatoryImpactSummary.invoke',
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
          action: 'aiRegulatoryImpactSummary.invoke',
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
          actorUserId: null,
          entityType: 'regulatory_update_summary',
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
