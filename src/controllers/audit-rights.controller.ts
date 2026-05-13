/**
 * Unit-3 / R-CES — Audit Rights controller.
 *
 * Route handled:
 *   GET /api/v1/contracts/:contractId/audit-rights
 *
 * Permission: contract.read (ANY of contract.read.all | contract.read.department | contract.read.own)
 *   OR insights.compliance_esg OR insights.executive.
 *   The fn_ body enforces the same gate internally (42501 → 403).
 *   Route layer applies authoriseAnyOf(['contract.read.all', ...]) as pre-gate.
 *
 * DB function: fn_contract_audit_rights_list(p_actor_id BIGINT, p_contract_id BIGINT)
 *   Returns: { contractId, auditRightsClauses: [...], count }
 *
 * Pattern: Route → Controller → db.callFunction → JSONB response.
 * No service layer needed — single DB call, no audit_log write.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ADNOC_TENANT_ID } from '../middleware/rls.middleware';
import type { ContractIdPersonaParam } from '../schemas/persona-actions.schemas';

interface AuditRightsClause {
  clauseId: string;
  clauseType: string;
  parameters: Record<string, unknown>;
  pageNo: number | null;
  confidence: number | null;
  summaryEn: string | null;
  summaryAr: string | null;
  reviewStatus: string;
  extractedAt: string;
  daysToExpiry: number | null;
  severity: string;
}

interface AuditRightsListResult {
  contractId: string;
  auditRightsClauses: AuditRightsClause[];
  count: number;
}

/**
 * GET /api/v1/contracts/:contractId/audit-rights
 * Calls fn_contract_audit_rights_list and returns JSON directly.
 */
export const getContractAuditRights = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'fn_contract_audit_rights_list',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await db.callFunction<AuditRightsListResult>(
      'fn_contract_audit_rights_list',
      [actorId, contractIdNum],
      { actorId, tenantId },
    );

    req.logger.info({
      action: 'fn_contract_audit_rights_list',
      userId: actorId,
      contractId: contractIdNum,
      count: result?.count ?? 0,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'fn_contract_audit_rights_list',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
