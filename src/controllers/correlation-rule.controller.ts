/**
 * M13 / CR-E — Correlation Rule Engine + DSL Controller.
 *
 * Routes → Controller → db.callFunction() → JSONB response.
 * No business logic here — everything in fn_ functions.
 *
 * SENSITIVE: matchYaml, produceYaml, matchEvidence, matchEntities,
 *            dismissalReason never logged.
 * Entry/exit Pino logging on every method. startTime + duration always tracked.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError, NotFoundError } from '../utils/errors.util';
import { parseRuleYaml } from '../services/rule-parser.service';
import { invalidateRuleCache } from '../services/rule-cache.service';
import type {
  RuleListQueryInput,
  CreateRuleBodyInput,
  UpdateRuleBodyInput,
  CorrelationListQueryInput,
  CorrelationDismissBodyInput,
} from '../schemas/correlation-rule.schemas';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

export const correlationRuleController = {

  // ============================================================
  // CR-E-001 — GET /api/v1/admin/rules
  // ============================================================

  listRules: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_rule_list', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const query = req.query as unknown as RuleListQueryInput;

      const result = await db.callFunction<{ data: unknown[]; pagination: unknown }>(
        'fn_rule_list',
        [
          query.page,
          query.limit,
          query.enabled ?? null,
          query.scenario ?? null,
          query.search ?? null,
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      // BLOCKER-4 fix: fn_rule_list returns { data: [], pagination: {} }.
      // Contract and FE types expect { items: [], pagination: {} }. Remap here.
      const responseData = result
        ? { items: (result as Record<string, unknown>)['data'] ?? [], pagination: (result as Record<string, unknown>)['pagination'] }
        : { items: [], pagination: { total: 0, page: query.page, limit: query.limit, totalPages: 1 } };

      req.logger.info({ action: 'fn_rule_list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: responseData });
    } catch (error) {
      req.logger.error({ action: 'fn_rule_list', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-007 — GET /api/v1/admin/rules/:id
  // ============================================================

  getRuleById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_rule_get_by_id', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const ruleId = parseInt(req.params['id'] as string, 10);
      if (isNaN(ruleId)) throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid rule ID format');

      // SENSITIVE: matchYaml, produceYaml not logged
      const result = await db.callFunction<unknown>(
        'fn_rule_get_by_id',
        [ruleId, req.user!.id, ADNOC_TENANT_ID],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      if (!result) throw new NotFoundError('Correlation rule not found in actor\'s tenant');

      req.logger.info({ action: 'fn_rule_get_by_id', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_rule_get_by_id', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-002 — POST /api/v1/admin/rules
  // ============================================================

  createRule: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    // NOTE: matchYaml and produceYaml are SENSITIVE — not logged
    req.logger.info({ action: 'fn_rule_create', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const body = req.body as CreateRuleBodyInput;

      // Validate YAML before persisting
      const parseResult = parseRuleYaml(body.matchYaml, body.produceYaml);
      if (!parseResult.valid) {
        const messages = parseResult.errors.map((e) => e.message).join('; ');
        throw new ApiError(422, 'RULE_YAML_INVALID', `Rule YAML validation failed: ${messages}`);
      }

      const result = await db.callFunction<{ ruleId: string; id: number }>(
        'fn_rule_create',
        [
          body.ruleId,
          body.name,
          body.nameAr,
          body.scenario ?? null,
          body.enabled ?? true,
          body.matchYaml,
          body.produceYaml,
          JSON.stringify(body.meta ?? {}),
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      // Hot-reload rule cache after successful creation
      invalidateRuleCache();

      req.logger.info({ action: 'fn_rule_create', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 201 });
      res.status(201).json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_rule_create', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-003 — PATCH /api/v1/admin/rules/:id
  // ============================================================

  updateRule: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    // NOTE: matchYaml and produceYaml are SENSITIVE — not logged
    req.logger.info({ action: 'fn_rule_update', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const ruleId = parseInt(req.params['id'] as string, 10);
      if (isNaN(ruleId)) throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid rule ID format');

      const body = req.body as UpdateRuleBodyInput;

      // If YAML fields are being updated, validate them before persisting
      if (body.matchYaml !== undefined || body.produceYaml !== undefined) {
        // Need both YAML fields to validate; if only one is provided, we can't validate together
        // but fn_rule_get_by_id would handle the merge — validate what we have
        if (body.matchYaml && body.produceYaml) {
          const parseResult = parseRuleYaml(body.matchYaml, body.produceYaml);
          if (!parseResult.valid) {
            const messages = parseResult.errors.map((e) => e.message).join('; ');
            throw new ApiError(422, 'RULE_YAML_INVALID', `Rule YAML validation failed: ${messages}`);
          }
        }
      }

      const result = await db.callFunction<unknown>(
        'fn_rule_update',
        [
          ruleId,
          body.name ?? null,
          body.nameAr ?? null,
          body.scenario ?? null,
          body.enabled ?? null,
          body.matchYaml ?? null,
          body.produceYaml ?? null,
          body.meta ? JSON.stringify(body.meta) : null,
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      if (!result) throw new NotFoundError('Correlation rule not found in actor\'s tenant');

      // Hot-reload rule cache after successful update (enabled/YAML may have changed)
      invalidateRuleCache();

      req.logger.info({ action: 'fn_rule_update', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_rule_update', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-008 — DELETE /api/v1/admin/rules/:id
  // ============================================================

  deleteRule: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_rule_delete', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const ruleId = parseInt(req.params['id'] as string, 10);
      if (isNaN(ruleId)) throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid rule ID format');

      const result = await db.callFunction<{ deleted: boolean }>(
        'fn_rule_delete',
        [ruleId, req.user!.id, ADNOC_TENANT_ID],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      if (!result?.deleted) throw new NotFoundError('Correlation rule not found in actor\'s tenant');

      // Evict from rule cache after soft-delete
      invalidateRuleCache();

      req.logger.info({ action: 'fn_rule_delete', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: { id: ruleId, isActive: false } });
    } catch (error) {
      req.logger.error({ action: 'fn_rule_delete', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-004 — POST /api/v1/admin/rules/:id/test
  // ============================================================

  testRule: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_rule_test_against_fixture', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const ruleId = parseInt(req.params['id'] as string, 10);
      if (isNaN(ruleId)) throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid rule ID format');

      const body = req.body as { fixtureId?: string };

      const result = await db.callFunction<{
        ruleId: string;
        fixtureId: string;
        expectedMatch: boolean;
        actualMatch: boolean;
        matchEvidence?: Record<string, unknown>;
        matchReason?: string;
        diffNotes?: unknown[];
        passed: boolean;
        durationMs?: number;
      }>(
        'fn_rule_test_against_fixture',
        [ruleId, body.fixtureId ?? null, req.user!.id, ADNOC_TENANT_ID],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      if (!result) throw new NotFoundError('Correlation rule not found in actor\'s tenant');

      req.logger.info({ action: 'fn_rule_test_against_fixture', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_rule_test_against_fixture', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-005 — GET /api/v1/correlations
  // ============================================================

  listCorrelations: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({ action: 'fn_correlation_list', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const query = req.query as unknown as CorrelationListQueryInput;

      // SENSITIVE: matchEvidence and matchEntities in results — covered by Pino redact
      const result = await db.callFunction<{ data: unknown[]; pagination: unknown }>(
        'fn_correlation_list',
        [
          query.page,
          query.limit,
          query.contractId ?? null,
          query.status ?? null,
          query.ruleId ?? null,
          query.fromDate ?? null,
          query.toDate ?? null,
          req.user!.id,
          ADNOC_TENANT_ID,
        ],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      // BLOCKER-4 fix: fn_correlation_list returns { data: [], pagination: {} }.
      // Contract and FE types expect { items: [], pagination: {} }. Remap here.
      const responseData = result
        ? { items: (result as Record<string, unknown>)['data'] ?? [], pagination: (result as Record<string, unknown>)['pagination'] }
        : { items: [], pagination: { total: 0, page: query.page, limit: query.limit, totalPages: 1 } };

      req.logger.info({ action: 'fn_correlation_list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: responseData });
    } catch (error) {
      req.logger.error({ action: 'fn_correlation_list', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },

  // ============================================================
  // CR-E-006 — POST /api/v1/correlations/:id/dismiss
  // ============================================================

  dismissCorrelation: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    // NOTE: dismissalReason is SENSITIVE — not logged
    req.logger.info({ action: 'fn_correlation_dismiss', method: req.method, path: req.path, userId: req.user?.id });

    try {
      const correlationId = parseInt(req.params['id'] as string, 10);
      if (isNaN(correlationId)) throw new ApiError(400, 'VALIDATION_ERROR', 'Invalid correlation ID format');

      const body = req.body as CorrelationDismissBodyInput;

      const result = await db.callFunction<{ correlationId: number; newStatus: string }>(
        'fn_correlation_dismiss',
        [correlationId, body.reason, req.user!.id, ADNOC_TENANT_ID],
        { actorId: req.user!.id, tenantId: ADNOC_TENANT_ID },
      );

      if (!result) throw new NotFoundError('Correlation record not found in actor\'s tenant');

      req.logger.info({ action: 'fn_correlation_dismiss', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 });
      res.json({ success: true, data: result });
    } catch (error) {
      req.logger.error({ action: 'fn_correlation_dismiss', userId: req.user?.id, duration: Date.now() - startTime, errorType: (error as Error).name });
      next(error);
    }
  },
};
