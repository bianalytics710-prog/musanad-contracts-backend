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
} from '../schemas/approval.schemas';
import type { ContractIdParamInferred } from '../schemas/contracts.schemas';

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
      const result = await approvalService.decide(req.user!.id, stepId, {
        decision: body.decision,
        decisionNote: body.decisionNote,
      });
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
};
