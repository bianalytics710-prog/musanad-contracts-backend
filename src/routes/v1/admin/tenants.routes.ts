/**
 * CR-C — /api/v1/admin/tenants
 *
 *   GET /          → fn_tenant_list
 *   GET /:id       → fn_tenant_get_by_id
 *
 * Permission: tenant.read.
 */
import { Router } from 'express';
import { adminTenantsController } from '../../../controllers/admin/tenants.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { authedReadRateLimiter } from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  tenantIdParamSchema,
  tenantListQuerySchema,
} from '../../../schemas/admin-tenants.schemas';

const router = Router();

router.use(authenticate);

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['tenant.read']),
  validate(tenantListQuerySchema, 'query'),
  adminTenantsController.list,
);

router.get(
  '/:id',
  authedReadRateLimiter,
  authorise(['tenant.read']),
  validate(tenantIdParamSchema, 'params'),
  adminTenantsController.getById,
);

export default router;
