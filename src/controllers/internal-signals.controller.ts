/**
 * M8 — Internal Signals user-facing controller (CR-A2).
 *
 *   GET  /api/v1/internal-signals               → fn_internal_signal_list
 *   POST /api/v1/internal-signals/:id/resolve   → fn_internal_signal_resolve
 *
 * Permissions (gated inside the fn_ bodies — defence-in-depth):
 *   - GET                 → internal_signal.read
 *   - POST :id/resolve    → internal_signal.resolve + per-signal_type role
 *                           allowlist (Q-DA3 hardcoded mapping).
 *
 * Tenant GUC is set via db.callFunction({ tenantId }) using `req.tenantId`
 * resolved by rls.middleware.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import type {
  InternalSignalIdParamInferred,
  InternalSignalListQueryInferred,
  InternalSignalResolveInferred,
} from '../schemas/internal-signals.schemas';
import type {
  InternalSignalListFilter,
  InternalSignalListResponse,
  InternalSignalResolveResponse,
} from '../types/internal-signal.types';
import {
  listInternalSignals,
  resolveInternalSignal,
} from '../services/internal-signals.service';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const internalSignalsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'internalSignals.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as InternalSignalListQueryInferred;
      const filter: InternalSignalListFilter = {};
      if (q.signalType !== undefined) filter.signalType = q.signalType;
      if (q.contractId !== undefined) filter.contractId = q.contractId;
      if (q.vendorId !== undefined) filter.vendorId = q.vendorId;
      if (q.since !== undefined) filter.since = q.since;
      if (q.status !== undefined) filter.status = q.status;

      const page = q.page ?? 1;
      const limit = q.limit ?? 20;

      const result: InternalSignalListResponse = await listInternalSignals(
        req.user!.id,
        req.tenantId,
        filter,
        page,
        limit,
      );

      req.logger.info(
        {
          action: 'internalSignals.list',
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
          action: 'internalSignals.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async resolve(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'internalSignals.resolve',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as InternalSignalIdParamInferred;
      const data = req.body as unknown as InternalSignalResolveInferred;
      // resolutionNote is optional free-text — DO NOT log its content
      // (defensive default per the prompt; it might carry sensitive info
      // about the resolution). Only resolutionKind is non-sensitive.
      const result: InternalSignalResolveResponse = await resolveInternalSignal(
        req.user!.id,
        req.tenantId,
        id,
        data.resolutionKind,
        data.resolutionNote ?? null,
      );

      req.logger.info(
        {
          action: 'internalSignals.resolve',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          signalId: id,
          resolutionKind: data.resolutionKind,
          idempotent: result?.idempotent ?? false,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'internalSignals.resolve',
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
