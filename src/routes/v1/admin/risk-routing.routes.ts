/**
 * Admin risk routing — Phase B.2.
 *
 *   GET    /api/v1/admin/risk-routing       (risk.routing.manage)
 *   POST   /api/v1/admin/risk-routing       (risk.routing.manage)
 *   PUT    /api/v1/admin/risk-routing/:id   (risk.routing.manage)
 *   DELETE /api/v1/admin/risk-routing/:id   (risk.routing.manage)
 *
 * All endpoints additionally enforce the permission inside the fn body
 * as defense-in-depth.
 */
import { Router } from 'express';
import { riskRoutingController } from '../../../controllers/risk-routing.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);
router.use(authorise(['risk.routing.manage']));

router.get('/', authedReadRateLimiter, riskRoutingController.list);
router.post('/', authedWriteRateLimiter, riskRoutingController.create);
router.put('/:id', authedWriteRateLimiter, riskRoutingController.update);
router.delete('/:id', authedWriteRateLimiter, riskRoutingController.remove);

export default router;
