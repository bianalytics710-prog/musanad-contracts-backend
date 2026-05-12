/**
 * M11 — Document Ingestion controller.
 *
 * Endpoints:
 *   POST /:id/versions/:vId/ingest        → manualIngest
 *   GET  /:id/versions/:vId/extracted-text → getExtractedTextSignedUrl
 *   GET  /:id/versions/:vId/ingestion-status → getIngestionStatus
 *
 * SENSITIVE FIELDS (never logged):
 *   extractedTextUri — Pino redact path covers it (M11_SENSITIVE_FIELD_EXTENSIONS).
 *   ingestionError   — Pino redact path covers it.
 *
 * Per ac-contracts.json ep_extracted_text_signed_url §controllerLogic:
 *   TTL is exactly 60 seconds (AC-S8-01 locked).
 *   409 if ingestionStatus NOT IN ('complete').
 *
 * Per ep_ingestion_status_poll §controllerLogic:
 *   NULL from fn → 404.
 *   extractedTextUri returned in body but MUST NOT appear in any log call.
 */

import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError, ConflictError, NotFoundError } from '../utils/errors.util';
import { signDownloadUrl } from '../services/supabase-storage.service';
import { ContractVersionParamsSchema } from '../schemas/document-ingestion.schemas';
import type {
  IngestionQueuedResponse,
  IngestionStatusResponse,
  SignedExtractedTextUrlResponse,
} from '../types/document-ingestion.types';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const documentIngestionController = {
  /**
   * POST /api/v1/contracts/:id/versions/:vId/ingest
   *
   * Manual trigger to (re-)queue a contract_version for text extraction.
   * Gated by document.ingest (Super Admin only per OPEN-DECISION-L).
   */
  async manualIngest(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'fn_contract_version_ingest',
        method: req.method,
        path: req.path,
        userId: req.user?.id,
      },
      'Controller entry',
    );

    try {
      const params = ContractVersionParamsSchema.parse(req.params);
      const userId = req.user!.id;
      const tenantId = (req.user as { tenantId?: string })?.tenantId ?? ADNOC_TENANT_ID;

      const result = await db.callFunction<IngestionQueuedResponse>(
        'fn_contract_version_ingest',
        [params.vId],
        { actorId: userId, tenantId },
      );

      req.logger.info(
        {
          action: 'fn_contract_version_ingest',
          userId,
          contractVersionId: params.vId,
          alreadyInProgress: result?.alreadyInProgress,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );

      res.status(201).json({ success: true, data: result });
    } catch (error) {
      req.logger.error(
        {
          action: 'fn_contract_version_ingest',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: (error as Error).name,
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/contracts/:id/versions/:vId/extracted-text
   *
   * Returns a 60s signed Supabase Storage URL for the extracted text file.
   * Uses fn_contract_version_ingestion_status as state guard.
   * 409 if extraction not complete. 404 if not found.
   *
   * SENSITIVE: extractedTextUri MUST NOT appear in any log call.
   */
  async getExtractedTextSignedUrl(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'fn_contract_version_ingestion_status',
        method: req.method,
        path: req.path,
        userId: req.user?.id,
        subAction: 'extracted_text_url',
      },
      'Controller entry',
    );

    try {
      const params = ContractVersionParamsSchema.parse(req.params);
      const userId = req.user!.id;
      const tenantId = (req.user as { tenantId?: string })?.tenantId ?? ADNOC_TENANT_ID;

      // Step 1: Get ingestion status — NULL if RLS-invisible
      const status = await db.callFunction<IngestionStatusResponse | null>(
        'fn_contract_version_ingestion_status',
        [params.vId],
        { actorId: userId, tenantId },
      );

      if (!status) {
        throw new NotFoundError('contract_version not found', {
          contractVersionId: 'contract_version not found',
        });
      }

      // Step 2: 409 if not complete
      if (status.ingestionStatus !== 'complete') {
        throw new ConflictError('extraction not complete', {
          ingestionStatus: 'extraction not complete',
        });
      }

      // Step 3: 404 if URI missing (shouldn't happen post-backfill)
      if (!status.extractedTextUri) {
        throw new NotFoundError('extracted text not available', {
          extractedTextUri: 'extracted text not available',
        });
      }

      // Step 4: Generate signed URL (TTL = 60s per AC-S8-01)
      const signedUrl = await signDownloadUrl({
        storagePath: status.extractedTextUri,
        filename: `extracted-text-v${params.vId}.txt`,
        ttlSeconds: 60,
      });

      const expiresAt = new Date(Date.now() + 60_000).toISOString();

      const responseBody: SignedExtractedTextUrlResponse = {
        signedUrl,
        expiresAt,
        ttlSeconds: 60,
      };

      req.logger.info(
        {
          action: 'fn_contract_version_ingestion_status',
          userId,
          contractVersionId: params.vId,
          subAction: 'extracted_text_url',
          duration: Date.now() - startTime,
          statusCode: 200,
          // NOTE: signedUrl and extractedTextUri are NOT logged here
        },
        'Controller exit',
      );

      res.status(200).json({ success: true, data: responseBody });
    } catch (error) {
      req.logger.error(
        {
          action: 'fn_contract_version_ingestion_status',
          userId: req.user?.id,
          subAction: 'extracted_text_url',
          duration: Date.now() - startTime,
          errorType: (error as Error).name,
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/contracts/:id/versions/:vId/ingestion-status
   *
   * Returns current ingestion lifecycle status for FE polling.
   * NULL from fn → 404. SENSITIVE fields (extractedTextUri, ingestionError)
   * are in the Pino redact list — never log them explicitly.
   */
  async getIngestionStatus(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'fn_contract_version_ingestion_status',
        method: req.method,
        path: req.path,
        userId: req.user?.id,
      },
      'Controller entry',
    );

    try {
      const params = ContractVersionParamsSchema.parse(req.params);
      const userId = req.user!.id;
      const tenantId = (req.user as { tenantId?: string })?.tenantId ?? ADNOC_TENANT_ID;

      const result = await db.callFunction<IngestionStatusResponse | null>(
        'fn_contract_version_ingestion_status',
        [params.vId],
        { actorId: userId, tenantId },
      );

      if (!result) {
        throw new NotFoundError('contract_version not found', {
          contractVersionId: 'contract_version not found',
        });
      }

      req.logger.info(
        {
          action: 'fn_contract_version_ingestion_status',
          userId,
          contractVersionId: params.vId,
          ingestionStatus: result.ingestionStatus,
          extractionEngine: result.extractionEngine,
          duration: Date.now() - startTime,
          statusCode: 200,
          // NOTE: extractedTextUri and ingestionError are NOT logged here
        },
        'Controller exit',
      );

      res.status(200).json({ success: true, data: result });
    } catch (error) {
      req.logger.error(
        {
          action: 'fn_contract_version_ingestion_status',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: (error as Error).name,
        },
        'Controller error',
      );
      next(error);
    }
  },
};

// Satisfy compiler — ApiError is used via ConflictError/NotFoundError
void ApiError;
