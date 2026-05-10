// ============================================================
// M9 — Counterparty Graph (CR-B) — Backend TypeScript Types
//
// Source of truth: .claude/workspace/current-module/types.ts (Agent 5).
// Re-implemented here (NOT imported from the workspace artifact path)
// because the workspace path is outside the BE tsconfig include root.
// Every shape is byte-for-byte identical to the artifact — JSONB key
// parity is the S2-16 invariant.
//
// camelCase invariant: every key matches the `jsonb_build_object` keys
// produced by every fn_party_* in db-design.md §3 and §4.
//
// Imports:
//   - PaginationMeta, ApiResponse, Paginated from '../types/api.types' (M0)
//   - EntityReference from '../types/osint.types' (M7) — sanctions match input.
// ============================================================
import type { ApiResponse, PaginationMeta, Paginated } from './api.types';
import type { EntityReference } from './osint.types';

// ============================================================
// 1. Closed-set string unions (locked enums)
// ============================================================

/**
 * RelationshipType — party_relationship.relationship_type CHECK enum (6 values).
 */
export type RelationshipType =
  | 'parent'
  | 'ubo'
  | 'subsidiary'
  | 'sub_contractor'
  | 'jv'
  | 'controlling_shareholder';

/** Iterable form for FE dropdowns. Stable order matches DB CHECK. */
export const RELATIONSHIP_TYPES: ReadonlyArray<RelationshipType> = [
  'parent',
  'ubo',
  'subsidiary',
  'sub_contractor',
  'jv',
  'controlling_shareholder',
] as const;

/** SanctionsStatus — party.sanctions_status CHECK enum (4 values). */
export type SanctionsStatus =
  | 'clean'
  | 'flagged'
  | 'sanctioned'
  | 'under_review';

/** IcvStatus — party.icv_status CHECK enum (5 values, nullable column). */
export type IcvStatus =
  | 'certified'
  | 'expired'
  | 'downgraded'
  | 'pending'
  | 'none';

/** RelationshipSource — party_relationship.source CHECK enum (4 values). */
export type RelationshipSource = 'dnb' | 'sayari' | 'manual' | 'demo_seed';

/** ChainHopVia — discriminator on each chain node. */
export type ChainHopVia = 'edge' | 'self_fk_parent' | 'self_fk_ubo';

/** SanctionsMatchType — discriminator on each match in sanctions match output. */
export type SanctionsMatchType =
  | 'direct_name'
  | 'direct_alias'
  | 'chain_ancestor'
  | 'chain_descendant';

/** Chain traversal direction. */
export type ChainDirection = 'up' | 'down' | 'both';

/** PartyType — existing M_parity 058 enum. */
export type PartyType = 'individual' | 'company';

// ============================================================
// 2. Party (extended) — superset of M_parity 058 / R-LC 075
// ============================================================

export type PartyAlias = string;

/**
 * PartyListItem — light projection from fn_party_list (Migration 120 EXTEND).
 * 11 existing M_parity fields preserved + 6 net-new CR-B badge fields appended.
 */
export interface PartyListItem {
  id: number;
  partyType: PartyType;
  nameEn: string;
  nameAr: string | null;
  tradeLicenseNumber: string | null;
  tradeLicenseIssuer: string | null;
  emirate: string | null;
  freeZone: string | null;
  country: string;
  contactEmail: string | null;
  contactPhone: string | null;
  createdAt: string;
  isVerified: boolean;
  parentId: number | null;
  aliases: PartyAlias[];
  sanctionsStatus: SanctionsStatus;
  sanctionsLastChecked: string | null;
  icvStatus: IcvStatus | null;
  icvPct: number | null;
}

/**
 * PartyDetail — full fn_party_get_by_id JSONB output (Migration 120 EXTEND).
 * 11 net-new CR-B fields appended to the existing M_parity 058 + R-LC shape.
 */
export interface PartyDetail {
  // Existing M_parity 058 + R-LC fields
  id: number;
  partyType: PartyType;
  nameEn: string;
  nameAr: string | null;
  tradeLicenseNumber: string | null;
  tradeLicenseIssuer: string | null;
  emirate: string | null;
  freeZone: string | null;
  country: string;
  contactEmail: string | null;
  contactPhone: string | null;
  registeredAddress: string | null;
  notes: string | null;
  isVerified: boolean;
  createdAt: string;
  updatedAt: string;
  recentContracts5: Array<{
    id: number;
    contractNumber: string;
    titleEn: string;
    status: string;
    valueAed: number | null;
    updatedAt: string;
  }>;

  // M9 (CR-B) — 11 net-new fields
  parentId: number | null;
  uboId: number | null;
  sanctionsStatus: SanctionsStatus;
  sanctionsLastChecked: string | null;
  sanctionsMatchSignalId: number | null;
  esgScore: number | null;
  icvStatus: IcvStatus | null;
  icvPct: number | null;
  icvLastChecked: string | null;
  aliases: PartyAlias[];
  metadata: Record<string, unknown>;
}

/** Alias of PartyDetail — orchestrator-prompt naming. */
export type PartyExtended = PartyDetail;

// ============================================================
// 3. PartyRelationship — net-new edge entity
// ============================================================

/**
 * PartyRelationship — full edge JSONB output from
 * fn_party_relationship_create / _update.
 */
export interface PartyRelationship {
  id: number;
  tenantId: string;
  parentId: number;
  childId: number;
  relationshipType: RelationshipType;
  ownershipPct: number | null;
  effectiveFrom: string | null;
  effectiveTo: string | null;
  source: RelationshipSource;
  confidence: number;
  metadata: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
  isActive: boolean;
}

/**
 * CreateRelationshipPayload — POST /api/v1/parties/:id/relationships body.
 * URL :id supplies parentId; body supplies childId.
 */
export interface CreateRelationshipPayload {
  childId: number;
  relationshipType: RelationshipType;
  ownershipPct?: number | null;
  effectiveFrom?: string | null;
  effectiveTo?: string | null;
  source?: RelationshipSource;
  confidence?: number;
  metadata?: Record<string, unknown>;
}

/**
 * UpdateRelationshipPayload — PATCH /api/v1/parties/:id/relationships/:relId body.
 * parentId / childId silently ignored even if forwarded (AC-S2-04).
 */
export interface UpdateRelationshipPayload {
  relationshipType?: RelationshipType;
  ownershipPct?: number | null;
  effectiveFrom?: string | null;
  effectiveTo?: string | null;
  source?: RelationshipSource;
  confidence?: number;
  metadata?: Record<string, unknown>;
}

/**
 * RelationshipListEdge — element of incoming[] / outgoing[] from
 * fn_party_relationship_list.
 */
export interface RelationshipListEdge {
  id: number;
  relationshipType: RelationshipType;
  ownershipPct: number | null;
  source: RelationshipSource;
  confidence: number;
  createdAt: string;
  otherParty: {
    partyId: number;
    nameEn: string;
    nameAr: string | null;
    sanctionsStatus: SanctionsStatus;
  };
}

/** ListRelationshipsResponse — fn_party_relationship_list JSONB output. */
export interface ListRelationshipsResponse {
  incoming: RelationshipListEdge[];
  outgoing: RelationshipListEdge[];
  counts: {
    incoming: number;
    outgoing: number;
  };
}

/** DeleteRelationshipResponse — fn_party_relationship_delete JSONB output. */
export interface DeleteRelationshipResponse {
  success: true;
  deletedAt: string;
  idempotent: boolean;
}

// ============================================================
// 4. Chain traversal types
// ============================================================

/** PartyChainNode — single node in traversal output array. */
export interface PartyChainNode {
  partyId: number;
  depth: number;
  relationshipType: RelationshipType;
  ownershipPct: number | null;
  sanctionsStatus: SanctionsStatus;
  nameEn: string;
  nameAr: string | null;
  via: ChainHopVia;
}

/** PartyChainTraverseQuery — query string for GET /api/v1/parties/:id/chain. */
export interface PartyChainTraverseQuery {
  direction?: ChainDirection; // default 'both'
  maxDepth?: number; // 1..10, default 5
}

/** PartyChainTraverseUpResponse — fn_party_chain_traverse_up JSONB output. */
export interface PartyChainTraverseUpResponse {
  rootPartyId: number;
  ancestors: PartyChainNode[];
  chainTruncated: boolean;
  depthReached: number;
}

/** PartyChainTraverseDownResponse — fn_party_chain_traverse_down JSONB output. */
export interface PartyChainTraverseDownResponse {
  rootPartyId: number;
  descendants: PartyChainNode[];
  chainTruncated: boolean;
  depthReached: number;
}

/** PartyChainBothResponse — BE-merged response for direction='both'. */
export interface PartyChainBothResponse {
  rootPartyId: number;
  ancestors: PartyChainNode[];
  descendants: PartyChainNode[];
  chainTruncated: boolean;
  depthReached: number;
}

/** PartyChainTraverseResponse — discriminated union returned by GET /chain. */
export type PartyChainTraverseResponse =
  | PartyChainTraverseUpResponse
  | PartyChainTraverseDownResponse
  | PartyChainBothResponse;

/** PartyChainSummaryRoot — root party light projection. */
export interface PartyChainSummaryRoot {
  id: number;
  nameEn: string;
  nameAr: string | null;
  sanctionsStatus: SanctionsStatus;
  esgScore: number | null;
  icvStatus: IcvStatus | null;
  icvPct: number | null;
}

/**
 * RelationshipTypeCounts — fn_party_chain_summary directRelationshipCounts.
 * AC-S8-03 invariant: ALL 6 keys ALWAYS present, default 0.
 */
export interface RelationshipTypeCounts {
  parent: number;
  ubo: number;
  subsidiary: number;
  sub_contractor: number;
  jv: number;
  controlling_shareholder: number;
}

/** PartyChainSummary — fn_party_chain_summary JSONB output. */
export interface PartyChainSummary {
  rootParty: PartyChainSummaryRoot;
  ancestorsByDepth: Record<string, PartyChainNode[]>;
  descendantsByDepth: Record<string, PartyChainNode[]>;
  directRelationshipCounts: RelationshipTypeCounts;
  chainTruncated: boolean;
}

// ============================================================
// 5. Sanctions match types
// ============================================================

/** PartySanctionsMatchInput — body of POST /api/v1/admin/parties/sanctions-match. */
export interface PartySanctionsMatchInput {
  signalEntities: EntityReference[];
  similarityThreshold?: number;
}

/** PartySanctionsMatchEntry — single match in the response. */
export interface PartySanctionsMatchEntry {
  partyId: number;
  name: string;
  matchedEntityName: string;
  matchType: SanctionsMatchType;
  similarity: number;
  chainPath: Array<{
    partyId: number;
    depth: number;
    relationshipType: RelationshipType;
  }> | null;
}

/** PartySanctionsMatchResponse — fn_party_sanctions_match JSONB output. */
export interface PartySanctionsMatchResponse {
  matches: PartySanctionsMatchEntry[];
}

// ============================================================
// 6. Party-update DTO (editable subset)
// ============================================================

/**
 * PartyUpdatePayload — PATCH /api/v1/parties/:id body.
 * sanctions_* columns silently ignored (Q-DA4 lock).
 *
 * `parentId` / `uboId` sentinel handling:
 *   - omitted (undefined) → leave unchanged
 *   - null                → explicitly unset (BE controller maps to -1
 *                            before calling fn_party_update)
 *   - <number>            → set to that party id (active-state pre-checked)
 */
export interface PartyUpdatePayload {
  // Existing M_parity columns
  nameEn?: string;
  nameAr?: string | null;
  emirate?: string | null;
  freeZone?: string | null;
  country?: string | null;
  contactEmail?: string | null;
  contactPhone?: string | null;
  registeredAddress?: string | null;
  notes?: string | null;
  tradeLicenseNumber?: string | null;
  tradeLicenseIssuer?: string | null;

  // M9 (CR-B) editable subset
  parentId?: number | null;
  uboId?: number | null;
  aliases?: PartyAlias[];
  esgScore?: number | null;
  icvStatus?: IcvStatus | null;
  icvPct?: number | null;
  icvLastChecked?: string | null;
  metadata?: Record<string, unknown>;
}

// ============================================================
// 7. API response envelopes (convenience aliases)
// ============================================================

export type PartyDetailResponse = ApiResponse<PartyDetail>;
export type PartyRelationshipResponse = ApiResponse<PartyRelationship>;
export type ListRelationshipsApiResponse = ApiResponse<ListRelationshipsResponse>;
export type DeleteRelationshipApiResponse = ApiResponse<DeleteRelationshipResponse>;
export type PartyChainTraverseApiResponse = ApiResponse<PartyChainTraverseResponse>;
export type PartyChainSummaryApiResponse = ApiResponse<PartyChainSummary>;
export type PartySanctionsMatchApiResponse = ApiResponse<PartySanctionsMatchResponse>;

// ============================================================
// 8. Re-exports from M0 / M7 registries (convenience)
// ============================================================

export type { ApiResponse, PaginationMeta, Paginated } from './api.types';
export type { EntityReference } from './osint.types';
