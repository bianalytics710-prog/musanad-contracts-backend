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
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  partiesController,
  templatesController,
  clausesController,
  obligationsController,
} from '../../controllers/m_parity.controller';

const partiesRouter = Router();
partiesRouter.use(authenticate);
partiesRouter.get('/', authedReadRateLimiter, partiesController.list);
partiesRouter.get('/:id', authedReadRateLimiter, partiesController.getById);

const templatesRouter = Router();
templatesRouter.use(authenticate);
templatesRouter.get('/', authedReadRateLimiter, templatesController.list);
templatesRouter.get('/:id', authedReadRateLimiter, templatesController.getById);

const clausesRouter = Router();
clausesRouter.use(authenticate);
clausesRouter.get('/', authedReadRateLimiter, clausesController.list);
clausesRouter.get('/:id', authedReadRateLimiter, clausesController.getById);

const obligationsRouter = Router();
obligationsRouter.use(authenticate);
obligationsRouter.get('/', authedReadRateLimiter, obligationsController.list);

export {
  partiesRouter,
  templatesRouter,
  clausesRouter,
  obligationsRouter,
};
