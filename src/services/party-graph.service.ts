/**
 * M9 — Counterparty Graph (CR-B) service.
 *
 * Thin DB-passthrough for the 9 net-new fn_'s introduced by Migrations
 * 116/118/119/120 + the existing fn_party_get_by_id (extended). Every
 * service function calls db.callFunction exactly once — no business logic
 * in this layer (CLAUDE.md §2: "Backend = thin HTTP layer").
 *
 * Permission gates live inside each fn_ body:
 *   - party.graph.read     — list + chain + chain-summary (read paths)
 *   - party.graph.manage   — relationship create / update / delete +
 *                             admin sanctions-match
 *   - contract.edit OR party.graph.manage — fn_party_update
 *
 * Tenant GUC is set via db.callFunction({ tenantId }) using `req.tenantId`
 * resolved by rls.middleware. party_relationship enforces FORCE RLS on
 * the tenant scope; party.* self-FK columns are single-tenant per Q-DA7.
 *
 * fn_party_chain_traverse_up + _down are exposed both individually (for
 * direction='up' / direction='down') and via fn_party_chain_summary which
 * already invokes both internally (see db-design.md §4.4). The composer
 * for direction='both' makes two parallel callFunction invocations and
 * merges the two responses into a PartyChainBothResponse — saves the FE
 * the extra roundtrip without paying the chain_summary aggregation cost
 * (which includes an extra fn_party_relationship_list call).
 */
import { db } from '../database/client';
import type {
  CreateRelationshipPayload,
  DeleteRelationshipResponse,
  ListRelationshipsResponse,
  PartyChainBothResponse,
  PartyChainSummary,
  PartyChainTraverseDownResponse,
  PartyChainTraverseUpResponse,
  PartyDetail,
  PartyRelationship,
  PartySanctionsMatchInput,
  PartySanctionsMatchResponse,
  PartyUpdatePayload,
  UpdateRelationshipPayload,
} from '../types/party-graph.types';

// ============================================================
// Relationship CRUD (4 endpoints)
// ============================================================

/** GET /api/v1/parties/:id/relationships → fn_party_relationship_list. */
export const listRelationships = (
  actorId: number,
  tenantId: string | undefined,
  partyId: number,
): Promise<ListRelationshipsResponse> =>
  db.callFunction<ListRelationshipsResponse>(
    'fn_party_relationship_list',
    [actorId, partyId],
    { actorId, tenantId },
  );

/**
 * POST /api/v1/parties/:id/relationships → fn_party_relationship_create.
 *
 * URL :id supplies parentId; payload supplies childId.
 */
export const createRelationship = (
  actorId: number,
  tenantId: string | undefined,
  parentId: number,
  payload: CreateRelationshipPayload,
): Promise<PartyRelationship> =>
  db.callFunction<PartyRelationship>(
    'fn_party_relationship_create',
    [
      actorId,
      parentId,
      payload.childId,
      payload.relationshipType,
      payload.ownershipPct ?? null,
      payload.effectiveFrom ?? null,
      payload.effectiveTo ?? null,
      payload.source ?? 'manual',
      payload.confidence ?? 1.0,
      payload.metadata ?? {},
    ],
    { actorId, tenantId },
  );

/**
 * PATCH /api/v1/parties/:id/relationships/:relId → fn_party_relationship_update.
 *
 * NULL = leave alone (COALESCE pattern in fn body). parent_id / child_id are
 * NOT in this DTO — endpoint immutability after create (AC-S2-04).
 */
export const updateRelationship = (
  actorId: number,
  tenantId: string | undefined,
  relationshipId: number,
  payload: UpdateRelationshipPayload,
): Promise<PartyRelationship> =>
  db.callFunction<PartyRelationship>(
    'fn_party_relationship_update',
    [
      actorId,
      relationshipId,
      payload.relationshipType ?? null,
      payload.ownershipPct ?? null,
      payload.effectiveFrom ?? null,
      payload.effectiveTo ?? null,
      payload.source ?? null,
      payload.confidence ?? null,
      payload.metadata ?? null,
    ],
    { actorId, tenantId },
  );

/**
 * DELETE /api/v1/parties/:id/relationships/:relId → fn_party_relationship_delete.
 *
 * Idempotent: returns { success: true, deletedAt, idempotent } whether the
 * edge was already soft-deleted or freshly removed (AC-S3-02).
 */
export const deleteRelationship = (
  actorId: number,
  tenantId: string | undefined,
  relationshipId: number,
): Promise<DeleteRelationshipResponse> =>
  db.callFunction<DeleteRelationshipResponse>(
    'fn_party_relationship_delete',
    [actorId, relationshipId],
    { actorId, tenantId },
  );

// ============================================================
// Chain traversal (1 endpoint, 3 sub-modes via direction= query)
// ============================================================

/** Internal — direction='up' single call. */
export const traverseChainUp = (
  actorId: number,
  tenantId: string | undefined,
  partyId: number,
  maxDepth: number,
): Promise<PartyChainTraverseUpResponse> =>
  db.callFunction<PartyChainTraverseUpResponse>(
    'fn_party_chain_traverse_up',
    [actorId, partyId, maxDepth],
    { actorId, tenantId },
  );

/** Internal — direction='down' single call. */
export const traverseChainDown = (
  actorId: number,
  tenantId: string | undefined,
  partyId: number,
  maxDepth: number,
): Promise<PartyChainTraverseDownResponse> =>
  db.callFunction<PartyChainTraverseDownResponse>(
    'fn_party_chain_traverse_down',
    [actorId, partyId, maxDepth],
    { actorId, tenantId },
  );

/**
 * direction='both' composer — invokes _up and _down in parallel then merges
 * into PartyChainBothResponse. chainTruncated is OR'd, depthReached is MAX'd.
 *
 * Note: this is the ONE place in the codebase where two fn_ calls are made
 * inside a single service function. The composition is purely structural
 * (no business logic); each fn already enforces its own permission gate +
 * existence pre-check, so the two-call pattern doesn't widen the security
 * surface. Errors from either call propagate verbatim via translatePgError.
 */
export const traverseChainBoth = async (
  actorId: number,
  tenantId: string | undefined,
  partyId: number,
  maxDepth: number,
): Promise<PartyChainBothResponse> => {
  const [up, down] = await Promise.all([
    traverseChainUp(actorId, tenantId, partyId, maxDepth),
    traverseChainDown(actorId, tenantId, partyId, maxDepth),
  ]);
  return {
    rootPartyId: up.rootPartyId,
    ancestors: up.ancestors,
    descendants: down.descendants,
    chainTruncated: Boolean(up.chainTruncated) || Boolean(down.chainTruncated),
    depthReached: Math.max(up.depthReached ?? 0, down.depthReached ?? 0),
  };
};

// ============================================================
// Chain summary (1 endpoint)
// ============================================================

/** GET /api/v1/parties/:id/chain-summary → fn_party_chain_summary. */
export const getChainSummary = (
  actorId: number,
  tenantId: string | undefined,
  partyId: number,
  maxDepth: number,
): Promise<PartyChainSummary> =>
  db.callFunction<PartyChainSummary>(
    'fn_party_chain_summary',
    [actorId, partyId, maxDepth],
    { actorId, tenantId },
  );

// ============================================================
// Sanctions match (1 admin endpoint)
// ============================================================

/**
 * POST /api/v1/admin/parties/sanctions-match → fn_party_sanctions_match.
 *
 * Per HITL Q-DA4 lock: this fn returns matches only — does NOT update
 * party.sanctions_status. CR-E rule engine (out of M9 scope) writes the
 * status via a separate DEFINER carve-out.
 *
 * Per HITL Q-DA2 lock: similarityThreshold is optional. When omitted, the
 * fn body resolves the threshold from the GUC `app.party_sanctions_match_
 * threshold` then falls back to 0.7.
 */
export const sanctionsMatch = (
  actorId: number,
  tenantId: string | undefined,
  input: PartySanctionsMatchInput,
): Promise<PartySanctionsMatchResponse> =>
  db.callFunction<PartySanctionsMatchResponse>(
    'fn_party_sanctions_match',
    [actorId, input.signalEntities, input.similarityThreshold ?? null],
    { actorId, tenantId },
  );

// ============================================================
// Party update (extended PATCH /api/v1/parties/:id)
// ============================================================

/**
 * PATCH /api/v1/parties/:id → fn_party_update.
 *
 * Sentinel mapping for parentId / uboId:
 *   - undefined / omitted → pass NULL (fn COALESCE leaves the column alone)
 *   - null                → pass -1 (the fn's "explicitly unset" sentinel —
 *                            CASE WHEN p_parent_id = -1 THEN NULL ...)
 *   - number              → pass through as-is
 *
 * sanctionsStatus / sanctionsLastChecked / sanctionsMatchSignalId are not
 * in PartyUpdatePayload and have no fn parameter — they're silently ignored
 * by both layers per Q-DA4 / AC-S9-05.
 *
 * fn_party_update returns whatever fn_party_get_by_id(actor, party) returns
 * — the extended PartyDetail with all 11 new CR-B columns.
 */
const mapNullableIdToSentinel = (v: number | null | undefined): number | null => {
  if (v === undefined) return null; // leave alone
  if (v === null) return -1; // explicit unset
  return v;
};

export const updateParty = (
  actorId: number,
  partyId: number,
  payload: PartyUpdatePayload,
): Promise<PartyDetail> =>
  db.callFunction<PartyDetail>(
    'fn_party_update',
    [
      actorId,
      partyId,
      // Existing M_parity columns (positional order matches fn signature in
      // db-design.md §3.4 — verified against migration 120).
      payload.nameEn ?? null,
      payload.nameAr ?? null,
      // M9 (CR-B) editable subset
      mapNullableIdToSentinel(payload.parentId),
      mapNullableIdToSentinel(payload.uboId),
      // M9 DEFECT-1 fix: aliases is a string[] which db.callFunction would
      // otherwise bind as TEXT[] (no objects in the array). fn_party_update
      // expects JSONB → pre-stringify so pg binds as JSONB scalar.
      payload.aliases !== undefined ? JSON.stringify(payload.aliases) : null,
      payload.esgScore ?? null,
      payload.icvStatus ?? null,
      payload.icvPct ?? null,
      payload.icvLastChecked ?? null,
      payload.metadata ?? null,
      // Remaining M_parity columns
      payload.emirate ?? null,
      payload.freeZone ?? null,
      payload.country ?? null,
      payload.contactEmail ?? null,
      payload.contactPhone ?? null,
      payload.registeredAddress ?? null,
      payload.notes ?? null,
      payload.tradeLicenseNumber ?? null,
      payload.tradeLicenseIssuer ?? null,
    ],
    { actorId },
  );
