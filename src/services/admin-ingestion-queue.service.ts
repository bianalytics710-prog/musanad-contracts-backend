/**
 * M11 — Admin Ingestion Queue service.
 *
 * Thin passthrough wrapping fn_ingestion_review_queue_list and
 * fn_ingestion_review_resolve. All business logic lives in the DB.
 */

import { db } from '../database/client';
import type {
  AdminIngestionQueueListResponse,
  AdminIngestionQueueListQuery,
} from '../types/admin-ingestion-queue.types';
import type { IngestionResolveResult } from '../types/document-ingestion.types';

export const adminIngestionQueueService = {
  /**
   * List paginated ingestion_review_queue rows for admin monitoring.
   * fn_ingestion_review_queue_list performs RLS narrowing by tenant_id GUC.
   */
  async list(
    query: AdminIngestionQueueListQuery,
    tenantId: string,
    actorId: number,
  ): Promise<AdminIngestionQueueListResponse> {
    const {
      page = 1,
      limit = 20,
      reviewStatus = null,
      contractVersionId = null,
      gpt4oUsed = null,
    } = query;

    const result = await db.callFunction<AdminIngestionQueueListResponse>(
      'fn_ingestion_review_queue_list',
      [page, limit, reviewStatus, contractVersionId, gpt4oUsed],
      { actorId, tenantId },
    );

    return result ?? { data: [], pagination: { total: 0, page, limit, totalPages: 0 } };
  },

  /**
   * Resolve a review queue item (confirm / correct / reject).
   * fn_ingestion_review_resolve is INVOKER — RLS narrows by tenant + permission.
   */
  async resolve(
    queueId: number,
    action: string,
    correctedText: string | null,
    actorId: number,
    tenantId: string,
  ): Promise<IngestionResolveResult> {
    return db.callFunction<IngestionResolveResult>(
      'fn_ingestion_review_resolve',
      [queueId, action, correctedText, actorId],
      { actorId, tenantId },
    );
  },
};
