/**
 * CR-C — /api/v1/admin/branding (S11)
 *
 *   GET   /             → composed branding.* read
 *   PATCH /             → updates color/footer keys
 *   POST  /upload       → multer single-file upload (logo | favicon)
 *
 * Permission: branding.manage. Tenant-scoped via tenantContextMiddleware
 * for upload (the file is persisted under branding/<tenantId>/...).
 */
import { Router } from 'express';
import multer from 'multer';
import { adminBrandingController } from '../../../controllers/admin/branding.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { tenantContextMiddleware } from '../../../middleware/tenant-context.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import {
  brandingPatchBodySchema,
  brandingUploadFormSchema,
} from '../../../schemas/admin-branding.schemas';

const router = Router();

router.use(authenticate);
router.use(tenantContextMiddleware);

const uploadMulter = multer({
  storage: multer.memoryStorage(),
  // Wire-level cap; controller re-checks against the 2 MB AC-S11-05 limit
  // and emits the contract-specified envelope.
  limits: { fileSize: 5 * 1024 * 1024 },
});

router.get(
  '/',
  authedReadRateLimiter,
  authorise(['branding.manage']),
  adminBrandingController.get,
);

router.patch(
  '/',
  authedWriteRateLimiter,
  authorise(['branding.manage']),
  validate(brandingPatchBodySchema, 'body'),
  adminBrandingController.patch,
);

router.post(
  '/upload',
  authedWriteRateLimiter,
  authorise(['branding.manage']),
  uploadMulter.single('file'),
  validate(brandingUploadFormSchema, 'body'),
  adminBrandingController.upload,
);

export default router;
