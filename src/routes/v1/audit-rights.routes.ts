/**
 * Unit-3 / R-CES — Audit Rights routes.
 *
 * Mounted under /api/v1/contracts (appended to existing contracts namespace).
 *
 * Endpoint roster:
 *   GET /api/v1/contracts/:contractId/audit-rights
 *
 * Permission gate: ANY of:
 *   contract.read.all | contract.read.department | contract.read.own
 *   OR insights.compliance_esg OR insights.executive
 *
 * The fn_contract_audit_rights_list body enforces the same gate (42501 → 403).
 * Route layer provides fast-fail pre-gate via authoriseAnyOf.
 *
 * Middleware stack: authenticate → authedReadRateLimiter → authoriseAnyOf → validate → controller.
 *
 * NOTE: This router is mounted at /api/v1/contracts (NOT /api/v1/contracts/:contractId)
 * so the :contractId param binding is resolved at the route level. It is appended
 * to the v1 index AFTER the existing contractsRouter.
 */
import { Router } from 'express';
import { authenticate, authoriseAnyOf } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { getContractAuditRights } from '../../controllers/audit-rights.controller';
import { ContractIdPersonaParamSchema } from '../../schemas/persona-actions.schemas';

const auditRightsRouter = Router();

// All routes require an authenticated user.
auditRightsRouter.use(authenticate);

// ------------------------------------------------------------
// GET /api/v1/contracts/:contractId/audit-rights
// ------------------------------------------------------------
// Permission: ANY of contract.read.* OR insights.compliance_esg OR insights.executive.
auditRightsRouter.get(
  '/:contractId/audit-rights',
  authedReadRateLimiter,
  authoriseAnyOf([
    'contract.read.all',
    'contract.read.department',
    'contract.read.own',
    'insights.compliance_esg',
    'insights.executive',
  ]),
  validate(ContractIdPersonaParamSchema, 'params'),
  getContractAuditRights,
);

export default auditRightsRouter;
