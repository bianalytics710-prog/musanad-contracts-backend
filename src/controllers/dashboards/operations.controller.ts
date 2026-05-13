/**
 * M15 / CR-G — GET /api/v1/dashboards/operations
 *
 * Operations & SLA persona dashboard.
 * DB: fn_dashboard_operations(p_actor_id bigint, p_window_days integer DEFAULT 30) RETURNS jsonb
 * Permission gate: insights.operations (fallback: insights.executive, Super Admin, platform_admin)
 *   — enforced at fn_ body; route layer applies authorise('insights.operations') as pre-gate.
 *
 * SENSITIVE fields (never in logs):
 *   - penaltyClauseSummary (fn_ internal match_reason text)
 *   - marAed (financial exposure amounts)
 *
 * Error routing (feedback_translatePgError_p0001_routing.md):
 *   - 22023 → 400  (invalid_parameter_value — windowDays out of range / bad actorId)
 *   - 42501 → 403  (insufficient_privilege — permission denied)
 *   - SQLSTATE → 500  (WHEN OTHERS re-raise)
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import type { OperationsDashboardResponse } from '../../types/crg-dashboards.types';
import { dashboardWindowDays30Schema } from '../../schemas/crg-dashboards.schemas';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';

/**
 * GET /api/v1/dashboards/operations
 * Returns operations & SLA persona dashboard for the authenticated caller.
 */
export const getOperationsDashboard = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  const startTime = Date.now();
  const userId = req.user!.id;

  req.logger.info({
    action: 'fn_dashboard_operations',
    method: req.method,
    path: req.path,
    userId,
  });

  try {
    const { windowDays } = dashboardWindowDays30Schema.parse(req.query);

    const result = await db.callFunction<OperationsDashboardResponse>(
      'fn_dashboard_operations',
      [userId, windowDays],
      { actorId: userId, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
    );

    req.logger.info({
      action: 'fn_dashboard_operations',
      userId,
      windowDays,
      duration: Date.now() - startTime,
      statusCode: 200,
    });

    res.status(200).json({ success: true, data: result });
  } catch (error) {
    req.logger.error({
      action: 'fn_dashboard_operations',
      userId,
      duration: Date.now() - startTime,
      errorType: (error as Error).name,
    });
    next(error);
  }
};
