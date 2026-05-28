/**
 * CR-M — Party Workforce routes.
 *
 * Endpoints:
 *   POST /api/v1/parties/:partyId/workforce  — upsert workforce (party.workforce.manage)
 *   GET  /api/v1/parties/:partyId/workforce  — get workforce snapshot (party.workforce.read)
 *   GET  /api/v1/parties/workforce           — list all contractors' workforce (party.workforce.read)
 *
 * Mount: v1Router.use('/parties', partyWorkforceRouter) BEFORE existing partiesRouter
 * so the literal /workforce path doesn't conflict with /:partyId param.
 *
 * IMPORTANT route ordering:
 *   GET /parties/workforce   (literal) MUST be mounted BEFORE GET /parties/:partyId/workforce
 *   (param) to avoid '/workforce' being captured as a partyId. The exports below separate
 *   the list route (workforceListRouter) from the per-party routes (partyWorkforceRouter).
 *   index.ts mounts workforceListRouter first.
 */
import { Router } from 'express';
import type { ZodSchema } from 'zod';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import { partyWorkforceController } from '../../controllers/party-workforce.controller';
import {
  setPartyWorkforceSchema,
  partyWorkforceListQuerySchema,
  type PartyWorkforceListQueryInput,
} from '../../schemas/regulatory-cascade.schemas';

/** GET /api/v1/parties/workforce — list across all contractors */
export const workforceListRouter = Router();

workforceListRouter.get(
  '/workforce',
  authenticate,
  rlsMiddleware,
  authorise(['party.workforce.read']),
  validate(partyWorkforceListQuerySchema as ZodSchema<PartyWorkforceListQueryInput>, 'query'),
  partyWorkforceController.list,
);

/** POST + GET /api/v1/parties/:partyId/workforce — per-party */
export const partyWorkforceRouter = Router({ mergeParams: true });

partyWorkforceRouter.post(
  '/:partyId/workforce',
  authenticate,
  rlsMiddleware,
  authorise(['party.workforce.manage']),
  validate(setPartyWorkforceSchema, 'body'),
  partyWorkforceController.set,
);

partyWorkforceRouter.get(
  '/:partyId/workforce',
  authenticate,
  rlsMiddleware,
  authorise(['party.workforce.read']),
  partyWorkforceController.get,
);
