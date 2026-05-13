/**
 * M15 / CR-G — GET /api/v1/dashboards/finance-treasury
 *
 * Finance & Treasury persona dashboard.
 * DB: fn_dashboard_finance_treasury(p_actor_id bigint, p_window_days integer DEFAULT 30) RETURNS jsonb
 * Permission gate: insights.finance_treasury (fallback: insights.executive, Super Admin, platform_admin)
 *   — enforced at fn_ body; route layer applies authorise('insights.finance_treasury') as pre-gate.
 *
 * SENSITIVE fields (never in logs):
 *   - totalExposureAed, fxExposureNonAedAed (financial exposure amounts)
 *   - amountAed (payment delay amounts)
 *
 * Error routing:
 *   - 22023 → 400  (windowDays out of range / bad actorId)
 *   - 42501 → 403  (permission denied)
 *   - SQLSTATE → 500
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import type { FinanceTreasuryDashboardResponse } from '../../types/crg-dashboards.types';
import { dashboardWindowDays30Schema } from '../../schemas/crg-dashboards.schemas';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';

/**
 * GET /api/v1/dashboards/finance-treasury
 * Returns finance & treasury persona dashboard for the authenticated caller.
 */
export const getFinanceTreasuryDashboard = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const userId = req.user!.id;

  req.logger.info({
    action: 'fn_dashboard_finance_treasury',
    method: req.method,
    path: req.path,
    userId,
  });

  try {
    const { windowDays } = dashboardWindowDays30Schema.parse(req.query);

    const result = await db.callFunction<FinanceTreasuryDashboardResponse>(
      'fn_dashboard_finance_treasury',
      [userId, windowDays],
      { actorId: userId, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
    );

    req.logger.info({
      action: 'fn_dashboard_finance_treasury',
      userId,
      windowDays,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'fn_dashboard_finance_treasury',
      userId,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
