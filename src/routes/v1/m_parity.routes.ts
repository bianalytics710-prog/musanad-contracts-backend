/**
 * M_parity routes — /api/v1/parties, /templates, /clauses, /obligations.
 *
 * Read-only this round (list + get for parties / templates / clauses; list
 * for obligations). All routes require an authenticated JWT; per-request
 * permission gating happens inside the fn_ body
 * (contract.read.department OR contract.edit). 42501 → 403 via
 * translatePgError.
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { authedReadRateLimiter, authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  partiesController,
  templatesController,
  clausesController,
  obligationsController,
} from '../../controllers/m_parity.controller';
import {
  CreatePartySchema,
  CreateTemplateSchema,
  CreateClauseSchema,
  CreateObligationSchema,
  IdParamSchema,
} from '../../schemas/m_parity.schemas';

const partiesRouter = Router();
partiesRouter.use(authenticate);
partiesRouter.get('/', authedReadRateLimiter, partiesController.list);
partiesRouter.post('/', authedWriteRateLimiter, validate(CreatePartySchema, 'body'), partiesController.create);
partiesRouter.get('/:id', authedReadRateLimiter, validate(IdParamSchema, 'params'), partiesController.getById);

const templatesRouter = Router();
templatesRouter.use(authenticate);
templatesRouter.get('/', authedReadRateLimiter, templatesController.list);
templatesRouter.post('/', authedWriteRateLimiter, validate(CreateTemplateSchema, 'body'), templatesController.create);
templatesRouter.get('/:id', authedReadRateLimiter, validate(IdParamSchema, 'params'), templatesController.getById);

const clausesRouter = Router();
clausesRouter.use(authenticate);
clausesRouter.get('/', authedReadRateLimiter, clausesController.list);
clausesRouter.post('/', authedWriteRateLimiter, validate(CreateClauseSchema, 'body'), clausesController.create);
clausesRouter.get('/:id', authedReadRateLimiter, validate(IdParamSchema, 'params'), clausesController.getById);

const obligationsRouter = Router();
obligationsRouter.use(authenticate);
obligationsRouter.get('/', authedReadRateLimiter, obligationsController.list);
obligationsRouter.post('/', authedWriteRateLimiter, validate(CreateObligationSchema, 'body'), obligationsController.create);

export {
  partiesRouter,
  templatesRouter,
  clausesRouter,
  obligationsRouter,
};
