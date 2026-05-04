/**
 * /api/v1/import-batches routes — M1c Bulk & Manual Import (S1–S4).
 *
 * Permission codes (per api-contracts.json — M1c migration 018 grants):
 *   - import.run     → create / update (counters + lifecycle status)
 *   - import.review  → list / getById (read across users)
 *   - anyOf(import.run, import.review) — list + getById since a contract_drafter
 *     who initiated a batch (has import.run) is naturally narrowed to own
 *     batches by RLS + fn_ v_role_can_see_all gate.
 *
 * Route ordering (W1 from M1b — Express matches in declaration order):
 *   1. POST   /                 — collection write
 *   2. GET    /                 — collection read (literal — must precede /:id)
 *   3. GET    /:id              — drill-down read
 *   4. PATCH  /:id              — single-record write
 *
 * Rate limits (M0 + M1b convention):
 *   - GETs:       authedReadRateLimiter (120/min/user)
 *   - Writes:     authedWriteRateLimiter (60/min/user)
 */
import { Router } from 'express';
import { importBatchController } from '../../controllers/import-batch.controller';
import {
  authenticate,
  authorise,
  authoriseAnyOf,
} from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  CreateImportBatchSchema,
  UpdateImportBatchSchema,
  ImportBatchListQuerySchema,
  ImportBatchIdParamSchema,
} from '../../schemas/import-batch.schemas';

const router = Router();

const IMPORT_VIEW_OR_RUN = ['import.review', 'import.run'] as const;

// All endpoints require authentication
router.use(authenticate);

// ---------------------------------------------------------------
// POST /api/v1/import-batches — create batch (S1 / fn_import_batch_create)
//   AC-S1-04 — caller must hold import.run permission
// ---------------------------------------------------------------
router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['import.run']),
  validate(CreateImportBatchSchema, 'body'),
  importBatchController.create,
);

// ---------------------------------------------------------------
// GET /api/v1/import-batches — list batches (S3 / fn_import_batch_list)
//   AC-S3-06 — caller must hold import.review OR import.run.
//   contract_drafter (with import.run) is narrowed to own batches via
//   RLS import_batch_select_role_aware + fn_ v_role_can_see_all gate
//   (defense in depth — AC-S3-07).
// ---------------------------------------------------------------
router.get(
  '/',
  authedReadRateLimiter,
  authoriseAnyOf(IMPORT_VIEW_OR_RUN),
  validate(ImportBatchListQuerySchema, 'query'),
  importBatchController.list,
);

// ---------------------------------------------------------------
// GET /api/v1/import-batches/:id — get by id (S4 / fn_import_batch_get_by_id)
//   AC-S4-03 — caller must be platform_admin / legal_counsel OR initiator.
//   import.review or import.run gates the BE; RLS narrows the data
//   visibility (returns NULL → 404 for not-authorised, matching M1a
//   precedent — Design Note D7).
// ---------------------------------------------------------------
router.get(
  '/:id',
  authedReadRateLimiter,
  authoriseAnyOf(IMPORT_VIEW_OR_RUN),
  validate(ImportBatchIdParamSchema, 'params'),
  importBatchController.getById,
);

// ---------------------------------------------------------------
// PATCH /api/v1/import-batches/:id — update batch (S2 / fn_import_batch_update)
//   AC-S2-07 — caller must hold import.run OR be the initiator. import.review
//   is sufficient for read; the fn_ enforces initiator-self at write time
//   when the caller lacks import.run. Gating with anyOf(import.run,
//   import.review) here lets initiator-self pass the BE middleware; the
//   fn_ raises 'permission:Forbidden' (translatePgError → 403) for
//   non-initiator non-import.run callers.
// ---------------------------------------------------------------
router.patch(
  '/:id',
  authedWriteRateLimiter,
  authoriseAnyOf(IMPORT_VIEW_OR_RUN),
  validate(ImportBatchIdParamSchema, 'params'),
  validate(UpdateImportBatchSchema, 'body'),
  importBatchController.update,
);

export default router;
