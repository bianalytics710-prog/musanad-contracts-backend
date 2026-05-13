/**
 * /api/v1/dashboards/* — M15 (CR-G) 4 new persona dashboard routes.
 *
 * Appended to the existing dashboardsRouter (src/routes/v1/dashboards.routes.ts)
 * via src/routes/v1/index.ts mount at /dashboards (same prefix).
 *
 * Endpoint roster:
 *   CR-G S5  GET /operations              fn_dashboard_operations
 *   CR-G S6  GET /finance-treasury        fn_dashboard_finance_treasury
 *   CR-G S7  GET /compliance-esg          fn_dashboard_compliance_esg
 *   CR-G S8  GET /procurement             fn_dashboard_procurement_supplier_risk
 *
 * Permission strategy:
 *   Each endpoint pre-gates on its persona-specific permission code:
 *     insights.operations         → /operations
 *     insights.finance_treasury   → /finance-treasury
 *     insights.compliance_esg     → /compliance-esg
 *     insights.procurement_supplier_risk → /procurement
 *
 *   Fallback roles (insights.executive OR platform_admin OR Super Admin) are
 *   enforced inside the fn_ body (42501 → 403 via translatePgError). The
 *   route-level authorise() provides a fast-fail pre-gate for callers who
 *   hold the persona-specific code; fn body covers the fallback OR semantics.
 *
 * Rate limits: authedReadRateLimiter (120/min/user) — same as M6.
 * Query validation: dashboardWindowDays30Schema (ops/ft/csg) / dashboardWindowDays90Schema (proc).
 */
import { Router } from 'express';
import { authenticate, authorise, authoriseAnyOf } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { getOperationsDashboard } from '../../controllers/dashboards/operations.controller';
import { getFinanceTreasuryDashboard } from '../../controllers/dashboards/finance-treasury.controller';
import { getComplianceEsgDashboard } from '../../controllers/dashboards/compliance-esg.controller';
import { getProcurementDashboard } from '../../controllers/dashboards/procurement.controller';
import {
  dashboardWindowDays30Schema,
  dashboardWindowDays90Schema,
} from '../../schemas/crg-dashboards.schemas';

const dashboardsCrgRouter = Router();

// All routes require an authenticated user.
dashboardsCrgRouter.use(authenticate);

// ------------------------------------------------------------
// CR-G S5 — GET /api/v1/dashboards/operations
// ------------------------------------------------------------
// Permission pre-gate: insights.operations (fallback roles in fn_ body).
dashboardsCrgRouter.get(
  '/operations',
  authedReadRateLimiter,
  authoriseAnyOf(['insights.operations', 'insights.executive']),
  validate(dashboardWindowDays30Schema, 'query'),
  getOperationsDashboard,
);

// ------------------------------------------------------------
// CR-G S6 — GET /api/v1/dashboards/finance-treasury
// ------------------------------------------------------------
// Permission pre-gate: insights.finance_treasury.
dashboardsCrgRouter.get(
  '/finance-treasury',
  authedReadRateLimiter,
  authoriseAnyOf(['insights.finance_treasury', 'insights.executive']),
  validate(dashboardWindowDays30Schema, 'query'),
  getFinanceTreasuryDashboard,
);

// ------------------------------------------------------------
// CR-G S7 — GET /api/v1/dashboards/compliance-esg
// ------------------------------------------------------------
// Permission pre-gate: insights.compliance_esg.
dashboardsCrgRouter.get(
  '/compliance-esg',
  authedReadRateLimiter,
  authoriseAnyOf(['insights.compliance_esg', 'insights.executive']),
  validate(dashboardWindowDays30Schema, 'query'),
  getComplianceEsgDashboard,
);

// ------------------------------------------------------------
// CR-G S8 — GET /api/v1/dashboards/procurement
// ------------------------------------------------------------
// Permission pre-gate: insights.procurement_supplier_risk.
// Default window 90 days (longer horizon for supplier-history aggregation).
dashboardsCrgRouter.get(
  '/procurement',
  authedReadRateLimiter,
  authoriseAnyOf(['insights.procurement_supplier_risk', 'insights.executive']),
  validate(dashboardWindowDays90Schema, 'query'),
  getProcurementDashboard,
);

export default dashboardsCrgRouter;
