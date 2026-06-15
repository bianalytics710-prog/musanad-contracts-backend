/**
 * M16 / CR-H — Advisory Drafts controller.
 *
 * Routes: generate, list, getById, approve, reject, modify, dispatch, dispatchLog.
 * generate delegates to advisory-drafter.service.ts for LLM call + fn_ persist.
 * dispatch delegates to notification-dispatcher.service.ts for SMTP + fn_advisory_dispatch.
 * All other endpoints call db.callFunction() directly (one per method).
 *
 * P0001 routing for advisory domain:
 *   cannot_self_approve → 422
 *   cannot_dispatch_unapproved / draft_not_approved → 422
 *   draft_already_dispatched / already_dispatched → 409
 *   role_mismatch → 403
 *   invalid_status_transition → 409
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import { generateAdvisoryDraft } from '../services/advisory-drafter.service';
import { dispatchAdvisoryDraft } from '../services/notification-dispatcher.service';
import {
  listAdvisoryDraftsSchema,
  approveAdvisoryDraftSchema,
  rejectAdvisoryDraftSchema,
  modifyAdvisoryDraftSchema,
  dispatchAdvisoryDraftSchema,
} from '../schemas/advisory-drafts.schemas';

export const advisoryDraftsController = {

  generate: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_generate',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const body = req.body as { correlationId?: unknown; templateId?: unknown; contractId?: unknown };
      const correlationId = typeof body.correlationId === 'number' ? body.correlationId : parseInt(String(body.correlationId ?? ''), 10);
      const templateId = typeof body.templateId === 'number' ? body.templateId : parseInt(String(body.templateId ?? ''), 10);
      const contractId = body.contractId != null
        ? (typeof body.contractId === 'number' ? body.contractId : parseInt(String(body.contractId), 10))
        : undefined;

      const result = await generateAdvisoryDraft({
        correlationId,
        templateId,
        contractId: contractId ?? null,
        actorId: req.user!.id,
        tenantId: req.tenantId ?? '',
      });

      req.logger.info({
        action: 'fn_advisory_draft_generate',
        userId: req.user?.id,
        draftId: result?.draftId,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_generate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = listAdvisoryDraftsSchema.parse(req.query);
      const result = await db.callFunction('fn_advisory_draft_list', [
        req.user!.id,
        params.approvalStatus ?? null,
        params.contractId ?? null,
        params.correlationId ?? null,
        params.draftType ?? null,
        params.myQueue,
        params.page,
        params.limit,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  getById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_get_by_id',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_advisory_draft_get_by_id', [
        req.user!.id,
        id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'draft_not_found', 'Advisory draft not found');

      req.logger.info({
        action: 'fn_advisory_draft_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  approve: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_approve',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = approveAdvisoryDraftSchema.parse(req.body);
      const result = await db.callFunction('fn_advisory_draft_approve', [
        req.user!.id,
        id,
        data.finalTextEn ?? null,
        data.finalTextAr ?? null,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_approve',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_approve',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  reject: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_reject',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = rejectAdvisoryDraftSchema.parse(req.body);
      const result = await db.callFunction('fn_advisory_draft_reject', [
        req.user!.id,
        id,
        data.rejectionReason,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_reject',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_reject',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  modify: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_modify',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = modifyAdvisoryDraftSchema.parse(req.body);
      const result = await db.callFunction('fn_advisory_draft_modify', [
        req.user!.id,
        id,
        data.finalTextEn,
        data.finalTextAr,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_modify',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_modify',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  dispatch: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_dispatch',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = dispatchAdvisoryDraftSchema.parse(req.body);
      const result = await dispatchAdvisoryDraft({
        draftId: id,
        recipients: data.recipients,
        actorId: req.user!.id,
        tenantId: req.tenantId ?? '',
      });

      req.logger.info({
        action: 'fn_advisory_dispatch',
        userId: req.user?.id,
        draftId: id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_dispatch',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  dispatchLog: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_dispatch_log_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_advisory_dispatch_log_list', [
        req.user!.id,
        id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_dispatch_log_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_dispatch_log_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ─── 2026-06-14 — Risk-case → contract → draft workflow ────────────────
  // generateFromRiskCase: LC clicks "Draft <Notice>" on contract detail.
  // No LLM — straight Mustache rendering with templateContext.
  generateFromRiskCase: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_draft_generate_v2',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });
    try {
      const body = req.body as {
        templateId?: unknown;
        contractId?: unknown;
        riskCaseId?: unknown;
        reviewPath?: unknown;
        templateContext?: unknown;
      };
      const templateId = parseInt(String(body.templateId ?? ''), 10);
      const contractId = parseInt(String(body.contractId ?? ''), 10);
      const riskCaseId = body.riskCaseId != null && body.riskCaseId !== ''
        ? parseInt(String(body.riskCaseId), 10) : null;
      // 2026-06-15 — reviewPath is now OPTIONAL. The two-step dialog
      // generates first (NULL path), shows preview, then user picks
      // send_directly or executive_review via separate endpoints.
      const reviewPath = typeof body.reviewPath === 'string'
        && ['send_directly', 'executive_review'].includes(body.reviewPath)
          ? body.reviewPath : null;
      const ctx = body.templateContext && typeof body.templateContext === 'object'
        ? body.templateContext : {};
      if (isNaN(templateId) || isNaN(contractId)) {
        throw new ApiError(400, 'invalid_payload', 'templateId, contractId required');
      }

      const result = await db.callFunction('fn_advisory_draft_generate', [
        req.user!.id,
        null,           // correlation_id — let DB resolve
        templateId,
        contractId,
        null, null, null, null, null,   // LLM fields unused
        ctx,
        riskCaseId,
        reviewPath,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_generate_v2',
        userId: req.user?.id,
        draftId: (result as { id?: number })?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_draft_generate_v2',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  sendDirectly: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');
      const body = req.body as {
        recipientAddress?: string;
        recipientName?: string;
        additionalRecipients?: Array<{ address?: string; name?: string }>;
      };
      if (!body?.recipientAddress) throw new ApiError(400, 'invalid_payload', 'recipientAddress required');

      // 2026-06-15 — multi-recipient: pass additionalRecipients as JSONB
      // ([{address,name},...]) to fn_advisory_draft_send_directly (mig 675).
      const extras = Array.isArray(body.additionalRecipients)
        ? body.additionalRecipients
            .filter((r) => r && typeof r.address === 'string' && r.address.includes('@'))
            .map((r) => ({ address: r.address, name: r.name ?? null }))
        : [];

      const result = await db.callFunction('fn_advisory_draft_send_directly', [
        req.user!.id, id, body.recipientAddress, body.recipientName ?? null,
        false, JSON.stringify(extras),
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_send_directly',
        userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  routeForReview: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_advisory_draft_route_for_review', [
        req.user!.id, id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_route_for_review',
        userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  execApprove: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_advisory_draft_exec_approve', [
        req.user!.id, id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_exec_approve',
        userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  sendAfterReview: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');
      const body = req.body as {
        recipientAddress?: string;
        recipientName?: string;
        additionalRecipients?: Array<{ address?: string; name?: string }>;
      };
      if (!body?.recipientAddress) throw new ApiError(400, 'invalid_payload', 'recipientAddress required');

      const extras = Array.isArray(body.additionalRecipients)
        ? body.additionalRecipients
            .filter((r) => r && typeof r.address === 'string' && r.address.includes('@'))
            .map((r) => ({ address: r.address, name: r.name ?? null }))
        : [];

      const result = await db.callFunction('fn_advisory_draft_send_after_review', [
        req.user!.id, id, body.recipientAddress, body.recipientName ?? null,
        JSON.stringify(extras),
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_send_after_review',
        userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  resend: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');
      const body = req.body as {
        recipientAddress?: string;
        recipientName?: string;
        additionalRecipients?: Array<{ address?: string; name?: string }>;
      };
      if (!body?.recipientAddress) throw new ApiError(400, 'invalid_payload', 'recipientAddress required');

      const extras = Array.isArray(body.additionalRecipients)
        ? body.additionalRecipients
            .filter((r) => r && typeof r.address === 'string' && r.address.includes('@'))
            .map((r) => ({ address: r.address, name: r.name ?? null }))
        : [];

      const result = await db.callFunction('fn_advisory_draft_resend', [
        req.user!.id, id, body.recipientAddress, body.recipientName ?? null,
        JSON.stringify(extras),
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_draft_resend',
        userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  // Recipient resolver — delegates to fn_advisory_recipient_resolve (mig 671).
  // Returns { recipientAddress, recipientName, source, counterpartyName }.
  resolveRecipient: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const contractId = parseInt(req.params.contractId ?? '', 10);
      if (isNaN(contractId) || contractId <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid contractId');
      }
      const result = await db.callFunction('fn_advisory_recipient_resolve', [
        req.user!.id, contractId,
      ], { actorId: req.user!.id, tenantId: req.tenantId });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  // GET /contracts/:id/advisories (mounted under /advisory-drafts for now;
  // FE service consumes from here)
  listForContract: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const id = parseInt(req.params.contractId ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid contractId');
      const result = await db.callFunction('fn_contract_advisory_list', [
        req.user!.id, id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  // 2026-06-15 — Phase 2: drafts awaiting executive review (exec inbox).
  pendingForExecutive: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const result = await db.callFunction('fn_advisory_draft_pending_for_executive', [
        req.user!.id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },

  // 2026-06-15 — Phase 2: executive edits the draft text before approving.
  execModify: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');
      const body = req.body as { modifiedTextEn?: string; modifiedTextAr?: string };
      if (!body?.modifiedTextEn) {
        throw new ApiError(400, 'invalid_payload', 'modifiedTextEn required');
      }
      const result = await db.callFunction('fn_advisory_draft_exec_modify', [
        req.user!.id, id, body.modifiedTextEn, body.modifiedTextAr ?? null,
      ], { actorId: req.user!.id, tenantId: req.tenantId });
      res.json(result);
    } catch (error) {
      next(error);
    }
  },
};
