/**
 * M15 / CR-G — GET /api/v1/dashboards/procurement
 *
 * Procurement & Supplier Risk persona dashboard.
 * DB: fn_dashboard_procurement_supplier_risk(p_actor_id bigint, p_window_days integer DEFAULT 90) RETURNS jsonb
 * Permission gate: insights.procurement_supplier_risk
 *   (fallback: insights.executive, Super Admin, platform_admin)
 *   — enforced at fn_ body; route layer applies authorise('insights.procurement_supplier_risk') as pre-gate.
 *
 * Default window is 90 days (longer horizon for supplier-history aggregation — api-contracts.json note).
 *
 * Error routing:
 *   - 22023 → 400  (windowDays out of range / bad actorId)
 *   - 42501 → 403  (permission denied)
 *   - SQLSTATE → 500
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import type { ProcurementSupplierRiskDashboardResponse } from '../../types/crg-dashboards.types';
import { dashboardWindowDays90Schema } from '../../schemas/crg-dashboards.schemas';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';

/**
 * GET /api/v1/dashboards/procurement
 * Returns procurement & supplier-risk persona dashboard for the authenticated caller.
 */
export const getProcurementDashboard = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const userId = req.user!.id;

  req.logger.info({
    action: 'fn_dashboard_procurement_supplier_risk',
    method: req.method,
    path: req.path,
    userId,
  });

  try {
    const { windowDays } = dashboardWindowDays90Schema.parse(req.query);

    const result = await db.callFunction<ProcurementSupplierRiskDashboardResponse>(
      'fn_dashboard_procurement_supplier_risk',
      [userId, windowDays],
      { actorId: userId, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
    );

    req.logger.info({
      action: 'fn_dashboard_procurement_supplier_risk',
      userId,
      windowDays,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'fn_dashboard_procurement_supplier_risk',
      userId,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
