/**
 * M14 / CR-F — Admin Scoring Weights Controller.
 *
 * Routes → Controller → db.callFunction() → JSONB response.
 * No business logic — everything in fn_ functions.
 *
 * SENSITIVE fields:
 *   - weightsApplied (contains individual dimension weights — financial intelligence)
 *   - Never log the raw weights JSONB object.
 *
 * Error routing (per feedback_translatePgError_p0001_routing.md):
 *   - 22023 → 400 VALIDATION_ERROR (weights sum / individual dim / windowDays)
 *   - 42501 → 403 FORBIDDEN (score.weights.manage permission gate in fn_)
 *   - Default → 500 via global error middleware
 *
 * R-PA7 pattern:
 *   fn_scoring_weights_set emits explicit INSERT INTO audit_log (Strategy A —
 *   system_setting has no audit trigger per DEFECT-1 notes).
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../../database/client';
import type {
  ScoringWeightsGetResponse,
  ScoringWeightsSetResponse,
  ScoreRecomputeForWeightChangeResult,
} from '../../types/risk-score.types';
import { ADNOC_TENANT_ID } from '../../types/risk-score.types';
import type { PatchScoringWeightsBodyInput } from '../../schemas/risk-score.schemas';

export const scoringWeightsController = {

  // ============================================================
  // CR-F-004 — GET /api/v1/admin/scoring-weights
  // ============================================================

  /**
   * Returns current scoring weights config (5 dims + version + updatedAt/updatedBy),
   * last 10 version history entries from audit_log, exposure fraction defaults,
   * and impact multipliers.
   *
   * DB: fn_scoring_weights_get(p_actor_id BIGINT) RETURNS JSONB
   * Security: INVOKER. Permission: score.weights.manage.
   */
  getWeights: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_scoring_weights_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const result = await db.callFunction<ScoringWeightsGetResponse>(
        'fn_scoring_weights_get',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'fn_scoring_weights_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'fn_scoring_weights_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // CR-F-005 — PATCH /api/v1/admin/scoring-weights
  // ============================================================

  /**
   * Saves new scoring weights. Validates all 5 dimensions present, each in [0,1],
   * sum = 1.0 ± 0.001 (validated at Zod layer AND fn_ layer). Bumps version
   * monotonically. Does NOT auto-trigger recompute.
   *
   * DB: fn_scoring_weights_set(p_weights JSONB, p_actor_id BIGINT) RETURNS JSONB
   * Security: INVOKER. Permission: score.weights.manage.
   *
   * S2-17: fn_ uses SELECT FOR UPDATE on system_setting row to prevent concurrent
   *        version bump race.
   * R-PA7 audit: fn_ emits explicit INSERT INTO audit_log (Strategy A).
   */
  setWeights: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    // NOTE: individual dimension values are SENSITIVE (financial intelligence) — not logged
    req.logger.info({
      action: 'fn_scoring_weights_set',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const body = req.body as PatchScoringWeightsBodyInput;

      // Build the p_weights JSONB to pass to fn_scoring_weights_set.
      // fn_ expects: { legal, financial, operational, reputational, compliance }
      const weightsPayload = {
        legal: body.legal,
        financial: body.financial,
        operational: body.operational,
        reputational: body.reputational,
        compliance: body.compliance,
      };

      const result = await db.callFunction<ScoringWeightsSetResponse>(
        'fn_scoring_weights_set',
        [weightsPayload, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'fn_scoring_weights_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        // Log new version only — not the individual weight values (SENSITIVE)
        newVersion: result?.newVersion,
      });

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'fn_scoring_weights_set',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // CR-F-006 — POST /api/v1/admin/scoring-weights/recompute-all
  // ============================================================

  /**
   * Triggers bulk recompute of all active tenant contracts using the current
   * scoring weights version. Per-contract SAVEPOINT — partial failure does not
   * roll back successes. Returns immediately with the bulk job results (synchronous
   * in v1 demo; <100 contracts at ADNOC pilot scale).
   *
   * DB: fn_score_recompute_for_weight_change(p_actor_id BIGINT) RETURNS JSONB
   * Security: DEFINER. Permission: score.weights.manage.
   * AC-S8-03: fn rejects non-human actors (p_actor_id = 0 → 403).
   *
   * S2-17: per-contract SAVEPOINT via nested BEGIN/EXCEPTION in fn_ body.
   */
  recomputeAll: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_score_recompute_for_weight_change',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const result = await db.callFunction<ScoreRecomputeForWeightChangeResult>(
        'fn_score_recompute_for_weight_change',
        [req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'fn_score_recompute_for_weight_change',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
        weightsVersion: result?.weightsVersion,
        recomputedCount: result?.recomputedCount,
        failedCount: result?.failedContractIds?.length ?? 0,
      });

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'fn_score_recompute_for_weight_change',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
