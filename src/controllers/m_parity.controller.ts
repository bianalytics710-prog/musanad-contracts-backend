/**
 * M_parity controllers — thin HTTP layer for the 4 entities introduced in
 * migration 058 (party / contract_template / contract_clause /
 * contract_obligation). Read-only; mirrors dashboards.controller logging.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import * as svc from '../services/m_parity.service';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const intParam = (raw: unknown, name: string): number => {
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new ApiError(400, 'BAD_REQUEST', `Invalid ${name}`);
  }
  return n;
};

const optInt = (raw: unknown): number | undefined => {
  if (raw === undefined || raw === null || raw === '') return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) return undefined;
  return n;
};

const optStr = (raw: unknown): string | undefined => {
  if (typeof raw !== 'string') return undefined;
  const t = raw.trim();
  return t === '' ? undefined : t;
};

export const partiesController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'parties.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const result = await svc.listParties(
        req.user!.id,
        optStr(req.query.partyType),
        optStr(req.query.q),
        optInt(req.query.limit),
        optInt(req.query.offset),
      );
      req.logger.info(
        { action: 'parties.list', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'parties.list', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'parties.get', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const id = intParam(req.params.id, 'id');
      const result = await svc.getPartyById(req.user!.id, id);
      req.logger.info(
        { action: 'parties.get', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'parties.get', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};

export const templatesController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'templates.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const result = await svc.listTemplates(
        req.user!.id,
        optStr(req.query.contractType),
        optStr(req.query.q),
        optInt(req.query.limit),
        optInt(req.query.offset),
      );
      req.logger.info(
        { action: 'templates.list', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'templates.list', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'templates.get', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const id = intParam(req.params.id, 'id');
      const result = await svc.getTemplateById(req.user!.id, id);
      req.logger.info(
        { action: 'templates.get', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'templates.get', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};

export const clausesController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'clauses.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const result = await svc.listClauses(
        req.user!.id,
        optStr(req.query.category),
        optStr(req.query.variant),
        optStr(req.query.q),
        optInt(req.query.limit),
        optInt(req.query.offset),
      );
      req.logger.info(
        { action: 'clauses.list', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'clauses.list', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'clauses.get', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const id = intParam(req.params.id, 'id');
      const result = await svc.getClauseById(req.user!.id, id);
      req.logger.info(
        { action: 'clauses.get', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'clauses.get', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};

export const obligationsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'obligations.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const assignee =
        req.query.assigneeUserId === 'me'
          ? req.user!.id
          : optInt(req.query.assigneeUserId);
      const result = await svc.listObligations(
        req.user!.id,
        optStr(req.query.status),
        assignee,
        optInt(req.query.limit),
        optInt(req.query.offset),
      );
      req.logger.info(
        { action: 'obligations.list', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'obligations.list', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};
