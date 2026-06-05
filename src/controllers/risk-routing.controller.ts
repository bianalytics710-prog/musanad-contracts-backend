/**
 * Risk routing controller — Phase B.2.
 *
 * Backs the /app/admin/risk-routing admin page. Thin pass-through over
 * the three fn_risk_routing_rule_* fns from migration 549/550. Every
 * endpoint requires risk.routing.manage permission (enforced by both
 * the route-layer authorise() and the fn body's own permission check).
 *
 *   GET    /api/v1/admin/risk-routing       fn_risk_routing_rule_list
 *   POST   /api/v1/admin/risk-routing       fn_risk_routing_rule_upsert (id=NULL)
 *   PUT    /api/v1/admin/risk-routing/:id   fn_risk_routing_rule_upsert
 *   DELETE /api/v1/admin/risk-routing/:id   fn_risk_routing_rule_delete
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

interface RoutingRuleInput {
  ruleOrder?: number;
  caseType?: string | null;
  riskType?: string | null;
  priorityMin?: string | null;
  contractType?: string | null;
  assignedRole?: string;
  slaHours?: number;
  materialityFloorAed?: number | null;
  confidenceFloor?: number | null;
  description?: string | null;
  isActive?: boolean;
}

function readInput(req: Request): RoutingRuleInput {
  const b = req.body as Record<string, unknown>;
  return {
    ruleOrder: typeof b.ruleOrder === 'number' ? b.ruleOrder : undefined,
    caseType: typeof b.caseType === 'string' ? b.caseType : null,
    riskType: typeof b.riskType === 'string' ? b.riskType : null,
    priorityMin: typeof b.priorityMin === 'string' ? b.priorityMin : null,
    contractType: typeof b.contractType === 'string' ? b.contractType : null,
    assignedRole: typeof b.assignedRole === 'string' ? b.assignedRole : undefined,
    slaHours: typeof b.slaHours === 'number' ? b.slaHours : undefined,
    materialityFloorAed: typeof b.materialityFloorAed === 'number' ? b.materialityFloorAed : null,
    confidenceFloor: typeof b.confidenceFloor === 'number' ? b.confidenceFloor : null,
    description: typeof b.description === 'string' ? b.description : null,
    isActive: typeof b.isActive === 'boolean' ? b.isActive : true,
  };
}

export const riskRoutingController = {
  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_routing_rule_list', userId: req.user?.id });
    try {
      const result = await db.callFunction(
        'fn_risk_routing_rule_list',
        [],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_routing_rule_list', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: { rules: result ?? [] } });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_routing_rule_list', errorType: (e as Error).name });
      next(e);
    }
  },

  create: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_risk_routing_rule_upsert.create', userId: req.user?.id });
    try {
      const i = readInput(req);
      const result = await db.callFunction(
        'fn_risk_routing_rule_upsert',
        [
          null,                                              // id (create)
          i.ruleOrder ?? 100,
          i.caseType, i.riskType, i.priorityMin, i.contractType,
          i.assignedRole ?? null,
          i.slaHours ?? 24,
          i.materialityFloorAed, i.confidenceFloor,
          i.description, i.isActive ?? true,
          req.user!.id,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_routing_rule_upsert.create', duration: Date.now() - startTime, statusCode: 200 });
      res.status(201).json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_routing_rule_upsert.create', errorType: (e as Error).name });
      next(e);
    }
  },

  update: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_risk_routing_rule_upsert.update', userId: req.user?.id, ruleId: id });
    try {
      const i = readInput(req);
      const result = await db.callFunction(
        'fn_risk_routing_rule_upsert',
        [
          id,
          i.ruleOrder ?? 100,
          i.caseType, i.riskType, i.priorityMin, i.contractType,
          i.assignedRole ?? null,
          i.slaHours ?? 24,
          i.materialityFloorAed, i.confidenceFloor,
          i.description, i.isActive ?? true,
          req.user!.id,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_routing_rule_upsert.update', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_routing_rule_upsert.update', errorType: (e as Error).name });
      next(e);
    }
  },

  remove: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const id = Number(req.params.id);
    req.logger.info({ action: 'fn_risk_routing_rule_delete', userId: req.user?.id, ruleId: id });
    try {
      const result = await db.callFunction(
        'fn_risk_routing_rule_delete',
        [id, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      req.logger.info({ action: 'fn_risk_routing_rule_delete', duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (e) {
      req.logger.error({ action: 'fn_risk_routing_rule_delete', errorType: (e as Error).name });
      next(e);
    }
  },
};
