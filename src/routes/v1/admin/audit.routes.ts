/**
 * /api/v1/admin/audit — audit_log viewer (R-PA5).
 *
 *   GET /          — auth + audit.read → fn_audit_log_list (paginated JSON)
 *   GET /export    — auth + audit.read → CSV stream of the same query
 */
import { Router } from 'express';
import { z } from 'zod';
import { adminAuditController } from '../../../controllers/admin-audit.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  heavyExportRateLimiter,
} from '../../../middleware/rate-limit.middleware';

const router = Router();

router.use(authenticate);

const listQuerySchema = z.object({
  page:       z.coerce.number().int().min(1).max(100000).optional(),
  limit:      z.coerce.number().int().min(1).max(200).optional(),
  tableName:  z.string().trim().min(1).max(80).optional(),
  action:     z.enum(['INSERT', 'UPDATE', 'DELETE']).optional(),
  changedBy:  z.coerce.number().int().positive().optional(),
  dateFrom:   z.coerce.date().optional(),
  dateTo:     z.coerce.date().optional(),
  contractId: z.coerce.number().int().positive().optional(),
});

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['audit.read']),
  validate(listQuerySchema, 'query'),
  adminAuditController.list,
);

router.get(
  '/export',
  heavyExportRateLimiter,
  authorise(['audit.read']),
  validate(listQuerySchema, 'query'),
  adminAuditController.exportCsv,
);

export default router;
