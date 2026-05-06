/**
 * Contract attachments — 4 endpoints:
 *
 *   GET    /api/v1/contracts/:id/attachments                  → list
 *   POST   /api/v1/contracts/:id/attachments                  → multipart upload
 *   GET    /api/v1/contracts/:id/attachments/:fileId/url      → signed download URL
 *   DELETE /api/v1/contracts/:id/attachments/:fileId          → soft delete + storage cleanup
 *
 * Bytes flow through the BE → Supabase Storage using the service-role key
 * (BE-mediated upload). FE never sees Supabase credentials.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError, NotFoundError, ValidationError } from '../utils/errors.util';
import {
  buildStoragePath,
  uploadAttachment,
  signDownloadUrl,
  deleteAttachment,
} from '../services/supabase-storage.service';

interface AttachmentCreateResult {
  data: { id: number; contractId: number };
}
interface AttachmentListResult {
  data: Array<{
    id: number;
    contractId: number;
    filename: string;
    mimeType: string;
    sizeBytes: number;
    description: string | null;
    storageBucket: string;
    storagePath: string;
    uploadedBy: { id: number; firstName: string; lastName: string };
    createdAt: string;
  }>;
}
interface AttachmentRow {
  id: number;
  contractId: number;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  storageBucket: string;
  storagePath: string;
  description: string | null;
  uploadedBy: number;
  createdAt: string;
}

export const contractAttachmentController = {
  /**
   * GET /api/v1/contracts/:id/attachments
   */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const contractId = Number(req.params.id);
      if (!Number.isInteger(contractId) || contractId <= 0) {
        throw new ValidationError('Invalid contract id', { contractId: 'Invalid contract id' });
      }
      const userId = req.user!.id;
      const role = req.user!.role;
      const result = await db.callFunction<AttachmentListResult>(
        'fn_contract_attachment_list',
        [contractId, userId, role],
        { actorId: userId },
      );
      req.logger.info(
        { action: 'contractAttachment.list', userId, contractId, count: result?.data?.length ?? 0, statusCode: 200 },
        'Listed contract attachments',
      );
      res.status(200).json({ success: true, data: result?.data ?? [] });
    } catch (err) {
      next(err);
    }
  },

  /**
   * POST /api/v1/contracts/:id/attachments  (multipart/form-data)
   * Field: `file` (required) + `description` (optional)
   */
  async upload(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const contractId = Number(req.params.id);
      if (!Number.isInteger(contractId) || contractId <= 0) {
        throw new ValidationError('Invalid contract id', { contractId: 'Invalid contract id' });
      }
      const userId = req.user!.id;
      const file = (req as Request & { file?: Express.Multer.File }).file;
      if (!file) {
        throw new ValidationError('File is required', { file: 'File is required' });
      }
      const filename = file.originalname || 'unnamed';
      const description = typeof req.body?.description === 'string'
        ? req.body.description.slice(0, 500)
        : null;

      const storagePath = buildStoragePath(contractId, filename);
      await uploadAttachment({
        storagePath,
        buffer: file.buffer,
        mimeType: file.mimetype || 'application/octet-stream',
      });

      let dbResult: AttachmentCreateResult;
      try {
        dbResult = await db.callFunction<AttachmentCreateResult>(
          'fn_contract_attachment_create',
          [contractId, filename, file.mimetype, file.size, storagePath, description, userId],
          { actorId: userId },
        );
      } catch (dbErr) {
        // If the metadata insert failed, remove the orphaned blob so we don't
        // accumulate dangling files.
        await deleteAttachment(storagePath);
        throw dbErr;
      }

      req.logger.info(
        {
          action: 'contractAttachment.upload',
          userId,
          contractId,
          attachmentId: dbResult?.data?.id,
          sizeBytes: file.size,
          statusCode: 201,
        },
        'Uploaded contract attachment',
      );
      res.status(201).json({
        success: true,
        data: {
          id: dbResult?.data?.id,
          contractId,
          filename,
          sizeBytes: file.size,
          mimeType: file.mimetype,
        },
      });
    } catch (err) {
      next(err);
    }
  },

  /**
   * GET /api/v1/contracts/:id/attachments/:fileId/url
   * Returns a 60s signed URL for direct browser download.
   */
  async getDownloadUrl(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const contractId = Number(req.params.id);
      const fileId = Number(req.params.fileId);
      if (!Number.isInteger(contractId) || contractId <= 0 || !Number.isInteger(fileId) || fileId <= 0) {
        throw new ValidationError('Invalid id', { id: 'Invalid id' });
      }
      const userId = req.user!.id;
      const role = req.user!.role;
      const row = await db.callFunction<AttachmentRow>(
        'fn_contract_attachment_get_by_id',
        [fileId, userId, role],
        { actorId: userId },
      );
      if (!row || row.contractId !== contractId) {
        throw new NotFoundError('Attachment not found', { attachmentId: 'Attachment not found' });
      }
      const url = await signDownloadUrl({
        storagePath: row.storagePath,
        filename: row.filename,
      });
      req.logger.info(
        { action: 'contractAttachment.signUrl', userId, contractId, attachmentId: fileId, statusCode: 200 },
        'Signed download URL',
      );
      res.status(200).json({
        success: true,
        data: {
          id: fileId,
          filename: row.filename,
          mimeType: row.mimeType,
          sizeBytes: row.sizeBytes,
          url,
          expiresIn: 60,
        },
      });
    } catch (err) {
      next(err);
    }
  },

  /**
   * DELETE /api/v1/contracts/:id/attachments/:fileId
   */
  async remove(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const contractId = Number(req.params.id);
      const fileId = Number(req.params.fileId);
      if (!Number.isInteger(contractId) || contractId <= 0 || !Number.isInteger(fileId) || fileId <= 0) {
        throw new ValidationError('Invalid id', { id: 'Invalid id' });
      }
      const userId = req.user!.id;
      const role = req.user!.role;
      // Resolve storage_path BEFORE soft-delete (we need it to remove from
      // bucket; the soft-delete fn_ doesn't return it).
      const row = await db.callFunction<AttachmentRow>(
        'fn_contract_attachment_get_by_id',
        [fileId, userId, role],
        { actorId: userId },
      );
      if (!row || row.contractId !== contractId) {
        throw new NotFoundError('Attachment not found', { attachmentId: 'Attachment not found' });
      }

      await db.callFunction(
        'fn_contract_attachment_soft_delete',
        [fileId, userId, role],
        { actorId: userId },
      );
      // Best-effort blob cleanup. Failure is logged but does not fail the
      // request — the metadata is already inactive.
      await deleteAttachment(row.storagePath);

      req.logger.info(
        { action: 'contractAttachment.delete', userId, contractId, attachmentId: fileId, statusCode: 204 },
        'Deleted contract attachment',
      );
      res.status(204).end();
    } catch (err) {
      if (err instanceof ApiError) return next(err);
      next(err);
    }
  },
};
