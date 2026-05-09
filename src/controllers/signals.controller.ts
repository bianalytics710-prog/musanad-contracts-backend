/**
 * M7 — OSINT Signals Controller (CR-A).
 *
 *   GET /api/v1/signals → fn_osint_signal_list
 *
 * Permission: signal.read.all (gated inside fn_).
 * Filters: kind / sourceId (TEXT denorm) / severityMin (ordered) / since /
 * geographyIntersects / affectedEntityId. Order: event_date DESC NULLS LAST,
 * fetched_at DESC. RLS auto-scopes by tenant.
 *
 * rawPayload IS exposed in the response (AC-S11 — legal_counsel needs SDN
 * entry text); redacted only at log + audit_log layer.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import type { OsintSignalListQueryInferred } from '../schemas/signals.schemas';
import type { OsintSignalListResponse } from '../types/osint.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const signalsController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'signals.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OsintSignalListQueryInferred;
      const filter: Record<string, unknown> = {};
      if (q.kind !== undefined) filter['kind'] = q.kind;
      if (q.sourceId !== undefined) filter['sourceId'] = q.sourceId;
      if (q.severityMin !== undefined) filter['severityMin'] = q.severityMin;
      if (q.since !== undefined) filter['since'] = q.since;
      if (q.geographyIntersects !== undefined) {
        filter['geographyIntersects'] = q.geographyIntersects.toUpperCase();
      }
      if (q.affectedEntityId !== undefined) {
        filter['affectedEntityId'] = q.affectedEntityId;
      }

      const result = await db.callFunction<OsintSignalListResponse>(
        'fn_osint_signal_list',
        [req.user!.id, filter, q.page ?? 1, q.limit ?? 20],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info(
        {
          action: 'signals.list',
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
          action: 'signals.list',
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
