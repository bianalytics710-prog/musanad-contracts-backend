/**
 * M11 — Admin Ingestion Queue types.
 * F-S2-22 patch applied: contractTitleEn + contractTitleAr (not contractTitle).
 */

import type { ReviewStatus, DataClassification } from './document-ingestion.types';

export interface IngestionReviewQueueItem {
  id: number;
  contractVersionId: number;
  /** F-S2-22: title_en from contract (via JOIN contract_version → contract). */
  contractTitleEn: string;
  /** F-S2-22: title_ar from contract (via JOIN contract_version → contract). */
  contractTitleAr: string | null;
  pageNo: number;
  tesseractConfidence: number | null;
  gpt4oUsed: boolean;
  reviewStatus: ReviewStatus;
  reviewedByName: string | null;
  reviewedAt: string | null;
  createdAt: string;
  dataClassification: DataClassification;
  tenantId: string;
}

export interface PaginationMeta {
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}

export interface AdminIngestionQueueListResponse {
  data: IngestionReviewQueueItem[];
  pagination: PaginationMeta;
}

export interface AdminIngestionQueueListQuery {
  page?: number;
  limit?: number;
  reviewStatus?: ReviewStatus;
  contractVersionId?: number;
  gpt4oUsed?: boolean;
}
