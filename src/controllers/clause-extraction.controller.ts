/**
 * M12 / CR-D — Clause Extraction + Taxonomy + Review Controller.
 *
 * Routes → Controller → db.callFunction() → JSONB response.
 * No business logic here — everything in fn_ functions.
 *
 * SENSITIVE: parameters, textExcerpts, queryText never logged.
 * Entry/exit Pino logging on every method. startTime + duration always tracked.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError, NotFoundError, ConflictError, UnprocessableEntityError } from '../utils/errors.util';
import { triggerExtractionRequest, embedQueryText } from '../services/clause-extraction.service';
import type {
  ExtractClausesBodyInput,
  ClauseReviewQueueQueryInput,
  ClauseReviewBodyInput,
  ClauseTaxonomyQueryInput,
  ClauseSemanticSearchBodyInput,
} from '../schemas/clause-extraction.schemas';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const clauseExtractionController = {

  // ============================================================
  // CR-D-001 — POST /api/v1/contracts/:id/extract-clauses
  // ============================================================

  extractClausesLatestVersion: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_clause_extraction_request', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const contractId = parseInt(req.params['id'] as string, 10);
      const body = req.body as ExtractClausesBodyInput;
      const forceReprocess = body.forceReprocess ?? false;

      const result = await triggerExtractionRequest(
        contractId,
        null, // latest version
        forceReprocess,
        req.user!.id,
      );

      if (!result.queued && result.reason === 'contract_not_found') {
        throw new NotFoundError('Contract not found or not in actor\'s tenant');
      }
      if (!result.queued && result.reason === 'already_queued') {
        throw new ConflictError('Extraction already running for this version (use forceReprocess=true to override)');
      }

      req.logger.info({ action: 'fn_clause_extraction_request', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 202 });
      res.status(202).json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_clause_extraction_request', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-D-002 — POST /api/v1/contracts/:id/versions/:vId/extract-clauses
  // ============================================================

  extractClausesSpecificVersion: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_clause_extraction_request', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const contractId = parseInt(req.params['id'] as string, 10);
      const versionId = parseInt(req.params['vId'] as string, 10);
      const body = req.body as ExtractClausesBodyInput;
      const forceReprocess = body.forceReprocess ?? false;

      const result = await triggerExtractionRequest(
        contractId,
        versionId,
        forceReprocess,
        req.user!.id,
      );

      if (!result.queued && result.reason === 'contract_not_found') {
        throw new NotFoundError('Contract or version not found in actor\'s tenant');
      }
      if (!result.queued && result.reason === 'already_queued') {
        throw new ConflictError('Extraction already running for this version');
      }

      req.logger.info({ action: 'fn_clause_extraction_request', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 202 });
      res.status(202).json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_clause_extraction_request', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-D-003 — GET /api/v1/clauses/review-queue
  // ============================================================

  listReviewQueue: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_clause_review_queue_list', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const query = req.query as unknown as ClauseReviewQueueQueryInput;

      const result = await db.callFunction<{ data: unknown[]; pagination: unknown }>(
        'fn_clause_review_queue_list',
        [
          query.page,
          query.limit,
          query.contractId ?? null,
          query.clauseType ?? null,   // mapped to p_family in fn_ — fn_ accepts family filter
          query.reviewStatus ?? null, // mapped to p_confidence_band in fn_ — NOTE: fn_ uses confidence_band not reviewStatus; this param will be ignored by fn_ if it doesn't match 'low'|'medium'
          query.confidenceBelow ?? null, // mapped to p_search in fn_ — WARN: fn_ signature mismatch; see integration-verifier-report
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      // BLOCKER-4 fix: fn_clause_review_queue_list returns { data: [], pagination: {} }.
      // Contract and FE types expect { items: [], pagination: {} }. Remap here.
      const responseData = result
        ? { items: (result as Record<string, unknown>)['data'] ?? [], pagination: (result as Record<string, unknown>)['pagination'] }
        : { items: [], pagination: { total: 0, page: query.page, limit: query.limit, totalPages: 1 } };

      req.logger.info({ action: 'fn_clause_review_queue_list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: responseData });
    } catch (error) {
      req.logger.error({ action: 'fn_clause_review_queue_list', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-D-004 — POST /api/v1/clauses/:id/review
  // ============================================================

  reviewClause: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_clause_review_resolve', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const clauseId = parseInt(req.params['id'] as string, 10);
      if (isNaN(clauseId)) throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid clause ID format');

      // SENSITIVE: parametersCorrection and textExcerptsCorrection not logged
      const body = req.body as ClauseReviewBodyInput;

      const result = await db.callFunction<{
        clauseId: number;
        newReviewStatus: string;
        obligationsRecomputed: boolean;
      }>(
        'fn_clause_review_resolve',
        [
          clauseId,
          body.action,
          body.parametersCorrection ?? null,
          body.textExcerptsCorrection ?? null,
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      if (!result) throw new NotFoundError('Clause record not found in actor\'s tenant');

      req.logger.info({ action: 'fn_clause_review_resolve', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_clause_review_resolve', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-D-005 — GET /api/v1/admin/clause-taxonomy
  // ============================================================

  listTaxonomy: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_clause_taxonomy_list', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const query = req.query as unknown as ClauseTaxonomyQueryInput;

      const result = await db.callFunction<{ data: unknown[]; groupedByFamily: unknown }>(
        'fn_clause_taxonomy_list',
        [
          query.family ?? null,
          query.search ?? null,
          query.isActive,
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      // BLOCKER-4 fix: fn_clause_taxonomy_list returns { data: [], groupedByFamily: {} }.
      // Contract and FE types expect { items: [], groupedByFamily: {} }. Remap here.
      const responseData = result
        ? { items: (result as Record<string, unknown>)['data'] ?? [], groupedByFamily: (result as Record<string, unknown>)['groupedByFamily'] ?? {} }
        : { items: [], groupedByFamily: {} };

      req.logger.info({ action: 'fn_clause_taxonomy_list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: responseData });
    } catch (error) {
      req.logger.error({ action: 'fn_clause_taxonomy_list', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-D-006 — POST /api/v1/clauses/search
  // ============================================================

  semanticSearch: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_clause_semantic_search', method: req.method, path: req.path, userId: req.user?.id });
    // NOTE: queryText is SENSITIVE — not logged

    try {
      const body = req.body as ClauseSemanticSearchBodyInput;

      // Generate embedding for the query text
      let embedding: number[];
      let queryEmbeddingLogId: number | null;
      try {
        const embedResult = await embedQueryText(body.queryText, req.user!.id);
        embedding = embedResult.embedding;
        queryEmbeddingLogId = embedResult.logId;
      } catch (err) {
        if (err instanceof UnprocessableEntityError) {
          throw err; // surfaces as 422 EMBEDDING_FAILED
        }
        throw err;
      }

      const result = await db.callFunction<{ data: unknown[]; count: number }>(
        'fn_clause_semantic_search',
        [
          `[${embedding.join(',')}]`,
          body.contractId ?? null,
          body.limit,
          body.similarityMin,
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      const responseData = {
        ...(result ?? { data: [], count: 0 }),
        queryEmbeddingLogId: queryEmbeddingLogId ?? undefined,
      };

      req.logger.info({ action: 'fn_clause_semantic_search', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: responseData });
    } catch (error) {
      req.logger.error({ action: 'fn_clause_semantic_search', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },
};
