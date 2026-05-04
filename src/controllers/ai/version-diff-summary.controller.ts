/**
 * S6 — POST /api/v1/ai/version-diff-summary
 *
 * Non-streaming. Cache TTL 7d via fn_ai_insight cache (entity_type =
 * 'contract_version', entity_id = rightVersionId). Persists summary to
 * contract_version.diff_summary via fn_contract_version_diff_summary_persist
 * (DEFINER carve-out — see DB design DN-3).
 *
 * Sensitive logging: additions / deletions / modifiedClauses NEVER logged.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, RateLimitError } from '../../utils/errors.util';
import { db } from '../../database/client';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import { buildPayloadHash, getCached, upsertCache } from '../../services/ai/_shared/cache-layer';
import * as service from '../../services/ai/openai-version-diff-summary.service';
import type { AiVersionDiffSummaryRequestInput } from '../../schemas/ai.schemas';
import type {
  AiVersionDiffSummaryPayload,
  AiVersionDiffSummaryResponse,
  ContractVersionDiffSummaryPersistData,
} from '../../types/ai.types';

const PROMPT_ID = service.PROMPT_ID;

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const versionDiffSummaryController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const body = req.body as AiVersionDiffSummaryRequestInput;
    const userId = req.user!.id;
    const language = body.language;

    req.logger.info(
      {
        action: 'aiVersionDiffSummary.invoke',
        userId,
        method: req.method,
        path: req.path,
        contractId: body.contractId,
        leftVersionId: body.leftVersionId,
        rightVersionId: body.rightVersionId,
        language,
        // additions / deletions / modifiedClauses NEVER logged.
        additionsLen: body.additions?.length ?? 0,
        deletionsLen: body.deletions?.length ?? 0,
        modifiedClauseCount: body.modifiedClauses?.length ?? 0,
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
        entityType: 'contract_version',
        entityId: body.rightVersionId,
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
      contractId: body.contractId,
      leftVersionId: body.leftVersionId,
      rightVersionId: body.rightVersionId,
      additions: body.additions,
      deletions: body.deletions,
      modifiedClauses: body.modifiedClauses,
    });

    // Cache lookup
    try {
      const cached = await getCached({
        entityType: 'contract_version',
        entityId: body.rightVersionId,
        insightType: 'version_diff_summary',
        language,
        payloadHash,
        actorUserId: userId,
      });
      if (cached) {
        cacheHit = true;
        outcome = 'success';
        modelUsed = cached.modelUsed;
        res.setHeader('X-AI-Cache', 'HIT');
        // Even on cache hit, persist a fresh diff_summary row only if absent —
        // skip persist (idempotent — controller cannot tell whether DB has it).
        // Caller still benefits from contract_version.diff_summary set on prior
        // call. AC-S6-04 — cache hit returns prior persisted data via the
        // payload itself.
        const payload = cached.payload as AiVersionDiffSummaryPayload;
        const persisted: ContractVersionDiffSummaryPersistData = {
          contractVersionId: body.rightVersionId,
          diffSummary: payload.summary,
          updatedAt: cached.createdAt,
        };
        const response: AiVersionDiffSummaryResponse = {
          summary: payload.summary,
          persisted,
          cacheHit: true,
        };
        res.status(200).json({ success: true, data: response, requestId: req.requestId });
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          actorUserId: userId,
          entityType: 'contract_version',
          entityId: body.rightVersionId,
          language,
          provider: 'openai',
          modelUsed,
          cacheHit: true,
          streamMode: false,
          outcome: 'success',
          latencyMs: Date.now() - startTime,
        });
        req.logger.info(
          { action: 'aiVersionDiffSummary.invoke', userId, cacheHit: true, duration: Date.now() - startTime, statusCode: 200 },
          'Controller exit (cache hit)',
        );
        return;
      }
    } catch (err) {
      req.logger.warn(
        { action: 'aiVersionDiffSummary.cache_lookup_failed', userId, errorType: errorTypeOf(err) },
        'Cache lookup failed — proceeding to provider',
      );
    }
    res.setHeader('X-AI-Cache', 'MISS');

    try {
      const ctx: service.VersionDiffSummaryContext = {
        language,
        contractId: body.contractId,
        leftVersionId: body.leftVersionId,
        rightVersionId: body.rightVersionId,
        additions: body.additions,
        deletions: body.deletions,
        modifiedClauses: body.modifiedClauses,
      };
      const systemPrompt = await service.buildSystemPrompt(ctx);
      const userMessage = `Summarize the diff between version ${body.leftVersionId} and version ${body.rightVersionId}.`;
      const result = await service.generateDiffSummary({ systemPrompt, userMessage });
      modelUsed = result.modelUsed;
      tokensInput = result.tokensInput;
      tokensOutput = result.tokensOutput;
      outcome = 'success';

      // Persist via fn_contract_version_diff_summary_persist (DEFINER carve-out)
      let persisted: ContractVersionDiffSummaryPersistData | null = null;
      try {
        const wrapper = await db.callFunction<{ data: ContractVersionDiffSummaryPersistData }>(
          'fn_contract_version_diff_summary_persist',
          [body.rightVersionId, userId, result.summary],
          { actorId: userId },
        );
        persisted = wrapper?.data ?? null;
      } catch (persistErr) {
        // Persist failure is propagated — the user-facing endpoint contract is
        // that the diff_summary IS persisted. Surface as 4xx/5xx.
        req.logger.error(
          { action: 'aiVersionDiffSummary.persist_failed', userId, errorType: errorTypeOf(persistErr) },
          'fn_contract_version_diff_summary_persist failed',
        );
        throw persistErr;
      }

      // Cache
      try {
        await upsertCache({
          entityType: 'contract_version',
          entityId: body.rightVersionId,
          insightType: 'version_diff_summary',
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
          { action: 'aiVersionDiffSummary.cache_upsert_failed', userId, errorType: errorTypeOf(upsertErr) },
          'Cache upsert failed (non-fatal)',
        );
      }

      const response: AiVersionDiffSummaryResponse = {
        summary: result.summary,
        persisted: persisted ?? {
          contractVersionId: body.rightVersionId,
          diffSummary: result.summary,
          updatedAt: new Date().toISOString(),
        },
        cacheHit: false,
      };
      res.status(200).json({ success: true, data: response, requestId: req.requestId });
      req.logger.info(
        {
          action: 'aiVersionDiffSummary.invoke',
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
          action: 'aiVersionDiffSummary.invoke',
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
          entityType: 'contract_version',
          entityId: body.rightVersionId,
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
