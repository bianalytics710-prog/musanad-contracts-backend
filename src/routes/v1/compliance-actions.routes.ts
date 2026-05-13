/**
 * Unit-3 / R-CES — Compliance & ESG persona action routes.
 *
 * Mounted at: /api/v1/compliance
 *
 * Endpoint roster:
 *   POST /api/v1/compliance/contracts/:contractId/raise-flag
 *   POST /api/v1/compliance/contracts/:contractId/supplier-audit
 *   POST /api/v1/compliance/contracts/:contractId/recommend-hold
 *   POST /api/v1/compliance/contracts/:contractId/recommend-termination
 *   POST /api/v1/compliance/contracts/:contractId/icv-certificate   (multipart)
 *
 * Permission gates:
 *   raise-flag / supplier-audit / recommend-hold / recommend-termination:
 *     risk.acknowledge
 *   icv-certificate:
 *     contract.edit  (uploading an attachment; same gate as contract_attachment writes)
 *
 * Middleware stack:
 *   authenticate → authedWriteRateLimiter → authorise → validate (where applicable) → multer (ICV) → controller.
 *
 * ICV upload: multer memoryStorage, 50MB cap, single 'file' field.
 *   Body field `validUntil` is validated by ComplianceIcvCertificateBodySchema AFTER multer
 *   (multer must run before body validators so req.body is populated).
 */
import { Router } from 'express';
import multer from 'multer';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import {
  raiseComplianceFlag,
  initiateSupplierAudit,
  recommendHold,
  recommendTermination,
  uploadIcvCertificate,
} from '../../controllers/compliance-actions.controller';
import {
  ContractIdPersonaParamSchema,
  ComplianceRaiseFlagBodySchema,
  ComplianceSupplierAuditBodySchema,
  ComplianceRecommendHoldBodySchema,
  ComplianceRecommendTerminationBodySchema,
  ComplianceIcvCertificateBodySchema,
} from '../../schemas/persona-actions.schemas';

const complianceActionsRouter = Router();

// All routes require an authenticated user.
complianceActionsRouter.use(authenticate);

// Multer config for ICV certificate upload — matches existing contract-attachment pattern.
const icvMulter = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB hard cap
  fileFilter: (_req, file, cb) => {
    // Accept PDF, PNG, JPG per API contract spec.
    const allowed = ['application/pdf', 'image/png', 'image/jpeg'];
    if (allowed.includes(file.mimetype)) {
      cb(null, true);
    } else {
      cb(new Error('Only PDF, PNG, and JPG files are allowed for ICV certificate upload'));
    }
  },
});

// ------------------------------------------------------------
// POST /api/v1/compliance/contracts/:contractId/raise-flag
// ------------------------------------------------------------
complianceActionsRouter.post(
  '/contracts/:contractId/raise-flag',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(ComplianceRaiseFlagBodySchema, 'body'),
  raiseComplianceFlag,
);

// ------------------------------------------------------------
// POST /api/v1/compliance/contracts/:contractId/supplier-audit
// ------------------------------------------------------------
complianceActionsRouter.post(
  '/contracts/:contractId/supplier-audit',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(ComplianceSupplierAuditBodySchema, 'body'),
  initiateSupplierAudit,
);

// ------------------------------------------------------------
// POST /api/v1/compliance/contracts/:contractId/recommend-hold
// ------------------------------------------------------------
complianceActionsRouter.post(
  '/contracts/:contractId/recommend-hold',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(ComplianceRecommendHoldBodySchema, 'body'),
  recommendHold,
);

// ------------------------------------------------------------
// POST /api/v1/compliance/contracts/:contractId/recommend-termination
// ------------------------------------------------------------
complianceActionsRouter.post(
  '/contracts/:contractId/recommend-termination',
  authedWriteRateLimiter,
  authorise(['risk.acknowledge']),
  validate(ContractIdPersonaParamSchema, 'params'),
  validate(ComplianceRecommendTerminationBodySchema, 'body'),
  recommendTermination,
);

// ------------------------------------------------------------
// POST /api/v1/compliance/contracts/:contractId/icv-certificate
// Multipart/form-data. Multer must run BEFORE body validate() so req.body
// is populated with text fields from the multipart form.
// ------------------------------------------------------------
complianceActionsRouter.post(
  '/contracts/:contractId/icv-certificate',
  authedWriteRateLimiter,
  // Migration 200 added `contract.attachment.upload` granted to compliance_esg +
  // drafter + approver + legal_counsel + platform_admin + Super Admin. Use that
  // gate (not contract.edit) so compliance role can upload ICV certificates
  // without holding the broader contract.edit grant.
  authorise(['contract.attachment.upload']),
  validate(ContractIdPersonaParamSchema, 'params'),
  icvMulter.single('file'),
  validate(ComplianceIcvCertificateBodySchema, 'body'),
  uploadIcvCertificate,
);

export default complianceActionsRouter;
