/**
 * CR-C — Audit chain verify service (S3).
 *
 * Thin db.callFunction passthrough for fn_audit_chain_verify. NFR target
 * < 30s @ 100k rows; the heavyExportRateLimiter (5/min/user) gates the route.
 */
import { db } from '../database/client';
import type { AuditChainVerifyResult } from '../types/admin-audit-chain.types';

export const verifyChain = (
  actorId: number,
  startSeq: number | null,
  endSeq: number | null,
): Promise<AuditChainVerifyResult> =>
  db.callFunction<AuditChainVerifyResult>(
    'fn_audit_chain_verify',
    [startSeq, endSeq],
    { actorId },
  );
