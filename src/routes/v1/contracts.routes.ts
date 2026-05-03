/**
 * /api/v1/contracts routes — M1a Core CRUD & Lifecycle + M1b Payment Schedules & Exports.
 *
 * Permission codes (per api-contracts.json + db-design CMSW-2 + M1b CMW-2):
 *   - contract.read.all | contract.read.department | contract.read.own
 *     (any of) — list, getById, getTree, listVersions, listActivity, payment-schedules read, exports
 *   - contract.draft           — create, payment-schedules write (drafter own-draft branch)
 *   - contract.edit            — update, createVersion, payment-schedules write
 *   - contract.delete          — delete
 *   - contract.status.update   — updateStatus
 *   - contract.tag.manage      — setTags
 *   - contract.export          — PDF export, XLSX export (M1b — granted to drafter via CMW-2)
 *
 * Route ordering (W1 — qa-stage1-report critical):
 *   Express matches in declaration order. Literal-path routes MUST appear
 *   BEFORE any ':id'-prefixed routes that could match the same shape.
 *     1. GET /export.xlsx                  — M1b list-level literal — DECLARE FIRST
 *     2. GET /:id/payment-schedules         — M1b
 *     3. PUT /:id/payment-schedules         — M1b
 *     4. GET /:id/export.pdf                — M1b
 *     5. existing M1a /:id routes (list, get, update, delete, /status, /tree, /tags, /versions, /activity)
 *   If '/contracts/:id' was declared before '/contracts/export.xlsx', the
 *   request /contracts/export.xlsx would bind :id='export.xlsx' and 400 on
 *   PositiveBigIntSchema.
 *
 * Rate limits:
 *   - GETs:   authedReadRateLimiter (120/min/user)
 *   - Writes: authedWriteRateLimiter (60/min/user)
 *   - PDF/XLSX exports: exportRateLimiter (30/min/user) — Puppeteer/exceljs are heavy
 */
import { Router } from 'express';
import { contractsController } from '../../controllers/contracts.controller';
import { authenticate, authorise, authoriseAnyOf } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import { exportRateLimiter } from '../../middleware/export-rate-limit.middleware';
import {
  ContractActivityListQuerySchema,
  ContractIdParamSchema,
  ContractListQuerySchema,
  ContractVersionListQuerySchema,
  CreateContractDtoSchema,
  CreateContractVersionDtoSchema,
  SetContractTagsDtoSchema,
  UpdateContractDtoSchema,
  UpdateContractStatusDtoSchema,
} from '../../schemas/contracts.schemas';
import {
  ContractExportPdfQuerySchema,
  ContractExportXlsxQuerySchema,
  PaymentScheduleBulkReplaceSchema,
  PaymentScheduleListQuerySchema,
} from '../../schemas/payment-schedule.schemas';

const router = Router();

const READ_ANY = ['contract.read.all', 'contract.read.department', 'contract.read.own'] as const;

// All endpoints require authentication
router.use(authenticate);

// ============================================================
// M1b literal-path routes — MUST be declared BEFORE any :id-prefixed routes
// (W1 — Express matches in declaration order; '/contracts/:id' would
// otherwise bind :id='export.xlsx' for a request to /contracts/export.xlsx
// and produce 400 from PositiveBigIntSchema).
// ============================================================

// GET /api/v1/contracts/export.xlsx — list-level XLSX export (M1b S5)
router.get(
  '/export.xlsx',
  exportRateLimiter,
  authoriseAnyOf(READ_ANY),
  authorise(['contract.export']),
  validate(ContractExportXlsxQuerySchema, 'query'),
  contractsController.exportXlsx,
);

// ============================================================
// M1a / M1b collection-level routes
// ============================================================

// GET /api/v1/contracts — list
router.get(
  '/',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractListQuerySchema, 'query'),
  contractsController.list,
);

// POST /api/v1/contracts — create (S3)
router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['contract.draft']),
  validate(CreateContractDtoSchema, 'body'),
  contractsController.create,
);

// ============================================================
// M1b :id-prefixed routes
// ============================================================

// GET /api/v1/contracts/:id/payment-schedules — list milestones (M1b S2)
router.get(
  '/:id/payment-schedules',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  validate(PaymentScheduleListQuerySchema, 'query'),
  contractsController.listPaymentSchedules,
);

// PUT /api/v1/contracts/:id/payment-schedules — bulk replace milestones (M1b S3)
//   contract.edit (full editors) OR contract.draft (drafter on own-draft);
//   the fn_payment_schedule_create_bulk RLS policy enforces own-draft scope
//   for drafters. authoriseAnyOf grants the route gate either way.
router.put(
  '/:id/payment-schedules',
  authedWriteRateLimiter,
  authoriseAnyOf(['contract.edit', 'contract.draft']),
  validate(ContractIdParamSchema, 'params'),
  validate(PaymentScheduleBulkReplaceSchema, 'body'),
  contractsController.replacePaymentSchedules,
);

// GET /api/v1/contracts/:id/export.pdf — single-contract PDF export (M1b S4)
router.get(
  '/:id/export.pdf',
  exportRateLimiter,
  authoriseAnyOf(READ_ANY),
  authorise(['contract.export']),
  validate(ContractIdParamSchema, 'params'),
  validate(ContractExportPdfQuerySchema, 'query'),
  contractsController.exportPdf,
);

// ============================================================
// M1a :id-prefixed routes (declared after M1b literal /export.xlsx
// per W1; relative ordering among M1a routes preserved)
// ============================================================

// GET /api/v1/contracts/:id — get (S2 — 403/404 layered in controller)
router.get(
  '/:id',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  contractsController.getById,
);

// PUT /api/v1/contracts/:id — update (S4)
router.put(
  '/:id',
  authedWriteRateLimiter,
  authorise(['contract.edit']),
  validate(ContractIdParamSchema, 'params'),
  validate(UpdateContractDtoSchema, 'body'),
  contractsController.update,
);

// DELETE /api/v1/contracts/:id — soft delete (S5)
router.delete(
  '/:id',
  authedWriteRateLimiter,
  authorise(['contract.delete']),
  validate(ContractIdParamSchema, 'params'),
  contractsController.delete,
);

// PATCH /api/v1/contracts/:id/status — status update (S6)
router.patch(
  '/:id/status',
  authedWriteRateLimiter,
  authorise(['contract.status.update']),
  validate(ContractIdParamSchema, 'params'),
  validate(UpdateContractStatusDtoSchema, 'body'),
  contractsController.updateStatus,
);

// GET /api/v1/contracts/:id/tree — parent/child timeline (S7)
router.get(
  '/:id/tree',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  contractsController.getTree,
);

// PUT /api/v1/contracts/:id/tags — replace tag set (S8)
router.put(
  '/:id/tags',
  authedWriteRateLimiter,
  authorise(['contract.tag.manage']),
  validate(ContractIdParamSchema, 'params'),
  validate(SetContractTagsDtoSchema, 'body'),
  contractsController.setTags,
);

// GET /api/v1/contracts/:id/versions — list versions (S9)
router.get(
  '/:id/versions',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  validate(ContractVersionListQuerySchema, 'query'),
  contractsController.listVersions,
);

// POST /api/v1/contracts/:id/versions — create version snapshot (S10)
router.post(
  '/:id/versions',
  authedWriteRateLimiter,
  authorise(['contract.edit']),
  validate(ContractIdParamSchema, 'params'),
  validate(CreateContractVersionDtoSchema, 'body'),
  contractsController.createVersion,
);

// GET /api/v1/contracts/:id/activity — activity timeline (S11)
router.get(
  '/:id/activity',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  validate(ContractActivityListQuerySchema, 'query'),
  contractsController.listActivity,
);

export default router;
