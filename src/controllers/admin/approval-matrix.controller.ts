/**
 * /api/v1/admin/approval-matrix controllers — M2 admin matrix management.
 * Thin HTTP layer over fn_approval_matrix_list / fn_approval_matrix_set.
 */
import type { NextFunction, Request, Response } from 'express';
import * as approvalMatrixService from '../../services/admin/approval-matrix.service';
import { ApiError } from '../../utils/errors.util';
import type {
  ApprovalMatrixListQueryInferred,
  UpdateApprovalMatrixInferred,
} from '../../schemas/approval.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const approvalMatrixController = {
  /** GET /api/v1/admin/approval-matrix → fn_approval_matrix_list (S4) */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'adminApprovalMatrix.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ApprovalMatrixListQueryInferred;
      const result = await approvalMatrixService.list(req.user!.id, {
        page: q.page,
        limit: q.limit,
        contractType: q.contractType,
      });
      req.logger.info(
        {
          action: 'adminApprovalMatrix.list',
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
          action: 'adminApprovalMatrix.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /** PUT /api/v1/admin/approval-matrix → fn_approval_matrix_set (S5) */
  async set(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'adminApprovalMatrix.set',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as UpdateApprovalMatrixInferred;
      const result = await approvalMatrixService.set(req.user!.id, {
        contractType: body.contractType,
        valueMin: body.valueMin,
        valueMax: body.valueMax ?? null,
        rules: body.rules,
      });
      req.logger.info(
        {
          action: 'adminApprovalMatrix.set',
          userId: req.user?.id,
          contractType: body.contractType,
          ruleCount: result?.ruleCount,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'adminApprovalMatrix.set',
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
