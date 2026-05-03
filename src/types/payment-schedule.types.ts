// ============================================================
// M1b — Contracts: Compose Wizard, Payment Schedules & Exports
// TypeScript Type Definitions (BE)
//
// Project:   Musanad Contracts Hub (musanad-contracts)
// Module:    M1b
// Source:    .claude/workspace/current-module/types.ts (Agent 5)
// Derived:   db-design.md v1.0 (Agent 4)
//            requirements-analysis.json (Agent 2)
//            db-design-summary.json (Agent 4)
//
// Stack:     Backend: Express + TypeScript strict
//
// Conventions:
//   - JSONB output keys are camelCase (matches fn_ output) — TS keys mirror.
//   - DTOs exclude id, createdAt, updatedAt, createdBy, updatedBy, isActive.
//   - body_en / body_ar leak into ContractExportPdfResponse for PDF rendering;
//     they remain SENSITIVE — pino-redacted in BE logs (M1a inheritance).
//   - No `any`. Where flexible JSON is needed: Record<string, unknown>.
// ============================================================

import type {
  Contract,
  ContractListItem,
  ContractStatus,
  ContractLanguage,
  GoverningLaw,
  RelationshipType,
  ContractRoleKey,
  ContractPermissionCode,
  UserRef,
  ActivityType,
  ContractListQuery,
} from './contracts.types';

// Re-export so M1b consumers (BE controllers) can grab everything from one barrel.
export type {
  Contract,
  ContractListItem,
  ContractStatus,
  ContractLanguage,
  GoverningLaw,
  RelationshipType,
  ContractRoleKey,
  ContractPermissionCode,
  UserRef,
  ActivityType,
  ContractListQuery,
};

// ------------------------------------------------------------
// 1. ActivityType union extension (M1b adds 2 values to M1a's enum)
// ------------------------------------------------------------

/**
 * M1b adds 2 values to the M1a contract_activity.activity_type CHECK enum.
 * Source: db-design.md migration 010 CMW-1.
 */
export const M1B_ACTIVITY_TYPE_EXTENSIONS = ['payment_schedule_replaced', 'exported'] as const;

export type M1bActivityTypeExtension = (typeof M1B_ACTIVITY_TYPE_EXTENSIONS)[number];

/** Widened activity type union — M1a 7 values + M1b 2 values = 9 total. */
export type M1bActivityType = ActivityType | M1bActivityTypeExtension;

// ------------------------------------------------------------
// 2. payment_schedule entity types
// ------------------------------------------------------------

/** AC-S2-06 / AC-S3-07 — 6-state lifecycle enum (DB CHECK). */
export type PaymentScheduleStatus = 'pending' | 'due' | 'paid' | 'overdue' | 'waived' | 'cancelled';

/** AC-S3-08 — 4-value recurrence enum (DB CHECK; null = single non-recurring). */
export type PaymentScheduleRecurrence = 'once' | 'monthly' | 'quarterly' | 'annually';

/**
 * PaymentSchedule — derived from fn_payment_schedule_list JSONB output.
 */
export interface PaymentSchedule {
  id: number;
  contractId: number;

  milestoneLabelEn: string;
  milestoneLabelAr: string | null;
  milestoneNameEn: string | null;
  milestoneNameAr: string | null;

  amountAed: number;
  dueDate: string | null;
  paidAt: string | null;

  status: PaymentScheduleStatus;
  recurrence: PaymentScheduleRecurrence | null;

  invoiceRef: string | null;

  createdAt: string;
  updatedAt: string;
}

export type PaymentScheduleListItem = PaymentSchedule;

// ------------------------------------------------------------
// 3. payment_schedule DTOs
// ------------------------------------------------------------

export interface PaymentScheduleCreateDto {
  milestoneLabelEn: string;
  milestoneLabelAr?: string | null;
  milestoneNameEn?: string | null;
  milestoneNameAr?: string | null;
  amountAed: number;
  dueDate?: string | null;
  paidAt?: string | null;
  status?: PaymentScheduleStatus;
  recurrence?: PaymentScheduleRecurrence | null;
  invoiceRef?: string | null;
}

export interface PaymentScheduleBulkReplaceDto {
  rows: PaymentScheduleCreateDto[];
  replaceExisting?: boolean;
}

export interface PaymentScheduleListQuery {
  status?: PaymentScheduleStatus;
}

// ------------------------------------------------------------
// 4. payment_schedule response shapes
// ------------------------------------------------------------

export interface PaymentScheduleListResponse {
  data: PaymentSchedule[];
}

export interface PaymentScheduleBulkReplaceResponse {
  contractId: number;
  inserted: number;
  softDeleted: number;
  rows: PaymentSchedule[];
}

// Convenience aliases matching api-contracts.json names.
export type PaymentScheduleResponse = PaymentSchedule;
export type ReplacePaymentScheduleDto = PaymentScheduleBulkReplaceDto;
export type ReplacePaymentScheduleResponse = PaymentScheduleBulkReplaceResponse;

// ------------------------------------------------------------
// 5. PDF export — request + response shapes
// ------------------------------------------------------------

export interface ContractExportPdfQuery {
  language?: ContractLanguage;
  includeAttachments?: boolean;
}

/**
 * Sub-shape inside ContractExportPdfResponse.contract — the head fields the
 * Puppeteer template renders. Mirrors fn_contract_export_pdf §3.2 return.
 */
export interface ContractExportPdfHead {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  contractType: string;
  language: ContractLanguage;
  valueAed: number | null;
  currency: string;
  startDate: string | null;
  endDate: string | null;
  signedAt: string | null;
  emirate: string | null;
  governingLaw: GoverningLaw | null;
  jurisdictionCourt: string | null;
  status: ContractStatus;
  currentVersion: number;
  draftedBy: UserRef | null;
  reviewedBy: UserRef | null;
  approvedBy: UserRef | null;
  /** SENSITIVE — pino-redact (M1a inheritance). */
  bodyEn: string | null;
  /** SENSITIVE — pino-redact (M1a inheritance). */
  bodyAr: string | null;
  createdAt: string;
}

/** Forward-deferred sub-shape — null until Parties module materialises. */
export interface PartyRef {
  id: number;
  nameEn: string;
  nameAr: string | null;
}

/**
 * fn_contract_export_pdf JSONB return shape (db-design.md §3.2).
 * NOT a wire response — BE controller consumes this then renders PDF.
 */
export interface ContractExportPdfResponse {
  contract: ContractExportPdfHead;
  tags: string[];
  paymentSchedule: PaymentSchedule[];
  ourParty: PartyRef | null;
  counterparty: PartyRef | null;
  attachments: null;
  exportLanguage: ContractLanguage;
  generatedAt: string;
}

// ------------------------------------------------------------
// 6. XLSX export — request + response shapes
// ------------------------------------------------------------

export interface ContractExportXlsxQueryParams {
  status?: ContractStatus;
  contractType?: string;
  counterpartyId?: number;
  draftedBy?: number;
  approvedBy?: number;
  startDateFrom?: string;
  startDateTo?: string;
  endDateFrom?: string;
  endDateTo?: string;
  tags?: string[];
  search?: string;
  /** AC-S5-05: defaults 10000, hard-clamped to MIN(input, 50000). */
  maxRows?: number;
}

export interface ContractExportXlsxRow {
  id: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  contractType: string;
  status: ContractStatus;
  valueAed: number | null;
  currency: string;
  startDate: string | null;
  endDate: string | null;
  counterpartyId: number | null;
  ourPartyId: number | null;
  /** Comma-joined tag list. */
  tagsCsv: string;
  currentVersion: number;
  createdAt: string;
  updatedAt: string;
}

/**
 * fn_contract_export_xlsx JSONB return shape (db-design.md §3.3).
 */
export interface ContractExportXlsxResponse {
  rows: ContractExportXlsxRow[];
  totalRows: number;
  truncated: boolean;
  filterApplied: ContractExportXlsxQueryParams;
  generatedAt: string;
}

// ------------------------------------------------------------
// 7. fn_audit_log_record helper (BE-internal, db-design.md §3.4)
// ------------------------------------------------------------

/**
 * @internal — must NEVER be exposed via HTTP.
 */
export interface AuditLogRecordInput {
  tableName: string;
  recordId: number | null;
  action: 'INSERT' | 'UPDATE' | 'DELETE';
  newValues: Record<string, unknown>;
  actorId?: number | null;
}

export interface AuditLogRecordResult {
  id: number;
}

// ------------------------------------------------------------
// 8. Permission codes summary for M1b (REUSED — none new)
// ------------------------------------------------------------

export const M1B_NEW_PERMISSIONS: readonly ContractPermissionCode[] = [] as const;
export const M1B_NEW_ROLES: readonly ContractRoleKey[] = [] as const;
