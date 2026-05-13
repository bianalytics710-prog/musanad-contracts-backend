/**
 * Unit-3 / R-CES — Compliance & ESG persona action controllers.
 *
 * Routes handled:
 *   POST /api/v1/compliance/contracts/:contractId/raise-flag
 *   POST /api/v1/compliance/contracts/:contractId/supplier-audit
 *   POST /api/v1/compliance/contracts/:contractId/recommend-hold
 *   POST /api/v1/compliance/contracts/:contractId/recommend-termination
 *   POST /api/v1/compliance/contracts/:contractId/icv-certificate  (multipart)
 *
 * Permission:
 *   raise-flag / supplier-audit / recommend-hold / recommend-termination:
 *     risk.acknowledge
 *   icv-certificate:
 *     contract.edit (uploading attachment — same as other contract_attachment writes)
 *
 * Audit: fn_audit_log_record_v2 via persona-actions.service.
 * Upload: Supabase Storage (existing pattern from contract-attachment.controller).
 *
 * Pattern: Route → Controller → service → db.callFunction → JSONB response.
 * No business logic in this file. One service call per handler (except ICV
 * which needs upload + DB insert + audit_log — three calls).
 */
import type { NextFunction, Request, Response } from 'express';
import { ADNOC_TENANT_ID } from '../middleware/rls.middleware';
import { personaActionsService } from '../services/persona-actions.service';
import { db } from '../database/client';
import { buildStoragePath, uploadAttachment, deleteAttachment } from '../services/supabase-storage.service';
import { ValidationError } from '../utils/errors.util';
import type {
  ComplianceRaiseFlagBody,
  ComplianceSupplierAuditBody,
  ComplianceRecommendHoldBody,
  ComplianceRecommendTerminationBody,
  ComplianceIcvCertificateBody,
  ContractIdPersonaParam,
} from '../schemas/persona-actions.schemas';

// ---------------------------------------------------------------------------
// Raise compliance flag
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/compliance/contracts/:contractId/raise-flag
 * Perm: risk.acknowledge.
 * Returns flagId = audit_log.id of the inserted row (synthetic handle for v1).
 */
export const raiseComplianceFlag = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'sanctions_flag_raised',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { flagKind, severity, note } = req.body as ComplianceRaiseFlagBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.raiseComplianceFlag(
      actorId,
      contractIdNum,
      flagKind,
      severity,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'sanctions_flag_raised',
      userId: actorId,
      contractId: contractIdNum,
      flagKind,
      severity,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'sanctions_flag_raised',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Initiate supplier audit
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/compliance/contracts/:contractId/supplier-audit
 * Perm: risk.acknowledge.
 */
export const initiateSupplierAudit = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'supplier_audit_initiated',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { scope, targetDate, note } = req.body as ComplianceSupplierAuditBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.initiateSupplierAudit(
      actorId,
      contractIdNum,
      scope,
      targetDate,
      note,
      tenantId,
    );

    req.logger.info({
      action: 'supplier_audit_initiated',
      userId: actorId,
      contractId: contractIdNum,
      scope,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'supplier_audit_initiated',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Recommend hold
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/compliance/contracts/:contractId/recommend-hold
 * Perm: risk.acknowledge.
 */
export const recommendHold = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'hold_recommended',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { reason, proposedHoldUntil } = req.body as ComplianceRecommendHoldBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.recommendHold(
      actorId,
      contractIdNum,
      reason,
      proposedHoldUntil,
      tenantId,
    );

    req.logger.info({
      action: 'hold_recommended',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'hold_recommended',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Recommend termination
// ---------------------------------------------------------------------------

/**
 * POST /api/v1/compliance/contracts/:contractId/recommend-termination
 * Perm: risk.acknowledge.
 */
export const recommendTermination = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'termination_recommended',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const { reason, grounds } = req.body as ComplianceRecommendTerminationBody;
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    const result = await personaActionsService.recommendTermination(
      actorId,
      contractIdNum,
      reason,
      grounds,
      tenantId,
    );

    req.logger.info({
      action: 'termination_recommended',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'termination_recommended',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};

// ---------------------------------------------------------------------------
// Upload ICV certificate (multipart)
// ---------------------------------------------------------------------------

interface AttachmentCreateIcvResult {
  id: number;
  contractId: number;
}

/**
 * POST /api/v1/compliance/contracts/:contractId/icv-certificate
 * Perm: contract.edit (same gate as other contract_attachment writes).
 * Body: multipart/form-data — `file` (PDF/PNG/JPG) + `validUntil` (YYYY-MM-DD optional).
 *
 * Upload flow:
 *   1. Validate file present
 *   2. Build description: 'valid_until=YYYY-MM-DD <filename>' when validUntil provided
 *   3. Upload to Supabase contract-attachments bucket
 *   4. Insert contract_attachment row via fn_contract_attachment_create with kind='icv_certificate'
 *   5. Write audit_log via fn_audit_log_record_v2 (icv_certificate_uploaded)
 */
export const uploadIcvCertificate = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const actorId = req.user!.id;
  const { contractId } = req.params as unknown as ContractIdPersonaParam;
  const contractIdNum = Number(contractId);

  req.logger.info({
    action: 'icv_certificate_uploaded',
    method: req.method,
    path: req.path,
    userId: actorId,
    contractId: contractIdNum,
  });

  try {
    const file = (req as Request & { file?: Express.Multer.File }).file;
    if (!file) {
      throw new ValidationError('File is required', { file: 'File is required' });
    }

    // Validate validUntil from body (already parsed by Zod middleware)
    const { validUntil } = req.body as ComplianceIcvCertificateBody;

    const filename = file.originalname || 'icv-certificate';
    const tenantId = req.tenantId ?? ADNOC_TENANT_ID;

    // Build description so fn_dashboard_compliance_esg can parse expiry
    const description = validUntil
      ? `valid_until=${validUntil} ${filename}`
      : `icv_certificate ${filename}`;

    // Upload to Supabase storage
    const storagePath = buildStoragePath(contractIdNum, filename);
    await uploadAttachment({
      storagePath,
      buffer: file.buffer,
      mimeType: file.mimetype || 'application/octet-stream',
    });

    // Insert contract_attachment row then UPDATE kind='icv_certificate'.
    // fn_contract_attachment_create has 7 params (no kind param) — migration 196
    // added the kind column with DEFAULT 'general'. We UPDATE kind immediately
    // after insert within the same executeInTransaction call so it is atomic.
    let attachmentId: number;
    try {
      attachmentId = await db.executeInTransaction(async (client) => {
        // Set GUCs for RLS
        await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
        await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);

        // Insert attachment row (kind defaults to 'general' at DB level)
        const insertResult = await client.query<{ result: AttachmentCreateIcvResult }>(
          `SELECT fn_contract_attachment_create($1,$2,$3,$4,$5,$6,$7) AS result`,
          [contractIdNum, filename, file!.mimetype || 'application/octet-stream', file!.size, storagePath, description, actorId],
        );
        const inserted = insertResult.rows[0]?.result;
        if (!inserted?.id) {
          throw new Error('fn_contract_attachment_create returned no id');
        }
        // UPDATE kind to 'icv_certificate'
        await client.query(
          `UPDATE contract_attachment SET kind = 'icv_certificate' WHERE id = $1`,
          [inserted.id],
        );
        return inserted.id;
      });
    } catch (dbErr) {
      // Rollback orphaned blob if DB operation fails
      await deleteAttachment(storagePath);
      throw dbErr;
    }

    // Write audit_log for ICV cert upload
    await personaActionsService.logIcvCertificateUpload(
      actorId,
      contractIdNum,
      attachmentId,
      filename,
      validUntil,
      tenantId,
    );

    req.logger.info({
      action: 'icv_certificate_uploaded',
      userId: actorId,
      contractId: contractIdNum,
      attachmentId,
      sizeBytes: file.size,
      duration: Date.now() - startTime,
      statusCode: 201,
    });

    res.status(201).json({
      success: true,
      data: {
        attachmentId,
        contractId: String(contractIdNum),
        kind: 'icv_certificate' as const,
        ...(validUntil !== undefined ? { validUntil } : {}),
      },
    });
  } catch (error) {
    req.logger.error({
      action: 'icv_certificate_uploaded',
      userId: actorId,
      contractId: contractIdNum,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
