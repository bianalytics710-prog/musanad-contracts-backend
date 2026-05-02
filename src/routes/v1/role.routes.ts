/**
 * /api/v1/roles routes — list active roles.
 */
import { Router } from 'express';
import { roleController } from '../../controllers/role.controller';
import { authenticate } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { listRolesQuerySchema } from '../../schemas/user.schemas';

const router = Router();

router.use(authenticate);

router.get(
  '/',
  authedReadRateLimiter,
  validate(listRolesQuerySchema, 'query'),
  roleController.list,
);

export default router;
