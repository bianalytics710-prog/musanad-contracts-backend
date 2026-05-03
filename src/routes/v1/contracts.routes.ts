/**
 * /api/v1/contracts routes — M1a Core CRUD & Lifecycle.
 *
 * Permission codes (per api-contracts.json + db-design CMSW-2):
 *   - contract.read.all | contract.read.department | contract.read.own
 *     (any of) — list, getById, getTree, listVersions, listActivity
 *   - contract.draft           — create
 *   - contract.edit            — update, createVersion
 *   - contract.delete          — delete
 *   - contract.status.update   — updateStatus
 *   - contract.tag.manage      — setTags
 *
 * Role-aware ownership/department/own filtering inside fn_ implementations
 * (RLS policy contract_select_role_aware) handles the per-row visibility;
 * authorisation here only gates "may attempt this kind of operation".
 *
 * Rate limits: GETs use authedReadRateLimiter, writes (POST/PUT/PATCH/DELETE)
 * use authedWriteRateLimiter.
 */
import { Router } from 'express';
import { contractsController } from '../../controllers/contracts.controller';
import { authenticate, authorise, authoriseAnyOf } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  ContractActivityListQuerySchema,
  ContractIdParamSchema,
  ContractListQuerySchema,
  ContractVersionListQuerySchema,
  CreateContractDtoSchema,
  CreateContractVersionDtoSchema,
  SetContractTagsDtoSchema,
  UpdateContractDtoSchema,
  UpdateContractStatusDtoSchema,
} from '../../schemas/contracts.schemas';

const router = Router();

const READ_ANY = ['contract.read.all', 'contract.read.department', 'contract.read.own'] as const;

// All endpoints require authentication
router.use(authenticate);

// GET /api/v1/contracts — list
router.get(
  '/',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractListQuerySchema, 'query'),
  contractsController.list,
);

// POST /api/v1/contracts — create (S3)
router.post(
  '/',
  authedWriteRateLimiter,
  authorise(['contract.draft']),
  validate(CreateContractDtoSchema, 'body'),
  contractsController.create,
);

// GET /api/v1/contracts/:id — get (S2 — 403/404 layered in controller)
router.get(
  '/:id',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  contractsController.getById,
);

// PUT /api/v1/contracts/:id — update (S4)
router.put(
  '/:id',
  authedWriteRateLimiter,
  authorise(['contract.edit']),
  validate(ContractIdParamSchema, 'params'),
  validate(UpdateContractDtoSchema, 'body'),
  contractsController.update,
);

// DELETE /api/v1/contracts/:id — soft delete (S5)
router.delete(
  '/:id',
  authedWriteRateLimiter,
  authorise(['contract.delete']),
  validate(ContractIdParamSchema, 'params'),
  contractsController.delete,
);

// PATCH /api/v1/contracts/:id/status — status update (S6)
router.patch(
  '/:id/status',
  authedWriteRateLimiter,
  authorise(['contract.status.update']),
  validate(ContractIdParamSchema, 'params'),
  validate(UpdateContractStatusDtoSchema, 'body'),
  contractsController.updateStatus,
);

// GET /api/v1/contracts/:id/tree — parent/child timeline (S7)
router.get(
  '/:id/tree',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  contractsController.getTree,
);

// PUT /api/v1/contracts/:id/tags — replace tag set (S8)
router.put(
  '/:id/tags',
  authedWriteRateLimiter,
  authorise(['contract.tag.manage']),
  validate(ContractIdParamSchema, 'params'),
  validate(SetContractTagsDtoSchema, 'body'),
  contractsController.setTags,
);

// GET /api/v1/contracts/:id/versions — list versions (S9)
router.get(
  '/:id/versions',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  validate(ContractVersionListQuerySchema, 'query'),
  contractsController.listVersions,
);

// POST /api/v1/contracts/:id/versions — create version snapshot (S10)
router.post(
  '/:id/versions',
  authedWriteRateLimiter,
  authorise(['contract.edit']),
  validate(ContractIdParamSchema, 'params'),
  validate(CreateContractVersionDtoSchema, 'body'),
  contractsController.createVersion,
);

// GET /api/v1/contracts/:id/activity — activity timeline (S11)
router.get(
  '/:id/activity',
  authedReadRateLimiter,
  authoriseAnyOf(READ_ANY),
  validate(ContractIdParamSchema, 'params'),
  validate(ContractActivityListQuerySchema, 'query'),
  contractsController.listActivity,
);

export default router;
