/**
 * Unit-3 / R-OPS — Operations persona action controllers.
 *
 * Routes handled:
 *   POST /api/v1/ops/events/:correlationId/acknowledge
 *   POST /api/v1/ops/events/:correlationId/link-remedy
 *   POST /api/v1/ops/events/:correlationId/escalate
 *
 * Permission: risk.acknowledge (all 3 routes)
 * Audit: fn_audit_log_record_v2 via persona-actions.service
 * Idempotency: acknowledge returns 409 if duplicate within 24h.
 *
 * Pattern: Route → Controller → service → db.callFunction → JSONB response.
 * No business logic in this file. One service call per handler.
 */
import type { NextFunction, Request, Response } from 'express';
import { ADNOC_TENANT_ID } from '../middleware/rls.middleware';
import { personaActionsService } from '../services/persona-actions.service';
import type {
  OpsAcknowledgeBody,
  OpsLinkRemedyBody,
  OpsEscalateBody,
  CorrelationIdParam,
} from '../schemas/persona-actions.schemas';

// ---------------------------------------------------------------------------
// Acknowledge ops event
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/ops/events/:correlationId/acknowledge
 * Idempotency: 409 + { error: 'already-acknowledged' } if duplicate in 24h.
 */
export const acknowledgeOpsEvent = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { correlationId } = req.params as unknown as CorrelationIdParam;
  const correlationIdNum = Number(correlationId);

  req.logger.info({
    action: 'ops_event_acknowledged',
    method: req.method,
    path: req.path,
    userId: actorId,
    correlationId: correlationIdNum,
  });

  try {
    const { note } = req.body as OpsAcknowledgeBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.acknowledgeOpsEvent(
      actorId,
      correlationIdNum,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'ops_event_acknowledged',
      userId: actorId,
      correlationId: correlationIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'ops_event_acknowledged',
      userId: actorId,
      correlationId: correlationIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Link remedy to ops event
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/ops/events/:correlationId/link-remedy
 */
export const linkRemedyToOpsEvent = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { correlationId } = req.params as unknown as CorrelationIdParam;
  const correlationIdNum = Number(correlationId);

  req.logger.info({
    action: 'ops_remedy_linked',
    method: req.method,
    path: req.path,
    userId: actorId,
    correlationId: correlationIdNum,
  });

  try {
    const { contractId, clauseId, note } = req.body as OpsLinkRemedyBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.linkRemedyToOpsEvent(
      actorId,
      correlationIdNum,
      contractId,
      clauseId,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'ops_remedy_linked',
      userId: actorId,
      correlationId: correlationIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'ops_remedy_linked',
      userId: actorId,
      correlationId: correlationIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Escalate ops event
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/ops/events/:correlationId/escalate
 */
export const escalateOpsEvent = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { correlationId } = req.params as unknown as CorrelationIdParam;
  const correlationIdNum = Number(correlationId);

  req.logger.info({
    action: 'ops_escalation_requested',
    method: req.method,
    path: req.path,
    userId: actorId,
    correlationId: correlationIdNum,
  });

  try {
    const { toRole, note } = req.body as OpsEscalateBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.escalateOpsEvent(
      actorId,
      correlationIdNum,
      toRole,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'ops_escalation_requested',
      userId: actorId,
      correlationId: correlationIdNum,
      toRole,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'ops_escalation_requested',
      userId: actorId,
      correlationId: correlationIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
