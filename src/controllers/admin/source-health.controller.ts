/**
 * M7 — Admin Source Health Controller (CR-A).
 *
 *   GET /api/v1/admin/source-health → fn_source_health_list
 *
 * Permission: source.read (gated inside fn_).
 * Returns a BARE ARRAY (no pagination envelope) per S2-12 documented design
 * exception — bounded set per tenant (~14 rows max in CR-A; AC-S8-04).
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError } from '../../utils/errors.util';
import type { SourceHealthListItem } from '../../types/osint.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminSourceHealthController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.sourceHealth.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await db.callFunction<SourceHealthListItem[]>(
        'fn_source_health_list',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      const arr = Array.isArray(result) ? result : [];
      req.logger.info(
        {
          action: 'admin.sourceHealth.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: arr.length,
        },
        'Controller exit',
      );
      res.status(200).json(arr);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.sourceHealth.list',
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
