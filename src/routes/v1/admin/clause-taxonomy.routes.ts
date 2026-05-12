/**
 * M12 / CR-D-005 — GET /api/v1/admin/clause-taxonomy
 *
 * Returns the full clause taxonomy catalogue (50 types + parameter schemas).
 * Permission: clause.taxonomy.read
 * Roles: Super Admin, platform_admin, legal_counsel, contract_drafter,
 *        contract_approver, contract_approver_2, contract_recipient, executive
 */
import { Router } from 'express';
import { clauseExtractionController } from '../../../controllers/clause-extraction.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../../middleware/rate-limit.middleware';
import { ClauseTaxonomyQuerySchema } from '../../../schemas/clause-extraction.schemas';

const router = Router();

// CR-D-005 — GET /admin/clause-taxonomy
router.get(
  '/',
  authenticate,
  authorise(['clause.taxonomy.read']),
  authedReadRateLimiter,
  validate(ClauseTaxonomyQuerySchema, 'query'),
  clauseExtractionController.listTaxonomy,
);

export default router;
