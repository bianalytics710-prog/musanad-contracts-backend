/**
 * /api/v1/admin/approval-matrix routes — M2 admin matrix management (S4, S5).
 *
 *   GET  /  → fn_approval_matrix_list (approval.matrix.read)
 *   PUT  /  → fn_approval_matrix_set  (approval.matrix.write)
 */
import { Router } from 'express';
import { approvalMatrixController } from '../../../controllers/admin/approval-matrix.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import {
  ApprovalMatrixListQuerySchema,
  UpdateApprovalMatrixSchema,
} from '../../../schemas/approval.schemas';

const router = Router();

router.use(authenticate);

// GET /api/v1/admin/approval-matrix — S4
router.get(
  '/',
  authedReadRateLimiter,
  authorise(['approval.matrix.read']),
  validate(ApprovalMatrixListQuerySchema, 'query'),
  approvalMatrixController.list,
);

// PUT /api/v1/admin/approval-matrix — S5 (upsert)
router.put(
  '/',
  authedWriteRateLimiter,
  authorise(['approval.matrix.write']),
  validate(UpdateApprovalMatrixSchema, 'body'),
  approvalMatrixController.set,
);

export default router;
