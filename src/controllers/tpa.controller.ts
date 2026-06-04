/**
 * TPA — Third-Party Agreement Assessment controller.
 *
 * Endpoints (mounted under /api/v1/tpa):
 *   GET    /playbooks                      — list active playbooks
 *   GET    /playbooks/:id                  — get playbook + clauses
 *   POST   /reviews/upload                 — multipart: create review + upload + extract + analyse (sync)
 *   GET    /reviews                        — paginated list
 *   GET    /reviews/:id                    — detail with findings + documents
 *   PATCH  /reviews/:id/findings/:findingId — override AI verdict / write user redline
 *   POST   /reviews/:id/status             — transition (sent / closed)
 *   GET    /reviews/:id/redline.docx       — stream the generated redline DOCX
 *
 * Permissions:
 *   tpa.review.read   — list / get
 *   tpa.review.create — upload + analyse
 *   tpa.review.amend  — finding update, status transition, redline export
 */
import type { Request, Response, NextFunction } from 'express';
import { createHash, randomUUID } from 'node:crypto';
import { db } from '../database/client';
import { ValidationError, NotFoundError, ApiError } from '../utils/errors.util';
import {
  analyseAgreementAgainstPlaybook,
  extractTextFromBuffer,
  type PlaybookClauseInput,
  type PlaybookInput,
} from '../services/tpa-analyzer.service';
import { buildRedlineDocx } from '../services/tpa-redline.service';
import { uploadAttachment } from '../services/supabase-storage.service';

const REVIEW_LIST_LIMIT = 25;

export const tpaController = {
  // ============================================================
  // Playbooks
  // ============================================================
  listPlaybooks: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const result = await db.callFunction<unknown>(
        'fn_tpa_playbook_list',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json({ data: result ?? [] });
    } catch (err) {
      next(err);
    }
  },

  getPlaybook: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (!Number.isFinite(id) || id <= 0) {
        throw new ValidationError('Invalid playbook id');
      }
      const result = await db.callFunction<unknown>(
        'fn_tpa_playbook_get',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (err) {
      next(err);
    }
  },

  // ============================================================
  // POST /reviews/upload — create + extract + analyse
  // ============================================================
  uploadAndAnalyse: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    try {
      const file = (req as Request & { file?: Express.Multer.File }).file;
      if (!file) {
        throw new ValidationError('No file uploaded — expected multipart field "file"');
      }
      const body = req.body as Record<string, unknown>;
      const playbookId = parseNum(body.playbookId);
      const agreementType = String(body.agreementType ?? '').trim();
      const counterpartyName = String(body.counterpartyName ?? '').trim();
      const counterpartyEmail = body.counterpartyEmail ? String(body.counterpartyEmail).trim() : '';
      const agreementTitle = String(body.agreementTitle ?? '').trim();

      if (!playbookId || !agreementType || !counterpartyName || !agreementTitle) {
        throw new ValidationError(
          'Missing required fields: playbookId, agreementType, counterpartyName, agreementTitle',
        );
      }

      // Step 1 — create review header
      const created = await db.callFunction<{ id: number; referenceCode: string; status: string }>(
        'fn_tpa_review_create',
        [req.user!.id, playbookId, counterpartyName, counterpartyEmail, agreementTitle, agreementType],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      if (!created?.id) {
        throw new ApiError(500, 'INTERNAL_ERROR', 'Failed to create review');
      }
      const reviewId = created.id;
      const referenceCode = created.referenceCode;

      req.logger.info({
        action: 'tpa.upload.created',
        reviewId,
        referenceCode,
        fileName: file.originalname,
        sizeBytes: file.size,
      });

      // Step 2 — upload original to Supabase Storage
      const storagePath = `tpa/${reviewId}/${randomUUID()}/${file.originalname.replace(/[^\w.\-]+/g, '_').slice(0, 200)}`;
      await uploadAttachment({
        storagePath,
        buffer: file.buffer,
        mimeType: file.mimetype,
      });
      const sha256 = createHash('sha256').update(file.buffer).digest('hex');
      await db.callFunction<number>(
        'fn_tpa_review_attach_document',
        [
          req.user!.id, reviewId, 'original_upload', file.originalname, file.mimetype,
          file.size, storagePath, null, null, sha256,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      // Step 3 — extract text
      let extracted;
      try {
        extracted = await extractTextFromBuffer(file.buffer, file.mimetype);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        await safeRecordFailure(req.user!.id, req.tenantId, reviewId, `extraction failed: ${msg}`);
        throw new ValidationError(`Could not extract text from uploaded file: ${msg}`);
      }
      if (!extracted.text || extracted.text.trim().length < 200) {
        await safeRecordFailure(req.user!.id, req.tenantId, reviewId, 'extracted text too short');
        throw new ValidationError(
          'Extracted document text was too short to analyse (less than 200 characters). Please verify the file is text-bearing.',
        );
      }

      // Step 4 — fetch playbook
      const playbookRaw = await db.callFunction<{
        id: number;
        agreementType: string;
        nameEn: string;
        clauses: PlaybookClauseInput[];
      } | null>(
        'fn_tpa_playbook_get',
        [req.user!.id, playbookId],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      if (!playbookRaw) {
        await safeRecordFailure(req.user!.id, req.tenantId, reviewId, 'playbook fetch failed');
        throw new NotFoundError('Playbook not found');
      }
      const playbook: PlaybookInput = {
        id: playbookRaw.id,
        agreementType: playbookRaw.agreementType,
        name: playbookRaw.nameEn,
        clauses: playbookRaw.clauses ?? [],
      };

      // Step 5 — run LLM analysis
      let analysis;
      try {
        analysis = await analyseAgreementAgainstPlaybook({
          agreementText: extracted.text,
          playbook,
          counterpartyName,
          agreementTitle,
          actorUserId: req.user!.id,
          reviewId,
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        await safeRecordFailure(req.user!.id, req.tenantId, reviewId, `analysis failed: ${msg}`);
        throw err;
      }

      // Step 6 — persist findings
      const persistResult = await db.callFunction<{
        reviewId: number;
        findingsCount: number;
        acceptCount: number;
        amendCount: number;
        rejectCount: number;
      }>(
        'fn_tpa_review_record_analysis',
        [
          req.user!.id,
          reviewId,
          JSON.stringify(analysis.findings),
          analysis.overallVerdict,
          analysis.overallRisk,
          analysis.riskScore,
          analysis.executiveSummary,
          analysis.modelVersion,
          analysis.promptHash,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'tpa.upload.completed',
        reviewId,
        referenceCode,
        durationMs: Date.now() - startTime,
        findingsCount: persistResult?.findingsCount ?? 0,
      });

      res.status(201).json({
        id: reviewId,
        referenceCode,
        status: 'awaiting_review',
        overallVerdict: analysis.overallVerdict,
        overallRisk: analysis.overallRisk,
        riskScore: analysis.riskScore,
        acceptCount: persistResult?.acceptCount ?? 0,
        amendCount: persistResult?.amendCount ?? 0,
        rejectCount: persistResult?.rejectCount ?? 0,
      });
    } catch (err) {
      req.logger.error({
        action: 'tpa.upload.failed',
        userId: req.user?.id,
        durationMs: Date.now() - startTime,
        errorType: (err as Error).name,
      });
      next(err);
    }
  },

  // ============================================================
  // GET /reviews — paginated list
  // ============================================================
  listReviews: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const status = typeof req.query.status === 'string' ? req.query.status : '';
      const limit = parseNum(req.query.limit) ?? REVIEW_LIST_LIMIT;
      const offset = parseNum(req.query.offset) ?? 0;
      const result = await db.callFunction<unknown>(
        'fn_tpa_review_list',
        [req.user!.id, status, limit, offset],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (err) {
      next(err);
    }
  },

  // ============================================================
  // GET /reviews/:id — detail
  // ============================================================
  getReview: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (!Number.isFinite(id) || id <= 0) throw new ValidationError('Invalid review id');
      const result = await db.callFunction<unknown>(
        'fn_tpa_review_get_by_id',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (err) {
      next(err);
    }
  },

  // ============================================================
  // PATCH /reviews/:id/findings/:findingId
  // ============================================================
  updateFinding: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const findingId = parseInt(req.params.findingId ?? '', 10);
      if (!Number.isFinite(findingId) || findingId <= 0) {
        throw new ValidationError('Invalid finding id');
      }
      const body = req.body as Record<string, unknown>;
      const result = await db.callFunction<{ findingId: number; reviewId: number }>(
        'fn_tpa_finding_update_verdict',
        [
          req.user!.id, findingId,
          body.userVerdict ? String(body.userVerdict) : null,
          body.userRedline ? String(body.userRedline) : null,
          body.userNotes ? String(body.userNotes) : null,
          body.resolutionStatus ? String(body.resolutionStatus) : null,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (err) {
      next(err);
    }
  },

  // ============================================================
  // POST /reviews/:id/status
  // ============================================================
  setStatus: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (!Number.isFinite(id) || id <= 0) throw new ValidationError('Invalid review id');
      const body = req.body as Record<string, unknown>;
      const status = body.status ? String(body.status) : '';
      const notes = body.notes ? String(body.notes) : null;
      const result = await db.callFunction<{ reviewId: number; status: string }>(
        'fn_tpa_review_set_status',
        [req.user!.id, id, status, notes],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );
      res.json(result);
    } catch (err) {
      next(err);
    }
  },

  // ============================================================
  // GET /reviews/:id/redline.docx — stream DOCX
  // ============================================================
  downloadRedline: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (!Number.isFinite(id) || id <= 0) throw new ValidationError('Invalid review id');

      const review = await db.callFunction<{
        id: number;
        referenceCode: string;
        counterpartyName: string;
        agreementTitle: string;
        agreementType: string;
        overallVerdict: 'accept' | 'amend' | 'reject' | null;
        overallRisk: 'low' | 'medium' | 'high' | 'critical' | null;
        riskScore: number | null;
        executiveSummary: string | null;
        acceptCount: number;
        amendCount: number;
        rejectCount: number;
        playbook: { nameEn: string } | null;
        createdByName: string | null;
        findings: Array<{
          clauseTitle: string;
          displayOrder: number;
          extractedText: string | null;
          extractedLocation: string | null;
          aiVerdict: 'accept' | 'amend' | 'reject' | 'missing' | 'info';
          userVerdict: 'accept' | 'amend' | 'reject' | 'missing' | 'info' | null;
          aiRationale: string | null;
          aiSuggestedRedline: string | null;
          userRedline: string | null;
          userNotes: string | null;
          playbookStandard?: string | null;
          playbookFallback?: string | null;
        }>;
      } | null>(
        'fn_tpa_review_get_by_id',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!review) throw new NotFoundError('Review not found');

      const { buffer, fileName } = await buildRedlineDocx({
        header: {
          referenceCode: review.referenceCode,
          counterpartyName: review.counterpartyName,
          agreementTitle: review.agreementTitle,
          agreementType: review.agreementType,
          overallVerdict: review.overallVerdict,
          overallRisk: review.overallRisk,
          riskScore: review.riskScore,
          executiveSummary: review.executiveSummary,
          acceptCount: review.acceptCount,
          amendCount: review.amendCount,
          rejectCount: review.rejectCount,
          playbookNameEn: review.playbook?.nameEn ?? null,
          generatedAt: new Date(),
          generatedByName: review.createdByName ?? 'ADNOC Legal Affairs',
        },
        findings: review.findings ?? [],
      });

      res.setHeader(
        'Content-Type',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
      res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
      res.setHeader('Content-Length', String(buffer.length));
      res.send(buffer);
    } catch (err) {
      next(err);
    }
  },
};

// ----------------------------------------------------------------
// Internal helpers
// ----------------------------------------------------------------

function parseNum(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  const s = typeof v === 'string' ? v.trim() : '';
  if (!s) return null;
  const n = parseInt(s, 10);
  return Number.isFinite(n) ? n : null;
}

async function safeRecordFailure(
  actorId: number,
  tenantId: string | undefined,
  reviewId: number,
  error: string,
): Promise<void> {
  try {
    await db.callFunction(
      'fn_tpa_review_record_failure',
      [actorId, reviewId, error],
      { actorId, tenantId },
    );
  } catch {
    // non-fatal
  }
}
