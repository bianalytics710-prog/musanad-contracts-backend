/**
 * Import Batch controller — M1c Bulk & Manual Import (S1–S4).
 *
 * 4 endpoints, each a thin HTTP layer over a single fn_ call:
 *
 *   POST   /api/v1/import-batches        → fn_import_batch_create   (S1)
 *   PATCH  /api/v1/import-batches/:id    → fn_import_batch_update   (S2)
 *   GET    /api/v1/import-batches        → fn_import_batch_list     (S3)
 *   GET    /api/v1/import-batches/:id    → fn_import_batch_get_by_id (S4)
 *
 * Permission gating (BE middleware) AND fn_/RLS narrowing (defense in depth):
 *   - import.run                         POST /import-batches
 *   - import.run OR import.review        PATCH /import-batches/:id (initiator-self
 *                                          enforced inside fn_)
 *   - import.run OR import.review        GET  /import-batches (role narrowing
 *                                          inside fn_ — drafter sees own only)
 *   - import.run OR import.review        GET  /import-batches/:id
 *
 * 404 mapping: fn_import_batch_get_by_id returns NULL for both "row absent"
 * AND "RLS hides the row from caller". Per Design Note D7 (matches M1a
 * fn_contract_get_by_id behaviour), we return 404 for both — avoids leaking
 * existence to unauthorised callers.
 *
 * fn_import_batch_update structured-raise mappings (translatePgError):
 *   - 404:Import batch not found     → 404 NOT_FOUND
 *   - permission:Forbidden           → 400 (translator routes 'permission' as
 *                                       a generic field). For M1c we want 403
 *                                       — ForbiddenError raised explicitly
 *                                       below isn't applicable here; the BE
 *                                       middleware blocks 403 cases upfront.
 *                                       The fn_'s permission raise is a
 *                                       defensive defence-in-depth path that
 *                                       only fires when middleware was
 *                                       bypassed (impossible via routes).
 *   - status:Invalid status transition → 409 CONFLICT (CONFLICT_FIELD_PREFIXES
 *                                       — see translate-pg-error update below).
 *   - <counter>:Counter underflow    → 400 VALIDATION (default field branch)
 *   - counters:Counter overflow vs totalFiles → 400 VALIDATION
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError, NotFoundError } from '../utils/errors.util';
import type {
  CreateImportBatchInferred,
  UpdateImportBatchInferred,
  ImportBatchListQueryInferred,
  ImportBatchIdParamInferred,
} from '../schemas/import-batch.schemas';
import type {
  ImportBatch,
  ImportBatchListResponse,
} from '../types/import-batch.types';

/** Standard error-type label for log lines. */
const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const importBatchController = {
  /**
   * POST /api/v1/import-batches → fn_import_batch_create (S1).
   *
   * fn_ enforces: import.run permission, totalFiles >= 1, config.statusMode
   * enum, config.contractType enum membership. RLS WITH CHECK pins
   * initiated_by to current_user (no impersonation).
   */
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'importBatch.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as CreateImportBatchInferred;
      const result = await db.callFunction<ImportBatch>(
        'fn_import_batch_create',
        [body, req.user!.id],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'importBatch.create',
          userId: req.user?.id,
          newBatchId: result?.id,
          totalFiles: result?.totalFiles,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'importBatch.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * PATCH /api/v1/import-batches/:id → fn_import_batch_update (S2).
   *
   * SELECT FOR UPDATE inside the fn_ serialises concurrent counter writes
   * (Codex BE-001). Counter underflow / overflow / status-transition errors
   * surface as field-prefixed RAISE EXCEPTION strings; translatePgError
   * maps them per the prefix table.
   *
   * Per AC-S2-06: 404 when id does not exist OR is_active = false. The fn_
   * raises '404:Import batch not found' which the translator maps to 404.
   * We add a defensive null-check fallback in case the fn_ ever returns
   * NULL silently (matches M1a contract.update pattern).
   */
  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'importBatch.update', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ImportBatchIdParamInferred;
      const body = req.body as UpdateImportBatchInferred;
      const result = await db.callFunction<ImportBatch | null>(
        'fn_import_batch_update',
        [
          id,
          req.user!.id,
          body.status ?? null,
          body.autoSavedDelta ?? 0,
          body.reviewQueueDelta ?? 0,
          body.manualEntryDelta ?? 0,
          body.duplicatesSkippedDelta ?? 0,
          body.erroredDelta ?? 0,
        ],
        { actorId: req.user!.id },
      );
      if (!result) {
        throw new NotFoundError('Import batch not found', { id: 'Import batch not found' });
      }
      req.logger.info(
        {
          action: 'importBatch.update',
          userId: req.user?.id,
          targetId: id,
          newStatus: result.status,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'importBatch.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/import-batches → fn_import_batch_list (S3).
   *
   * Role narrowing inside the fn_ (v_role_can_see_all gate) excludes
   * contract_drafter from the see-all list — drafter sees own batches only
   * (AC-S3-07). RLS import_batch_select_role_aware mirrors this for
   * defense in depth.
   *
   * AC-S3-02: when total = 0 → totalPages = 0, data = [] (M1a 007 patch
   * precedent — already implemented inside fn_).
   */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'importBatch.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ImportBatchListQueryInferred;
      const result = await db.callFunction<ImportBatchListResponse>(
        'fn_import_batch_list',
        [
          q.page ?? 1,
          q.limit ?? 20,
          q.status ?? null,
          q.initiatedBy ?? null,
          req.user!.id,
          req.user!.role,
        ],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'importBatch.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'importBatch.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/import-batches/:id → fn_import_batch_get_by_id (S4).
   *
   * Returns 404 when:
   *   - row does not exist (AC-S4-02)
   *   - row is_active = false (AC-S4-02)
   *   - row exists but RLS hides it from caller (AC-S4-03 — Design Note D7
   *     matches M1a fn_contract_get_by_id pattern: returns 404, not 403, to
   *     avoid leaking existence)
   *
   * AC-S4-04: initiatedBy is a UserRef hydrated by fn_user_get_by_id inside
   * the fn_ (no BE join required).
   */
  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'importBatch.getById', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ImportBatchIdParamInferred;
      const result = await db.callFunction<ImportBatch | null>(
        'fn_import_batch_get_by_id',
        [id, req.user!.id],
        { actorId: req.user!.id },
      );
      if (!result) {
        throw new NotFoundError('Import batch not found', { id: 'Import batch not found' });
      }
      req.logger.info(
        {
          action: 'importBatch.getById',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'importBatch.getById',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};
