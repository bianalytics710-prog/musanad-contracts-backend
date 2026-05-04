/**
 * S12 — GET /api/v1/admin/ai/cost-report
 *
 * Aggregated cost report by prompt and (optional) user. 90-day max window
 * (enforced both at Zod and in the fn_).
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError } from '../../utils/errors.util';
import type { AiCostReportQueryInput } from '../../schemas/ai.schemas';
import type { AiCostReportResponse } from '../../types/ai.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminAiCostReportController = {
  async report(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'adminAiCostReport.report', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as AiCostReportQueryInput;
      const result = await db.callFunction<AiCostReportResponse>(
        'fn_ai_request_log_cost_report',
        [q.fromDate, q.toDate, q.groupByUser ?? false],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'adminAiCostReport.report',
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
          action: 'adminAiCostReport.report',
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
