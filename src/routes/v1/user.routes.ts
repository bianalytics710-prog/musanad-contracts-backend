/**
 * /api/v1/users routes.
 *
 * Authorisation matrix (api-contracts.json):
 *   GET    /        — auth + user.read.all
 *   POST   /        — auth + user.manage
 *   GET    /:id     — auth + (self OR user.read.all)
 *   PUT    /:id     — auth + (self limited fields OR user.manage); finer
 *                     check happens inside the controller because schema-
 *                     middleware has already coerced `:id`.
 *   DELETE /:id     — auth + user.manage
 */
import { Router } from 'express';
import { userController } from '../../controllers/user.controller';
import {
  authenticate,
  authorise,
  authoriseSelfOr,
} from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  createUserSchema,
  listUsersQuerySchema,
  updateUserSchema,
  userIdParamSchema,
} from '../../schemas/user.schemas';

const router = Router();

// Apply auth on every endpoint in this router
router.use(authenticate);

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['user.read.all']),
  validate(listUsersQuerySchema, 'query'),
  userController.list,
);

router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['user.manage']),
  validate(createUserSchema, 'body'),
  userController.create,
);

router.get(
  '/:id',
  authedReadRateLimiter,
  validate(userIdParamSchema, 'params'),
  authoriseSelfOr(['user.read.all', 'user.manage']),
  userController.getById,
);

router.put(
  '/:id',
  authedWriteRateLimiter,
  validate(userIdParamSchema, 'params'),
  // Self vs user.manage refinement is in the controller (depends on body shape)
  validate(updateUserSchema, 'body'),
  userController.update,
);

router.delete(
  '/:id',
  authedWriteRateLimiter,
  authorise(['user.manage']),
  validate(userIdParamSchema, 'params'),
  userController.delete,
);

export default router;
