/**
 * M7 — Admin OSINT Sources Controller (CR-A).
 *
 *   GET    /api/v1/admin/sources                  → fn_osint_source_list
 *   POST   /api/v1/admin/sources                  → fn_osint_source_create
 *   GET    /api/v1/admin/sources/:id              → fn_osint_source_get_by_id
 *   PATCH  /api/v1/admin/sources/:id              → fn_osint_source_update
 *   DELETE /api/v1/admin/sources/:id              → fn_osint_source_delete
 *   POST   /api/v1/admin/sources/:id/test-pull    → fn_osint_source_test_pull
 *   POST   /api/v1/admin/sources/:id/credential   → fn_source_credential_set
 *
 * Permission gates live in fn_ bodies (source.read / source.manage). Tenant
 * GUC is set via db.callFunction({ tenantId }) using `req.tenantId` resolved
 * by rls.middleware (Q-DA4 ADNOC fallback for v1 single-tenant demo).
 *
 * Sensitive payload: POST /credential body carries `credentialRef` which is
 * redacted by Pino (logger.util.ts SENSITIVE_PATHS — `credentialRef`,
 * `credential_ref`) AND by fn_audit_trigger (migration 102 `credential_ref`
 * in v_redact_fields). Controller never logs req.body.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError } from '../../utils/errors.util';
import type {
  OsintSourceListQueryInferred,
  OsintSourceIdParamInferred,
  CreateOsintSourceInferred,
  UpdateOsintSourceInferred,
  SetCredentialInferred,
} from '../../schemas/admin-sources.schemas';
import type {
  OsintSourceListResponse,
  OsintSourceDetail,
  DeleteOsintSourceResponse,
  TestPullResponse,
  SetCredentialResponse,
} from '../../types/osint.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminSourcesController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.sources.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OsintSourceListQueryInferred;
      const filter: Record<string, unknown> = {};
      if (q.kind !== undefined) filter['kind'] = q.kind;
      if (q.state !== undefined) filter['state'] = q.state;
      if (q.search !== undefined) filter['search'] = q.search;
      const result = await db.callFunction<OsintSourceListResponse>(
        'fn_osint_source_list',
        [req.user!.id, filter, q.page ?? 1, q.limit ?? 20],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'admin.sources.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.sources.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.sources.getById', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as OsintSourceIdParamInferred;
      const result = await db.callFunction<OsintSourceDetail | null>(
        'fn_osint_source_get_by_id',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      // fn_ raises 22023 'Source not found' (mapped to 404 via translatePgError)
      // when row is missing; on the happy path result is non-null.
      req.logger.info(
        {
          action: 'admin.sources.getById',
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
          action: 'admin.sources.getById',
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
      { action: 'admin.sources.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const data = req.body as unknown as CreateOsintSourceInferred;
      const result = await db.callFunction<OsintSourceDetail>(
        'fn_osint_source_create',
        [req.user!.id, data],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'admin.sources.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
          sourceId: data.sourceId,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.sources.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.sources.update', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as OsintSourceIdParamInferred;
      const data = req.body as unknown as UpdateOsintSourceInferred;
      const result = await db.callFunction<OsintSourceDetail>(
        'fn_osint_source_update',
        [req.user!.id, id, data],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'admin.sources.update',
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
          action: 'admin.sources.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async delete(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.sources.delete', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as OsintSourceIdParamInferred;
      const result = await db.callFunction<DeleteOsintSourceResponse>(
        'fn_osint_source_delete',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'admin.sources.delete',
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
          action: 'admin.sources.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async testPull(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.sources.testPull', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as OsintSourceIdParamInferred;
      const result = await db.callFunction<TestPullResponse>(
        'fn_osint_source_test_pull',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'admin.sources.testPull',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 202,
        },
        'Controller exit',
      );
      res.status(202).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.sources.testPull',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async setCredential(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    // CRITICAL: NEVER log req.body — it contains credentialRef. Pino redact
    // covers the path as defence-in-depth, but the explicit no-log policy
    // here is the primary safeguard (AC-S3-05 invariant).
    req.logger.info(
      {
        action: 'admin.sources.setCredential',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as OsintSourceIdParamInferred;
      const data = req.body as unknown as SetCredentialInferred;
      const result = await db.callFunction<SetCredentialResponse>(
        'fn_source_credential_set',
        [req.user!.id, id, data.credentialKind, data.credentialRef],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'admin.sources.setCredential',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          // result.credentialKind is non-sensitive metadata — credentialRef
          // is NEVER returned by the fn_ (AC-S3-04).
          credentialKind: result?.credentialKind,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.sources.setCredential',
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
