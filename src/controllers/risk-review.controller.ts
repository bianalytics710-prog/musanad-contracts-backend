/**
 * Risk Review controller — Phase C.2.
 *
 * Backs the Executive Risk Review section on the Executive Dashboard.
 * Three thin pass-throughs over the fn_risk_review_* fns from migration 550.
 *
 *   GET  /api/v1/dashboards/executive/risk-review        fn_risk_review_list
 *   POST /api/v1/risk-cases/:id/promote                  fn_risk_review_promote
 *   POST /api/v1/risk-cases/:id/dismiss-as-noise         fn_risk_review_dismiss
 *   POST /api/v1/risk-cases/risk-review/bulk             { action, caseIds[] }
 *
 * All gated by risk.review.manage. Bulk endpoint runs each per-case fn
 * inside a single transaction so all-succeed-or-all-rollback semantics
 * apply.
 */
import type { Request, Response, NextFunction } from 'express';
import { db, executeInTransaction } from '../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const riskReviewController = {
  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_review_list', userId: req.user?.id });
    try {
      const limit = Math.min(50, Math.max(1, Number(req.query.limit ?? 10)));
      const result = await db.callFunction(
        'fn_risk_review_list',
        [limit],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_review_list', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_review_list', errorType: (e as Error).name });
      next(e);
    }
  },

  promote: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_risk_review_promote', userId: req.user?.id, caseId: id });
    try {
      const result = await db.callFunction(
        'fn_risk_review_promote',
        [id, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_review_promote', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_review_promote', errorType: (e as Error).name });
      next(e);
    }
  },

  dismiss: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_risk_review_dismiss', userId: req.user?.id, caseId: id });
    try {
      const result = await db.callFunction(
        'fn_risk_review_dismiss',
        [id, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_review_dismiss', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_review_dismiss', errorType: (e as Error).name });
      next(e);
    }
  },

  bulk: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_review.bulk', userId: req.user?.id });
    try {
      const body = req.body as { action?: 'promote' | 'dismiss'; caseIds?: unknown[] };
      const action = body.action;
      const caseIds = Array.isArray(body.caseIds)
        ? body.caseIds.filter((v): v is number => typeof v === 'number')
        : [];
      if (action !== 'promote' && action !== 'dismiss') {
        res.status(400).json({ success: false, error: 'action must be promote|dismiss' });
        return;
      }
      if (caseIds.length === 0) {
        res.status(400).json({ success: false, error: 'caseIds is required' });
        return;
      }

      const fnName = action === 'promote' ? 'fn_risk_review_promote' : 'fn_risk_review_dismiss';
      const result = await executeInTransaction(async (client) => {
        await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(req.user!.id)]);
        await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [req.tenantId ?? ADNOC_TENANT_ID]);
        const outcomes: Array<{ id: number; ok: boolean }> = [];
        for (const id of caseIds) {
          await client.query(`SELECT ${fnName}($1, $2)`, [id, req.user!.id]);
          outcomes.push({ id, ok: true });
        }
        return outcomes;
      });

      req.logger.info({ action: 'fn_risk_review.bulk', duration: Date.now() - startTime, statusCode: 200, count: result.length });
      res.json({ success: true, data: { action, processed: result } });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_review.bulk', errorType: (e as Error).name });
      next(e);
    }
  },
};
