/**
 * Unit-4 / R-PROC — Procurement persona action routes.
 *
 * Mounted at: /api/v1/procurement
 *
 * Endpoint roster:
 *   POST /api/v1/procurement/vendors/:partyId/activate-alternate
 *   POST /api/v1/procurement/vendors/:partyId/escalate
 *   POST /api/v1/procurement/contracts/:contractId/cure-notice-intent
 *   POST /api/v1/procurement/contracts/:contractId/icv-remediation
 *
 * Permission gate: risk.acknowledge (all 4 routes — granted to contract_drafter +
 *   contract_approver + platform_admin per M14 mig 175).
 * Middleware stack: authenticate → authedWriteRateLimiter → authorise → validate → controller.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  activateAlternateVendor,
  escalateVendorPerformance,
  recordCureNoticeIntent,
  initiateIcvRemediation,
} from '../../controllers/procurement-actions.controller';
import {
  PartyIdParamSchema,
  ContractIdPersonaParamSchema,
  ProcurementActivateAlternateBodySchema,
  ProcurementEscalateVendorBodySchema,
  ProcurementCureNoticeIntentBodySchema,
  ProcurementIcvRemediationBodySchema,
} from '../../schemas/persona-actions.schemas';

const procurementActionsRouter = Router();

procurementActionsRouter.use(authenticate);

procurementActionsRouter.post(
  '/vendors/:partyId/activate-alternate',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(PartyIdParamSchema, 'params'),
  validate(ProcurementActivateAlternateBodySchema, 'body'),
  activateAlternateVendor,
);

procurementActionsRouter.post(
  '/vendors/:partyId/escalate',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(PartyIdParamSchema, 'params'),
  validate(ProcurementEscalateVendorBodySchema, 'body'),
  escalateVendorPerformance,
);

procurementActionsRouter.post(
  '/contracts/:contractId/cure-notice-intent',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(ProcurementCureNoticeIntentBodySchema, 'body'),
  recordCureNoticeIntent,
);

procurementActionsRouter.post(
  '/contracts/:contractId/icv-remediation',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(ProcurementIcvRemediationBodySchema, 'body'),
  initiateIcvRemediation,
);

export default procurementActionsRouter;
