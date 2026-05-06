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
import multer from 'multer';
import { contractsController } from '../../controllers/contracts.controller';
import { approvalController } from '../../controllers/approval.controller';
import { signatureController } from '../../controllers/signature.controller';
import { contractAttachmentController } from '../../controllers/contract-attachment.controller';
import { contractCommentController } from '../../controllers/contract-comment.controller';
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
  UpdateContractStatusUserDtoSchema,
} from '../../schemas/contracts.schemas';
import {
  ContractExportPdfQuerySchema,
  ContractExportXlsxQuerySchema,
  PaymentScheduleBulkReplaceSchema,
  PaymentScheduleListQuerySchema,
} from '../../schemas/payment-schedule.schemas';
import {
  RouteInitPreviewSchema,
  SubmitForApprovalSchema,
} from '../../schemas/approval.schemas';
import {
  SendForSignatureDtoSchema,
  SignaturePartyCreateBulkDtoSchema,
} from '../../schemas/signature.schemas';

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
// M2 :id-prefixed sub-routes (W1 — POST literals before bare :id):
//   POST /:id/approval-chain/preview   — S6 (BEFORE the GET /:id/approval-chain literal)
//   POST /:id/submit-for-approval      — S7
//   GET  /:id/approval-chain           — S10 (most-recent chain)
// ============================================================

// POST /api/v1/contracts/:id/approval-chain/preview — S6
//   approval.matrix.read covers preview + chain visibility (Q3-OI-F kept POST + body
//   to keep commercial value out of access logs).
router.post(
  '/:id/approval-chain/preview',
  authedWriteRateLimiter,
  authorise(['approval.matrix.read']),
  validate(ContractIdParamSchema, 'params'),
  validate(RouteInitPreviewSchema, 'body'),
  approvalController.routeInitPreview,
);

// POST /api/v1/contracts/:id/submit-for-approval — S7
router.post(
  '/:id/submit-for-approval',
  authedWriteRateLimiter,
  authorise(['approval.submit_for_review']),
  validate(ContractIdParamSchema, 'params'),
  validate(SubmitForApprovalSchema, 'body'),
  approvalController.submitForApproval,
);

// GET /api/v1/contracts/:id/approval-chain — S10
//   Standard contract-read narrowing — RLS auto-narrows via parent contract.
router.get(
  '/:id/approval-chain',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  approvalController.chainGetByContract,
);

// ============================================================
// M3 :id-prefixed sub-routes (W1 — POST literals before bare :id):
//   POST /:id/signature-parties     — S1 (bulk-create roster)
//   POST /:id/send-for-signature    — S2 (issue invitations + status flip)
//   GET  /:id/signatures            — S6 (per-contract signature progress)
// ============================================================

// POST /api/v1/contracts/:id/signature-parties — S1
router.post(
  '/:id/signature-parties',
  authedWriteRateLimiter,
  authorise(['signature.send']),
  validate(ContractIdParamSchema, 'params'),
  validate(SignaturePartyCreateBulkDtoSchema, 'body'),
  signatureController.createPartiesBulk,
);

// POST /api/v1/contracts/:id/send-for-signature — S2
router.post(
  '/:id/send-for-signature',
  authedWriteRateLimiter,
  authorise(['signature.send']),
  validate(ContractIdParamSchema, 'params'),
  validate(SendForSignatureDtoSchema, 'body'),
  signatureController.sendForSignature,
);

// GET /api/v1/contracts/:id/signatures — S6
//   Permission: contract.read.* (any) — caller is a contract participant or
//   privileged role. Email masking is role-aware inside the fn_.
router.get(
  '/:id/signatures',
  authedReadRateLimiter,
  authoriseAnyOf([...READ_ANY, 'signature.read.all']),
  validate(ContractIdParamSchema, 'params'),
  signatureController.listForContract,
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

// PATCH /api/v1/contracts/:id/status — status update (M1a S6, extended by M2 / AE-2)
//
// M2 / AE-2: replaces fn_contract_status_update with fn_contract_status_update_user
// (INVOKER, drafter narrow transitions). Wire signature unchanged. Per-transition
// permission gates are enforced inside the fn_; the route-level authorise()
// keeps the M1a contract.status.update grant as a baseline so the BE middleware
// can produce a clear 403 for callers without ANY status-mutation grant. Drafters
// + admins must additionally hold approval.submit_for_review (for in_review
// transitions) or contract.delete / contract.edit per-transition; the fn_ raises
// 42501 → 403 with a precise message when the per-transition grant is missing.
router.patch(
  '/:id/status',
  authedWriteRateLimiter,
  authoriseAnyOf([
    'contract.status.update',
    'approval.submit_for_review',
    'contract.edit',
    'contract.delete',
    'contract.draft',
  ]),
  validate(ContractIdParamSchema, 'params'),
  validate(UpdateContractStatusUserDtoSchema, 'body'),
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

// ============================================================
// Contract attachments — Supabase-backed file storage
// ============================================================
//
// Bytes flow through the BE → Supabase Storage using the service-role key
// (BE-mediated upload). The FE never sees Supabase credentials. Permission
// codes:
//   contract.attachment.read   — list + download URL
//   contract.attachment.write  — upload
//   contract.attachment.delete — soft delete + storage cleanup

const uploadMulter = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB hard cap; matches CHECK on contract_attachment.size_bytes
});

router.get(
  '/:id/attachments',
  authedReadRateLimiter,
  authoriseAnyOf(['contract.attachment.read', ...READ_ANY]),
  validate(ContractIdParamSchema, 'params'),
  contractAttachmentController.list,
);

router.post(
  '/:id/attachments',
  authedWriteRateLimiter,
  authorise(['contract.attachment.write']),
  validate(ContractIdParamSchema, 'params'),
  uploadMulter.single('file'),
  contractAttachmentController.upload,
);

router.get(
  '/:id/attachments/:fileId/url',
  authedReadRateLimiter,
  authoriseAnyOf(['contract.attachment.read', ...READ_ANY]),
  // Validation done inline in the controller (validate() strips unknown
  // params per the Zod schema, which would drop :fileId).
  contractAttachmentController.getDownloadUrl,
);

router.delete(
  '/:id/attachments/:fileId',
  authedWriteRateLimiter,
  authorise(['contract.attachment.delete']),
  contractAttachmentController.remove,
);

// ============================================================================
// R4 audit gap 8.2.1 — Contract comments tab.
// Anyone who can read the contract can read + write comments. Resolve and
// delete are also broadly available (the fn_'s gate creator-only on delete).
// ============================================================================
router.get(
  '/:id/comments',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  contractCommentController.list,
);

router.post(
  '/:id/comments',
  authedWriteRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  contractCommentController.create,
);

router.post(
  '/:id/comments/:commentId/resolve',
  authedWriteRateLimiter,
  authoriseAnyOf(READ_ANY),
  // Inline-validate :commentId in the controller; validate() would strip it.
  contractCommentController.resolve,
);

router.delete(
  '/:id/comments/:commentId',
  authedWriteRateLimiter,
  authoriseAnyOf(READ_ANY),
  contractCommentController.remove,
);

export default router;
