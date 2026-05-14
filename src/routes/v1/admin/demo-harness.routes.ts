/**
 * CR-J — Demo Harness routes under /api/v1/admin/demo/
 *
 * Mounted by admin/index.ts at '/demo' — this file handles the CR-I/J
 * harness endpoints. The existing demo.routes.ts (CR-C purge + classification)
 * remains mounted at the same prefix; paths are disjoint.
 *
 * Permission gates per api-contracts.json:
 *   demo.scenario.trigger — list, get, trigger, scenario-runs
 *   demo.reset            — reset
 *   demo.time_freeze.manage — time-freeze set/unfreeze/current
 *   demo.health_check.read  — health-check
 *
 * GET /scenarios/runs MUST be registered BEFORE GET /scenarios/:scenarioId
 * to prevent Express matching 'runs' as a :scenarioId param.
 */
import { Router } from 'express';
import { demoHarnessController } from '../../../controllers/admin/demo-harness.controller';
import { authenticate, authorise, authoriseAnyOf } from '../../../middleware/auth.middleware';
import {
  authedReadRateLimiter,
  heavyExportRateLimiter,
} from '../../../middleware/rate-limit.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { resetDemoBodySchema, timeFreezeSetBodySchema } from '../../../schemas/demo-harness.schemas';
import { demoTimeFreezeMiddleware } from '../../../middleware/demo-time-freeze.middleware';

const router = Router();

// All demo-harness routes require authentication
router.use(authenticate);

// Time-freeze header middleware — applies to all demo harness routes
router.use(demoTimeFreezeMiddleware);

// ─── Scenario runs list (MUST be before /:scenarioId) ────────────────────────
router.get(
  '/scenarios/runs',
  authedReadRateLimiter,
  authorise(['demo.scenario.trigger']),
  demoHarnessController.listScenarioRuns,
);

// ─── Scenario list ────────────────────────────────────────────────────────────
router.get(
  '/scenarios',
  authedReadRateLimiter,
  authoriseAnyOf(['demo.scenario.trigger', 'demo.reset']),
  demoHarnessController.listScenarios,
);

// ─── Scenario detail ─────────────────────────────────────────────────────────
router.get(
  '/scenarios/:scenarioId',
  authedReadRateLimiter,
  authorise(['demo.scenario.trigger']),
  demoHarnessController.getScenario,
);

// ─── Trigger scenario ────────────────────────────────────────────────────────
router.post(
  '/scenarios/:scenarioId/trigger',
  heavyExportRateLimiter,
  authorise(['demo.scenario.trigger']),
  demoHarnessController.triggerScenario,
);

// ─── Reset demo ──────────────────────────────────────────────────────────────
router.post(
  '/reset',
  heavyExportRateLimiter,
  authorise(['demo.reset']),
  validate(resetDemoBodySchema, 'body'),
  demoHarnessController.resetDemo,
);

// ─── Time-freeze: set ────────────────────────────────────────────────────────
router.post(
  '/time-freeze',
  authedReadRateLimiter,
  authorise(['demo.time_freeze.manage']),
  validate(timeFreezeSetBodySchema, 'body'),
  demoHarnessController.setTimeFreeze,
);

// ─── Time-freeze: unfreeze ───────────────────────────────────────────────────
router.post(
  '/time-unfreeze',
  authedReadRateLimiter,
  authorise(['demo.time_freeze.manage']),
  demoHarnessController.unfreeze,
);

// ─── Time-freeze: current ────────────────────────────────────────────────────
router.get(
  '/time-freeze/current',
  authedReadRateLimiter,
  authorise(['demo.time_freeze.manage']),
  demoHarnessController.getTimeCurrent,
);

// ─── Health check ────────────────────────────────────────────────────────────
router.get(
  '/health-check',
  authedReadRateLimiter,
  authorise(['demo.health_check.read']),
  demoHarnessController.healthCheck,
);

export default router;
