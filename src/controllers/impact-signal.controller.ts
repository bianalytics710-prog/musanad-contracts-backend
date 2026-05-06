/**
 * R-LC7 — Impact Watch controller. Thin HTTP wrapper over the
 * impact-signal service.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import * as svc from '../services/impact-signal.service';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const intParam = (raw: unknown, name: string): number => {
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new ApiError(400, 'BAD_REQUEST', `Invalid ${name}`);
  }
  return n;
};

const optStr = (raw: unknown): string | undefined => {
  if (typeof raw !== 'string') return undefined;
  const t = raw.trim();
  return t === '' ? undefined : t;
};

export const impactSignalController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'impact.list', userId: req.user?.id, method: req.method, path: req.path }, 'Controller entry');
    try {
      const result = await svc.listImpactSignals(
        req.user!.id,
        optStr(req.query.category),
        optStr(req.query.severity),
        optStr(req.query.q),
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
      const id = intParam(req.params.id, 'id');
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
      const linkId = intParam(req.params.linkId, 'linkId');
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
      const id = intParam(req.params.id, 'id');
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
      const id = intParam(req.params.id, 'id');
      const result = await svc.bulkAmend(req.user!.id, id);
      req.logger.info({ action: 'impact.bulkAmend', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 }, 'Controller exit');
      res.status(200).json(result);
    } catch (e) {
      req.logger.error({ action: 'impact.bulkAmend', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) }, 'Controller error');
      next(e);
    }
  },
};
