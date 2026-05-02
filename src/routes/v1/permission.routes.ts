/**
 * /api/v1/permissions routes — list permission catalog.
 *
 * Per Contract Generator's accepted deviation (decisions / api-contracts.json
 * x-designNotes): the M0 spec doesn't list this route explicitly but the
 * user-management UI needs it and the DB design defines fn_permission_list.
 */
import { Router } from 'express';
import { permissionController } from '../../controllers/permission.controller';
import { authenticate } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { listPermissionsQuerySchema } from '../../schemas/user.schemas';

const router = Router();

router.use(authenticate);

router.get(
  '/',
  authedReadRateLimiter,
  validate(listPermissionsQuerySchema, 'query'),
  permissionController.list,
);

export default router;
