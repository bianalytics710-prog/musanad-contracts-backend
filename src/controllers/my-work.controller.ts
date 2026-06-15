/**
 * Phase A (mig 640) — My Work unified inbox controller.
 *
 * Thin HTTP layer over fn_my_work_list_v2. The fn UNIONs five sources
 * (work_order + approval_step + risk_case + tpa_review + advisory_draft)
 * and returns the standard envelope shape so the FE can reuse the existing
 * WorkOrderRow type with only a label-mapping update.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import { listMyWorkQuerySchema, setMyWorkStatusSchema } from '../schemas/my-work.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const myWorkController = {
  // ============================================================
  // GET /api/v1/my-work
  // ============================================================
  // Returns the actor's unified inbox: existing work_order rows plus
  // approval_step / risk_case / tpa_review / advisory_draft assigned to
  // them (or to their role). Same envelope as /api/v1/work-orders so the
  // FE can share rendering.
  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_my_work_list_v2',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const q = listMyWorkQuerySchema.parse(req.query);
      const result = await db.callFunction(
        'fn_my_work_list_v2',
        [
          req.user!.id,
          q.status ?? null,
          q.type ?? null,
          q.search ?? null,
          q.page,
          q.limit,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_my_work_list_v2',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_my_work_list_v2',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/my-work/statuses  (mig 684)
  // ============================================================
  // The actor's personal work-status overlay as [{workItemId,status}].
  // Items without a row default to to_do on the FE.
  listStatuses: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const result = await db.callFunction(
        'fn_my_work_status_list',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (error) {
      req.logger.error({ action: 'fn_my_work_status_list', userId: req.user?.id, errorType: errorType(error) });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/my-work/status  (mig 684)
  // ============================================================
  // Upsert the actor's personal status for one unified My Work row.
  setStatus: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const { workItemId, status } = setMyWorkStatusSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_my_work_status_set',
        [req.user!.id, workItemId, status],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (error) {
      req.logger.error({ action: 'fn_my_work_status_set', userId: req.user?.id, errorType: errorType(error) });
      next(error);
    }
  },
};
