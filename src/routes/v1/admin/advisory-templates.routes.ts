/**
 * M16 / CR-H — /api/v1/admin/advisory-templates routes.
 *
 * 5 endpoints: list, get-by-id, create, update, delete.
 * Permission: advisory.template.manage.
 * Roles: Super Admin, platform_admin, legal_counsel.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { advisoryTemplatesController } from '../../../controllers/advisory-templates.controller';
import {
  createAdvisoryTemplateSchema,
  updateAdvisoryTemplateSchema,
} from '../../../schemas/advisory-templates.schemas';

const router = Router();

const ADVISORY_TEMPLATE_ROLES = ['Super Admin', 'platform_admin', 'legal_counsel'] as const;
const PERMISSION = ['advisory.template.manage'] as const;

// GET /api/v1/admin/advisory-templates
router.get(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  advisoryTemplatesController.list,
);

// GET /api/v1/admin/advisory-templates/:id
router.get(
  '/:id',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  advisoryTemplatesController.getById,
);

// POST /api/v1/admin/advisory-templates
router.post(
  '/',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  validate(createAdvisoryTemplateSchema, 'body'),
  advisoryTemplatesController.create,
);

// PATCH /api/v1/admin/advisory-templates/:id
// Note: validate runs AFTER authenticate so req.body is available.
// Controller enforces immutable-field pre-check (DD-6) before fn_ call.
router.patch(
  '/:id',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  validate(updateAdvisoryTemplateSchema, 'body'),
  advisoryTemplatesController.update,
);

// DELETE /api/v1/admin/advisory-templates/:id
router.delete(
  '/:id',
  authenticate,
  rlsMiddleware,
  authorise(PERMISSION),
  advisoryTemplatesController.delete,
);

export default router;

// Suppress unused-variable warning for the roles constant
void ADVISORY_TEMPLATE_ROLES;
