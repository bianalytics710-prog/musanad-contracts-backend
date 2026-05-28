/**
 * CR-M — Labor-Law Cascade + ADNOC-World Foundation
 * TypeScript Type Definitions (BE)
 * Derived from: db-design.md §C, §D (Agent 4 output)
 * Do not edit manually — regenerate via Agent 5 if DB design changes.
 * Generated: 2026-05-28
 */

import type { ApiResponse } from './api.types';
import type { DataClassification } from './osint.types';

// -----------------------------------------------------------
// 1. Closed-set string unions (locked DB CHECK enums)
// -----------------------------------------------------------

/**
 * headcount_band — statutory 3-value band per Federal Decree-Law No.9/2024.
 */
export type HeadcountBand = '<20' | '20-49' | '50+';

export const HEADCOUNT_BANDS: ReadonlyArray<HeadcountBand> = ['<20', '20-49', '50+'] as const;

/**
 * party_workforce.category — contractor service category.
 */
export type WorkforceCategory =
  | 'drilling'
  | 'logistics'
  | 'epc'
  | 'operational_support'
  | 'other';

/**
 * party_workforce.source — provenance of the workforce record.
 */
export type WorkforceSource = 'manual' | 'demo_seed' | 'import';

/**
 * regulatory_cascade_item.remediation_status
 */
export type RemediationStatus =
  | 'pending'
  | 'in_progress'
  | 'amended'
  | 'dismissed'
  | 'resolved';

export const REMEDIATION_STATUSES: ReadonlyArray<RemediationStatus> = [
  'pending',
  'in_progress',
  'amended',
  'dismissed',
  'resolved',
] as const;

/**
 * regulatory_cascade_run.status
 */
export type CascadeRunStatus = 'running' | 'completed' | 'failed';

// -----------------------------------------------------------
// 2. Nested JSONB sub-shapes
// -----------------------------------------------------------

/** penalty_basis JSONB — SENSITIVE */
export interface PenaltyBasis {
  band: HeadcountBand;
  emiratisationGap: number;
  finePerHeadMin: number;
  finePerHeadMax: number;
  statutoryFloor: number;
  statutoryCeiling: number;
}

export interface CascadeBandCountEntry {
  total: number;
  nonCompliant: number;
  compliant: number;
  totalPenaltyMinAed: number;
  totalPenaltyMaxAed: number;
}

export type CascadeSummaryByBand = {
  [K in HeadcountBand]?: CascadeBandCountEntry;
};

export interface CascadeSummaryTotals {
  affectedContractors: number;
  totalPenaltyMinAed: number;
  totalPenaltyMaxAed: number;
  nonCompliantCount: number;
}

export interface CascadeSummary {
  byBand: CascadeSummaryByBand;
  totals: CascadeSummaryTotals;
  generatedAt: string;
}

// -----------------------------------------------------------
// 3. PartyWorkforce entity
// -----------------------------------------------------------

export interface PartyWorkforce {
  id: number;
  partyId: number;
  partyNameEn: string;
  partyNameAr: string | null;
  headcount: number;
  headcountBand: HeadcountBand;
  emiratisationTarget: number;
  emiratisationActual: number;
  isCompliant: boolean;
  category: WorkforceCategory;
  source: WorkforceSource;
  updatedAt: string;
}

export type PartyWorkforceListItem = PartyWorkforce;

export interface PartyWorkforceOffsetPagination {
  total: number;
  limit: number;
  offset: number;
}

export interface PartyWorkforceListResponse {
  data: PartyWorkforceListItem[];
  pagination: PartyWorkforceOffsetPagination;
}

export interface SetPartyWorkforceDto {
  headcount: number;
  emiratisationTarget: number;
  emiratisationActual: number;
  category?: WorkforceCategory;
  notes?: string;
}

// -----------------------------------------------------------
// 4. RegulatoryCascadeRun entity
// -----------------------------------------------------------

export interface RegulatoryCascadeRunListItem {
  id: number;
  signalId: number;
  regulationRef: string | null;
  status: CascadeRunStatus;
  runAt: string;
  affectedContractorCount: number;
  totalPenaltyMinAed: number;
  totalPenaltyMaxAed: number;
  summary: CascadeSummary;
  createdByName: string | null;
}

export interface RegulatoryCascadeItemDetail {
  id: number;
  partyId: number;
  contractorNameEn: string;
  contractorNameAr: string | null;
  emirate: string | null;
  headcountBand: HeadcountBand;
  isCompliant: boolean;
  emiratisationGap: number;
  affectedClauseCount: number;
  affectedClauseIds: number[];
  affectedContractIds: number[];
  icvAttachmentIds: number[];
  icvAttachmentCount: number;
  penaltyExposureMinAed: number;
  penaltyExposureMaxAed: number;
  /** SENSITIVE — see db-design.md §5 */
  penaltyBasis: PenaltyBasis;
  remediationStatus: RemediationStatus;
  advisoryDraftId: number | null;
  advisoryDraftStatus: string | null;
}

export interface RegulatoryCascadeRun {
  id: number;
  tenantId: string;
  signalId: number;
  regulationRef: string | null;
  status: CascadeRunStatus;
  summary: CascadeSummary;
  params: Record<string, unknown>;
  affectedContractorCount: number;
  totalPenaltyMinAed: number;
  totalPenaltyMaxAed: number;
  dataClassification: DataClassification;
  runAt: string;
  createdAt: string;
  createdByName: string | null;
  items: RegulatoryCascadeItemDetail[];
}

export interface RegulatoryCascadeRunListResponse {
  data: RegulatoryCascadeRunListItem[];
  pagination: PartyWorkforceOffsetPagination;
}

// -----------------------------------------------------------
// 5. Request DTOs
// -----------------------------------------------------------

export interface RunRegulatoryCascadeDto {
  signalId?: number;
  impactSignalId?: number;
  params?: {
    employmentClauseTypes?: string[];
  };
}

export interface SetRemediationStatusDto {
  status: RemediationStatus;
  note?: string | null;
}

export interface DraftAmendmentDto {
  contractId?: number;
}

export interface DraftAmendmentResponse {
  draftId: number;
  correlationId: number;
  templateId: number;
  contractId: number | null;
  approvalStatus: string;
  remediationStatus: RemediationStatus;
  itemId: number;
}

// -----------------------------------------------------------
// 6. Query shapes
// -----------------------------------------------------------

export interface PartyWorkforceListQuery {
  band?: HeadcountBand;
  compliant?: boolean;
  search?: string;
  limit?: number;
  offset?: number;
}

export interface RegulatoryCascadeListQuery {
  signalId?: number;
  limit?: number;
  offset?: number;
}

// -----------------------------------------------------------
// 7. Response envelope aliases
// -----------------------------------------------------------

export type PartyWorkforceResponse = ApiResponse<PartyWorkforce>;
export type PartyWorkforceListEnvelope = ApiResponse<PartyWorkforceListResponse>;

export type RunCascadeResponse = ApiResponse<RegulatoryCascadeRun>;
export type CascadeListEnvelope = ApiResponse<RegulatoryCascadeRunListResponse>;
export type CascadeDetailEnvelope = ApiResponse<RegulatoryCascadeRun>;
export type DraftAmendmentEnvelope = ApiResponse<DraftAmendmentResponse>;
export type SetRemediationStatusEnvelope = ApiResponse<RegulatoryCascadeItemDetail>;
