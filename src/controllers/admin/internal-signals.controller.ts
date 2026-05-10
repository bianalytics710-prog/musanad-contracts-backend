/**
 * M8 — Admin Internal Signals controller (CR-A2).
 *
 *   POST /api/v1/admin/internal-signals → fn_internal_signal_ingest
 *
 * Permission: internal_signal.ingest (system-only — Super Admin +
 * platform_admin). Defence-in-depth permission gate lives inside the fn
 * body. fn is SECURITY DEFINER; EXECUTE is REVOKE-only on PUBLIC. The
 * route is JWT-authenticated via the standard authenticate middleware.
 *
 * Idempotent on UNIQUE(tenant_id, dedup_hash) — same payload posted twice
 * yields { inserted: false, dedupHashHit: true } with the same signalId;
 * both return 201 (NOT 409, per AC-S2-02).
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../../utils/errors.util';
import type { InternalSignalIngestInferred } from '../../schemas/internal-signals.schemas';
import { ingestInternalSignal } from '../../services/internal-signals.service';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminInternalSignalsController = {
  async ingest(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.internalSignals.ingest',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const data = req.body as unknown as InternalSignalIngestInferred;
      const result = await ingestInternalSignal(req.user!.id, req.tenantId, data);
      req.logger.info(
        {
          action: 'admin.internalSignals.ingest',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
          // Non-sensitive metadata: signalType + the dedup outcome. raw
          // payload contents (contractId / vendorId / refs) NOT logged here.
          signalType: data.signalType,
          inserted: result?.inserted,
          dedupHashHit: result?.dedupHashHit,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.internalSignals.ingest',
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
