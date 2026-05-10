/**
 * CR-C — Admin Audit Chain Controller (S3).
 *
 *   POST /api/v1/admin/audit/verify → fn_audit_chain_verify
 *
 * Permission: audit.verify (route layer + fn body redundantly enforced).
 * Rate-limited via heavyExportRateLimiter (5/min/user — same family as
 * /admin/audit/export per R-PA7).
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../../utils/errors.util';
import * as svc from '../../services/admin-audit-chain.service';
import type { AuditChainVerifyBodyInferred } from '../../schemas/admin-audit-chain.schemas';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminAuditChainController = {
  async verify(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.auditChain.verify',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = (req.body ?? {}) as AuditChainVerifyBodyInferred;
      const startSeq = body.startSeq ?? null;
      const endSeq = body.endSeq ?? null;
      const result = await svc.verifyChain(req.user!.id, startSeq, endSeq);
      req.logger.info(
        {
          action: 'admin.auditChain.verify',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          verified: result?.verified ?? null,
          rowsWalked: result?.rowsWalked ?? 0,
          elapsedMs: result?.elapsedMs ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.auditChain.verify',
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
