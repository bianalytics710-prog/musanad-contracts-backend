/**
 * Work Order Queue (M21) — controller.
 *
 * Thin HTTP layer over fn_work_order_* (mig 618) + fn_work_order_create_
 * draft_from_contract / fn_work_order_assignable_drafters (mig 620).
 * No business logic here — fn bodies are authoritative.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  cancelWorkOrderSchema,
  createDraftRequestSchema,
  createManualWorkOrderSchema,
  extractFromSourceSchema,
  linkTargetSchema,
  listAssignedByMeQuerySchema,
  listMineQuerySchema,
  lookupContractQuerySchema,
  nudgeWorkOrderSchema,
  reassignWorkOrderSchema,
  setStageSchema,
} from '../schemas/work-order.schemas';
import { extractTemplateFromContract } from '../services/ai/extract-template-from-contract.service';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const workOrderController = {
  // ============================================================
  // GET /api/v1/work-orders
  // ============================================================
  listMine: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_list_for_user',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const q = listMineQuerySchema.parse(req.query);
      const result = await db.callFunction(
        'fn_work_order_list_for_user',
        [
          req.user!.id,
          q.status ?? null,
          q.type ?? null,
          q.limit,
          q.page,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_list_for_user',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_list_for_user',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/progress (M21 — sidecar)
  // ============================================================
  // Returns currentApproverNames per work order with a target contract that
  // has an in-progress approval chain. Used to render "Awaiting <name>" in
  // the My Work table's Stage column. The canonical listMine endpoint above
  // already returns targetContractStatus + workOrder.status which are
  // sufficient to derive the Stage label client-side — this sidecar adds
  // only the human approver detail.
  progress: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_progress_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const result = await db.callFunction(
        'fn_work_order_progress_get',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_progress_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_progress_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/requestor-options (M21 2026-06-12)
  // ============================================================
  // Populates the FE "Requestor" dropdown in the Add to my queue modal.
  // Returns active tenant users for the drafter to pick from.
  requestorOptions: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_requestor_options',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const result = await db.callFunction(
        'fn_work_order_requestor_options',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_requestor_options',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_requestor_options',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/manual (M21 2026-06-12)
  // ============================================================
  // Drafter self-adds a work order that originated outside the system
  // (email, chat, etc.). Always self-assigned both sides; source = manual.
  // Existing fn_work_order_create is intentionally untouched — this calls
  // the dedicated fn_work_order_create_manual.
  createManual: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_create_manual',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const body = createManualWorkOrderSchema.parse(req.body);
      const data = {
        requestType: body.requestType,
        instructionNote: body.instructionNote,
        requestorUserId: body.requestorUserId,
        initialStage: body.initialStage,
        sourceContractId: body.sourceContractId ?? null,
      };
      const result = await db.callFunction(
        'fn_work_order_create_manual',
        [JSON.stringify(data), req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_create_manual',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_create_manual',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/assignable-drafters
  // ============================================================
  assignableDrafters: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_assignable_drafters',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const result = await db.callFunction(
        'fn_work_order_assignable_drafters',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_assignable_drafters',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_assignable_drafters',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/:id
  // ============================================================
  getById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      req.logger.info({
        action: 'fn_work_order_get',
        method: req.method,
        path: req.path,
        userId: req.user?.id,
        targetId: id,
      });
      const result = await db.callFunction(
        'fn_work_order_get',
        [id, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      if (!result) {
        throw new ApiError(404, 'work_order_not_found', 'Work order not found');
      }
      req.logger.info({
        action: 'fn_work_order_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/from-contract
  // ============================================================
  // Exec-driven "Request similar contract" flow. Creates ONLY the work_order
  // — no contract. The drafter composes the contract via the wizard.
  createDraftRequest: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_create_draft_request',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const body = createDraftRequestSchema.parse(req.body);
      const data = {
        counterpartyId: body.counterpartyId ?? null,
        counterpartyProspectName: body.counterpartyProspectName ?? null,
        instructionNote: body.instructionNote ?? null,
        valueAed: body.valueAed ?? null,
        priority: body.priority,
        dueAt: body.dueAt ?? null,
      };
      const result = await db.callFunction(
        'fn_work_order_create_draft_request',
        [
          body.sourceContractId,
          body.assignedDrafterId,
          req.user!.id,
          JSON.stringify(data),
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_create_draft_request',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
        targetId: (result as { workOrderId?: number })?.workOrderId,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_create_draft_request',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/counterparty-options
  // ============================================================
  // Cheap dropdown source for the exec's "Request similar contract" modal.
  // Lists all active parties in the caller's tenant without requiring the
  // party.read.all permission (which executives in some tenants don't have).
  counterpartyOptions: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      req.logger.info({
        action: 'work_order.counterparty_options',
        userId: req.user?.id,
      });
      const result = await db.callFunction<{ data: Array<{ id: number; nameEn: string; partyType: string | null }> }>(
        'fn_party_dropdown_list',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      const data = result?.data ?? [];
      req.logger.info({
        action: 'work_order.counterparty_options',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        resultCount: data.length,
      });
      res.json({ data });
    } catch (error) {
      req.logger.error({
        action: 'work_order.counterparty_options',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/extract-from-source
  // ============================================================
  // Calls the AI to redact a source contract's body and emit a placeholder
  // catalog. Used by the Compose wizard when entered from a work order —
  // skips the template picker entirely.
  extractFromSource: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'work_order.extract_from_source',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const { sourceContractId } = extractFromSourceSchema.parse(req.body);
      // Fetch source contract (filtered by RLS for the caller).
      const sourceResult = await db.callFunction<{
        id: number;
        contractNumber: string;
        titleEn: string | null;
        titleAr: string | null;
        contractType: string;
        bodyEn: string | null;
        bodyAr: string | null;
      } | null>(
        'fn_contract_get_by_id',
        // 2026-06-12 — signature is (p_id, p_actor_id); we had these swapped,
        // which made every Compose-draft extract from contract id = userId
        // (so Hala = userId 5 always read OQOOD-2026-001's body, an MSA).
        // That's why every MNDA Compose looked like an MSA in the wizard.
        [sourceContractId, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      if (!sourceResult) {
        throw new ApiError(404, 'source_contract_not_found', 'Source contract not found');
      }
      const body = sourceResult.bodyEn ?? sourceResult.bodyAr ?? '';
      if (body.trim().length < 50) {
        throw new ApiError(422, 'source_body_too_short', 'Source contract has no usable body to extract from');
      }
      const extracted = await extractTemplateFromContract({
        filename: sourceResult.contractNumber + '.txt',
        extractedText: body,
        contractTypeHint: sourceResult.contractType,
      });
      req.logger.info({
        action: 'work_order.extract_from_source',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        targetId: sourceContractId,
      });
      res.json({
        sourceContractId,
        sourceContractNumber: sourceResult.contractNumber,
        sourceTitleEn: sourceResult.titleEn,
        sourceTitleAr: sourceResult.titleAr,
        sourceContractType: sourceResult.contractType,
        contractType: extracted.contractType,
        language: extracted.language,
        bodyEnRedacted: extracted.bodyEnRedacted,
        placeholders: extracted.placeholders,
        warnings: extracted.warnings,
      });
    } catch (error) {
      req.logger.error({
        action: 'work_order.extract_from_source',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/:id/link-target
  // ============================================================
  // Called by the FE compose-submit handler immediately after the drafter
  // creates the new contract. Stamps target_contract_id on the work_order
  // so the existing trg_work_order_on_contract_status trigger auto-completes
  // when the contract moves to in_approval.
  linkTarget: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      const { contractId } = linkTargetSchema.parse(req.body);
      req.logger.info({
        action: 'fn_work_order_link_target',
        userId: req.user?.id,
        targetId: id,
      });
      const result = await db.callFunction(
        'fn_work_order_link_target',
        [id, contractId, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_link_target',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_link_target',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/:id/complete
  // ============================================================
  complete: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      req.logger.info({
        action: 'fn_work_order_complete',
        userId: req.user?.id,
        targetId: id,
      });
      const result = await db.callFunction(
        'fn_work_order_complete',
        [id, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_complete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_complete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/lookup-contract?number=…  (M21 mig 631)
  // ============================================================
  // Powers the "Similar contract" field on the Add to my queue modal.
  // Returns the contract matching the supplied number in the caller's
  // tenant, or {found:false}. Read-only, no side effects.
  lookupContract: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const { number } = lookupContractQuerySchema.parse(req.query);
      req.logger.info({
        action: 'fn_work_order_contract_lookup',
        userId: req.user?.id,
      });
      const result = await db.callFunction(
        'fn_work_order_contract_lookup',
        [req.user!.id, number],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_contract_lookup',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_contract_lookup',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // PATCH /api/v1/work-orders/:id/stage   (M21 mig 631)
  // ============================================================
  // Drafter override of the My Work Stage column. Body: { stage: <one of 5> | null }.
  // RBAC enforced inside fn_work_order_stage_set — only the assigned drafter
  // can change their own row.
  setStage: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      const body = setStageSchema.parse(req.body);
      req.logger.info({
        action: 'fn_work_order_stage_set',
        userId: req.user?.id,
        targetId: id,
      });
      const result = await db.callFunction(
        'fn_work_order_stage_set',
        [id, body.stage, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_stage_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_stage_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/assigned-by-me  (M21 mig 638)
  // ============================================================
  // Mirror of listMine but scoped to work orders the caller assigned to others.
  // Executive's "Assigned Work" page reads from here. The exec sees who owns
  // each row (assignedToName) — the inverse perspective of the drafter queue.
  listAssignedByMe: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_work_order_list_assigned_by_user',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const q = listAssignedByMeQuerySchema.parse(req.query);
      const result = await db.callFunction(
        'fn_work_order_list_assigned_by_user',
        [
          req.user!.id,
          q.status ?? null,
          q.type ?? null,
          q.ownerId ?? null,
          q.limit,
          q.page,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_list_assigned_by_user',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_list_assigned_by_user',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/work-orders/owner-options  (M21 mig 639)
  // ============================================================
  // OWNER dropdown source for the executive's Assigned Work table.
  ownerOptions: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const result = await db.callFunction(
        'fn_work_order_owner_options',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_owner_options',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_owner_options',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/:id/nudge  (M21 mig 639)
  // ============================================================
  // Executive sends an in-app reminder to the owner of the work order.
  // fn_work_order_nudge enforces:
  //   - caller is the original requestor (42501 otherwise)
  //   - work_order is not cancelled/completed
  //   - 6h idempotency window (returns {throttled:true} without firing)
  nudge: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      const body = nudgeWorkOrderSchema.parse(req.body ?? {});
      req.logger.info({ action: 'fn_work_order_nudge', userId: req.user?.id, targetId: id });
      const result = await db.callFunction(
        'fn_work_order_nudge',
        [id, req.user!.id, body.message ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_nudge',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_nudge',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/:id/reassign  (M21 mig 639)
  // ============================================================
  reassign: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      const body = reassignWorkOrderSchema.parse(req.body ?? {});
      req.logger.info({
        action: 'fn_work_order_reassign',
        userId: req.user?.id,
        targetId: id,
        newAssigneeId: body.newAssigneeId,
      });
      const result = await db.callFunction(
        'fn_work_order_reassign',
        [id, body.newAssigneeId, req.user!.id, body.reason ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_reassign',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_reassign',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/work-orders/:id/cancel
  // ============================================================
  cancel: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (Number.isNaN(id) || id <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid work order id');
      }
      const body = cancelWorkOrderSchema.parse(req.body ?? {});
      req.logger.info({
        action: 'fn_work_order_cancel',
        userId: req.user?.id,
        targetId: id,
      });
      const result = await db.callFunction(
        'fn_work_order_cancel',
        [id, req.user!.id, body.reason ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      req.logger.info({
        action: 'fn_work_order_cancel',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_work_order_cancel',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: errorType(error),
      });
      next(error);
    }
  },
};
