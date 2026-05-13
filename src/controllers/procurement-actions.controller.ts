/**
 * Unit-4 / R-PROC — Procurement persona action controllers.
 *
 * Routes handled:
 *   POST /api/v1/procurement/vendors/:partyId/activate-alternate
 *   POST /api/v1/procurement/vendors/:partyId/escalate
 *   POST /api/v1/procurement/contracts/:contractId/cure-notice-intent
 *   POST /api/v1/procurement/contracts/:contractId/icv-remediation
 *
 * Permission: risk.acknowledge (all 4 — granted to drafter+approver+platform_admin).
 * Audit: fn_audit_log_record_v2 via persona-actions.service.
 *
 * Cure-notice intent is a STUB until CR-H (Unit 5) ships the advisory drafter.
 * For now we record intent in audit_log so the demo can show "Procurement
 * initiated cure notice on 2026-05-13" — when CR-H lands, the same trigger
 * will cascade to fn_advisory_draft_generate.
 *
 * Pattern: Route → Controller → service → db.callFunction → JSONB response.
 * No business logic in this file.
 */
import type { NextFunction, Request, Response } from 'express';
import { ADNOC_TENANT_ID } from '../middleware/rls.middleware';
import { personaActionsService } from '../services/persona-actions.service';
import type {
  PartyIdParam,
  ContractIdPersonaParam,
  ProcurementActivateAlternateBody,
  ProcurementEscalateVendorBody,
  ProcurementCureNoticeIntentBody,
  ProcurementIcvRemediationBody,
} from '../schemas/persona-actions.schemas';

// ---------------------------------------------------------------------------
// Activate alternate vendor
// ---------------------------------------------------------------------------

export const activateAlternateVendor = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { partyId } = req.params as unknown as PartyIdParam;
  const partyIdNum = Number(partyId);

  req.logger.info({
    action: 'vendor_alternate_activated',
    method: req.method,
    path: req.path,
    userId: actorId,
    partyId: partyIdNum,
  });

  try {
    const body = req.body as ProcurementActivateAlternateBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;
    const result = await personaActionsService.activateAlternateVendor(
      actorId,
      partyIdNum,
      body,
      tenantId,
    );
    req.logger.info({
      action: 'vendor_alternate_activated',
      userId: actorId,
      partyId: partyIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });
    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'vendor_alternate_activated',
      userId: actorId,
      partyId: partyIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Escalate vendor performance
// ---------------------------------------------------------------------------

export const escalateVendorPerformance = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { partyId } = req.params as unknown as PartyIdParam;
  const partyIdNum = Number(partyId);

  req.logger.info({
    action: 'vendor_performance_escalated',
    method: req.method,
    path: req.path,
    userId: actorId,
    partyId: partyIdNum,
  });

  try {
    const body = req.body as ProcurementEscalateVendorBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;
    const result = await personaActionsService.escalateVendorPerformance(
      actorId,
      partyIdNum,
      body,
      tenantId,
    );
    req.logger.info({
      action: 'vendor_performance_escalated',
      userId: actorId,
      partyId: partyIdNum,
      toRole: body.toRole,
      duration: Date.now() - startTime,
      statusCode: 200,
    });
    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'vendor_performance_escalated',
      userId: actorId,
      partyId: partyIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Cure-notice intent (stub until CR-H lands in Unit 5)
// ---------------------------------------------------------------------------

export const recordCureNoticeIntent = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'cure_notice_intent_recorded',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const body = req.body as ProcurementCureNoticeIntentBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;
    const result = await personaActionsService.recordCureNoticeIntent(
      actorId,
      contractIdNum,
      body,
      tenantId,
    );
    req.logger.info({
      action: 'cure_notice_intent_recorded',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });
    res.status(200).json({
      success: true,
      data: { ...result, note: 'Advisory drafter ships in CR-H (Unit 5). Intent recorded.' },
    });
  } catch (error) {
    req.logger.error({
      action: 'cure_notice_intent_recorded',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// ICV remediation
// ---------------------------------------------------------------------------

export const initiateIcvRemediation = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'icv_remediation_initiated',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const body = req.body as ProcurementIcvRemediationBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;
    const result = await personaActionsService.initiateIcvRemediation(
      actorId,
      contractIdNum,
      body,
      tenantId,
    );
    req.logger.info({
      action: 'icv_remediation_initiated',
      userId: actorId,
      contractId: contractIdNum,
      forwardToCompliance: body.forwardToCompliance,
      duration: Date.now() - startTime,
      statusCode: 200,
    });
    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'icv_remediation_initiated',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
