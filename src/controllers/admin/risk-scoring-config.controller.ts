/**
 * Admin Risk Scoring Config Controller.
 *
 * The risk scoring formula (mig 529) is fully data-driven via system_setting
 * rows. This controller exposes the 7 configurable knobs through a single
 * GET/PUT endpoint pair so platform admin can tune them without a developer.
 *
 * After a save, the controller asynchronously triggers a bulk recompute so
 * existing snapshots reflect the new formula immediately.
 *
 * SENSITIVE: nothing in this controller is logged at debug level — the
 * actual config values shape an internal risk model and could be reverse-
 * engineered by competitors.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const riskScoringConfigController = {

  /**
   * GET /api/v1/admin/risk-scoring-config — returns the 7 settings as a
   * single object the FE can render in one form.
   *
   * DB: fn_risk_scoring_config_get(p_actor_id BIGINT) RETURNS JSONB
   * Permission: score.config.manage OR score.weights.manage OR score.read
   *             (the read path is wider so the FE hover-card can fetch
   *             the band thresholds without admin rights).
   */
  getConfig: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_scoring_config_get', method: req.method, path: req.path, userId: req.user?.id });
    try {
      const result = await db.callFunction<Record<string, unknown>>(
        'fn_risk_scoring_config_get',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_scoring_config_get', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_risk_scoring_config_get', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  /**
   * PUT /api/v1/admin/risk-scoring-config — partial updates supported.
   * Any key omitted from the body is left untouched.
   *
   * DB: fn_risk_scoring_config_set(p_input JSONB, p_actor_id BIGINT) RETURNS JSONB
   * Permission: score.config.manage.
   *
   * After the write succeeds, fire a recompute job in the background so
   * the new formula propagates to every snapshot. We don't await it —
   * caller gets the updated config immediately and the recompute drains
   * over the next ~30s for ~120 contracts.
   */
  setConfig: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_scoring_config_set', method: req.method, path: req.path, userId: req.user?.id });
    try {
      const body = req.body as Record<string, unknown>;
      const result = await db.callFunction<{ updatedKeys: string[]; config: Record<string, unknown> }>(
        'fn_risk_scoring_config_set',
        [body, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({
        action: 'fn_risk_scoring_config_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        updatedKeys: result?.updatedKeys,
      });

      // Background recompute via fn_risk_score_recompute_all (mig 530).
      // We don't await — caller gets the saved config immediately while the
      // ~30s recompute runs in the background. Failures are logged only.
      const actorId = req.user!.id;
      const tenantId = req.tenantId ?? ADNOC_TENANT_ID;
      void (async () => {
        try {
          const summary = await db.callFunction<{ recomputedCount: number; failedCount: number; elapsedMs: number }>(
            'fn_risk_score_recompute_all',
            [actorId],
            { actorId, tenantId },
          );
          req.logger.info({ action: 'risk_scoring_recompute_after_config', userId: actorId, statusCode: 'background_ok', ...summary });
        } catch (err) {
          req.logger.error({ action: 'risk_scoring_recompute_after_config', userId: actorId, errorType: (err as Error).name, message: (err as Error).message });
        }
      })();

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_risk_scoring_config_set', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },
};
