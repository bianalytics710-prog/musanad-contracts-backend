/**
 * Contract comments — 4 endpoints (R4 audit gap 8.2.1):
 *
 *   GET    /api/v1/contracts/:id/comments?filter=all|unresolved|mine|mentions_me
 *   POST   /api/v1/contracts/:id/comments
 *   POST   /api/v1/contracts/:id/comments/:commentId/resolve
 *   DELETE /api/v1/contracts/:id/comments/:commentId
 *
 * Each is a thin HTTP layer over a single fn_contract_comment_* call. The
 * BE validates payload shape inline (the route schema strips unknown
 * params for two-id routes, see the attachments-controller note).
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ValidationError } from '../utils/errors.util';

interface CommentRowEnvelope<T> { data: T }

export const contractCommentController = {
  /** GET /api/v1/contracts/:id/comments */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const contractId = Number(req.params.id);
      if (!Number.isInteger(contractId) || contractId <= 0) {
        throw new ValidationError('Invalid contract id', { contractId: 'Invalid contract id' });
      }
      const filterRaw = (req.query.filter as string | undefined) ?? 'all';
      if (!['all', 'unresolved', 'mine', 'mentions_me'].includes(filterRaw)) {
        throw new ValidationError('Invalid filter', { filter: 'Invalid filter' });
      }
      const result = await db.callFunction<CommentRowEnvelope<unknown[]>>(
        'fn_contract_comment_list',
        [req.user!.id, contractId, filterRaw],
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
      const contractId = Number(req.params.id);
      if (!Number.isInteger(contractId) || contractId <= 0) {
        throw new ValidationError('Invalid contract id', { contractId: 'Invalid contract id' });
      }
      const body = req.body as {
        body?: string;
        parentId?: number | null;
        mentionedUserIds?: number[];
      };
      if (typeof body.body !== 'string' || body.body.trim().length === 0) {
        throw new ValidationError('Body required', { body: 'Body is required' });
      }
      if (body.body.length > 4000) {
        throw new ValidationError('Body too long', { body: 'Max 4000 chars' });
      }
      const parentId = body.parentId ?? null;
      const mentions = Array.isArray(body.mentionedUserIds)
        ? body.mentionedUserIds.filter((n) => Number.isInteger(n) && n > 0)
        : [];
      const result = await db.callFunction<CommentRowEnvelope<{ id: number }>>(
        'fn_contract_comment_create',
        [req.user!.id, contractId, body.body, parentId, mentions],
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
      const commentId = Number(req.params.commentId);
      if (!Number.isInteger(commentId) || commentId <= 0) {
        throw new ValidationError('Invalid comment id', { commentId: 'Invalid comment id' });
      }
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
      const commentId = Number(req.params.commentId);
      if (!Number.isInteger(commentId) || commentId <= 0) {
        throw new ValidationError('Invalid comment id', { commentId: 'Invalid comment id' });
      }
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
