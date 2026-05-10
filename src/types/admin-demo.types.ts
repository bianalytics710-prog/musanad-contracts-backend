/**
 * CR-C — Demo data purge (S6) + data classification summary (S7) types.
 *
 * Mirrors workspace types.ts §3. Tenant-aware data classification enum is
 * re-declared here to avoid cross-module osint.types dependency.
 */
import type { ApiResponse } from './api.types';

/**
 * DataClassification — every CR-C content row carries this CHECK enum.
 * Default 'demo' on existing rows. Demo rows purged by fn_demo_data_purge
 * (Super Admin only).
 *
 * Owning module: M7 (osint.types.ts) — re-declared here to keep admin-cockpit
 * decoupled from CRIP imports. Both definitions MUST stay in sync.
 */
export type DataClassification = 'demo' | 'pilot' | 'production';

export const DATA_CLASSIFICATIONS: ReadonlyArray<DataClassification> = [
  'demo',
  'pilot',
  'production',
] as const;

/**
 * DataClassificationAware — mixin every CR-C-touched content row implements
 * after migration 127 lands.
 */
export interface DataClassificationAware {
  dataClassification: DataClassification;
}

/**
 * DemoPurgeRequest — POST /api/v1/admin/demo/purge body.
 *
 * confirmToken format (AC-S6-05):
 *   `PURGE_DEMO_DATA_<utc-iso-date>` where date = today (YYYY-MM-DD) per
 *   server clock. dryRun=true bypasses the confirmToken check.
 */
export interface DemoPurgeRequest {
  /** REQUIRED unless dryRun=true. */
  confirmToken?: string;
  /** Default false. When true, returns same shape with no DELETE. */
  dryRun?: boolean;
}

/** Per-table count row inside DemoPurgeResult.details. */
export interface DemoPurgeDetailRow {
  tableName: string;
  rowsDeleted: number;
}

/**
 * DemoPurgeResult — fn_demo_data_purge JSONB output.
 * BE wraps inside ApiResponse<DemoPurgeResult>.
 */
export interface DemoPurgeResult {
  success: true;
  /** Tables that had at least one demo row deleted (excluded if 0). */
  tablesPurged: string[];
  /** Sum of rowsDeleted across the topological order. */
  rowsDeleted: number;
  /** Per-table breakdown keyed by table name. */
  details: Record<string, number>;
  /** Echo of request flag (true → no DELETEs were performed). */
  dryRun: boolean;
}

/** Per-table per-classification count row. */
export interface DataClassificationSummaryRow {
  tableName: string;
  demo: number;
  pilot: number;
  production: number;
  total: number;
}

/** fn_data_classification_summary JSONB output. */
export interface DataClassificationSummary {
  summary: DataClassificationSummaryRow[];
  totals: {
    demo: number;
    pilot: number;
    production: number;
    total: number;
  };
}

export type DemoPurgeApiResponse = ApiResponse<DemoPurgeResult>;
export type DataClassificationSummaryApiResponse =
  ApiResponse<DataClassificationSummary>;
