/**
 * M_parity controllers — thin HTTP layer for the 4 entities introduced in
 * migration 058 (party / contract_template / contract_clause /
 * contract_obligation). Read-only; mirrors dashboards.controller logging.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import * as svc from '../services/m_parity.service';
import type {
  CreatePartyInferred,
  CreateTemplateInferred,
  CreateClauseInferred,
  CreateObligationInferred,
} from '../schemas/m_parity.schemas';

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

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'parties.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      // R-LC9-2 — body shape guaranteed by validate(CreatePartySchema, 'body').
      const body = req.body as CreatePartyInferred;
      const result = await svc.createParty(req.user!.id, {
        partyType: body.partyType,
        nameEn: body.nameEn,
        nameAr: body.nameAr ?? null,
        tradeLicenseNumber: body.tradeLicenseNumber ?? null,
        tradeLicenseIssuer: body.tradeLicenseIssuer ?? null,
        emirate: body.emirate ?? null,
        freeZone: body.freeZone ?? null,
        country: body.country ?? null,
        contactEmail: body.contactEmail ?? null,
        contactPhone: body.contactPhone ?? null,
        registeredAddress: body.registeredAddress ?? null,
        notes: body.notes ?? null,
      });
      req.logger.info(
        { action: 'parties.create', userId: req.user?.id, duration: Date.now() - start, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'parties.create', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
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

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'templates.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as CreateTemplateInferred;
      const result = await svc.createTemplate(req.user!.id, {
        nameEn: body.nameEn,
        contractType: body.contractType,
        language: body.language ?? 'en',
        nameAr: body.nameAr ?? null,
        descriptionEn: body.descriptionEn ?? null,
        descriptionAr: body.descriptionAr ?? null,
        bodyEn: body.bodyEn ?? null,
        bodyAr: body.bodyAr ?? null,
        regulatoryTags: body.regulatoryTags ?? [],
      });
      req.logger.info(
        { action: 'templates.create', userId: req.user?.id, duration: Date.now() - start, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'templates.create', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
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

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'clauses.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as CreateClauseInferred;
      const result = await svc.createClause(req.user!.id, {
        category: body.category,
        titleEn: body.titleEn,
        bodyEn: body.bodyEn,
        variant: body.variant ?? 'standard',
        titleAr: body.titleAr ?? null,
        bodyAr: body.bodyAr ?? null,
        legalCommentaryEn: body.legalCommentaryEn ?? null,
        legalCommentaryAr: body.legalCommentaryAr ?? null,
        regulatoryRefs: body.regulatoryRefs ?? [],
      });
      req.logger.info(
        { action: 'clauses.create', userId: req.user?.id, duration: Date.now() - start, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'clauses.create', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
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

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'obligations.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as CreateObligationInferred;
      const result = await svc.createObligation(req.user!.id, {
        contractId: body.contractId,
        titleEn: body.titleEn,
        obligationType: body.obligationType,
        dueDate: body.dueDate ?? null,
        recurrence: body.recurrence ?? 'once',
        responsibleParty: body.responsibleParty ?? 'our_party',
        titleAr: body.titleAr ?? null,
        descriptionEn: body.descriptionEn ?? null,
        descriptionAr: body.descriptionAr ?? null,
        assigneeUserId: body.assigneeUserId ?? null,
        status: body.status ?? 'open',
      });
      req.logger.info(
        { action: 'obligations.create', userId: req.user?.id, duration: Date.now() - start, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'obligations.create', userId: req.user?.id, duration: Date.now() - start, errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};
