/**
 * M_parity routes — /api/v1/parties, /templates, /clauses, /obligations.
 *
 * Read-only this round (list + get for parties / templates / clauses; list
 * for obligations). All routes require an authenticated JWT; per-request
 * permission gating happens inside the fn_ body
 * (contract.read.department OR contract.edit). 42501 → 403 via
 * translatePgError.
 *
 * M9 (CR-B) extension — /api/v1/parties is extended with:
 *   - PATCH  /:id                                 — editable subset
 *   - GET    /:id/relationships                   — list edges
 *   - POST   /:id/relationships                   — create edge
 *   - PATCH  /:id/relationships/:relId            — update edge
 *   - DELETE /:id/relationships/:relId            — soft-delete edge
 *   - GET    /:id/chain?direction=&maxDepth=      — traverse chain
 *   - GET    /:id/chain-summary?maxDepth=         — chain summary
 * All M9 sub-routes flow through rls.middleware (tenant GUC) and gate
 * inside the fn_ body on party.graph.read / party.graph.manage /
 * (contract.edit OR party.graph.manage).
 */
import { Router } from 'express';
import { authenticate } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { authedReadRateLimiter, authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  partiesController,
  templatesController,
  clausesController,
  obligationsController,
} from '../../controllers/m_parity.controller';
import { partyGraphController } from '../../controllers/party-graph.controller';
import {
  CreatePartySchema,
  CreateTemplateSchema,
  UpdateTemplateSchema,
  ExtractTemplateFromContractSchema,
  AnalyzeTemplateUploadSchema,
  ExtractClausesFromContractSchema,
  CreateClauseSchema,
  CreateObligationSchema,
  FlagObligationSchema,
  IdParamSchema,
} from '../../schemas/m_parity.schemas';
import {
  partyIdParamSchema,
  partyRelationshipIdParamSchema,
  createRelationshipSchema,
  updateRelationshipSchema,
  partyChainTraverseQuerySchema,
  partyChainSummaryQuerySchema,
  partyUpdateSchema,
} from '../../schemas/party-graph.schemas';

const partiesRouter = Router();
partiesRouter.use(authenticate);
// M9 — tenant GUC needed by party_relationship + chain fn_'s. Mounting the
// middleware here is harmless for the existing M_parity reads (pre-M9 fn_'s
// don't read app.current_tenant_id).
partiesRouter.use(rlsMiddleware);

partiesRouter.get('/', authedReadRateLimiter, partiesController.list);
partiesRouter.post('/', authedWriteRateLimiter, validate(CreatePartySchema, 'body'), partiesController.create);
partiesRouter.get('/:id', authedReadRateLimiter, validate(IdParamSchema, 'params'), partiesController.getById);

// ----------------------------------------------------------
// M9 (CR-B) sub-routes — relationships + chain + chain-summary + PATCH /:id
// ----------------------------------------------------------

// PATCH /api/v1/parties/:id — editable subset (M9 ep_party_update / S9).
// Gate: contract.edit OR party.graph.manage (fn body raises 42501 if neither).
partiesRouter.patch(
  '/:id',
  authedWriteRateLimiter,
  validate(partyIdParamSchema, 'params'),
  validate(partyUpdateSchema, 'body'),
  partyGraphController.updateParty,
);

// GET /api/v1/parties/:id/chain
partiesRouter.get(
  '/:id/chain',
  authedReadRateLimiter,
  validate(partyIdParamSchema, 'params'),
  validate(partyChainTraverseQuerySchema, 'query'),
  partyGraphController.traverseChain,
);

// GET /api/v1/parties/:id/chain-summary
partiesRouter.get(
  '/:id/chain-summary',
  authedReadRateLimiter,
  validate(partyIdParamSchema, 'params'),
  validate(partyChainSummaryQuerySchema, 'query'),
  partyGraphController.chainSummary,
);

// GET /api/v1/parties/:id/relationships
partiesRouter.get(
  '/:id/relationships',
  authedReadRateLimiter,
  validate(partyIdParamSchema, 'params'),
  partyGraphController.listRelationships,
);

// POST /api/v1/parties/:id/relationships
partiesRouter.post(
  '/:id/relationships',
  authedWriteRateLimiter,
  validate(partyIdParamSchema, 'params'),
  validate(createRelationshipSchema, 'body'),
  partyGraphController.createRelationship,
);

// PATCH /api/v1/parties/:id/relationships/:relId
partiesRouter.patch(
  '/:id/relationships/:relId',
  authedWriteRateLimiter,
  validate(partyRelationshipIdParamSchema, 'params'),
  validate(updateRelationshipSchema, 'body'),
  partyGraphController.updateRelationship,
);

// DELETE /api/v1/parties/:id/relationships/:relId
partiesRouter.delete(
  '/:id/relationships/:relId',
  authedWriteRateLimiter,
  validate(partyRelationshipIdParamSchema, 'params'),
  partyGraphController.deleteRelationship,
);

const templatesRouter = Router();
templatesRouter.use(authenticate);
templatesRouter.get('/', authedReadRateLimiter, templatesController.list);
templatesRouter.post('/', authedWriteRateLimiter, validate(CreateTemplateSchema, 'body'), templatesController.create);
// AI-assisted template generation from an uploaded contract's extracted text.
// Mounted BEFORE /:id so the literal path segment wins over the dynamic param.
templatesRouter.post(
  '/extract-from-contract',
  authedWriteRateLimiter,
  validate(ExtractTemplateFromContractSchema, 'body'),
  templatesController.extractFromContract,
);
// AI-assisted analyze: extract + similarity match against library templates
// + clause cross-check against library clauses. One round-trip drives the
// "Match results" step on the New Template upload page.
templatesRouter.post(
  '/analyze-upload',
  authedWriteRateLimiter,
  validate(AnalyzeTemplateUploadSchema, 'body'),
  templatesController.analyzeUpload,
);
templatesRouter.get('/:id', authedReadRateLimiter, validate(IdParamSchema, 'params'), templatesController.getById);
templatesRouter.get(
  '/:id/default-clauses',
  authedReadRateLimiter,
  validate(IdParamSchema, 'params'),
  templatesController.defaultClauses,
);
templatesRouter.patch(
  '/:id',
  authedWriteRateLimiter,
  validate(IdParamSchema, 'params'),
  validate(UpdateTemplateSchema, 'body'),
  templatesController.update,
);
templatesRouter.delete(
  '/:id',
  authedWriteRateLimiter,
  validate(IdParamSchema, 'params'),
  templatesController.remove,
);

const clausesRouter = Router();
clausesRouter.use(authenticate);
clausesRouter.get('/', authedReadRateLimiter, clausesController.list);
clausesRouter.post('/', authedWriteRateLimiter, validate(CreateClauseSchema, 'body'), clausesController.create);
// AI-assisted clause extraction from an uploaded contract's extracted text.
// Mounted BEFORE /:id so the literal path segment wins over the dynamic param.
clausesRouter.post(
  '/extract-from-contract',
  authedWriteRateLimiter,
  validate(ExtractClausesFromContractSchema, 'body'),
  clausesController.extractFromContract,
);
clausesRouter.get('/:id', authedReadRateLimiter, validate(IdParamSchema, 'params'), clausesController.getById);

const obligationsRouter = Router();
obligationsRouter.use(authenticate);
obligationsRouter.get('/', authedReadRateLimiter, obligationsController.list);
obligationsRouter.post('/', authedWriteRateLimiter, validate(CreateObligationSchema, 'body'), obligationsController.create);
obligationsRouter.post(
  '/:id/flag',
  authedWriteRateLimiter,
  validate(IdParamSchema, 'params'),
  validate(FlagObligationSchema, 'body'),
  obligationsController.flag,
);

export {
  partiesRouter,
  templatesRouter,
  clausesRouter,
  obligationsRouter,
};
