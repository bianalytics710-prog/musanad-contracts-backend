/**
 * CR-C — Admin Tenants Controller (S8).
 *
 *   GET /api/v1/admin/tenants       → fn_tenant_list
 *   GET /api/v1/admin/tenants/:id   → fn_tenant_get_by_id
 *
 * Permission: tenant.read (route + fn body).
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, NotFoundError } from '../../utils/errors.util';
import * as svc from '../../services/admin-tenants.service';
import type {
  TenantIdParamInferred,
  TenantListQueryInferred,
} from '../../schemas/admin-tenants.schemas';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminTenantsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.tenants.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as TenantListQueryInferred;
      const result = await svc.listTenants(
        req.user!.id,
        q.page ?? 1,
        q.limit ?? 20,
        q.search ?? null,
      );
      req.logger.info(
        {
          action: 'admin.tenants.list',
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
          action: 'admin.tenants.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.tenants.create', userId: req.user?.id },
      'Controller entry',
    );
    try {
      const b = req.body as Record<string, unknown>;
      const result = await svc.createTenant(req.user!.id, {
        slug: String(b.slug ?? ''),
        displayName: String(b.displayName ?? ''),
        name: String(b.name ?? ''),
        industryId: Number(b.industryId),
        configPack: typeof b.configPack === 'string' ? b.configPack : null,
        riskAppetite: typeof b.riskAppetite === 'string' ? b.riskAppetite : null,
        dataRegion: typeof b.dataRegion === 'string' ? b.dataRegion : null,
      });
      req.logger.info(
        { action: 'admin.tenants.create', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.tenants.create', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.tenants.getById',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const params = req.params as unknown as TenantIdParamInferred;
      const result = await svc.getTenantById(req.user!.id, params.id);
      if (result === null || result === undefined) {
        throw new NotFoundError('tenant_not_found', { id: 'tenant_not_found' });
      }
      req.logger.info(
        {
          action: 'admin.tenants.getById',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.tenants.getById',
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
