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

      // DB signature: fn_rule_list(p_page, p_limit, p_scenario, p_enabled, p_search, p_actor_id) — 6 args
      const result = await db.callFunction<{ data: unknown[]; pagination: unknown }>(
        'fn_rule_list',
        [
          query.page,
          query.limit,
          query.scenario ?? null,
          query.enabled ?? null,
          query.search ?? null,
          req.user!.id,
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

      // DB signature: fn_rule_get_by_id(p_rule_pk, p_actor_id) — 2 args
      // SENSITIVE: matchYaml, produceYaml not logged
      const result = await db.callFunction<unknown>(
        'fn_rule_get_by_id',
        [ruleId, req.user!.id],
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

      // DB signature: fn_rule_create(p_data jsonb, p_actor_id bigint) — 2 args; all fields packed into p_data
      const result = await db.callFunction<{ ruleId: string; id: number }>(
        'fn_rule_create',
        [
          {
            ruleId: body.ruleId,
            name: body.name,
            nameAr: body.nameAr,
            scenario: body.scenario ?? null,
            enabled: body.enabled ?? true,
            matchYaml: body.matchYaml,
            produceYaml: body.produceYaml,
            meta: body.meta ?? {},
          },
          req.user!.id,
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

      // DB signature: fn_rule_update(p_rule_pk, p_data jsonb, p_actor_id) — 3 args; patch fields packed into p_data
      const result = await db.callFunction<unknown>(
        'fn_rule_update',
        [
          ruleId,
          {
            ...(body.name !== undefined && { name: body.name }),
            ...(body.nameAr !== undefined && { nameAr: body.nameAr }),
            ...(body.scenario !== undefined && { scenario: body.scenario }),
            ...(body.enabled !== undefined && { enabled: body.enabled }),
            ...(body.matchYaml !== undefined && { matchYaml: body.matchYaml }),
            ...(body.produceYaml !== undefined && { produceYaml: body.produceYaml }),
            ...(body.meta !== undefined && { meta: body.meta }),
          },
          req.user!.id,
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

      // DB signature: fn_rule_delete(p_rule_pk, p_actor_id) — 2 args
      const result = await db.callFunction<{ deleted: boolean }>(
        'fn_rule_delete',
        [ruleId, req.user!.id],
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

      const body = req.body as { fixtureId?: string | number };

      // DB signature: fn_rule_test_against_fixture(p_rule_pk, p_fixture_pk, p_evaluation_payload, p_actor_id) — 4 args
      // FE sends the fixture's numeric PK as a string (HTML select option value).
      // Coerce to integer before passing to a BIGINT param.
      let fixturePk: number | null = null;
      if (body.fixtureId !== undefined && body.fixtureId !== null && body.fixtureId !== '') {
        const n = typeof body.fixtureId === 'number' ? body.fixtureId : parseInt(String(body.fixtureId), 10);
        if (Number.isNaN(n)) throw new ApiError(400, 'VALIDATION_ERROR', 'fixtureId must be numeric');
        fixturePk = n;
      }

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
        [ruleId, fixturePk, null, req.user!.id],
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

      // DB signature: fn_correlation_list(p_page, p_limit, p_contract_id, p_rule_id, p_signal_id, p_status, p_scenario, p_since, p_actor_id) — 9 args
      // SENSITIVE: matchEvidence and matchEntities in results — covered by Pino redact
      const result = await db.callFunction<{ data: unknown[]; pagination: unknown }>(
        'fn_correlation_list',
        [
          query.page,
          query.limit,
          query.contractId ?? null,
          query.ruleId ?? null,
          null,                   // p_signal_id — not exposed in query schema
          query.status ?? null,
          null,                   // p_scenario — not exposed in query schema
          query.fromDate ?? null, // p_since (use fromDate; toDate is client-side post-filter if needed)
          req.user!.id,
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

      // DB signature: fn_correlation_dismiss(p_correlation_pk, p_reason, p_actor_id) — 3 args
      const result = await db.callFunction<{ correlationId: number; newStatus: string }>(
        'fn_correlation_dismiss',
        [correlationId, body.reason, req.user!.id],
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
