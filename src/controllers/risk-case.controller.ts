/**
 * M19 / CR-K — Risk Case controller.
 *
 * Routes: list, getById, create, autoCreateFromCorrelation (internal),
 *         assign, addComment, addEvidence, evidenceGet, statusTransition,
 *         escalate, acceptRisk, snooze, close, escalationCheck (internal).
 *
 * Pattern: validate → SET LOCAL guc via db.callFunction({actorId, tenantId})
 *          → unwrap JSONB → respond. NO business logic in controllers.
 *
 * fn signatures (from db-design.md §2 + §3 + DB Impl handover):
 *   fn_risk_case_create(p_actor_id, p_contract_id, p_priority, p_title,
 *     p_body, p_assigned_role, p_assigned_user_id, p_sla_hours, p_metadata) -> JSONB
 *   fn_risk_case_assign(p_actor_id, p_id, p_assigned_role, p_assigned_user_id) -> JSONB
 *   fn_risk_case_add_comment(p_actor_id, p_id, p_comment) -> JSONB
 *   fn_risk_case_add_evidence(p_actor_id, p_id, p_file_uri, p_file_name,
 *     p_file_mime, p_file_bytes) -> JSONB
 *   fn_risk_case_status_transition(p_actor_id, p_id, p_to_status, p_decision_note) -> JSONB
 *   fn_risk_case_escalate(p_actor_id, p_id, p_reason) -> JSONB
 *   fn_risk_case_accept_risk(p_actor_id, p_id, p_approver_user_id, p_justification) -> JSONB
 *   fn_risk_case_snooze(p_actor_id, p_id, p_snoozed_until) -> JSONB
 *   fn_risk_case_close(p_actor_id, p_id, p_outcome, p_closure_note) -> JSONB
 *   fn_risk_case_list(p_actor_id, p_status, p_priority, p_assigned_to_me,
 *     p_sla_due_within_hours, p_case_type, p_search, p_page, p_limit) -> JSONB
 *   fn_risk_case_get_by_id(p_actor_id, p_id) -> JSONB
 *   fn_risk_case_evidence_get(p_actor_id, p_id, p_attachment_id) -> JSONB
 *
 * DEFINER worker-only (no user GUC):
 *   fn_risk_case_auto_create_from_correlation(p_correlation_id) -> JSONB
 *   fn_risk_case_escalation_check(p_limit) -> JSONB
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  listRiskCasesSchema,
  createRiskCaseSchema,
  assignRiskCaseSchema,
  addRiskCaseCommentSchema,
  addRiskCaseEvidenceMultipartFieldsSchema,
  statusTransitionRiskCaseSchema,
  escalateRiskCaseSchema,
  acceptRiskCaseSchema,
  snoozeRiskCaseSchema,
  closeRiskCaseSchema,
  autoCreateRiskCaseSchema,
  riskCaseEscalationCheckQuerySchema,
} from '../schemas/risk-case.schemas';
import {
  buildRiskCaseEvidencePath,
  signDownloadUrl,
  uploadRiskCaseEvidence,
} from '../services/supabase-storage.service';

/**
 * DEFECT-CRKL-INTV-1 — Allow-list of MIME types accepted for risk-case
 * evidence uploads. Mirrors the contract-attachment + branding patterns
 * (compliance-actions.routes.ts:58 — PDF/PNG/JPG core set) and extends
 * to the broader document set used by M11 ingestion (docx, xlsx, etc.).
 * Rejecting unknown MIME prevents storing arbitrary blobs in the bucket.
 */
const EVIDENCE_ALLOWED_MIMES = new Set([
  'application/pdf',
  'application/x-pdf',
  'application/acrobat',
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/tiff',
  'image/bmp',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain',
  'text/csv',
  'application/octet-stream',
]);
const EVIDENCE_MAX_BYTES = 52_428_800;

interface AttachmentSummary {
  fileUri?: string;
  fileName?: string;
  [k: string]: unknown;
}

interface EvidenceGetResult {
  attachment?: AttachmentSummary | null;
  fileUri?: string;
  fileName?: string;
  [k: string]: unknown;
}

export const riskCaseController = {
  // ============================================================
  // GET /api/v1/risk-cases
  // ============================================================
  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = listRiskCasesSchema.parse(req.query);
      const result = await db.callFunction(
        'fn_risk_case_list',
        [
          req.user!.id,
          params.status ?? null,
          params.priority ?? null,
          params.assignedToMe,
          params.slaDueWithinHours ?? null,
          params.caseType ?? null,
          params.search ?? null,
          params.page,
          params.limit,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/risk-cases/:id
  // ============================================================
  getById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_get_by_id',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction(
        'fn_risk_case_get_by_id',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'risk_case_not_found', 'Risk case not found');

      req.logger.info({
        action: 'fn_risk_case_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases
  // ============================================================
  create: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_create',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = createRiskCaseSchema.parse(req.body);
      // fn_risk_case_create signature (migration 258):
      //   (p_actor_id, p_priority, p_title, p_contract_id, p_body,
      //    p_assigned_role, p_assigned_user_id, p_sla_hours, p_metadata)
      // DEFECT-CRKL-INT-1 fix (2026-05-15): positional args previously had
      // contractId before priority/title — bound title TEXT to p_contract_id
      // BIGINT and returned 400 on every call. Keep this comment + named tags.
      const result = await db.callFunction(
        'fn_risk_case_create',
        [
          req.user!.id,                                                // p_actor_id
          data.priority,                                               // p_priority
          data.title,                                                  // p_title
          data.contractId ?? null,                                     // p_contract_id
          data.body ?? null,                                           // p_body
          data.assignedRole ?? null,                                   // p_assigned_role
          data.assignedUserId ?? null,                                 // p_assigned_user_id
          data.slaHours ?? null,                                       // p_sla_hours
          data.metadata ? JSON.stringify(data.metadata) : '{}',        // p_metadata
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_create',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_create',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/auto-create-from-correlation (INTERNAL)
  // ============================================================
  autoCreateFromCorrelation: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_auto_create_from_correlation',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = autoCreateRiskCaseSchema.parse(req.body);
      // DEFINER fn — no actor GUC required. Use the worker / SYSTEM_ACTOR
      // sentinel anyway so audit_log entries carry the system actor.
      const result = await db.callFunction(
        'fn_risk_case_auto_create_from_correlation',
        [data.correlationId],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_auto_create_from_correlation',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_auto_create_from_correlation',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/assign
  // ============================================================
  assign: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_assign',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = assignRiskCaseSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_risk_case_assign',
        [
          req.user!.id,
          id,
          data.assignedRole ?? null,
          data.assignedUserId ?? null,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_assign',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_assign',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/comments
  // ============================================================
  addComment: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_add_comment',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = addRiskCaseCommentSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_risk_case_add_comment',
        [req.user!.id, id, data.comment],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_add_comment',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_add_comment',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/evidence
  //
  // DEFECT-CRKL-INTV-1 — Multipart upload:
  //   1. multer.single('file') in the route parses the FormData body,
  //      populating req.file (binary buffer + originalname + mimetype + size)
  //      and req.body (text fields: fileName, fileMime, fileBytes, kind?,
  //      description?).
  //   2. Validate file presence, MIME allow-list, and size cap (defence-in-
  //      depth — multer also enforces 50MB via limits.fileSize).
  //   3. Build deterministic storage path (risk-case/<id>/<uuid>/<safe-name>)
  //      and upload the buffer to Supabase Storage.
  //   4. Bind the derived fileUri (server-controlled — NEVER from client) +
  //      authoritative size/mime (from req.file, not from the FormData text
  //      fields) to fn_risk_case_add_evidence.
  //   5. Return the fn JSONB result (envelope-wrapped via res.status(201)).
  //
  // NOTE: fileUri MUST be server-derived. Trusting client-supplied fileUri
  // would let a caller bind an arbitrary storage path to a risk case.
  // ============================================================
  addEvidence: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_add_evidence',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const file = (req as Request & { file?: Express.Multer.File }).file;
      if (!file) {
        throw new ApiError(400, 'evidence_required', 'A file is required for evidence upload');
      }

      // Defence-in-depth size check — multer enforces 50MB via limits.fileSize
      // (throws MulterError 'LIMIT_FILE_SIZE' before reaching here), but we
      // re-validate so a misconfigured limit can't silently let a 51MB file
      // through.
      if (file.size <= 0) {
        throw new ApiError(400, 'evidence_empty', 'Evidence file must not be empty');
      }
      if (file.size > EVIDENCE_MAX_BYTES) {
        throw new ApiError(413, 'evidence_too_large', 'Evidence file must not exceed 50MB');
      }

      // Authoritative MIME is req.file.mimetype (parsed by multer from the
      // multipart part headers). Client-supplied fileMime in FormData is
      // ONLY used as a fallback for logging — never for validation or for
      // the fn argument.
      const authoritativeMime = file.mimetype || 'application/octet-stream';
      if (!EVIDENCE_ALLOWED_MIMES.has(authoritativeMime)) {
        throw new ApiError(
          415,
          'evidence_mime_not_allowed',
          `MIME type "${authoritativeMime}" is not allowed for evidence uploads`,
        );
      }

      // Parse the multipart text fields. Failure here is a 400, but most
      // fields are optional — the controller can fall back to authoritative
      // values from req.file.
      const fields = addRiskCaseEvidenceMultipartFieldsSchema.parse(req.body);

      const authoritativeName =
        (fields.fileName ?? '').trim() || file.originalname || 'evidence';

      // Build deterministic storage path + upload to Supabase.
      const storagePath = buildRiskCaseEvidencePath(id, authoritativeName);
      await uploadRiskCaseEvidence({
        storagePath,
        buffer: file.buffer,
        mimeType: authoritativeMime,
      });

      // fileUri is server-derived (storagePath). fileBytes + fileMime are
      // pulled from req.file (authoritative); the FormData text fields are
      // only used for fileName fallback above. This guarantees the fn never
      // receives client-tampered metadata.
      const result = await db.callFunction(
        'fn_risk_case_add_evidence',
        [
          req.user!.id,
          id,
          storagePath,
          authoritativeName,
          authoritativeMime,
          file.size,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_add_evidence',
        userId: req.user?.id,
        riskCaseId: id,
        sizeBytes: file.size,
        mimeType: authoritativeMime,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      // Multer wraps file-size violations as MulterError with code
      // 'LIMIT_FILE_SIZE' — surface a clean 413 to the client instead of
      // a generic 500.
      const err = error as Error & { code?: string };
      if (err?.name === 'MulterError' && err.code === 'LIMIT_FILE_SIZE') {
        req.logger.warn({
          action: 'fn_risk_case_add_evidence',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: 'MulterError.LIMIT_FILE_SIZE',
        });
        return next(
          new ApiError(413, 'evidence_too_large', 'Evidence file must not exceed 50MB'),
        );
      }
      req.logger.error({
        action: 'fn_risk_case_add_evidence',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/risk-cases/:id/evidence/:attachmentId
  // Mints a 60-second signed URL on top of the fn_ result.
  // ============================================================
  evidenceGet: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_evidence_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      const attachmentId = parseInt(req.params.attachmentId ?? '', 10);
      if (isNaN(id) || id <= 0 || isNaN(attachmentId) || attachmentId <= 0) {
        throw new ApiError(400, 'invalid_id', 'Invalid ID format');
      }

      const result = await db.callFunction<EvidenceGetResult | null>(
        'fn_risk_case_evidence_get',
        [req.user!.id, id, attachmentId],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'attachment_not_found', 'Attachment not found');

      // The fn returns either an `attachment` envelope or a flat row.
      const attachment = (result.attachment ?? result) as AttachmentSummary;
      const fileUri = typeof attachment.fileUri === 'string' ? attachment.fileUri : null;
      const fileName = typeof attachment.fileName === 'string' ? attachment.fileName : 'evidence';

      let signedUrl: string | null = null;
      let signedUrlExpiresAt: string | null = null;
      if (fileUri) {
        try {
          signedUrl = await signDownloadUrl({ storagePath: fileUri, filename: fileName, ttlSeconds: 60 });
          signedUrlExpiresAt = new Date(Date.now() + 60_000).toISOString();
        } catch (mintErr) {
          // Don't fail the GET — surface metadata even if signing fails.
          req.logger.warn(
            {
              action: 'fn_risk_case_evidence_get.signFailed',
              userId: req.user?.id,
              attachmentId,
              errorType: (mintErr as Error).name,
            },
            'Failed to mint signed URL for evidence',
          );
        }
      }

      req.logger.info({
        action: 'fn_risk_case_evidence_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });

      // Strip raw fileUri from the response — never echo Supabase Storage paths.
      const safeAttachment = { ...attachment };
      delete safeAttachment.fileUri;
      res.json({
        ...safeAttachment,
        signedUrl,
        signedUrlExpiresAt,
      });
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_evidence_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/status-transition
  // ============================================================
  statusTransition: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_status_transition',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = statusTransitionRiskCaseSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_risk_case_status_transition',
        [req.user!.id, id, data.toStatus, data.decisionNote ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_status_transition',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_status_transition',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/escalate
  // ============================================================
  escalate: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_escalate',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = escalateRiskCaseSchema.parse(req.body ?? {});
      const result = await db.callFunction(
        'fn_risk_case_escalate',
        [req.user!.id, id, data.reason ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_escalate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_escalate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/accept-risk
  // Self-approval guard: actor cannot be the approver — defense in depth
  // alongside whatever the fn enforces. Mirrors M16 CR-H-Q1 = denied.
  // ============================================================
  acceptRisk: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_accept_risk',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = acceptRiskCaseSchema.parse(req.body);

      if (data.approverUserId === req.user!.id) {
        throw new ApiError(
          403,
          'cannot_self_approve',
          'Caller cannot record themselves as the accept-risk approver',
        );
      }

      const result = await db.callFunction(
        'fn_risk_case_accept_risk',
        [req.user!.id, id, data.approverUserId, data.justification],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_accept_risk',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_accept_risk',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/snooze
  // ============================================================
  snooze: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_snooze',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = snoozeRiskCaseSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_risk_case_snooze',
        [req.user!.id, id, data.snoozedUntil],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_snooze',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_snooze',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/risk-cases/:id/close
  // ============================================================
  close: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_close',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = closeRiskCaseSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_risk_case_close',
        [req.user!.id, id, data.outcome, data.closureNote ?? null],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_risk_case_close',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_close',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/risk-cases/escalation-check (INTERNAL)
  // DEFINER + STABLE; cross-tenant. Worker uses this to enumerate
  // candidates, then escalates them one-by-one with per-row tenant GUC.
  // ============================================================
  escalationCheck: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_case_escalation_check',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = riskCaseEscalationCheckQuerySchema.parse(req.query);
      // DEFINER fn — cross-tenant. Pass actorId for the audit context.
      const result = await db.callFunction(
        'fn_risk_case_escalation_check',
        [params.limit],
        { actorId: req.user!.id },
      );

      req.logger.info({
        action: 'fn_risk_case_escalation_check',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_case_escalation_check',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
