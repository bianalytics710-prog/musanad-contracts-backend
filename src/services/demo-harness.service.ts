/**
 * CR-J — Demo Harness Service.
 *
 * Wraps the 6 demo fn_'s (trigger / reset / time-freeze-set / time-unfreeze /
 * health-check / scenario-list). All calls are thin db.callFunction passthroughs
 * per the v2.6 pattern (Route → Controller → Service → db.callFunction → JSONB).
 *
 * Pre-demo health-check fans out to:
 *   1. fn_pre_demo_health_check (DB probes: db, sources, rules, scoring, advisory, notification)
 *   2. Parallel HTTP probes: Supabase Storage HEAD, OpenAI /v1/models, SMTP (email-config)
 * Returns within 5s NFR (AC-S15-03).
 *
 * fn_demo_reset confirmToken lifecycle per DN-4:
 *   Controller calls set_config('app.demo.reset_token', uuid, false) on the same
 *   DB connection; this service is called AFTER that GUC is set, via
 *   executeInTransaction callback that the controller drives.
 */
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import type {
  DemoScenarioListResult,
  DemoScenarioGetResult,
  DemoTriggerResult,
  DemoResetResult,
  DemoTimeFreezeResult,
  DemoTimeUnfreezeResult,
  DemoTimeFreezeCurrentResult,
  DemoSubsystemHealth,
  DemoHealthCheckResult,
  DemoScenarioRunListResult,
} from '../types/demo-harness.types';

/** Timeout for HTTP probes in health-check (NFR: overall < 5s) */
const HTTP_PROBE_TIMEOUT_MS = 3000;

/** ADNOC single-tenant constant — same sentinel used across all tenant-scoped services */
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

// ─── fn_ wrappers ────────────────────────────────────────────────────────────

export const listScenarios = (
  actorId: number,
  onlyActive: boolean,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<DemoScenarioListResult> =>
  db.callFunction<DemoScenarioListResult>(
    'fn_demo_scenario_list',
    [actorId, onlyActive],
    { actorId, tenantId },
  );

export const getScenarioById = (
  actorId: number,
  id: number,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<DemoScenarioGetResult> =>
  db.callFunction<DemoScenarioGetResult>(
    'fn_demo_scenario_get_by_id',
    [actorId, id],
    { actorId, tenantId },
  );

/**
 * CR-V: scenario→module mapping. Before triggering a scenario that depends on a
 * specific togglable ECIP module, check fn_module_enabled and short-circuit with
 * the standard module_disabled envelope if the module is off.
 * Scenarios not listed here have no single-module dependency and always run.
 * Mirrors the demo_scenario.scenario_id values from migration 323.
 */
const SCENARIO_MODULE_MAP: Record<string, string> = {
  labor_cascade:  'regulatory_cascade',
  budget_burn:    'financial.budget_burn',
  trade_margin:   'financial.trade_margin',
};

/**
 * Shape returned by fn_demo_scenario_trigger (per migration 324 fn_ envelope).
 * The module_disabled variant matches the existing outcome-envelope shape so the
 * FE demo control panel can render an "off" badge via the same result.prepared check.
 */
interface ModuleDisabledTriggerResult {
  prepared: false;
  reason: 'module_disabled';
  moduleKey: string;
  scenarioCode: string;
}

export const triggerScenario = async (
  actorId: number,
  scenarioId: string,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<DemoTriggerResult | ModuleDisabledTriggerResult> => {
  // CR-V: per-scenario module gate (BE service layer — no migration needed).
  const moduleKey = SCENARIO_MODULE_MAP[scenarioId];
  if (moduleKey) {
    try {
      const enabled = await db.callFunction<boolean>(
        'fn_module_enabled',
        [tenantId, moduleKey],
        { actorId, tenantId },
      );
      if (!enabled) {
        logger.info(
          { action: 'demoHarness.triggerScenario.moduleDisabled', moduleKey, scenarioId, tenantId },
          'Demo scenario blocked — module disabled',
        );
        return {
          prepared: false,
          reason: 'module_disabled',
          moduleKey,
          scenarioCode: scenarioId,
        };
      }
    } catch (guardErr) {
      // Non-fatal: if fn_module_enabled errors (e.g. migration lag), proceed with trigger.
      logger.warn(
        {
          action: 'demoHarness.triggerScenario.moduleGuardError',
          scenarioId,
          moduleKey,
          errorType: guardErr instanceof Error ? guardErr.name : 'UNKNOWN',
        },
        'module guard check failed — proceeding with scenario trigger (fail-open)',
      );
    }
  }

  return db.callFunction<DemoTriggerResult>(
    'fn_demo_scenario_trigger',
    [actorId, scenarioId],
    { actorId, tenantId },
  );
};

/**
 * Reset demo — sets app.demo.reset_token GUC in the same transaction before
 * calling fn_demo_reset. The token is session-scoped, single-use (DN-4).
 * Uses executeInTransaction so both SET LOCAL calls + fn call share one txn.
 */
export const resetDemo = async (
  actorId: number,
  confirmToken: string,
): Promise<DemoResetResult> => {
  return db.executeInTransaction(async (client) => {
    // Set RLS actor
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    // Set tenant context (required by tenant-scoped RLS policies)
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [ADNOC_TENANT_ID]);
    // Set reset token — fn_demo_reset validates this internally
    await client.query("SELECT set_config('app.demo.reset_token', $1, true)", [confirmToken]);
    const result = await client.query<{ result: DemoResetResult }>(
      'SELECT fn_demo_reset($1, $2) AS result',
      [actorId, confirmToken],
    );
    const raw = result.rows[0]?.result;
    return raw as DemoResetResult;
  });
};

export const timeFreezeSet = (
  actorId: number,
  targetTimestamp: string,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<DemoTimeFreezeResult> =>
  db.callFunction<DemoTimeFreezeResult>(
    'fn_demo_time_freeze_set',
    [actorId, targetTimestamp],
    { actorId, tenantId },
  );

export const timeUnfreeze = (
  actorId: number,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<DemoTimeUnfreezeResult> =>
  db.callFunction<DemoTimeUnfreezeResult>(
    'fn_demo_time_unfreeze',
    [actorId],
    { actorId, tenantId },
  );

export const getTimeFreezeCurrentRaw = async (
  actorId: number,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<{ demoNow: string }> => {
  // fn_demo_now() returns a bare TIMESTAMPTZ. node-postgres maps that to a JS
  // Date object — not a string and not a wrapper object. MUST pass tenantId so
  // app.current_tenant_id GUC is set (fn_demo_now reads demo_time_freeze_state
  // for that tenant).
  const result = await db.callFunction<Date | string | { demoNow?: string; fnDemoNow?: string }>(
    'fn_demo_now',
    [],
    { actorId, tenantId },
  );
  if (result instanceof Date) return { demoNow: result.toISOString() };
  if (typeof result === 'string') return { demoNow: result };
  if (result && typeof result === 'object') {
    return { demoNow: result.demoNow ?? result.fnDemoNow ?? new Date().toISOString() };
  }
  return { demoNow: new Date().toISOString() };
};

export const listScenarioRuns = (
  actorId: number,
  page: number,
  limit: number,
  scenarioId: string | null,
  success: boolean | null,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<DemoScenarioRunListResult> =>
  db.callFunction<DemoScenarioRunListResult>(
    'fn_demo_scenario_run_list',
    [actorId, page, limit, scenarioId, success],
    { actorId, tenantId },
  );

// ─── Pre-demo health check ────────────────────────────────────────────────────

interface DbHealthCheckRaw {
  subsystems?: Array<{
    name: string;
    status: string;
    lastChecked?: string | null;
    remediation?: string | null;
  }>;
}

/**
 * Fan-out health check combining DB probe + HTTP probes.
 * Times out HTTP probes at HTTP_PROBE_TIMEOUT_MS to meet the 5s NFR.
 */
export const runHealthCheck = async (
  actorId: number,
): Promise<DemoHealthCheckResult> => {
  const startMs = Date.now();

  // DB side probe
  const dbRaw = await db.callFunction<DbHealthCheckRaw>(
    'fn_pre_demo_health_check',
    [actorId],
    { actorId, tenantId: ADNOC_TENANT_ID },
  );

  const dbSubsystems: DemoSubsystemHealth[] = (dbRaw?.subsystems ?? []).map((s) => ({
    name: s.name,
    status: _normaliseStatus(s.status),
    lastChecked: s.lastChecked ?? null,
    remediation: s.remediation ?? null,
  }));

  // HTTP probes (parallel, with individual timeouts)
  const httpProbes = await Promise.all([
    _probeStorage(),
    _probeOpenAI(),
    _probeSMTP(),
  ]);

  // Merge by name: HTTP probe is authoritative for storage/openai/smtp; the
  // DB function emits placeholder rows for those three so the legacy contract
  // shape stays stable, but the HTTP probe is the real signal.
  const httpProbeNames = new Set(httpProbes.map((p) => p.name));
  const allSubsystems: DemoSubsystemHealth[] = [
    ...dbSubsystems.filter((s) => !httpProbeNames.has(s.name)),
    ...httpProbes,
  ];

  const hasDown = allSubsystems.some((s) => s.status === 'down');
  const hasDegraded = allSubsystems.some((s) => s.status === 'degraded');
  const overallStatus: 'ok' | 'degraded' | 'down' = hasDown
    ? 'down'
    : hasDegraded
    ? 'degraded'
    : 'ok';

  logger.info(
    {
      action: 'demo.health_check',
      actorId,
      elapsedMs: Date.now() - startMs,
      overallStatus,
      subsystemCount: allSubsystems.length,
    },
    'Demo health check complete',
  );

  return { subsystems: allSubsystems, overallStatus };
};

// ─── HTTP probe helpers ───────────────────────────────────────────────────────

const _withTimeout = async <T>(
  promise: Promise<T>,
  timeoutMs: number,
): Promise<T | null> => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeoutPromise = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), timeoutMs);
  });
  try {
    const result = await Promise.race([promise, timeoutPromise]);
    return result;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
};

const _probeStorage = async (): Promise<DemoSubsystemHealth> => {
  const name = 'storage';
  const storageUrl = process.env['SUPABASE_STORAGE_URL'] ?? process.env['SUPABASE_URL'];
  const anonKey = process.env['SUPABASE_ANON_KEY'] ?? '';
  // When Supabase Storage is not configured for this deployment (no URL set
  // OR no anon key — both are required to actually use Storage), report ok
  // with a not-in-use remediation hint rather than blocking the demo.
  if (!storageUrl || !anonKey) {
    return {
      name,
      status: 'ok',
      lastChecked: new Date().toISOString(),
      remediation: null,
    };
  }
  try {
    const probeUrl = storageUrl.replace(/\/$/, '') + '/storage/v1/bucket';
    const result = await _withTimeout(
      fetch(probeUrl, {
        method: 'GET',
        headers: {
          'User-Agent': 'Musanad-Demo-HealthCheck/1.0',
          Authorization: `Bearer ${anonKey}`,
        },
      }),
      HTTP_PROBE_TIMEOUT_MS,
    );
    if (!result) {
      return { name, status: 'degraded', lastChecked: new Date().toISOString(), remediation: 'Storage probe timed out' };
    }
    // 200 or 401 (auth required) both indicate storage is reachable
    const ok = result.ok || result.status === 401 || result.status === 403;
    void result.body?.cancel().catch(() => undefined);
    return {
      name,
      status: ok ? 'ok' : 'degraded',
      lastChecked: new Date().toISOString(),
      remediation: ok ? null : `HTTP ${result.status} from storage`,
    };
  } catch (err) {
    return {
      name,
      status: 'down',
      lastChecked: new Date().toISOString(),
      remediation: err instanceof Error ? err.message : String(err),
    };
  }
};

const _probeOpenAI = async (): Promise<DemoSubsystemHealth> => {
  const name = 'openai';
  if (!process.env['OPENAI_API_KEY']) {
    return {
      name,
      status: 'degraded',
      lastChecked: new Date().toISOString(),
      remediation: 'OPENAI_API_KEY env var not set',
    };
  }
  try {
    const result = await _withTimeout(
      fetch('https://api.openai.com/v1/models', {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${process.env['OPENAI_API_KEY']}`,
          'User-Agent': 'Musanad-Demo-HealthCheck/1.0',
        },
      }),
      HTTP_PROBE_TIMEOUT_MS,
    );
    if (!result) {
      return { name, status: 'degraded', lastChecked: new Date().toISOString(), remediation: 'OpenAI probe timed out' };
    }
    void result.body?.cancel().catch(() => undefined);
    return {
      name,
      status: result.ok ? 'ok' : 'degraded',
      lastChecked: new Date().toISOString(),
      remediation: result.ok ? null : `HTTP ${result.status} from OpenAI /v1/models`,
    };
  } catch (err) {
    return {
      name,
      status: 'down',
      lastChecked: new Date().toISOString(),
      remediation: err instanceof Error ? err.message : String(err),
    };
  }
};

const _probeSMTP = async (): Promise<DemoSubsystemHealth> => {
  const name = 'smtp';
  // SMTP connectivity probed via env — we don't open a raw socket here.
  // HOST + PORT are required; USER/PASS are optional (Mailpit and other
  // local relays accept unauthenticated submissions).
  const configured =
    !!process.env['SMTP_HOST'] && !!process.env['SMTP_PORT'];

  return {
    name,
    status: configured ? 'ok' : 'degraded',
    lastChecked: new Date().toISOString(),
    remediation: configured ? null : 'SMTP env vars (SMTP_HOST, SMTP_PORT) not configured',
  };
};

const _normaliseStatus = (raw: string): 'ok' | 'degraded' | 'down' => {
  if (raw === 'ok') return 'ok';
  if (raw === 'degraded') return 'degraded';
  if (raw === 'down') return 'down';
  return 'degraded';
};
