/**
 * Contract comments — 4 endpoints (R4 audit gap 8.2.1):
 *
 *   GET    /api/v1/contracts/:id/comments?filter=all|unresolved|mine|mentions_me
 *   POST   /api/v1/contracts/:id/comments
 *   POST   /api/v1/contracts/:id/comments/:commentId/resolve
 *   DELETE /api/v1/contracts/:id/comments/:commentId
 *
 * Each is a thin HTTP layer over a single fn_contract_comment_* call.
 * R-DA9-2 — all 4 endpoints now Zod-validated upstream by validate()
 * middleware in routes/v1/contracts.routes.ts (see
 * schemas/contract-comment.schemas.ts). Controllers consume the typed
 * params/body/query directly.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import type {
  ContractCommentIdParamsInferred,
  CommentListQueryInferred,
  CreateCommentInferred,
} from '../schemas/contract-comment.schemas';
import type { ContractIdParamInferred } from '../schemas/contracts.schemas';

interface CommentRowEnvelope<T> { data: T }

export const contractCommentController = {
  /** GET /api/v1/contracts/:id/comments */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const { id: contractId } = req.params as unknown as ContractIdParamInferred;
      const { filter } = req.query as unknown as CommentListQueryInferred;
      const result = await db.callFunction<CommentRowEnvelope<unknown[]>>(
        'fn_contract_comment_list',
        [req.user!.id, contractId, filter],
        { actorId: req.user!.id },
      );
      res.json({ success: true, data: result.data, requestId: req.requestId });
    } catch (err) {
      next(err);
    }
  },

  /** POST /api/v1/contracts/:id/comments */
  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const { id: contractId } = req.params as unknown as ContractIdParamInferred;
      const body = req.body as CreateCommentInferred;
      const result = await db.callFunction<CommentRowEnvelope<{ id: number }>>(
        'fn_contract_comment_create',
        [
          req.user!.id,
          contractId,
          body.body,
          body.parentId ?? null,
          body.mentionedUserIds ?? [],
        ],
        { actorId: req.user!.id },
      );
      res.status(201).json({ success: true, data: result.data, requestId: req.requestId });
    } catch (err) {
      next(err);
    }
  },

  /** POST /api/v1/contracts/:id/comments/:commentId/resolve */
  async resolve(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const { commentId } = req.params as unknown as ContractCommentIdParamsInferred;
      const result = await db.callFunction<CommentRowEnvelope<{ id: number; resolved: boolean }>>(
        'fn_contract_comment_resolve',
        [req.user!.id, commentId],
        { actorId: req.user!.id },
      );
      res.json({ success: true, data: result.data, requestId: req.requestId });
    } catch (err) {
      next(err);
    }
  },

  /** DELETE /api/v1/contracts/:id/comments/:commentId */
  async remove(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const { commentId } = req.params as unknown as ContractCommentIdParamsInferred;
      const result = await db.callFunction<CommentRowEnvelope<{ id: number; deleted: boolean }>>(
        'fn_contract_comment_delete',
        [req.user!.id, commentId],
        { actorId: req.user!.id },
      );
      res.json({ success: true, data: result.data, requestId: req.requestId });
    } catch (err) {
      next(err);
    }
  },
};
