/**
 * CR-C — Admin Demo Controller (S6, S7).
 *
 *   POST /api/v1/admin/demo/purge                          → fn_demo_data_purge
 *   GET  /api/v1/admin/demo/data-classification-summary    → fn_data_classification_summary
 *
 * Super Admin gate (compound) is enforced inside fn_demo_data_purge body
 * (P0001 'super_admin_required' on miss). Route layer additionally requires
 * the `demo.purge` permission to provide a clear 403 envelope.
 *
 * confirmToken format `PURGE_DEMO_DATA_<utc-iso-date>` (today, server clock)
 * is enforced at the controller layer — Zod schema only verifies the shape.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, ValidationError } from '../../utils/errors.util';
import * as svc from '../../services/admin-demo.service';
import type { DemoPurgeBodyInferred } from '../../schemas/admin-demo.schemas';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const todayIsoUtc = (): string => {
  const d = new Date();
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
};

export const adminDemoController = {
  async purge(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.demo.purge',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
        dryRun: req.body?.dryRun === true,
      },
      'Controller entry',
    );
    try {
      const body = (req.body ?? {}) as DemoPurgeBodyInferred;
      const dryRun = body.dryRun === true;
      if (!dryRun) {
        const expected = `PURGE_DEMO_DATA_${todayIsoUtc()}`;
        if (body.confirmToken !== expected) {
          throw new ValidationError('Double confirmation required', {
            confirmToken: 'double_confirmation_required',
          });
        }
      }
      const result = await svc.purgeDemoData(req.user!.id, dryRun);
      req.logger.info(
        {
          action: 'admin.demo.purge',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          dryRun,
          rowsDeleted: result?.rowsDeleted ?? 0,
          tablesPurgedCount: result?.tablesPurged?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.demo.purge',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async dataClassificationSummary(
    req: Request,
    res: Response,
    next: NextFunction,
  ): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.demo.dataClassificationSummary',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await svc.getDataClassificationSummary(req.user!.id);
      req.logger.info(
        {
          action: 'admin.demo.dataClassificationSummary',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          tableCount: result?.summary?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.demo.dataClassificationSummary',
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
