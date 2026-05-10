/**
 * M8 — Admin Internal Signal Kinds controller (CR-A2).
 *
 *   GET /api/v1/admin/internal-signal-kinds → fn_internal_signal_kind_list
 *
 * Permission: internal_signal.read (gated inside fn_).
 * Returns a BARE ARRAY (no pagination envelope) — bounded set per tenant
 * (8 rows in v1; AC-S6-01) per the M7 fn_source_health_list precedent.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../../utils/errors.util';
import type { InternalSignalKind } from '../../types/internal-signal.types';
import { listInternalSignalKinds } from '../../services/internal-signals.service';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminInternalSignalKindsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.internalSignalKinds.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await listInternalSignalKinds(req.user!.id, req.tenantId);
      const arr: InternalSignalKind[] = Array.isArray(result) ? result : [];
      req.logger.info(
        {
          action: 'admin.internalSignalKinds.list',
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
          action: 'admin.internalSignalKinds.list',
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
