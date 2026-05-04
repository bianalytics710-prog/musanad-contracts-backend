/**
 * S13 — GET /api/v1/admin/ai/prompts
 *
 * Read-only list of registered ai_prompt rows. 6 rows in M4. Read-only in M4
 * (no admin mutate endpoint); platform_admin can edit via direct DB tooling
 * (or future M5 admin write endpoint).
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError } from '../../utils/errors.util';
import type { AiPromptListQueryInput } from '../../schemas/ai.schemas';
import type { AiPromptListResponse } from '../../types/ai.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminAiPromptsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'adminAiPrompts.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as AiPromptListQueryInput;
      const result = await db.callFunction<AiPromptListResponse>(
        'fn_ai_prompt_list',
        [q.includeInactive ?? false],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'adminAiPrompts.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          rowCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'adminAiPrompts.list',
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
