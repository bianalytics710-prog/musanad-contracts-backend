/**
 * /api/v1/admin/approval-chains + /api/v1/admin/approval-steps/:stepId/reassign
 * controllers — M2 admin chain monitor + reassign override.
 */
import type { NextFunction, Request, Response } from 'express';
import * as approvalChainsService from '../../services/admin/approval-chains.service';
import { ApiError } from '../../utils/errors.util';
import type {
  ApprovalChainListQueryInferred,
  ApprovalStepIdParamInferred,
  ReassignApprovalInferred,
} from '../../schemas/approval.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const approvalChainsController = {
  /** GET /api/v1/admin/approval-chains → fn_approval_chain_list (S11) */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'adminApprovalChains.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ApprovalChainListQueryInferred;
      const result = await approvalChainsService.list(req.user!.id, {
        page: q.page,
        limit: q.limit,
        contractId: q.contractId,
        status: q.status,
        submittedBy: q.submittedBy,
      });
      req.logger.info(
        {
          action: 'adminApprovalChains.list',
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
          action: 'adminApprovalChains.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** POST /api/v1/admin/approval-steps/:stepId/reassign → fn_approval_reassign (S8) */
  async reassign(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'adminApprovalChains.reassign',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const { stepId } = req.params as unknown as ApprovalStepIdParamInferred;
      const body = req.body as ReassignApprovalInferred;
      const result = await approvalChainsService.reassign(req.user!.id, stepId, {
        reassignedToUserId: body.reassignedToUserId,
        decisionNote: body.decisionNote,
      });
      req.logger.info(
        {
          action: 'adminApprovalChains.reassign',
          userId: req.user?.id,
          targetStepId: stepId,
          reassignedToUserId: body.reassignedToUserId,
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
          action: 'adminApprovalChains.reassign',
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
