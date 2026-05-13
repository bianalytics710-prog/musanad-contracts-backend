/**
 * M14 / CR-F — 5-Dim Risk Scoring + MaR + AVaR — Risk Score Controller.
 *
 * Routes → Controller → db.callFunction() → JSONB response.
 * No business logic here — everything in fn_ functions.
 *
 * SENSITIVE fields that must NEVER appear in logs:
 *   - contributingCorrelations (risk_score JSONB — redacted in audit_log by migration 173)
 *   - explanation (risk_score JSONB — redacted in audit_log by migration 173)
 *   - marValue (financial exposure amount)
 *   - dimLegal, dimFinancial, dimOperational, dimReputational, dimCompliance (dim scores)
 *
 * Error routing (per feedback_translatePgError_p0001_routing.md):
 *   - 22023 (invalid_parameter_value) → 400 VALIDATION_ERROR (handled by db.callFunction)
 *   - 42501 (insufficient_privilege)  → 403 FORBIDDEN
 *   - P0002 (no_data_found)           → 404 NOT_FOUND
 *   - Default                         → 500 via global error middleware
 *
 * Entry/exit Pino logging on every method.
 * startTime + duration always tracked.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import type {
  RiskScoreExplainResponse,
  RiskScoreHistoryResponse,
  AvarAggregateResponse,
  AvarGroupBy,
} from '../types/risk-score.types';
import { ADNOC_TENANT_ID } from '../types/risk-score.types';
import type {
  ContractIdParamsInput,
  GetRiskScoreHistoryQueryInput,
  GetAvarQueryInput,
} from '../schemas/risk-score.schemas';

export const riskScoreController = {

  // ============================================================
  // CR-F-001 — GET /api/v1/contracts/:id/risk-score
  // ============================================================

  /**
   * Returns the latest risk_score snapshot for a contract with hydrated contributing
   * correlations, reason codes per dimension, MaR formula breakdown, and weights-at-calculation.
   *
   * DB: fn_risk_score_explain(p_contract_id BIGINT, p_actor_id BIGINT) RETURNS JSONB
   * Security: INVOKER — RLS applies. Tenant scoping via GUC.
   * Permission: score.read (enforced by authorise() middleware + fn_ body ERRCODE 42501).
   */
  getRiskScoreExplain: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_score_explain',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { id } = req.params as unknown as ContractIdParamsInput;
      const contractId = parseInt(id, 10);

      // SENSITIVE: never log contributingCorrelations, explanation, or marValue from result
      const result = await db.callFunction<RiskScoreExplainResponse>(
        'fn_risk_score_explain',
        [contractId, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'fn_risk_score_explain',
        userId: req.user?.id,
        contractId,
        duration: Date.now() - startTime,
        statusCode: 200,
      });

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_score_explain',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // CR-F-002 — GET /api/v1/contracts/:id/risk-score/history
  // ============================================================

  /**
   * Returns risk_score snapshot history for a contract over a bounded window (30/90/180 days).
   * Snapshots ordered ascending by calculatedAt for chart rendering.
   *
   * DB: fn_risk_score_history(p_contract_id BIGINT, p_window_days INTEGER, p_actor_id BIGINT) RETURNS JSONB
   * Security: INVOKER. Permission: score.read.
   */
  getRiskScoreHistory: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_risk_score_history',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const { id } = req.params as unknown as ContractIdParamsInput;
      const contractId = parseInt(id, 10);
      const query = req.query as unknown as GetRiskScoreHistoryQueryInput;
      const windowDays = query.windowDays ?? 90;

      const result = await db.callFunction<RiskScoreHistoryResponse>(
        'fn_risk_score_history',
        [contractId, windowDays, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'fn_risk_score_history',
        userId: req.user?.id,
        contractId,
        windowDays,
        duration: Date.now() - startTime,
        statusCode: 200,
      });

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'fn_risk_score_history',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // CR-F-003 — GET /api/v1/risk/avar
  // ============================================================

  /**
   * Aggregates MaR across latest_risk_score for the calling tenant with optional filters.
   * Returns totalAvar, delta vs prior window, and per-bucket breakdown.
   *
   * DB: fn_avar_aggregate(p_filters JSONB, p_window_days INTEGER, p_actor_id BIGINT) RETURNS JSONB
   * Security: INVOKER. Permission: score.read.
   *
   * S2-24: fn_avar_aggregate uses WITH per_bucket CTE (SUM + GROUP BY) + outer jsonb_agg.
   * S2-22b: JOIN path is latest_risk_score → contract via contract_id (direct).
   * A3: latest_risk_score MV has no RLS — fn_ always filters by tenant_id via GUC.
   */
  getAvar: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_avar_aggregate',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const query = req.query as unknown as GetAvarQueryInput;

      // Build the p_filters JSONB object. Only include keys that are provided.
      // fn_avar_aggregate reads each key from the JSONB input; absent keys = no filter.
      const filters: Record<string, unknown> = {};
      if (query.businessUnit !== undefined) filters['businessUnit'] = query.businessUnit;
      if (query.counterpartyId !== undefined) filters['counterpartyId'] = query.counterpartyId;
      if (query.counterpartyChainRootId !== undefined) filters['counterpartyChainRootId'] = query.counterpartyChainRootId;
      if (query.geography !== undefined) filters['geography'] = query.geography;
      if (query.riskKind !== undefined) filters['riskKind'] = query.riskKind;
      if (query.groupBy !== undefined) filters['groupBy'] = query.groupBy as AvarGroupBy;

      const windowDays = query.windowDays ?? 90;

      const result = await db.callFunction<AvarAggregateResponse>(
        'fn_avar_aggregate',
        [filters, windowDays, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );

      req.logger.info({
        action: 'fn_avar_aggregate',
        userId: req.user?.id,
        windowDays,
        duration: Date.now() - startTime,
        statusCode: 200,
      });

      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({
        action: 'fn_avar_aggregate',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
