/**
 * Industry catalogs admin routes — R-IL Phase B + H.
 *
 *   GET    /api/v1/admin/industry-catalogs                                      (platform.catalog.manage)
 *   POST   /api/v1/admin/industry-catalogs                                      (platform.catalog.manage)  ← H
 *   GET    /api/v1/admin/industry-catalogs/:industryId/benchmarks               (platform.catalog.manage)
 *   POST   /api/v1/admin/industry-catalogs/:industryId/benchmarks               (platform.catalog.manage)
 *   PUT    /api/v1/admin/industry-catalogs/benchmarks/:id                       (platform.catalog.manage)
 *   DELETE /api/v1/admin/industry-catalogs/benchmarks/:id                       (platform.catalog.manage)
 *   GET    /api/v1/admin/industry-catalogs/:industryId/cost-components          (platform.catalog.manage)
 *   POST   /api/v1/admin/industry-catalogs/:industryId/cost-components          (platform.catalog.manage)
 *   PUT    /api/v1/admin/industry-catalogs/cost-components/:id                  (platform.catalog.manage)
 *   DELETE /api/v1/admin/industry-catalogs/cost-components/:id                  (platform.catalog.manage)
 *   PUT    /api/v1/admin/industry-catalogs/:id                                  (platform.catalog.manage)  ← H
 *   DELETE /api/v1/admin/industry-catalogs/:id                                  (platform.catalog.manage)  ← H
 *
 * Route ordering: literal segment paths ('/benchmarks/:id', '/cost-components/:id',
 * '/:industryId/benchmarks', '/:industryId/cost-components') MUST come before
 * the generic '/:id' industry PUT/DELETE so Express doesn't capture 'benchmarks'
 * or 'cost-components' as the industry id.
 */
import { Router } from 'express';
import { industryCatalogController } from '../../../controllers/industry-catalog.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);
router.use(rlsMiddleware);
router.use(authorise(['platform.catalog.manage']));

// ── Industry list + create (root) ──────────────────────────
router.get('/', authedReadRateLimiter, industryCatalogController.listIndustries);
router.post('/', authedWriteRateLimiter, industryCatalogController.upsertIndustry);

// ── Benchmark CRUD ─────────────────────────────────────────
// Literal '/benchmarks/:id' must come BEFORE any '/:industryId/...' or
// '/:id' so Express doesn't try to interpret 'benchmarks' as an id.
router.put('/benchmarks/:id', authedWriteRateLimiter, industryCatalogController.upsertBenchmark);
router.delete('/benchmarks/:id', authedWriteRateLimiter, industryCatalogController.deactivateBenchmark);

// ── Cost-component CRUD ────────────────────────────────────
router.put('/cost-components/:id', authedWriteRateLimiter, industryCatalogController.upsertCostComponent);
router.delete('/cost-components/:id', authedWriteRateLimiter, industryCatalogController.deactivateCostComponent);

// ── Industry sub-resources (industryId-scoped) ─────────────
router.get('/:industryId/benchmarks', authedReadRateLimiter, industryCatalogController.listBenchmarks);
router.post('/:industryId/benchmarks', authedWriteRateLimiter, industryCatalogController.upsertBenchmark);
router.get('/:industryId/cost-components', authedReadRateLimiter, industryCatalogController.listCostComponents);
router.post('/:industryId/cost-components', authedWriteRateLimiter, industryCatalogController.upsertCostComponent);

// ── Industry update/delete by id (LAST — catches everything else) ──
router.put('/:id', authedWriteRateLimiter, industryCatalogController.upsertIndustry);
router.delete('/:id', authedWriteRateLimiter, industryCatalogController.deactivateIndustry);

export default router;
