/**
 * /api/v1/regulations + /regulatory-updates + /regulatory-impacts +
 * /impact-categories — M5 Regulatory Radar (15 endpoints).
 *
 * Mounted as four sibling routers from src/routes/v1/index.ts.
 *
 * Permission codes (Q2 — seeded by migration 046):
 *   regulations.read      — list/get/list-impact endpoints
 *   regulations.manage    — write endpoints (create/update/bulk-detect/resolve)
 *   config.manage         — impact_category upsert (platform_admin only)
 *
 * Polymorphic permission (W2 — QA Stage 3):
 *   PATCH /regulatory-impacts/:id/resolve gates with authoriseAnyOf
 *   ([regulations.read, regulations.manage]) at the route layer (broad
 *   pre-gate so callers without ANY relevant grant fail fast as 403).
 *   The fn body enforces the strict OR-branch (regulations.manage OR
 *   drafted_by = current_user) and raises 42501 if a non-manager,
 *   non-drafter passes the route gate.
 *
 * Auth mode: 15/15 endpoints JWT (Q1 confirmed — zero new PUBLIC,
 * zero signed-token).
 *
 * Rate limits:
 *   GETs   → authedReadRateLimiter  (120/min/user)
 *   Writes → authedWriteRateLimiter (60/min/user)
 */
import { Router } from 'express';
import {
  authenticate,
  authorise,
  authoriseAnyOf,
} from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  impactCategoriesController,
  regulationsController,
  regulatoryImpactsController,
  regulatoryUpdatesController,
} from '../../controllers/regulatory.controller';
import {
  bulkDetectRegulatoryImpactSchema,
  createRegulationSchema,
  createRegulatoryUpdateSchema,
  impactCategoryListQuerySchema,
  regulationListQuerySchema,
  regulatoryIdParamSchema,
  regulatoryImpactListQuerySchema,
  regulatoryUpdateListQuerySchema,
  resolveRegulatoryImpactSchema,
  updateRegulationSchema,
  updateRegulatoryUpdateSchema,
  upsertImpactCategorySchema,
} from '../../schemas/regulatory.schemas';

// ============================================================
// 1. /api/v1/regulations — S1..S5
// ============================================================
const regulationsRouter = Router();
regulationsRouter.use(authenticate);

// GET /api/v1/regulations → S1
regulationsRouter.get(
  '/',
  authedReadRateLimiter,
  authorise(['regulations.read']),
  validate(regulationListQuerySchema, 'query'),
  regulationsController.list,
);

// POST /api/v1/regulations → S3
regulationsRouter.post(
  '/',
  authedWriteRateLimiter,
  authorise(['regulations.manage']),
  validate(createRegulationSchema, 'body'),
  regulationsController.create,
);

// GET /api/v1/regulations/:id → S2
regulationsRouter.get(
  '/:id',
  authedReadRateLimiter,
  authorise(['regulations.read']),
  validate(regulatoryIdParamSchema, 'params'),
  regulationsController.getById,
);

// PATCH /api/v1/regulations/:id → S4
regulationsRouter.patch(
  '/:id',
  authedWriteRateLimiter,
  authorise(['regulations.manage']),
  validate(regulatoryIdParamSchema, 'params'),
  validate(updateRegulationSchema, 'body'),
  regulationsController.update,
);

// DELETE /api/v1/regulations/:id → S5 (platform_admin only — fn body enforces)
regulationsRouter.delete(
  '/:id',
  authedWriteRateLimiter,
  // Route-level gate uses regulations.manage; the fn body raises 42501
  // if the caller is not platform_admin (AC-S5-04 — legal_counsel cannot
  // delete). translatePgError maps 42501 → ForbiddenError(403).
  authorise(['regulations.manage']),
  validate(regulatoryIdParamSchema, 'params'),
  regulationsController.delete,
);

// ============================================================
// 2. /api/v1/regulatory-updates — S6..S10
// ============================================================
const regulatoryUpdatesRouter = Router();
regulatoryUpdatesRouter.use(authenticate);

// GET /api/v1/regulatory-updates → S6
regulatoryUpdatesRouter.get(
  '/',
  authedReadRateLimiter,
  authorise(['regulations.read']),
  validate(regulatoryUpdateListQuerySchema, 'query'),
  regulatoryUpdatesController.list,
);

// POST /api/v1/regulatory-updates → S8
regulatoryUpdatesRouter.post(
  '/',
  authedWriteRateLimiter,
  authorise(['regulations.manage']),
  validate(createRegulatoryUpdateSchema, 'body'),
  regulatoryUpdatesController.create,
);

// GET /api/v1/regulatory-updates/:id → S7
regulatoryUpdatesRouter.get(
  '/:id',
  authedReadRateLimiter,
  authorise(['regulations.read']),
  validate(regulatoryIdParamSchema, 'params'),
  regulatoryUpdatesController.getById,
);

// PATCH /api/v1/regulatory-updates/:id → S9
regulatoryUpdatesRouter.patch(
  '/:id',
  authedWriteRateLimiter,
  authorise(['regulations.manage']),
  validate(regulatoryIdParamSchema, 'params'),
  validate(updateRegulatoryUpdateSchema, 'body'),
  regulatoryUpdatesController.update,
);

// DELETE /api/v1/regulatory-updates/:id → S10 (platform_admin only — fn enforces)
regulatoryUpdatesRouter.delete(
  '/:id',
  authedWriteRateLimiter,
  authorise(['regulations.manage']),
  validate(regulatoryIdParamSchema, 'params'),
  regulatoryUpdatesController.delete,
);

// ============================================================
// 3. /api/v1/regulatory-impacts — S11..S13
// ============================================================
const regulatoryImpactsRouter = Router();
regulatoryImpactsRouter.use(authenticate);

// W1 — literal-path routes BEFORE :id-prefixed routes (Express matches in
// declaration order; '/regulatory-impacts/:id' would otherwise bind
// :id='bulk-detect' for a request to /regulatory-impacts/bulk-detect).

// POST /api/v1/regulatory-impacts/bulk-detect → S11 (DEFINER fn_)
regulatoryImpactsRouter.post(
  '/bulk-detect',
  authedWriteRateLimiter,
  authorise(['regulations.manage']),
  validate(bulkDetectRegulatoryImpactSchema, 'body'),
  regulatoryImpactsController.bulkDetect,
);

// GET /api/v1/regulatory-impacts → S12
regulatoryImpactsRouter.get(
  '/',
  authedReadRateLimiter,
  authorise(['regulations.read']),
  validate(regulatoryImpactListQuerySchema, 'query'),
  regulatoryImpactsController.list,
);

// PATCH /api/v1/regulatory-impacts/:id/resolve → S13 (polymorphic permission)
//
// W2 — Broad route gate so callers with NO relevant permission fail fast
// at 403 without reaching the DB. The fn body enforces the strict polymorphic
// OR-branch (regulations.manage OR drafted_by = current_user); a contract
// drafter without regulations.manage will pass the gate (they hold
// regulations.read) and the fn will allow them when their drafted_by
// matches; a caller without either passes the gate (still has
// regulations.read) and the fn raises 42501 → 403 with the structured
// 'forbidden:regulations.manage required (or be the contract drafter)'.
regulatoryImpactsRouter.patch(
  '/:id/resolve',
  authedWriteRateLimiter,
  authoriseAnyOf(['regulations.read', 'regulations.manage']),
  validate(regulatoryIdParamSchema, 'params'),
  validate(resolveRegulatoryImpactSchema, 'body'),
  regulatoryImpactsController.resolve,
);

// ============================================================
// 4. /api/v1/impact-categories — S14..S15
// ============================================================
const impactCategoriesRouter = Router();
impactCategoriesRouter.use(authenticate);

// GET /api/v1/impact-categories → S14 (any authenticated; no permission gate)
impactCategoriesRouter.get(
  '/',
  authedReadRateLimiter,
  validate(impactCategoryListQuerySchema, 'query'),
  impactCategoriesController.list,
);

// POST /api/v1/impact-categories → S15 (config.manage; platform_admin only)
//
// Per api-contracts.json (canonical contract): POST + body-keyed upsert
// (createdOrUpdated discriminator distinguishes branches; status 200
// returned for both per AC-S15-01 / AC-S15-02 — idiomatic for upsert).
impactCategoriesRouter.post(
  '/',
  authedWriteRateLimiter,
  authorise(['config.manage']),
  validate(upsertImpactCategorySchema, 'body'),
  impactCategoriesController.upsert,
);

// ============================================================
// Aggregated default export — convenience handle for index.ts
// ============================================================
//
// Exporting the four routers individually keeps index.ts symmetric with
// the four URL prefixes. We also expose a single barrel object so future
// callers (e.g. test harnesses) can mount them in bulk.
export const regulatoryRouters = {
  regulations: regulationsRouter,
  regulatoryUpdates: regulatoryUpdatesRouter,
  regulatoryImpacts: regulatoryImpactsRouter,
  impactCategories: impactCategoriesRouter,
} as const;

export {
  regulationsRouter,
  regulatoryUpdatesRouter,
  regulatoryImpactsRouter,
  impactCategoriesRouter,
};

export default regulatoryRouters;
