/**
 * S11 — GET /api/v1/admin/ai/insights
 *
 * Admin observability — paginated list of ai_insight rows with filters.
 * Visible only to platform_admin + ai.observability.read (RLS narrows).
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError } from '../../utils/errors.util';
import type { AiInsightListQueryInput } from '../../schemas/ai.schemas';
import type { AiInsightListResponse } from '../../types/ai.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminAiInsightsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'adminAiInsights.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as AiInsightListQueryInput;
      const result = await db.callFunction<AiInsightListResponse>(
        'fn_ai_insight_list',
        [
          q.page ?? 1,
          q.limit ?? 20,
          q.entityType ?? null,
          q.insightType ?? null,
          q.language ?? null,
          q.provider ?? null,
          q.includeExpired ?? false,
        ],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'adminAiInsights.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'adminAiInsights.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },
};
