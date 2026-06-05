/**
 * Index-Linked Contracts tenant-side catalog routes — R-IL Phase B.
 *
 *   GET /api/v1/index-linked/catalog/benchmarks       (finance.margin.read)
 *   GET /api/v1/index-linked/catalog/cost-components  (finance.margin.read)
 *
 * Returns the resolved catalog (industry rows ∪ tenant overrides) for the
 * current tenant. FE uses this to render labels, units, slider bounds,
 * waterfall sort order, and kicker text in the Index-Linked Contracts
 * module (formerly "Trade Margin").
 */
import { Router } from 'express';
import { indexLinkedCatalogController } from '../../controllers/index-linked-catalog.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);
router.use(authorise(['finance.margin.read']));

router.get('/catalog/benchmarks', authedReadRateLimiter, indexLinkedCatalogController.benchmarks);
router.get('/catalog/cost-components', authedReadRateLimiter, indexLinkedCatalogController.costComponents);

export default router;
