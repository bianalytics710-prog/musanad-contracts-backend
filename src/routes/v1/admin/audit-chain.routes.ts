/**
 * CR-C — /api/v1/admin/audit/verify
 *
 * POST /verify → fn_audit_chain_verify
 *
 * Permission: audit.verify (route + fn body).
 * Rate limit: heavyExportRateLimiter (5/min/user) — chain walk is bounded
 * (NFR target < 30s @ 100k rows) but the limiter prevents accidental abuse.
 */
import { Router } from 'express';
import { adminAuditChainController } from '../../../controllers/admin/audit-chain.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { heavyExportRateLimiter } from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { auditChainVerifyBodySchema } from '../../../schemas/admin-audit-chain.schemas';

const router = Router();

router.use(authenticate);

router.post(
  '/verify',
  heavyExportRateLimiter,
  authorise(['audit.verify']),
  validate(auditChainVerifyBodySchema, 'body'),
  adminAuditChainController.verify,
);

export default router;
