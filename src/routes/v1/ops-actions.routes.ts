/**
 * Unit-3 / R-OPS — Operations persona action routes.
 *
 * Mounted at: /api/v1/ops
 *
 * Endpoint roster:
 *   POST /api/v1/ops/events/:correlationId/acknowledge
 *   POST /api/v1/ops/events/:correlationId/link-remedy
 *   POST /api/v1/ops/events/:correlationId/escalate
 *
 * Permission gate: risk.acknowledge (all 3 routes).
 * Middleware stack: authenticate → authedWriteRateLimiter → authorise → validate → controller.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  acknowledgeOpsEvent,
  linkRemedyToOpsEvent,
  escalateOpsEvent,
} from '../../controllers/ops-actions.controller';
import {
  CorrelationIdParamSchema,
  OpsAcknowledgeBodySchema,
  OpsLinkRemedyBodySchema,
  OpsEscalateBodySchema,
} from '../../schemas/persona-actions.schemas';

const opsActionsRouter = Router();

// All routes require an authenticated user.
opsActionsRouter.use(authenticate);

// ------------------------------------------------------------
// POST /api/v1/ops/events/:correlationId/acknowledge
// ------------------------------------------------------------
// Idempotency: 409 + { error: 'already-acknowledged' } if duplicate within 24h.
opsActionsRouter.post(
  '/events/:correlationId/acknowledge',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(CorrelationIdParamSchema, 'params'),
  validate(OpsAcknowledgeBodySchema, 'body'),
  acknowledgeOpsEvent,
);

// ------------------------------------------------------------
// POST /api/v1/ops/events/:correlationId/link-remedy
// ------------------------------------------------------------
opsActionsRouter.post(
  '/events/:correlationId/link-remedy',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(CorrelationIdParamSchema, 'params'),
  validate(OpsLinkRemedyBodySchema, 'body'),
  linkRemedyToOpsEvent,
);

// ------------------------------------------------------------
// POST /api/v1/ops/events/:correlationId/escalate
// ------------------------------------------------------------
opsActionsRouter.post(
  '/events/:correlationId/escalate',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(CorrelationIdParamSchema, 'params'),
  validate(OpsEscalateBodySchema, 'body'),
  escalateOpsEvent,
);

export default opsActionsRouter;
