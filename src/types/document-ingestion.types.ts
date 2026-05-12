/**
 * M11 — Document Ingestion Pipeline (CR-D0) — BE types.
 *
 * Mirrors workspace/current-module/types.ts with BE-specific additions.
 * See types.ts for the canonical source; this file is the BE re-export
 * with runtime helpers and ExtractionEngine runtime value.
 */

export type IngestionStatus =
  | 'pending'
  | 'extracting'
  | 'complete'
  | 'failed'
  | 'partial';

export type ExtractionEngine =
  | 'digital_pdf'
  | 'tesseract'
  | 'gpt4o_vision'
  | 'mammoth_docx'
  | 'mixed';

export type ReviewStatus =
  | 'pending_auto'
  | 'pending_human'
  | 'resolved'
  | 'rejected';

export type DataClassification = 'demo' | 'pilot' | 'production';

export type IngestionReviewAction = 'confirm' | 'correct' | 'reject';

export interface IngestionQueuedResponse {
  contractVersionId: number;
  ingestionStatus: IngestionStatus;
  queuedAt: string;
  alreadyInProgress: boolean;
}

export interface IngestionCompleteResponse {
  contractVersionId: number;
  ingestionStatus: 'complete';
  extractedAt: string;
  notifyEmitted: boolean;
}

export interface IngestionCompleteRequest {
  contractVersionId: number;
  extractedTextUri: string;
  pageCount: number;
  ocrUsed: boolean;
  ocrConfidenceAvg?: number | null;
  extractionEngine: ExtractionEngine;
}

export interface IngestionFailResponse {
  contractVersionId: number;
  ingestionStatus: 'failed';
  failedAt: string;
  attemptCount: number;
}

export interface IngestionStatusResponse {
  contractVersionId: number;
  ingestionStatus: IngestionStatus;
  ingestionError: string | null;
  pageCount: number | null;
  ocrUsed: boolean;
  ocrConfidenceAvg: number | null;
  extractionEngine: ExtractionEngine | null;
  extractedAt: string | null;
  extractedTextUri: string | null;
  lowConfidencePageCount: number;
}

export interface SignedExtractedTextUrlResponse {
  signedUrl: string;
  expiresAt: string;
  ttlSeconds: 60;
}

export interface IngestionResolveRequest {
  action: IngestionReviewAction;
  correctedText?: string;
}

export interface IngestionResolveResult {
  queueId: number;
  reviewStatus: ReviewStatus;
  finalText: string | null;
  reviewedAt: string;
}

export interface IngestionQueueRecordRequest {
  tenantId: string;
  contractVersionId: number;
  pageNo: number;
  tesseractConfidence?: number | null;
  tesseractText?: string | null;
  gpt4oText?: string | null;
  gpt4oUsed: boolean;
  initialReviewStatus: 'pending_auto' | 'pending_human';
}

export interface IngestionQueueRecordResult {
  id: number;
  contractVersionId: number;
  pageNo: number;
  reviewStatus: ReviewStatus;
  createdAt: string;
}

/**
 * DocumentIngestionResult — returned by document-ingestion.service.ts
 * extractDocument(). Not a DB fn shape — this is the service-layer contract.
 */
export interface DocumentIngestionResult {
  extractedText: string;
  extractedTextUri: string;
  pageCount: number;
  ocrUsed: boolean;
  ocrConfidenceAvg: number | null;
  extractionEngine: ExtractionEngine;
  lowConfidencePages: LowConfidencePage[];
}

export interface LowConfidencePage {
  pageNo: number;
  tesseractConfidence: number | null;
  tesseractText: string | null;
  gpt4oText: string | null;
  gpt4oUsed: boolean;
  initialReviewStatus: 'pending_auto' | 'pending_human';
}

/** M11 sensitive field names — extend logger.util.ts Pino redact paths. */
export const M11_SENSITIVE_FIELD_EXTENSIONS = [
  'tesseract_text',
  'gpt4o_text',
  'final_text',
  'ingestion_error',
  'extracted_text_uri',
  'tesseractText',
  'gpt4oText',
  'finalText',
  'ingestionError',
  'extractedTextUri',
  'correctedText',
] as const;
