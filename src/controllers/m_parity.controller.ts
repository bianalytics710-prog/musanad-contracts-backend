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

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'parties.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const b = req.body ?? {};
      const result = await svc.createParty(req.user!.id, {
        partyType: String(b.partyType ?? 'company') as 'individual' | 'company',
        nameEn: String(b.nameEn ?? ''),
        nameAr: optStr(b.nameAr) ?? null,
        tradeLicenseNumber: optStr(b.tradeLicenseNumber) ?? null,
        tradeLicenseIssuer: optStr(b.tradeLicenseIssuer) ?? null,
        emirate: optStr(b.emirate) ?? null,
        freeZone: optStr(b.freeZone) ?? null,
        country: optStr(b.country) ?? null,
        contactEmail: optStr(b.contactEmail) ?? null,
        contactPhone: optStr(b.contactPhone) ?? null,
        registeredAddress: optStr(b.registeredAddress) ?? null,
        notes: optStr(b.notes) ?? null,
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
      const b = req.body ?? {};
      const tags: string[] = Array.isArray(b.regulatoryTags)
        ? b.regulatoryTags.filter((t: unknown): t is string => typeof t === 'string')
        : [];
      const result = await svc.createTemplate(req.user!.id, {
        nameEn: String(b.nameEn ?? ''),
        contractType: String(b.contractType ?? ''),
        language: (b.language as 'en' | 'ar' | 'bilingual') ?? 'en',
        nameAr: optStr(b.nameAr) ?? null,
        descriptionEn: optStr(b.descriptionEn) ?? null,
        descriptionAr: optStr(b.descriptionAr) ?? null,
        bodyEn: optStr(b.bodyEn) ?? null,
        bodyAr: optStr(b.bodyAr) ?? null,
        regulatoryTags: tags,
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
      const b = req.body ?? {};
      const refs: string[] = Array.isArray(b.regulatoryRefs)
        ? b.regulatoryRefs.filter((t: unknown): t is string => typeof t === 'string')
        : [];
      const result = await svc.createClause(req.user!.id, {
        category: String(b.category ?? ''),
        titleEn: String(b.titleEn ?? ''),
        bodyEn: String(b.bodyEn ?? ''),
        variant: (b.variant as 'standard' | 'alternative' | 'fallback') ?? 'standard',
        titleAr: optStr(b.titleAr) ?? null,
        bodyAr: optStr(b.bodyAr) ?? null,
        legalCommentaryEn: optStr(b.legalCommentaryEn) ?? null,
        legalCommentaryAr: optStr(b.legalCommentaryAr) ?? null,
        regulatoryRefs: refs,
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
      const b = req.body ?? {};
      const contractId = Number(b.contractId);
      if (!Number.isInteger(contractId) || contractId <= 0) {
        throw new ApiError(400, 'BAD_REQUEST', 'Invalid contractId');
      }
      const result = await svc.createObligation(req.user!.id, {
        contractId,
        titleEn: String(b.titleEn ?? ''),
        obligationType: (b.obligationType as 'payment' | 'delivery' | 'reporting' | 'renewal' | 'compliance' | 'notice' | 'other') ?? 'other',
        dueDate: optStr(b.dueDate) ?? null,
        recurrence: (b.recurrence as 'once' | 'monthly' | 'quarterly' | 'annually') ?? 'once',
        responsibleParty: (b.responsibleParty as 'our_party' | 'counterparty' | 'both') ?? 'our_party',
        titleAr: optStr(b.titleAr) ?? null,
        descriptionEn: optStr(b.descriptionEn) ?? null,
        descriptionAr: optStr(b.descriptionAr) ?? null,
        assigneeUserId: optInt(b.assigneeUserId) ?? null,
        status: (b.status as 'open' | 'in_progress' | 'completed' | 'overdue' | 'waived') ?? 'open',
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
