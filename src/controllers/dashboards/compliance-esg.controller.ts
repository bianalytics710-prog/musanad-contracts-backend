/**
 * M15 / CR-G — GET /api/v1/dashboards/compliance-esg
 *
 * Compliance & ESG persona dashboard.
 * DB: fn_dashboard_compliance_esg(p_actor_id bigint, p_window_days integer DEFAULT 30) RETURNS jsonb
 * Permission gate: insights.compliance_esg (fallback: insights.executive, Super Admin, platform_admin)
 *   — enforced at fn_ body; route layer applies authorise('insights.compliance_esg') as pre-gate.
 *
 * Error routing:
 *   - 22023 → 400  (windowDays out of range / bad actorId)
 *   - 42501 → 403  (permission denied)
 *   - SQLSTATE → 500
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import type { ComplianceEsgDashboardResponse } from '../../types/crg-dashboards.types';
import { dashboardWindowDays30Schema } from '../../schemas/crg-dashboards.schemas';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';

/**
 * GET /api/v1/dashboards/compliance-esg
 * Returns compliance & ESG persona dashboard for the authenticated caller.
 */
export const getComplianceEsgDashboard = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const userId = req.user!.id;

  req.logger.info({
    action: 'fn_dashboard_compliance_esg',
    method: req.method,
    path: req.path,
    userId,
  });

  try {
    const { windowDays } = dashboardWindowDays30Schema.parse(req.query);

    const result = await db.callFunction<ComplianceEsgDashboardResponse>(
      'fn_dashboard_compliance_esg',
      [userId, windowDays],
      { actorId: userId, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
    );

    req.logger.info({
      action: 'fn_dashboard_compliance_esg',
      userId,
      windowDays,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'fn_dashboard_compliance_esg',
      userId,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
