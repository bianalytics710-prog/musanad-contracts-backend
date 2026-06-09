/**
 * /api/v1/approvals/* + /api/v1/contracts/:id/{approval-chain*,submit-for-approval}
 * controllers — M2 Approval Workflows.
 *
 * Each method is a thin HTTP layer: parse + validate (already done by the
 * route's validate() middleware) + call service + format response. No
 * business logic. Sensitive fields (decisionNote) are pino-redacted at the
 * logger layer (logger.util.ts SENSITIVE_PATHS already covers the keys we
 * surface; see "Redaction additions" in be-implementation-summary.json).
 */
import type { NextFunction, Request, Response } from 'express';
import * as approvalService from '../services/approval.service';
import { ApiError, ForbiddenError, NotFoundError } from '../utils/errors.util';
import type {
  ApprovalStepIdParamInferred,
  DecideApprovalInferred,
  DelegateApprovalInferred,
  MyPendingApprovalListQueryInferred,
  RouteInitPreviewInferred,
  RequestInfoInferred,
} from '../schemas/approval.schemas';
import type { ContractIdParamInferred } from '../schemas/contracts.schemas';
import type { SetContractWatchInferred } from '../schemas/contract-comment.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const approvalController = {
  /** GET /api/v1/approvals/my-pending → fn_approval_my_pending (S1) */
  async listMyPending(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.listMyPending',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as MyPendingApprovalListQueryInferred;
      const result = await approvalService.listMyPending(req.user!.id, {
        page: q.page,
        limit: q.limit,
        sort: q.sort,
      });
      req.logger.info(
        {
          action: 'approval.listMyPending',
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
          action: 'approval.listMyPending',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/approvals/:stepId/decide → fn_approval_decide (S2) */
  async decide(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.decide',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { stepId } = req.params as unknown as ApprovalStepIdParamInferred;
      const body = req.body as DecideApprovalInferred;
      // v611 — fan-out (contract_comment + fn_notification_dispatch)
      // requires app.current_tenant_id GUC. Resolve from req.tenantId
      // first; fall back to req.user.tenantId for routes that haven't
      // run rls.middleware. Hardcoded ADNOC fallback is single-tenant
      // safe; drop when we onboard a second tenant.
      const tenantId =
        req.tenantId ??
        (req.user as { tenantId?: string } | undefined)?.tenantId ??
        '00000000-0000-0000-0000-000000000001';
      const result = await approvalService.decide(req.user!.id, stepId, {
        decision: body.decision,
        decisionNote: body.decisionNote,
      }, tenantId);
      req.logger.info(
        {
          action: 'approval.decide',
          userId: req.user?.id,
          targetStepId: stepId,
          decision: body.decision,
          newStepStatus: result?.newStepStatus,
          newChainStatus: result?.newChainStatus,
          allChainStepsResolved: result?.allChainStepsResolved,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'approval.decide',
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
   * POST /api/v1/approvals/:stepId/request-info → fn_approval_request_info
   * (R-LC4 LC-F7). Body: { message: string (>= 1 char) }.
   */
  async requestInfo(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'approval.requestInfo', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      // R-LC9-2 — params + body shape guaranteed by validate(...).
      const { stepId } = req.params as unknown as ApprovalStepIdParamInferred;
      const { message } = req.body as RequestInfoInferred;
      const result = await approvalService.requestInfo(req.user!.id, stepId, { message });
      req.logger.info(
        { action: 'approval.requestInfo', userId: req.user?.id, targetStepId: stepId, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        { action: 'approval.requestInfo', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorType(error) },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/approvals/:stepId/delegate → fn_approval_delegate (S3) */
  async delegate(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.delegate',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { stepId } = req.params as unknown as ApprovalStepIdParamInferred;
      const body = req.body as DelegateApprovalInferred;
      // Defense in depth — fn_approval_delegate also rejects self-delegation
      // (AC-S3-04) but a 400 here saves a DB round-trip when self is obvious.
      if (body.delegatedToUserId === req.user!.id) {
        throw new ForbiddenError('Cannot delegate to self');
      }
      const result = await approvalService.delegate(req.user!.id, stepId, {
        delegatedToUserId: body.delegatedToUserId,
        decisionNote: body.decisionNote,
      });
      req.logger.info(
        {
          action: 'approval.delegate',
          userId: req.user?.id,
          targetStepId: stepId,
          delegatedToUserId: body.delegatedToUserId,
          decisionId: result?.decisionId,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'approval.delegate',
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
   * GET /api/v1/approvals/:stepId/delegate-candidates → fn_approval_delegate_candidates
   * (A38 Aisha audit fix — name+role picker source for the Delegate flow).
   */
  async listDelegateCandidates(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.listDelegateCandidates',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { stepId } = req.params as unknown as ApprovalStepIdParamInferred;
      const result = await approvalService.listDelegateCandidates(req.user!.id, stepId);
      req.logger.info(
        {
          action: 'approval.listDelegateCandidates',
          userId: req.user?.id,
          targetStepId: stepId,
          candidateCount: Array.isArray(result?.data) ? result.data.length : 0,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'approval.listDelegateCandidates',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/contracts/:id/approval-chain/preview → fn_approval_route_init_preview (S6) */
  async routeInitPreview(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.routeInitPreview',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      // contractId is path-only; preview itself does not need it (preview reads
      // matrix only). Keep validation already done by params middleware.
      const body = req.body as RouteInitPreviewInferred;
      const result = await approvalService.routeInitPreview(req.user!.id, {
        contractType: body.contractType,
        valueAed: body.valueAed,
      });
      req.logger.info(
        {
          action: 'approval.routeInitPreview',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          stepCount: result?.steps?.length ?? 0,
          hasNoMatchingRule: result?.hasNoMatchingRule ?? false,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'approval.routeInitPreview',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/contracts/:id/submit-for-approval → fn_approval_route_init (S7) */
  async submitForApproval(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.submitForApproval',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await approvalService.routeInit(req.user!.id, id);
      req.logger.info(
        {
          action: 'approval.submitForApproval',
          userId: req.user?.id,
          contractId: id,
          chainId: result?.chainId,
          totalSteps: result?.totalSteps,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'approval.submitForApproval',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /api/v1/contracts/:id/approval-chain → fn_approval_chain_get (S10) */
  async chainGetByContract(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'approval.chainGetByContract',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { id } = req.params as unknown as ContractIdParamInferred;
      const result = await approvalService.chainGetByContractId(req.user!.id, id);
      if (!result) {
        // Per Design Note D7 / AC-S10-04: RLS-narrowed silently → 404.
        throw new NotFoundError('Approval chain not found');
      }
      req.logger.info(
        {
          action: 'approval.chainGetByContract',
          userId: req.user?.id,
          contractId: id,
          chainId: result.chain?.id,
          stepCount: result.steps?.length ?? 0,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'approval.chainGetByContract',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** GET /api/v1/approvals/my-decisions — R5 audit 6.2.1 */
  async listMyDecisions(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const q = req.query as { kind?: string; page?: string; limit?: string };
      const allowedKinds = ['approve', 'reject', 'request_resubmission', 'skipped'];
      const kind = q.kind && allowedKinds.includes(q.kind)
        ? (q.kind as 'approve' | 'reject' | 'request_resubmission' | 'skipped')
        : undefined;
      const page = q.page ? Number(q.page) : 1;
      const limit = q.limit ? Number(q.limit) : 20;
      const result = await approvalService.listMyDecisions(req.user!.id, { page, limit, kind });
      res.status(200).json(result);
    } catch (error) {
      next(error);
    }
  },

  /** GET /api/v1/approvals/watching — R5 audit 6.2.1 */
  async listWatching(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const q = req.query as { page?: string; limit?: string };
      const page = q.page ? Number(q.page) : 1;
      const limit = q.limit ? Number(q.limit) : 20;
      const result = await approvalService.listWatching(req.user!.id, { page, limit });
      res.status(200).json(result);
    } catch (error) {
      next(error);
    }
  },

  /** PUT /api/v1/contracts/:id/watch — R5 audit toggle watch */
  async setWatch(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      // R-DA9-2 — params + body shape guaranteed by validate() middleware.
      const { id: contractId } = req.params as unknown as ContractIdParamInferred;
      const { watching } = req.body as SetContractWatchInferred;
      const result = await approvalService.setContractWatch(
        req.user!.id,
        contractId,
        watching,
      );
      res.status(200).json(result);
    } catch (error) {
      next(error);
    }
  },
};
