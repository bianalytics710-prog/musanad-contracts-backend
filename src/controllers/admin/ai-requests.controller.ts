/**
 * S11 — GET /api/v1/admin/ai/requests
 *
 * Admin observability — paginated list of ai_request_log rows.
 * errorMessage is pre-redacted at write time (AC-S10-07); the audit trigger
 * also redacts it (defence-in-depth, migration 041).
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError } from '../../utils/errors.util';
import type { AiRequestLogListQueryInput } from '../../schemas/ai.schemas';
import type { AiRequestLogListResponse } from '../../types/ai.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminAiRequestsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'adminAiRequests.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as AiRequestLogListQueryInput;
      const result = await db.callFunction<AiRequestLogListResponse>(
        'fn_ai_request_log_list',
        [
          q.page ?? 1,
          q.limit ?? 50,
          q.actorUserId ?? null,
          q.promptId ?? null,
          q.outcome ?? null,
          q.fromDate ?? null,
          q.toDate ?? null,
        ],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'adminAiRequests.list',
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
          action: 'adminAiRequests.list',
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
