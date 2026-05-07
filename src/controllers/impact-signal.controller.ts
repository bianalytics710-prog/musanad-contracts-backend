/**
 * R-LC7 — Impact Watch controller. Thin HTTP wrapper over the
 * impact-signal service.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import * as svc from '../services/impact-signal.service';
import type {
  ImpactSignalListQueryInferred,
  ImpactSignalIdParamInferred,
  ImpactSignalLinkIdParamInferred,
} from '../schemas/impact-signal.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const impactSignalController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'impact.list', userId: req.user?.id, method: req.method, path: req.path }, 'Controller entry');
    try {
      // R-LC9-2 — query shape guaranteed by validate(ImpactSignalListQuerySchema, 'query').
      const q = req.query as unknown as ImpactSignalListQueryInferred;
      const result = await svc.listImpactSignals(
        req.user!.id,
        q.category,
        q.severity,
        q.q,
        q.limit,
        q.offset,
      );
      req.logger.info({ action: 'impact.list', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 }, 'Controller exit');
      res.status(200).json(result);
    } catch (e) {
      req.logger.error({ action: 'impact.list', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) }, 'Controller error');
      next(e);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'impact.get', userId: req.user?.id, method: req.method, path: req.path }, 'Controller entry');
    try {
      const { id } = req.params as unknown as ImpactSignalIdParamInferred;
      const result = await svc.getImpactSignal(req.user!.id, id);
      req.logger.info({ action: 'impact.get', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 }, 'Controller exit');
      res.status(200).json(result);
    } catch (e) {
      req.logger.error({ action: 'impact.get', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) }, 'Controller error');
      next(e);
    }
  },

  async markReviewed(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'impact.markReviewed', userId: req.user?.id, method: req.method, path: req.path }, 'Controller entry');
    try {
      const { linkId } = req.params as unknown as ImpactSignalLinkIdParamInferred;
      const result = await svc.markImpactReviewed(req.user!.id, linkId);
      req.logger.info({ action: 'impact.markReviewed', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 }, 'Controller exit');
      res.status(200).json(result);
    } catch (e) {
      req.logger.error({ action: 'impact.markReviewed', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) }, 'Controller error');
      next(e);
    }
  },

  async notifyDrafters(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'impact.notify', userId: req.user?.id, method: req.method, path: req.path }, 'Controller entry');
    try {
      const { id } = req.params as unknown as ImpactSignalIdParamInferred;
      const result = await svc.notifyDrafters(req.user!.id, id);
      req.logger.info({ action: 'impact.notify', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 }, 'Controller exit');
      res.status(200).json(result);
    } catch (e) {
      req.logger.error({ action: 'impact.notify', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) }, 'Controller error');
      next(e);
    }
  },

  async bulkAmend(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'impact.bulkAmend', userId: req.user?.id, method: req.method, path: req.path }, 'Controller entry');
    try {
      const { id } = req.params as unknown as ImpactSignalIdParamInferred;
      const result = await svc.bulkAmend(req.user!.id, id);
      req.logger.info({ action: 'impact.bulkAmend', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 }, 'Controller exit');
      res.status(200).json(result);
    } catch (e) {
      req.logger.error({ action: 'impact.bulkAmend', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) }, 'Controller error');
      next(e);
    }
  },
};
