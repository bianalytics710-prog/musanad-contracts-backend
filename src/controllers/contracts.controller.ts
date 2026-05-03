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
  UpdateContractStatusDtoInferred,
  SetContractTagsDtoInferred,
  CreateContractVersionDtoInferred,
} from '../schemas/contracts.schemas';
import type {
  Contract,
  ContractListResponse,
  ContractTreeResponse,
  ContractVersionListResponse,
  ContractActivityListResponse,
  ContractVersionCreated,
  DeleteContractResponse,
  SetContractTagsResponse,
  UpdateContractStatusResponse,
} from '../types/contracts.types';

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
   * PATCH /api/v1/contracts/:id/status → fn_contract_status_update
   *
   * M1a placeholder — validates enum membership only (AC-S6-07: no transition
   * validity in M1a; M2 will replace with state-machine-aware variant).
   */
  async updateStatus(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'contract.updateStatus', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as UpdateContractStatusDtoInferred;
      const result = await db.callFunction<UpdateContractStatusResponse>(
        'fn_contract_status_update',
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
};
