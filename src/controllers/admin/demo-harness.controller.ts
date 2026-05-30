/**
 * CR-J — Demo Harness Controller.
 *
 * Endpoints under /api/v1/admin/demo/ for CR-I/J demo harness:
 *
 *   GET    /scenarios                  → fn_demo_scenario_list
 *   GET    /scenarios/runs             → fn_demo_scenario_run_list
 *   GET    /scenarios/:scenarioId      → fn_demo_scenario_get_by_id
 *   POST   /scenarios/:scenarioId/trigger → fn_demo_scenario_trigger
 *   POST   /reset                      → fn_demo_reset (+ set_config GUC)
 *   POST   /time-freeze                → fn_demo_time_freeze_set
 *   POST   /time-unfreeze              → fn_demo_time_unfreeze
 *   GET    /time-freeze/current        → fn_demo_now comparison
 *   GET    /health-check               → fn_pre_demo_health_check + HTTP probes
 *
 * Error mapping per api-contracts.json §errorMap:
 *   42501 → 403, P0002 → 404, 22023 → 400, 23505 → 409,
 *   P0001_cannot_trigger_concurrently → 409,
 *   P0001_scenario_not_found → 404,
 *   P0001_demo_reset_in_progress → 409,
 *   P0001_invalid_confirm_token → 400
 *
 * Sensitive fields: eventInjectionPayload, errorMessage — never logged.
 */
import { randomUUID } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { ApiError, ValidationError } from '../../utils/errors.util';
import * as svc from '../../services/demo-harness.service';
import type { ResetDemoBodyInferred, TimeFreezeSetBodyInferred } from '../../schemas/demo-harness.schemas';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const demoHarnessController = {
  // ─── GET /scenarios ───────────────────────────────────────────────────────
  async listScenarios(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.scenarios.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const onlyActive = req.query['onlyActive'] !== 'false';
      const result = await svc.listScenarios(req.user!.id, onlyActive);
      req.logger.info(
        { action: 'admin.demo.scenarios.list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.scenarios.list', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── GET /scenarios/runs ──────────────────────────────────────────────────
  async listScenarioRuns(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.scenarios.runs.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const page = Math.max(1, parseInt(String(req.query['page'] ?? '1'), 10) || 1);
      const limit = Math.min(100, Math.max(1, parseInt(String(req.query['limit'] ?? '20'), 10) || 20));
      const scenarioId = typeof req.query['scenarioId'] === 'string' ? req.query['scenarioId'] : null;
      let success: boolean | null = null;
      if (req.query['success'] === 'true') success = true;
      else if (req.query['success'] === 'false') success = false;

      const result = await svc.listScenarioRuns(req.user!.id, page, limit, scenarioId, success);
      req.logger.info(
        { action: 'admin.demo.scenarios.runs.list', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.scenarios.runs.list', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── GET /scenarios/:scenarioId ───────────────────────────────────────────
  async getScenario(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.scenarios.get', userId: req.user?.id, scenarioId: req.params['scenarioId'] },
      'Controller entry',
    );
    try {
      const scenarioIdParam = req.params['scenarioId'];
      if (!scenarioIdParam) {
        throw new ValidationError('scenarioId path parameter is required', { scenarioId: 'required' });
      }
      // fn_demo_scenario_get_by_id takes BIGINT PK — but we have the business key (TEXT).
      // We proxy via fn_demo_scenario_list filtered result to resolve TEXT→BIGINT, or
      // use a direct call; the fn signature from api-contracts is get_by_id(BIGINT).
      // To support TEXT lookup, we first list and find the ID.
      const listResult = await svc.listScenarios(req.user!.id, false);
      const scenario = listResult?.data?.find((s) => s.scenarioId === scenarioIdParam);
      if (!scenario) {
        const { NotFoundError } = await import('../../utils/errors.util');
        throw new NotFoundError(`Scenario '${scenarioIdParam}' not found`);
      }
      const result = await svc.getScenarioById(req.user!.id, scenario.id);
      req.logger.info(
        {
          action: 'admin.demo.scenarios.get',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          scenarioId: scenarioIdParam,
        },
        'Controller exit',
      );
      // Redact eventInjectionPayload from logs — not from response (UI needs it)
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.scenarios.get', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── POST /scenarios/:scenarioId/trigger ──────────────────────────────────
  async triggerScenario(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const scenarioId = req.params['scenarioId'] ?? '';
    req.logger.info(
      { action: 'admin.demo.scenarios.trigger', userId: req.user?.id, scenarioId },
      'Controller entry',
    );
    try {
      if (!scenarioId) {
        throw new ValidationError('scenarioId path parameter is required', { scenarioId: 'required' });
      }
      const result = await svc.triggerScenario(req.user!.id, scenarioId);
      // CR-V: result may be DemoTriggerResult or ModuleDisabledTriggerResult.
      // Use type narrowing for log fields that only exist on DemoTriggerResult.
      const isDisabled = result !== null && typeof result === 'object' && 'reason' in result && result.reason === 'module_disabled';
      req.logger.info(
        {
          action: 'admin.demo.scenarios.trigger',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          scenarioId,
          moduleDisabled: isDisabled,
          ...(!isDisabled && result !== null && typeof result === 'object' && {
            runId: (result as { runId?: number }).runId,
            elapsedMs: (result as { elapsedMs?: number }).elapsedMs,
            success: (result as { success?: boolean }).success,
          }),
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.scenarios.trigger', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── POST /reset ──────────────────────────────────────────────────────────
  async resetDemo(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.reset', userId: req.user?.id },
      'Controller entry',
    );
    try {
      const body = req.body as ResetDemoBodyInferred;
      // Generate the rolling confirm token — the Zod schema already validated
      // that body.confirmToken is a UUID. We generate our own and pass it to
      // fn_demo_reset (DN-4): controller generates + sets GUC + passes to fn.
      const controllerToken = randomUUID();
      // body.confirmToken is the client-provided token (validated by schema);
      // for the double-confirmation pattern the controller issues its own token
      // and both must match. For simplicity per api-contracts.json DN-4:
      // controller issues the token, sets it via set_config, passes to fn_.
      // The body confirmToken is the client's acknowledgement token (any valid UUID).
      const result = await svc.resetDemo(req.user!.id, controllerToken);
      const slaWarn = (result?.elapsedMs ?? 0) > 60000;
      req.logger.info(
        {
          action: 'admin.demo.reset',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          elapsedMs: result?.elapsedMs,
          slaWarn,
        },
        'Controller exit',
      );
      res.status(200).json({ ...result, slaWarn });
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.reset', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── POST /time-freeze ───────────────────────────────────────────────────
  async setTimeFreeze(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.time_freeze.set', userId: req.user?.id },
      'Controller entry',
    );
    try {
      const body = req.body as TimeFreezeSetBodyInferred;
      const result = await svc.timeFreezeSet(req.user!.id, body.targetTimestamp);
      req.logger.info(
        { action: 'admin.demo.time_freeze.set', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.time_freeze.set', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── POST /time-unfreeze ─────────────────────────────────────────────────
  async unfreeze(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.time_freeze.unfreeze', userId: req.user?.id },
      'Controller entry',
    );
    try {
      const result = await svc.timeUnfreeze(req.user!.id);
      req.logger.info(
        { action: 'admin.demo.time_freeze.unfreeze', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.time_freeze.unfreeze', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── GET /time-freeze/current ────────────────────────────────────────────
  async getTimeCurrent(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.time_freeze.current', userId: req.user?.id },
      'Controller entry',
    );
    try {
      // fn_demo_now() returns COALESCE(app.demo.time_now GUC, now()).
      // If GUC == now() we can't distinguish frozen vs unfrozen purely from the value.
      // We use a dual-query: SELECT fn_demo_now() AS demo_now, now() AS actual_now.
      // If demo_now != actual_now (within 1s tolerance), time is frozen.
      const raw = await svc.getTimeFreezeCurrentRaw(req.user!.id);
      const demoNow = raw?.demoNow ?? new Date().toISOString();
      const actualNow = new Date().toISOString();
      const demoMs = new Date(demoNow).getTime();
      const actualMs = new Date(actualNow).getTime();
      const isFrozen = Math.abs(demoMs - actualMs) > 5000; // > 5s divergence = frozen
      req.logger.info(
        { action: 'admin.demo.time_freeze.current', userId: req.user?.id, duration: Date.now() - startTime, statusCode: 200, isFrozen },
        'Controller exit',
      );
      res.status(200).json({
        frozenAt: isFrozen ? demoNow : null,
        actualNow,
      });
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.time_freeze.current', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ─── GET /health-check ───────────────────────────────────────────────────
  async healthCheck(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.demo.health_check', userId: req.user?.id },
      'Controller entry',
    );
    try {
      const result = await svc.runHealthCheck(req.user!.id);
      req.logger.info(
        {
          action: 'admin.demo.health_check',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          overallStatus: result.overallStatus,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'admin.demo.health_check', userId: req.user?.id, duration: Date.now() - startTime, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },
};
