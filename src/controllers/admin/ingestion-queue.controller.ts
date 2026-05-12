/**
 * M11 — Admin Ingestion Queue controller.
 *
 * Endpoints:
 *   GET  /admin/ingestion-queue           → list
 *   POST /admin/ingestion-queue/:id/resolve → resolve
 *
 * SENSITIVE FIELDS:
 *   finalText — Pino-redacted at controller boundary. Returned in response
 *               body to authorised reviewer but NEVER logged.
 *   correctedText — Pino-redacted in request body logging.
 *
 * Error translation for fn_ingestion_review_resolve:
 *   P0002 → 404 (queue item not found / RLS-invisible)
 *   22023 with 'action:' prefix → 400 (invalid action)
 *   22023 with 'correctedText:' prefix → 400 (missing correctedText)
 *   22023 with 'reviewStatus:' prefix → 409 (already resolved)
 *   42501 → 403 (missing document.review permission)
 *
 * Note: db.callFunction's translatePgError handles P0002 → 404 and
 * 42501 → 403 automatically. The 22023 'reviewStatus:' → 409 remapping
 * is handled by the structured-raise regex in translatePgError matching
 * 'reviewStatus' as the field prefix. The translatePgError in client.ts
 * routes 22023 structured raises to 400 by default; BUT for 'reviewStatus:'
 * prefix the message 'queue item already resolved' → ConflictError per
 * structured-field routing (CONFLICT_FIELD_PREFIXES doesn't include it,
 * so we catch and re-throw as ConflictError if needed in the controller).
 */

import type { NextFunction, Request, Response } from 'express';
import { adminIngestionQueueService } from '../../services/admin-ingestion-queue.service';
import { ConflictError } from '../../utils/errors.util';
import {
  AdminIngestionQueueListQuerySchema,
  AdminIngestionQueueIdParamSchema,
  IngestionResolveBodySchema,
} from '../../schemas/admin-ingestion-queue.schemas';
import type { AdminIngestionQueueListResponse } from '../../types/admin-ingestion-queue.types';
import type { IngestionResolveResult } from '../../types/document-ingestion.types';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const ingestionQueueController = {
  /**
   * GET /api/v1/admin/ingestion-queue
   *
   * Paginated admin monitor. Gated by document.review OR ingestion_queue.read.
   */
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'fn_ingestion_review_queue_list',
        method: req.method,
        path: req.path,
        userId: req.user?.id,
      },
      'Controller entry',
    );

    try {
      const query = AdminIngestionQueueListQuerySchema.parse(req.query);
      const userId = req.user!.id;
      const tenantId = (req.user as { tenantId?: string })?.tenantId ?? ADNOC_TENANT_ID;

      const result: AdminIngestionQueueListResponse = await adminIngestionQueueService.list(
        query,
        tenantId,
        userId,
      );

      req.logger.info(
        {
          action: 'fn_ingestion_review_queue_list',
          userId,
          total: result.pagination.total,
          page: result.pagination.page,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );

      res.status(200).json({ success: true, ...result });
    } catch (error) {
      req.logger.error(
        {
          action: 'fn_ingestion_review_queue_list',
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
   * POST /api/v1/admin/ingestion-queue/:id/resolve
   *
   * Reviewer confirms / corrects / rejects a low-confidence page.
   * Gated by document.review.
   *
   * SENSITIVE: correctedText and finalText are NEVER logged.
   * The 22023 'reviewStatus:queue item already resolved' → 409 translation:
   *   db.callFunction translatePgError maps 22023 structured to 400 by default.
   *   We check if the error is a ValidationError with field='reviewStatus'
   *   and the message contains 'already resolved' and re-throw as ConflictError.
   */
  async resolve(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'fn_ingestion_review_resolve',
        method: req.method,
        path: req.path,
        userId: req.user?.id,
        // correctedText deliberately NOT logged here (SENSITIVE)
      },
      'Controller entry',
    );

    try {
      const { id } = AdminIngestionQueueIdParamSchema.parse(req.params);
      // SENSITIVE: correctedText is Pino-redacted; don't log req.body
      const body = IngestionResolveBodySchema.parse(req.body);
      const userId = req.user!.id;
      const tenantId = (req.user as { tenantId?: string })?.tenantId ?? ADNOC_TENANT_ID;

      let result: IngestionResolveResult;
      try {
        result = await adminIngestionQueueService.resolve(
          id,
          body.action,
          body.correctedText ?? null,
          userId,
          tenantId,
        );
      } catch (err) {
        // Translate 22023 with 'reviewStatus:' prefix → 409 ConflictError
        // translatePgError routes it to ValidationError by default since
        // 'reviewStatus' is not in CONFLICT_FIELD_PREFIXES. We intercept here.
        if (
          err instanceof Error &&
          err.constructor.name === 'ValidationError' &&
          'details' in err &&
          typeof (err as { details?: Record<string, string> }).details === 'object' &&
          (err as { details?: Record<string, string> }).details?.['reviewStatus']
        ) {
          const msg = (err as { details?: Record<string, string> }).details?.['reviewStatus'] ?? 'queue item already resolved';
          if (/already resolved/i.test(msg)) {
            throw new ConflictError(msg, { reviewStatus: msg });
          }
        }
        throw err;
      }

      req.logger.info(
        {
          action: 'fn_ingestion_review_resolve',
          userId,
          queueId: id,
          action_taken: body.action,
          reviewStatus: result?.reviewStatus,
          duration: Date.now() - startTime,
          statusCode: 200,
          // NOTE: finalText and correctedText are NOT logged here
        },
        'Controller exit',
      );

      res.status(200).json({ success: true, data: result });
    } catch (error) {
      req.logger.error(
        {
          action: 'fn_ingestion_review_resolve',
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
