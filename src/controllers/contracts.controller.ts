/**
 * Contracts controller — M1a Core CRUD & Lifecycle.
 *
 * 11 endpoints, each a thin HTTP layer over a single fn_ call:
 *
 *   GET    /api/v1/contracts                 → fn_contract_list
 *   GET    /api/v1/contracts/:id             → fn_contract_get_by_id
 *   POST   /api/v1/contracts                 → fn_contract_create
 *   PUT    /api/v1/contracts/:id             → fn_contract_update
 *   DELETE /api/v1/contracts/:id             → fn_contract_delete
 *   PATCH  /api/v1/contracts/:id/status      → fn_contract_status_update
 *   GET    /api/v1/contracts/:id/tree        → fn_contract_get_tree
 *   PUT    /api/v1/contracts/:id/tags        → fn_contract_set_tags
 *   GET    /api/v1/contracts/:id/versions    → fn_contract_version_list
 *   POST   /api/v1/contracts/:id/versions    → fn_contract_version_create
 *   GET    /api/v1/contracts/:id/activity    → fn_contract_activity_list
 *
 * AC-S2-03 403-vs-404 layering (F1 from qa-stage2-report.json):
 *   fn_contract_get_by_id returns NULL for both "row absent" and "RLS hides
 *   the row". The controller distinguishes the two by issuing an existence
 *   check that bypasses RLS (db.checkActiveRowExists). If the row physically
 *   exists AND the caller has any contract.read.* permission, return 403;
 *   if the row doesn't exist, return 404.
 *
 * Sensitive logging:
 *   bodyEn / bodyAr never appear in any req.logger call. Pino redaction
 *   (logger.util.ts SENSITIVE_PATHS includes *.bodyEn / *.bodyAr / snake-case
 *   variants) is the safety net. We deliberately log only action / userId /
 *   targetId / statusCode / duration — never req.body or response payloads.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError, ForbiddenError, NotFoundError } from '../utils/errors.util';
import type {
  ContractIdParamInferred,
  ContractListQueryInferred,
  ContractVersionListQueryInferred,
  ContractActivityListQueryInferred,
  CreateContractDtoInferred,
  UpdateContractDtoInferred,
  UpdateContractStatusUserDtoInferred,
  SetContractTagsDtoInferred,
  CreateContractVersionDtoInferred,
} from '../schemas/contracts.schemas';
import type {
  ContractExportPdfQueryInferred,
  ContractExportXlsxQueryInferred,
  PaymentScheduleBulkReplaceInferred,
  PaymentScheduleListQueryInferred,
} from '../schemas/payment-schedule.schemas';
import type {
  Contract,
  ContractListResponse,
  ContractTreeResponse,
  ContractVersionListResponse,
  ContractActivityListResponse,
  ContractActivityCreated,
  ContractVersionCreated,
  DeleteContractResponse,
  SetContractTagsResponse,
} from '../types/contracts.types';
import type { UpdateContractStatusUserResponse } from '../types/approval.types';
import type {
  AuditLogRecordResult,
  ContractExportPdfResponse,
  ContractExportXlsxResponse,
  PaymentScheduleBulkReplaceResponse,
  PaymentScheduleListResponse,
} from '../types/payment-schedule.types';
import { renderContractPdf } from '../services/export/contract-pdf.service';
import { renderContractXlsx } from '../services/export/contract-xlsx.service';
import * as redlineImport from '../services/contract-redline-import.service';

const READ_PERMISSION_CODES: ReadonlyArray<string> = [
  'contract.read.all',
  'contract.read.department',
  'contract.read.own',
];

const hasAnyReadPermission = (perms: ReadonlyArray<string>): boolean =>
  perms.some((p) => READ_PERMISSION_CODES.includes(p));

/** Standard error-type label for log lines. */
const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const contractsController = {
  /**
   * GET /api/v1/contracts → fn_contract_list
   *
   * Pagination + role-aware filter + status/type/counterparty/date filters
   * + tag AND-semantics + ILIKE search. body_en/body_ar excluded from
   * response (AC-S1-08).
   */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ContractListQueryInferred;
      // M1c: fn_contract_list signature widened from 15 -> 18 params
      // (db-design.md §4.3 / migration 017). Three new optional filter
      // params appended at the end (default NULL). Existing positional
      // call site preserved + extended additively.
      const result = await db.callFunction<ContractListResponse>(
        'fn_contract_list',
        [
          q.page ?? 1,
          q.limit ?? 20,
          q.status ?? null,
          q.contractType ?? null,
          q.counterpartyId ?? null,
          q.draftedBy ?? null,
          q.approvedBy ?? null,
          q.startDateFrom ?? null,
          q.startDateTo ?? null,
          q.endDateFrom ?? null,
          q.endDateTo ?? null,
          q.tags ?? null,
          q.search ?? null,
          req.user!.id,
          req.user!.role,
          // ---- M1c additive params (AE-1) ----
          q.importBatchId ?? null,
          q.importConfidenceMin ?? null,
          q.importConfidenceMax ?? null,
          // ---- R5+ Lovable parity filters ----
          q.language ?? null,
          q.governingLaw ?? null,
          q.sort ?? null,
          // ---- Mig 562 — risk bucket filter ----
          q.risk ?? null,
        ],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.list',
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
          action: 'contract.list',
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
   * GET /api/v1/contracts/:id → fn_contract_get_by_id
   *
   * AC-S2-02 / AC-S2-03 layering:
   *   - Row exists + visible → 200
   *   - Row missing or is_active=false → 404 (AC-S2-02)
   *   - Row exists, RLS hides it, caller has any contract.read.* → 403 (AC-S2-03)
   */
  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.getById', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;

      const result = await db.callFunction<Contract | null>(
        'fn_contract_get_by_id',
        [id, req.user!.id, req.user!.role],
        { actorId: req.user!.id },
      );

      if (!result) {
        // AC-S2-03 branch — distinguish 403 from 404 via RLS-bypass existence check.
        const exists = await db.checkActiveRowExists('contract', id);
        if (exists && hasAnyReadPermission(req.user!.permissions)) {
          throw new ForbiddenError('Forbidden');
        }
        throw new NotFoundError('Contract not found', { id: 'Contract not found' });
      }

      req.logger.info(
        {
          action: 'contract.getById',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      // Note: bodyEn / bodyAr present in `result` but pino redaction strips
      // them from any log line that incidentally references the object.
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.getById',
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
   * POST /api/v1/contracts → fn_contract_create
   *
   * Status forced to 'draft' by fn_; auto-generates contract_number; emits
   * 'created' contract_activity via trigger. body fields are pino-redacted
   * on inbound logging.
   */
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.create', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const body = req.body as CreateContractDtoInferred;
      const result = await db.callFunction<Contract>('fn_contract_create', [body, req.user!.id], {
        actorId: req.user!.id,
      });
      req.logger.info(
        {
          action: 'contract.create',
          userId: req.user?.id,
          newContractId: result?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.create',
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
   * PUT /api/v1/contracts/:id → fn_contract_update
   *
   * Partial COALESCE update. Zod (.strict + status check) rejects status
   * payload at the boundary; fn_contract_update raises AC-S4-04 if it
   * somehow gets through. Body changes auto-create a contract_version row.
   */
  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.update', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as UpdateContractDtoInferred;
      const result = await db.callFunction<Contract | null>(
        'fn_contract_update',
        [id, body, req.user!.id],
        { actorId: req.user!.id },
      );
      if (!result) {
        // fn_contract_update raises 'id:Contract not found' which the
        // translator already maps to 404. This is a defensive fallback.
        throw new NotFoundError('Contract not found', { id: 'Contract not found' });
      }
      req.logger.info(
        {
          action: 'contract.update',
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
          action: 'contract.update',
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
   * DELETE /api/v1/contracts/:id → fn_contract_delete (SECURITY DEFINER)
   *
   * Soft-delete cascading to contract_tag. Cannot delete a contract with
   * active children (AC-S5-04 → 409). Atomic SELECT FOR UPDATE + GUC-gated
   * is_active flip (Codex G2 TOCTOU defence).
   */
  async delete(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.delete', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await db.callFunction<DeleteContractResponse>(
        'fn_contract_delete',
        [id, req.user!.id],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.delete',
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
          action: 'contract.delete',
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
   * PATCH /api/v1/contracts/:id/status → fn_contract_status_update_user (M2 / AE-2).
   *
   * Drafter / admin narrow transitions only. fn_contract_status_update_user is
   * INVOKER + per-transition permission-gated + FOR UPDATE on the contract row.
   * The M1a placeholder fn_contract_status_update was DROPPED in migration 026;
   * this endpoint now delegates to the _user variant.
   *
   * In_approval terminal transitions (in_approval → approved | rejected |
   * resubmission_requested) are REJECTED here with 409 (M2-NEW-1) — those flow
   * via fn_approval_decide invoked from POST /api/v1/approvals/:stepId/decide.
   *
   * The special case `in_review → in_approval` atomically delegates to
   * fn_approval_route_init inside the same DB transaction; the response
   * includes a routeInit nested object on that branch only.
   */
  async updateStatus(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.updateStatus', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as UpdateContractStatusUserDtoInferred;
      const result = await db.callFunction<UpdateContractStatusUserResponse>(
        'fn_contract_status_update_user',
        [id, body.newStatus, req.user!.id, body.reason ?? null],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.updateStatus',
          userId: req.user?.id,
          targetId: id,
          fromStatus: result?.fromStatus,
          toStatus: result?.toStatus,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.updateStatus',
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
   * GET /api/v1/contracts/:id/tree → fn_contract_get_tree
   *
   * Recursive parent/child timeline (depth cap 20, role-aware filter).
   */
  async getTree(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.getTree', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await db.callFunction<ContractTreeResponse>(
        'fn_contract_get_tree',
        [id, req.user!.id, req.user!.role],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.getTree',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
          treeSize: result?.tree?.length ?? 0,
          truncated: result?.truncated ?? false,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.getTree',
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
   * PUT /api/v1/contracts/:id/tags → fn_contract_set_tags
   *
   * Atomic add/remove diff with single statement-level activity row
   * (metadata={added, removed}). Empty array clears all tags.
   */
  async setTags(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.setTags', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as SetContractTagsDtoInferred;
      const result = await db.callFunction<SetContractTagsResponse>(
        'fn_contract_set_tags',
        [id, body.tags, req.user!.id],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.setTags',
          userId: req.user?.id,
          targetId: id,
          tagCount: result?.tags?.length ?? 0,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.setTags',
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
   * GET /api/v1/contracts/:id/versions → fn_contract_version_list
   *
   * Newest-first paginated version list. body fields surface in payload
   * but are pino-redacted in any log line.
   */
  async listVersions(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.listVersions', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const q = req.query as unknown as ContractVersionListQueryInferred;
      const result = await db.callFunction<ContractVersionListResponse>(
        'fn_contract_version_list',
        [id, q.page ?? 1, q.limit ?? 20, req.user!.id, req.user!.role],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.listVersions',
          userId: req.user?.id,
          targetId: id,
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
          action: 'contract.listVersions',
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
   * POST /api/v1/contracts/:id/versions → fn_contract_version_create
   *
   * Atomic version-number increment via SELECT FOR UPDATE on parent. Updates
   * contract.body_en/body_ar to match the new snapshot. Auto-emits
   * 'version_created' contract_activity (metadata={ versionNumber }).
   */
  async createVersion(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'contract.createVersion',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as CreateContractVersionDtoInferred;
      const result = await db.callFunction<ContractVersionCreated>(
        'fn_contract_version_create',
        [id, body, req.user!.id],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.createVersion',
          userId: req.user?.id,
          targetId: id,
          newVersionNumber: result?.versionNumber,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.createVersion',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  // ── Counterparty redline upload + diff (Scenario 2, mig 710) ──────────────

  /** POST /:id/redline-imports — upload the counterparty's returned file, diff it. */
  async redlineImportUpload(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const file = (req as Request & { file?: Express.Multer.File }).file;
      if (!file) {
        res.status(400).json({ error: { code: 'VALIDATION_ERROR', message: 'No file uploaded (field "file").' } });
        return;
      }
      const result = await redlineImport.importRedline({
        actorId: req.user!.id,
        role: req.user!.role,
        contractId: id,
        filename: file.originalname,
        mime: file.mimetype,
        buffer: file.buffer,
      });
      req.logger.info(
        { action: 'contract.redlineImport.upload', userId: req.user?.id, targetId: id, duration: Date.now() - start, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        { action: 'contract.redlineImport.upload', userId: req.user?.id, errorType: errorType(error) },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /:id/redline-imports — list imports for a contract. */
  async redlineImportList(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await redlineImport.listImports(req.user!.id, id);
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        { action: 'contract.redlineImport.list', userId: req.user?.id, errorType: errorType(error) },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /:id/redline-imports/:importId — full import + changes. */
  async redlineImportGet(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const importId = Number((req.params as { importId: string }).importId);
      const result = await redlineImport.getImport(req.user!.id, importId);
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        { action: 'contract.redlineImport.get', userId: req.user?.id, errorType: errorType(error) },
        'Controller error',
      );
      next(error);
    }
  },

  /** PATCH /:id/redline-imports/:importId/changes/:changeId — accept/reject. */
  async redlineChangeDecide(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const changeId = Number((req.params as { changeId: string }).changeId);
      const decision = String((req.body as { decision?: string }).decision ?? '');
      const result = await redlineImport.decideChange(req.user!.id, changeId, decision);
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        { action: 'contract.redlineImport.decide', userId: req.user?.id, errorType: errorType(error) },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /:id/redline-imports/:importId/apply — accepted changes → new version. */
  async redlineImportApply(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const importId = Number((req.params as { importId: string }).importId);
      const result = await redlineImport.applyImport({
        actorId: req.user!.id,
        role: req.user!.role,
        importId,
      });
      req.logger.info(
        { action: 'contract.redlineImport.apply', userId: req.user?.id, importId, newVersion: result.versionNumber, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        { action: 'contract.redlineImport.apply', userId: req.user?.id, errorType: errorType(error) },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/contracts/:id/activity → fn_contract_activity_list
   *
   * Newest-first activity timeline. actor enriched as { id, firstName,
   * lastName } | null when underlying user has been soft-deleted.
   */
  async listActivity(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.listActivity', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const q = req.query as unknown as ContractActivityListQueryInferred;
      const result = await db.callFunction<ContractActivityListResponse>(
        'fn_contract_activity_list',
        [id, q.page ?? 1, q.limit ?? 50, q.activityType ?? null, req.user!.id, req.user!.role],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'contract.listActivity',
          userId: req.user?.id,
          targetId: id,
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
          action: 'contract.listActivity',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  // ============================================================
  // M1b — Compose Wizard, Payment Schedules & Exports
  // ============================================================

  /**
   * GET /api/v1/contracts/:id/payment-schedules → fn_payment_schedule_list (S2)
   *
   * Returns the active milestone schedule for a contract, ordered by due_date
   * ASC NULLS LAST then id ASC. Not paginated. Optional ?status= filter.
   *
   * 404 mapping: fn_payment_schedule_list returns NULL when the parent
   * contract is invisible (RLS) or soft-deleted — controller maps to 404.
   */
  async listPaymentSchedules(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'paymentSchedule.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const q = req.query as unknown as PaymentScheduleListQueryInferred;
      const result = await db.callFunction<PaymentScheduleListResponse | null>(
        'fn_payment_schedule_list',
        [id, req.user!.id, req.user!.role, q.status ?? null],
        { actorId: req.user!.id },
      );
      if (!result) {
        throw new NotFoundError('Contract not found', { id: 'Contract not found' });
      }
      req.logger.info(
        {
          action: 'paymentSchedule.list',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
          resultCount: result.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'paymentSchedule.list',
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
   * PUT /api/v1/contracts/:id/payment-schedules → fn_payment_schedule_create_bulk (S3)
   *
   * Atomic bulk replace. Soft-deletes existing active rows then inserts the
   * new set in a single transaction. p_replace_existing is hardcoded to TRUE
   * regardless of body value (AC-S3-01). SELECT FOR UPDATE on parent contract
   * head row inside the fn_ provides AC-S3-11 serialisation (Codex BE-001).
   *
   * fn_ raises 'id:Contract not found' when contract missing/inactive — the
   * error translator maps this to 404 via NOT_FOUND_FIELD_PREFIXES.
   */
  async replacePaymentSchedules(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'paymentSchedule.replace',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as PaymentScheduleBulkReplaceInferred;
      const result = await db.callFunction<PaymentScheduleBulkReplaceResponse>(
        'fn_payment_schedule_create_bulk',
        [id, body.rows, true /* AC-S3-01: replace-by-default */, req.user!.id],
        { actorId: req.user!.id },
      );
      req.logger.info(
        {
          action: 'paymentSchedule.replace',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
          inserted: result?.inserted ?? 0,
          softDeleted: result?.softDeleted ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'paymentSchedule.replace',
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
   * GET /api/v1/contracts/:id/export.pdf → fn_contract_export_pdf (S4)
   *
   * Single-contract PDF export. fn_contract_export_pdf both prepares the
   * data AND emits a 'exported' contract_activity row inside the same
   * transaction (AC-S4-06). Controller hands the JSONB to the Puppeteer
   * renderer and pipes binary back.
   *
   * NULL fn_ return → 404 (contract missing or RLS-hidden — AC-S4-03).
   * body_en / body_ar reach the renderer in the JSONB payload but pino
   * redaction (logger.util.ts) strips them from any log line that
   * incidentally references the object (AC-S4-08).
   */
  async exportPdf(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'contract.exportPdf',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const q = req.query as unknown as ContractExportPdfQueryInferred;
      const data = await db.callFunction<ContractExportPdfResponse | null>(
        'fn_contract_export_pdf',
        [
          id,
          req.user!.id,
          req.user!.role,
          q.language ?? 'bilingual',
          q.includeAttachments === true,
        ],
        { actorId: req.user!.id },
      );
      if (!data) {
        throw new NotFoundError('Contract not found', { id: 'Contract not found' });
      }

      // Codex BE-M1b-004 fix: render FIRST, then emit activity, then send.
      // Migration 015 stripped the activity-emit from fn_contract_export_pdf,
      // so the controller is now the sole source of the 'exported' activity
      // row. We emit BEFORE res.send (but AFTER the buffer is materialised in
      // memory) so the activity row's commit synchronises with the response —
      // if Puppeteer throws, the catch block runs and no activity row is
      // ever written. A failed activity emit is non-fatal once the buffer
      // exists; we warn-log and serve the file.
      const pdfBuffer = await renderContractPdf(data);

      try {
        const lang = q.language ?? 'bilingual';
        await db.callFunction<ContractActivityCreated>(
          'fn_contract_activity_create',
          [
            id,
            'exported',
            req.user!.id,
            `Exported contract to PDF (language=${lang})`,
            null,
            { format: 'pdf', language: lang, includeAttachments: q.includeAttachments === true },
          ],
          { actorId: req.user!.id },
        );
      } catch (activityErr) {
        req.logger.warn(
          {
            action: 'contract.exportPdf.activity',
            userId: req.user?.id,
            targetId: id,
            errorType: activityErr instanceof Error ? activityErr.name : 'UNKNOWN',
          },
          'fn_contract_activity_create emission failed (non-fatal)',
        );
      }

      const filename = `${data.contract.contractNumber}-${q.language ?? 'bilingual'}.pdf`;

      req.logger.info(
        {
          action: 'contract.exportPdf',
          userId: req.user?.id,
          targetId: id,
          duration: Date.now() - startTime,
          statusCode: 200,
          bytes: pdfBuffer.length,
          language: q.language ?? 'bilingual',
        },
        'Controller exit',
      );
      res.setHeader('Content-Type', 'application/pdf');
      res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
      res.setHeader('Content-Length', String(pdfBuffer.length));
      res.status(200).send(pdfBuffer);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.exportPdf',
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
   * GET /api/v1/contracts/export.xlsx → fn_contract_export_xlsx (S5)
   *
   * List-level XLSX export — same filter set as M1a fn_contract_list, no
   * pagination, max_rows hard-clamped 1..50000 (default 10000). Renders via
   * exceljs WorkbookWriter (memory-bounded). Per AC-S5-08 the audit row is
   * emitted by the controller AFTER the workbook materialises, via
   * fn_audit_log_record (action='INSERT', new_values.event='EXPORT').
   *
   * Critical W1: this route's literal path '/export.xlsx' MUST be declared
   * BEFORE any '/:id' matchers — otherwise Express binds :id='export.xlsx'
   * and PositiveBigIntSchema 400s.
   */
  async exportXlsx(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'contract.exportXlsx',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ContractExportXlsxQueryInferred;
      const data = await db.callFunction<ContractExportXlsxResponse>(
        'fn_contract_export_xlsx',
        [
          req.user!.id,
          req.user!.role,
          q.status ?? null,
          q.contractType ?? null,
          q.counterpartyId ?? null,
          q.draftedBy ?? null,
          q.approvedBy ?? null,
          q.startDateFrom ?? null,
          q.startDateTo ?? null,
          q.endDateFrom ?? null,
          q.endDateTo ?? null,
          q.tags ?? null,
          q.search ?? null,
          q.maxRows ?? 10000,
        ],
        { actorId: req.user!.id },
      );

      // Codex BE-M1b-001 fix: render FIRST, then audit, then send. If
      // renderContractXlsx throws mid-stream (corrupt input, OOM in
      // exceljs) the controller's catch block runs and NO audit row is
      // committed. Once the xlsxBuffer is fully materialised in memory, the
      // remaining work (header + send) cannot fail in a way that delivers a
      // partial file — so emitting the audit row before res.send is safe
      // and lets the response semantics ("response complete iff audit
      // committed") hold for tests and for synchronous downstream auditing.
      const xlsxBuffer = await renderContractXlsx(data);

      try {
        await db.callFunction<AuditLogRecordResult>(
          'fn_audit_log_record',
          [
            'contract',
            null /* list-level event — no record id */,
            'INSERT',
            {
              event: 'EXPORT',
              format: 'xlsx',
              rowCount: data.totalRows,
              filter: data.filterApplied,
            },
            req.user!.id,
          ],
          { actorId: req.user!.id },
        );
      } catch (auditErr) {
        // A failed audit must not block the export — the workbook is
        // already materialised. Surface in logs and continue.
        req.logger.warn(
          {
            action: 'contract.exportXlsx.audit',
            userId: req.user?.id,
            errorType: auditErr instanceof Error ? auditErr.name : 'UNKNOWN',
          },
          'fn_audit_log_record emission failed (non-fatal)',
        );
      }

      const ts = new Date();
      const pad = (n: number): string => String(n).padStart(2, '0');
      const filename = `contracts-${ts.getFullYear()}${pad(ts.getMonth() + 1)}${pad(ts.getDate())}-${pad(ts.getHours())}${pad(ts.getMinutes())}.xlsx`;

      req.logger.info(
        {
          action: 'contract.exportXlsx',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          bytes: xlsxBuffer.length,
          rowCount: data.totalRows,
          truncated: data.truncated,
        },
        'Controller exit',
      );
      res.setHeader(
        'Content-Type',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
      res.setHeader('Content-Length', String(xlsxBuffer.length));
      if (data.truncated) {
        res.setHeader('X-Export-Truncated', 'true');
      }
      res.status(200).send(xlsxBuffer);
    } catch (error) {
      req.logger.error(
        {
          action: 'contract.exportXlsx',
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
