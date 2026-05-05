/**
 * Regulatory service — thin DB-passthrough for M5 (Regulatory Radar).
 *
 * One service function per fn_; each returns the parsed JSONB envelope.
 * Positional argument ordering is taken DIRECTLY from migration 050 fn_
 * signatures. Any drift here will surface as a 500 at controller invocation.
 *
 *   Library:
 *     fn_regulation_list             (S1 — read)
 *     fn_regulation_get_by_id        (S2 — read)
 *     fn_regulation_create           (S3 — write, INVOKER, regulations.manage)
 *     fn_regulation_update           (S4 — write, INVOKER, regulations.manage)
 *     fn_regulation_delete           (S5 — write, INVOKER, platform_admin only)
 *
 *   Radar:
 *     fn_regulatory_update_list      (S6 — read)
 *     fn_regulatory_update_get_by_id (S7 — read)
 *     fn_regulatory_update_create    (S8 — write, INVOKER, regulations.manage)
 *     fn_regulatory_update_update    (S9 — write, INVOKER, regulations.manage)
 *     fn_regulatory_update_delete    (S10 — write, INVOKER, platform_admin)
 *
 *   Impact detection:
 *     fn_regulatory_impact_create_bulk (S11 — write, DEFINER carve-out)
 *     fn_regulatory_impact_list        (S12 — read)
 *     fn_regulatory_impact_resolve     (S13 — write, polymorphic permission)
 *
 *   Taxonomy:
 *     fn_impact_category_list          (S14 — read, no permission gate)
 *     fn_impact_category_upsert        (S15 — write, config.manage)
 *
 * RLS context: every call passes opts.actorId so callFunction sets
 * `app.current_user_id` GUC inside the same transaction. Required by all
 * INVOKER fn_'s; harmless on the single DEFINER carve-out
 * (fn_regulatory_impact_create_bulk).
 */
import { db } from '../database/client';
import type {
  BulkDetectRegulatoryImpactDto,
  BulkDetectRegulatoryImpactResult,
  CreateRegulationDto,
  CreateRegulatoryUpdateDto,
  ImpactCategoryListResponse,
  ImpactCategoryUpsertResult,
  Regulation,
  RegulationCreateResult,
  RegulationDeleteResult,
  RegulationListQuery,
  RegulationListResponse,
  RegulationUpdateResult,
  RegulatoryImpactListQuery,
  RegulatoryImpactListResponse,
  RegulatoryImpactResolveResult,
  RegulatoryUpdate,
  RegulatoryUpdateCreateResult,
  RegulatoryUpdateDeleteResult,
  RegulatoryUpdateListQuery,
  RegulatoryUpdateListResponse,
  RegulatoryUpdateUpdateResult,
  ResolveRegulatoryImpactDto,
  UpdateRegulationDto,
  UpdateRegulatoryUpdateDto,
  UpsertImpactCategoryDto,
} from '../types/regulatory.types';

// ============================================================
// Regulation library (S1–S5)
// ============================================================

/** GET /api/v1/regulations → fn_regulation_list (S1). */
export const listRegulations = (
  actorId: number,
  q: RegulationListQuery,
): Promise<RegulationListResponse> =>
  db.callFunction<RegulationListResponse>(
    'fn_regulation_list',
    [
      q.page ?? 1,
      q.limit ?? 20,
      q.jurisdiction ?? null,
      q.regulationType ?? null,
      q.issuerId ?? null,
      q.status ?? null,
      q.search ?? null,
    ],
    { actorId },
  );

/** GET /api/v1/regulations/:id → fn_regulation_get_by_id (S2). NULL → 404 at controller. */
export const getRegulationById = (
  actorId: number,
  id: number,
): Promise<Regulation | null> =>
  db.callFunction<Regulation | null>(
    'fn_regulation_get_by_id',
    [id],
    { actorId },
  );

/** POST /api/v1/regulations → fn_regulation_create (S3). */
export const createRegulation = (
  actorId: number,
  body: CreateRegulationDto,
): Promise<RegulationCreateResult> =>
  db.callFunction<RegulationCreateResult>(
    'fn_regulation_create',
    [
      body.referenceCode,
      body.titleEn,
      body.titleAr ?? null,
      body.issuerId,
      body.regulationType,
      body.jurisdiction ?? null,
      body.effectiveDate ?? null,
      body.summaryEn ?? null,
      body.summaryAr ?? null,
      body.sourceUrl ?? null,
      body.tags ?? null,
      body.status ?? null,
      actorId,
    ],
    { actorId },
  );

/** PATCH /api/v1/regulations/:id → fn_regulation_update (S4). */
export const updateRegulation = (
  actorId: number,
  id: number,
  patch: UpdateRegulationDto,
): Promise<RegulationUpdateResult> =>
  db.callFunction<RegulationUpdateResult>(
    'fn_regulation_update',
    [id, patch, actorId],
    { actorId },
  );

/** DELETE /api/v1/regulations/:id → fn_regulation_delete (S5). */
export const deleteRegulation = (
  actorId: number,
  id: number,
): Promise<RegulationDeleteResult> =>
  db.callFunction<RegulationDeleteResult>(
    'fn_regulation_delete',
    [id, actorId],
    { actorId },
  );

// ============================================================
// Regulatory updates (radar feed S6–S10)
// ============================================================

/** GET /api/v1/regulatory-updates → fn_regulatory_update_list (S6). */
export const listRegulatoryUpdates = (
  actorId: number,
  q: RegulatoryUpdateListQuery,
): Promise<RegulatoryUpdateListResponse> =>
  db.callFunction<RegulatoryUpdateListResponse>(
    'fn_regulatory_update_list',
    [
      q.page ?? 1,
      q.limit ?? 20,
      q.regulatorId ?? null,
      q.severity ?? null,
      q.categoryId ?? null,
      q.effectiveFrom ?? null,
      q.effectiveTo ?? null,
      q.complianceDeadlineMax ?? null,
    ],
    { actorId },
  );

/** GET /api/v1/regulatory-updates/:id → fn_regulatory_update_get_by_id (S7). NULL → 404. */
export const getRegulatoryUpdateById = (
  actorId: number,
  id: number,
): Promise<RegulatoryUpdate | null> =>
  db.callFunction<RegulatoryUpdate | null>(
    'fn_regulatory_update_get_by_id',
    [id],
    { actorId },
  );

/** POST /api/v1/regulatory-updates → fn_regulatory_update_create (S8). */
export const createRegulatoryUpdate = (
  actorId: number,
  body: CreateRegulatoryUpdateDto,
): Promise<RegulatoryUpdateCreateResult> =>
  db.callFunction<RegulatoryUpdateCreateResult>(
    'fn_regulatory_update_create',
    [
      body.regulatorId,
      body.titleEn,
      body.titleAr ?? null,
      body.summaryEn ?? null,
      body.summaryAr ?? null,
      body.referenceNumber ?? null,
      body.publishedDate,
      body.effectiveDate ?? null,
      body.complianceDeadline ?? null,
      body.severity ?? null,
      body.sourceUrl ?? null,
      body.affectedClauseCategories ?? null,
      body.categoryId ?? null,
      body.subSource ?? null,
      actorId,
    ],
    { actorId },
  );

/** PATCH /api/v1/regulatory-updates/:id → fn_regulatory_update_update (S9). */
export const updateRegulatoryUpdate = (
  actorId: number,
  id: number,
  patch: UpdateRegulatoryUpdateDto,
): Promise<RegulatoryUpdateUpdateResult> =>
  db.callFunction<RegulatoryUpdateUpdateResult>(
    'fn_regulatory_update_update',
    [id, patch, actorId],
    { actorId },
  );

/** DELETE /api/v1/regulatory-updates/:id → fn_regulatory_update_delete (S10). */
export const deleteRegulatoryUpdate = (
  actorId: number,
  id: number,
): Promise<RegulatoryUpdateDeleteResult> =>
  db.callFunction<RegulatoryUpdateDeleteResult>(
    'fn_regulatory_update_delete',
    [id, actorId],
    { actorId },
  );

// ============================================================
// Regulatory impact detection (S11–S13)
// ============================================================

/**
 * POST /api/v1/regulatory-impacts/bulk-detect → fn_regulatory_impact_create_bulk (S11).
 *
 * Only DEFINER carve-out in M5 (DN-3). S2-17 atomic gate+commit
 * (SELECT FOR UPDATE on regulatory_update row before per-contract loop) is
 * inside the fn body; controller does NOT replicate. Impact payload is
 * SENSITIVE — pino-redacted at the controller via the 'impactPayload'
 * key (logger.util.ts SENSITIVE_PATHS).
 */
export const bulkDetectRegulatoryImpacts = (
  actorId: number,
  body: BulkDetectRegulatoryImpactDto,
): Promise<BulkDetectRegulatoryImpactResult> =>
  db.callFunction<BulkDetectRegulatoryImpactResult>(
    'fn_regulatory_impact_create_bulk',
    [
      body.regulatoryUpdateId,
      body.regulationId,
      body.contractIds,
      body.impactPayload,
      actorId,
    ],
    { actorId },
  );

/** GET /api/v1/regulatory-impacts → fn_regulatory_impact_list (S12). */
export const listRegulatoryImpacts = (
  actorId: number,
  q: RegulatoryImpactListQuery,
): Promise<RegulatoryImpactListResponse> =>
  db.callFunction<RegulatoryImpactListResponse>(
    'fn_regulatory_impact_list',
    [
      q.page ?? 1,
      q.limit ?? 20,
      q.contractId ?? null,
      q.regulationId ?? null,
      q.regulatoryUpdateId ?? null,
      q.resolved ?? null,
    ],
    { actorId },
  );

/**
 * PATCH /api/v1/regulatory-impacts/:id/resolve → fn_regulatory_impact_resolve (S13).
 *
 * Polymorphic permission (W2): the fn body checks
 *   regulations.manage  OR  contract.drafted_by = current_user
 * The controller pre-gates with authoriseAnyOf so a caller without ANY
 * relevant permission gets a clean 403 without reaching the DB; the fn
 * raises 42501 → 403 if the polymorphic OR-branch fails inside.
 */
export const resolveRegulatoryImpact = (
  actorId: number,
  id: number,
  body: ResolveRegulatoryImpactDto,
): Promise<RegulatoryImpactResolveResult> =>
  db.callFunction<RegulatoryImpactResolveResult>(
    'fn_regulatory_impact_resolve',
    [id, body.resolutionAction, body.resolutionNote ?? null, actorId],
    { actorId },
  );

// ============================================================
// Impact taxonomy (S14–S15)
// ============================================================

/** GET /api/v1/impact-categories → fn_impact_category_list (S14). */
export const listImpactCategories = (
  actorId: number,
  includeInactive: boolean | undefined,
): Promise<ImpactCategoryListResponse> =>
  db.callFunction<ImpactCategoryListResponse>(
    'fn_impact_category_list',
    [includeInactive ?? null],
    { actorId },
  );

/**
 * POST /api/v1/impact-categories → fn_impact_category_upsert (S15).
 *
 * fn parameter types vs DTO array shapes:
 *   - p_sources         JSONB   ← body.sources (string[])
 *   - p_severity_scale  JSONB   ← body.severityScale (string[])
 *   - p_default_clause_categories TEXT[] ← body.defaultClauseCategories (string[])
 *
 * `db.callFunction` auto-binds string[] as Postgres TEXT[] (the
 * containsObject branch only fires for arrays-of-objects). The two JSONB
 * fields above must be hand-serialised so pg sends them as JSON text;
 * callFunction will JSON.stringify any plain object, so we wrap the JSONB
 * arrays via a minimal `{ value }` envelope... actually no — passing the
 * raw string[] to a plain object spread would still send it as TEXT[].
 * Instead we route the JSONB arrays through `toJsonbArg` which performs
 * an explicit JSON.stringify. The receiver fn body uses jsonb_typeof /
 * jsonb_array_length on these arguments, so they MUST arrive as JSONB.
 */
const toJsonbArg = (arr: ReadonlyArray<string> | null | undefined): string | null =>
  arr ? JSON.stringify(arr) : null;

export const upsertImpactCategory = (
  actorId: number,
  body: UpsertImpactCategoryDto,
): Promise<ImpactCategoryUpsertResult> =>
  db.callFunction<ImpactCategoryUpsertResult>(
    'fn_impact_category_upsert',
    [
      body.key,
      body.nameEn,
      body.nameAr,
      body.descriptionEn ?? null,
      body.descriptionAr ?? null,
      body.icon ?? null,
      body.colour ?? null,
      body.active ?? null,
      body.displayOrder ?? null,
      // p_sources JSONB — string[] must be JSON-stringified, not bound as
      // Postgres TEXT[].
      toJsonbArg(body.sources),
      // p_severity_scale JSONB — same.
      toJsonbArg(body.severityScale),
      body.aiPromptContext ?? null,
      // p_default_clause_categories TEXT[] — leave as native array; pg
      // binds to TEXT[] correctly without stringification.
      body.defaultClauseCategories ?? null,
      actorId,
    ],
    { actorId },
  );
