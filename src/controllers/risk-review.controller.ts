/**
 * Risk Review controller — Phase C.2 + Phase E.8.
 *
 * Backs the Executive Risk Review / Risk Triage surface.
 *
 *   Phase C (pre-existing):
 *     GET  /api/v1/dashboards/executive/risk-review        fn_risk_review_list
 *     POST /api/v1/risk-cases/:id/promote                  fn_risk_review_promote
 *     POST /api/v1/risk-cases/:id/dismiss-as-noise         fn_risk_review_dismiss
 *     POST /api/v1/risk-cases/risk-review/bulk             { action, caseIds[] }
 *
 *   Phase E (new — mig 648..652):
 *     GET  /api/v1/dashboards/executive/risk-triage/tier1  fn_risk_triage_tier1_list
 *     GET  /api/v1/risk-review/assignee-suggest?role=…     fn_risk_review_assignee_suggest
 *     POST /api/v1/risk-cases/:id/reassign  { newUserId }  fn_risk_triage_reassign
 *
 * The Phase C `promote` handler is widened to read `assignedUserId` from the
 * request body and forward it as the third positional arg to the now-3-arg
 * fn_risk_review_promote (mig 649). When omitted, behaviour is identical to
 * pre-Phase-E (role-only routing).
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
    // Phase E.8 — optional assignedUserId in body. NULL when caller didn't
    // pick a specific person; falls back to role-only routing.
    const bodyAssignee = (req.body as { assignedUserId?: unknown } | undefined)?.assignedUserId;
    const assignedUserId =
      typeof bodyAssignee === 'number' && Number.isFinite(bodyAssignee)
        ? bodyAssignee
        : typeof bodyAssignee === 'string' && /^\d+$/.test(bodyAssignee)
          ? Number(bodyAssignee)
          : null;
    req.logger.info({ action: 'fn_risk_review_promote', userId: req.user?.id, caseId: id, assignedUserId });
    try {
      const result = await db.callFunction(
        'fn_risk_review_promote',
        [id, req.user!.id, assignedUserId],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_review_promote', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_review_promote', errorType: (e as Error).name });
      next(e);
    }
  },

  // Phase E.3 — Tier-1 oversight queue. Same envelope as list().
  tier1List: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_triage_tier1_list', userId: req.user?.id });
    try {
      const limit = Math.min(50, Math.max(1, Number(req.query.limit ?? 25)));
      const result = await db.callFunction(
        'fn_risk_triage_tier1_list',
        [limit],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_triage_tier1_list', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_triage_tier1_list', errorType: (e as Error).name });
      next(e);
    }
  },

  // Phase E.1 — assignee suggestion for the confirm-risk modal dropdown.
  assigneeSuggest: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const role = String(req.query.role ?? '').trim();
    req.logger.info({ action: 'fn_risk_review_assignee_suggest', userId: req.user?.id, role });
    if (!role) {
      res.status(400).json({ success: false, error: 'role query parameter is required' });
      return;
    }
    try {
      const result = await db.callFunction(
        'fn_risk_review_assignee_suggest',
        [role],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_review_assignee_suggest', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_review_assignee_suggest', errorType: (e as Error).name });
      next(e);
    }
  },

  // Gap 3 (mig 658) — executive reverse-view: risk cases I assigned.
  assignedByMe: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_case_list_assigned_by_actor', userId: req.user?.id });
    try {
      const limit = Math.min(50, Math.max(1, Number(req.query.limit ?? 25)));
      const result = await db.callFunction(
        'fn_risk_case_list_assigned_by_actor',
        [req.user!.id, limit],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_case_list_assigned_by_actor', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_case_list_assigned_by_actor', errorType: (e as Error).name });
      next(e);
    }
  },

  // Phase E.4 — executive reassign override for Tier-1 cases.
  reassign: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    const body = req.body as { newUserId?: unknown } | undefined;
    const raw = body?.newUserId;
    const newUserId =
      typeof raw === 'number' && Number.isFinite(raw)
        ? raw
        : typeof raw === 'string' && /^\d+$/.test(raw)
          ? Number(raw)
          : null;
    req.logger.info({ action: 'fn_risk_triage_reassign', userId: req.user?.id, caseId: id, newUserId });
    if (newUserId === null || newUserId <= 0) {
      res.status(400).json({ success: false, error: 'newUserId (positive integer) is required' });
      return;
    }
    try {
      const result = await db.callFunction(
        'fn_risk_triage_reassign',
        [id, req.user!.id, newUserId],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_triage_reassign', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_triage_reassign', errorType: (e as Error).name });
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
