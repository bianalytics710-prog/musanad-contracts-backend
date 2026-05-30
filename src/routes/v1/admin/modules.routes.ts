/**
 * CR-V — Admin Product Module Toggle routes.
 *
 *   GET    /api/v1/admin/modules               → list all modules with enable state
 *   PATCH  /api/v1/admin/modules/:key          → toggle module on/off
 *   PATCH  /api/v1/admin/bundles/:code         → toggle bundle on/off
 *   GET    /api/v1/admin/role-modules          → role × module access matrix
 *   PATCH  /api/v1/admin/role-modules/:roleId/:moduleKey → toggle role × module cell
 *
 * All require authenticate + authorise(['settings.write']).
 * Module key and bundle code are free-form strings validated by Zod (trimmed, max 120).
 * The fn_ bodies validate against the catalog and raise 22023 if the key/code is unknown.
 *
 * Route order note: PATCH /bundles/:code is distinct from PATCH /modules/:key because
 * the paths differ (/bundles vs /modules). Both are prefixed at /api/v1/admin.
 */
import { Router } from 'express';
import { adminModulesController } from '../../../controllers/admin/modules.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import {
  PatchModuleBodySchema,
  PatchBundleBodySchema,
  PatchRoleModuleBodySchema,
} from '../../../schemas/modules.schemas';
import { z } from 'zod';

const router = Router();

router.use(authenticate, rlsMiddleware);

// ─── Path param schemas ───────────────────────────────────────────────────────

const moduleKeyParamSchema = z.object({
  key: z
    .string()
    .trim()
    .min(1, 'key is required')
    .max(120, 'key must be at most 120 characters'),
});

const bundleCodeParamSchema = z.object({
  code: z
    .string()
    .trim()
    .min(1, 'code is required')
    .max(50, 'code must be at most 50 characters'),
});

const roleModuleParamSchema = z.object({
  roleId: z
    .string()
    .trim()
    .regex(/^\d+$/, 'roleId must be a positive integer string'),
  moduleKey: z
    .string()
    .trim()
    .min(1, 'moduleKey is required')
    .max(120, 'moduleKey must be at most 120 characters'),
});

// ─── GET /modules ─────────────────────────────────────────────────────────────

router.get(
  '/modules',
  authedReadRateLimiter,
  authorise(['settings.read']),
  adminModulesController.listModules,
);

// ─── PATCH /modules/:key ──────────────────────────────────────────────────────

router.patch(
  '/modules/:key',
  authedWriteRateLimiter,
  authorise(['settings.write']),
  validate(moduleKeyParamSchema, 'params'),
  validate(PatchModuleBodySchema, 'body'),
  adminModulesController.patchModule,
);

// ─── PATCH /bundles/:code ─────────────────────────────────────────────────────

router.patch(
  '/bundles/:code',
  authedWriteRateLimiter,
  authorise(['settings.write']),
  validate(bundleCodeParamSchema, 'params'),
  validate(PatchBundleBodySchema, 'body'),
  adminModulesController.patchBundle,
);

// ─── GET /role-modules ────────────────────────────────────────────────────────

router.get(
  '/role-modules',
  authedReadRateLimiter,
  authorise(['settings.read']),
  adminModulesController.getRoleModuleMatrix,
);

// ─── PATCH /role-modules/:roleId/:moduleKey ───────────────────────────────────

router.patch(
  '/role-modules/:roleId/:moduleKey',
  authedWriteRateLimiter,
  authorise(['settings.write']),
  validate(roleModuleParamSchema, 'params'),
  validate(PatchRoleModuleBodySchema, 'body'),
  adminModulesController.patchRoleModuleAccess,
);

export default router;
