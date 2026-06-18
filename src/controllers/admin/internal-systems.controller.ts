/**
 * Internal Systems controller — Platform Admin registry of ERP / Finance /
 * HRMS / CRM / etc. integrations. Backs /app/admin/internal-systems.
 *
 * Thin pass-through over fn_internal_system_* (mig 578).
 *
 *   GET    /api/v1/admin/internal-systems
 *   POST   /api/v1/admin/internal-systems
 *   GET    /api/v1/admin/internal-systems/:id
 *   PUT    /api/v1/admin/internal-systems/:id
 *   DELETE /api/v1/admin/internal-systems/:id
 *   POST   /api/v1/admin/internal-systems/:id/test-connection
 *
 * Route ordering: literal segments first (none here), then `:id` last.
 *
 * Permission: platform.integrations.manage (route-layer + fn body).
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../../database/client';
import { probeInternalSystem } from '../../services/internal-system-probe.service';
import {
  fetchConnectorRecords,
  hasConnectorAdapter,
  getConnectorMappings,
} from '../../services/internal-system-connectors.service';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

interface UpsertInput {
  systemCode: string;
  displayName: string;
  displayNameAr?: string | null;
  kind: string;
  vendor?: string | null;
  baseUrl?: string | null;
  apiEndpoint?: string | null;
  authMethod?: string | null;
  pullScheduleCron?: string | null;
  notes?: string | null;
}

function readUpsert(req: Request): UpsertInput {
  const b = req.body as Record<string, unknown>;
  return {
    systemCode: String(b.systemCode ?? ''),
    displayName: String(b.displayName ?? ''),
    displayNameAr: typeof b.displayNameAr === 'string' ? b.displayNameAr : null,
    kind: String(b.kind ?? ''),
    vendor: typeof b.vendor === 'string' ? b.vendor : null,
    baseUrl: typeof b.baseUrl === 'string' ? b.baseUrl : null,
    apiEndpoint: typeof b.apiEndpoint === 'string' ? b.apiEndpoint : null,
    authMethod: typeof b.authMethod === 'string' ? b.authMethod : null,
    pullScheduleCron: typeof b.pullScheduleCron === 'string' ? b.pullScheduleCron : null,
    notes: typeof b.notes === 'string' ? b.notes : null,
  };
}

const ctx = (req: Request) => ({
  actorId: req.user!.id,
  tenantId: req.tenantId ?? ADNOC_TENANT_ID,
});

const errorType = (e: unknown): string =>
  e instanceof Error ? e.name : 'UNKNOWN';

export const internalSystemsController = {
  /**
   * GET /field-mappings — the declarative "their model → our model" contract
   * for every wired connector. Static config (no DB); the same specs drive the
   * pull, so the view can't drift from what actually gets ingested.
   */
  fieldMappings(req: Request, res: Response, next: NextFunction): void {
    try {
      res.status(200).json({ data: getConnectorMappings() });
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.fieldMappings', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info(
      { action: 'admin.internalSystems.list', userId: req.user?.id, query: req.query },
      'Controller entry',
    );
    try {
      const kind = typeof req.query.kind === 'string' ? req.query.kind : null;
      const status = typeof req.query.status === 'string' ? req.query.status : null;
      const search = typeof req.query.search === 'string' ? req.query.search : null;
      const result = await db.callFunction<{ data: unknown[]; total: number }>(
        'fn_internal_system_list',
        [kind, status, search],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.internalSystems.list',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
          rows: result.total,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.list', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async get(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const id = Number(req.params.id);
      const result = await db.callFunction(
        'fn_internal_system_get',
        [id],
        ctx(req),
      );
      req.logger.info(
        { action: 'admin.internalSystems.get', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.get', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const input = readUpsert(req);
      const result = await db.callFunction(
        'fn_internal_system_upsert',
        [
          req.user!.id,
          null, // create
          input.systemCode,
          input.displayName,
          input.displayNameAr,
          input.kind,
          input.vendor,
          input.baseUrl,
          input.apiEndpoint,
          input.authMethod,
          input.pullScheduleCron,
          input.notes,
        ],
        ctx(req),
      );
      req.logger.info(
        { action: 'admin.internalSystems.create', userId: req.user?.id, duration: Date.now() - start, statusCode: 201 },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.create', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const id = Number(req.params.id);
      const input = readUpsert(req);
      const result = await db.callFunction(
        'fn_internal_system_upsert',
        [
          req.user!.id,
          id,
          input.systemCode,
          input.displayName,
          input.displayNameAr,
          input.kind,
          input.vendor,
          input.baseUrl,
          input.apiEndpoint,
          input.authMethod,
          input.pullScheduleCron,
          input.notes,
        ],
        ctx(req),
      );
      req.logger.info(
        { action: 'admin.internalSystems.update', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.update', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async deactivate(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const id = Number(req.params.id);
      const result = await db.callFunction(
        'fn_internal_system_deactivate',
        [id],
        ctx(req),
      );
      req.logger.info(
        { action: 'admin.internalSystems.deactivate', userId: req.user?.id, duration: Date.now() - start, statusCode: 200 },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.deactivate', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async testConnection(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const id = Number(req.params.id);
      // Load the row to get base_url / api_endpoint / auth_method.
      const row = (await db.callFunction(
        'fn_internal_system_get',
        [id],
        ctx(req),
      )) as { id: number; baseUrl: string | null; apiEndpoint: string | null };

      const probe = await probeInternalSystem({
        baseUrl: row.baseUrl,
        apiEndpoint: row.apiEndpoint,
      });

      const setResult = (await db.callFunction(
        'fn_internal_system_set_health',
        [req.user!.id, id, probe.status, probe.error],
        ctx(req),
      )) as Record<string, unknown>;

      req.logger.info(
        {
          action: 'admin.internalSystems.testConnection',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
          status: probe.status,
        },
        'Controller exit',
      );
      res.status(200).json({ ...setResult, probe });
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.testConnection', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  /**
   * POST /:id/sync — "Sync now". Runs the connector's adapter (sample/sandbox
   * pull for the demo; real vendor API in production), then lands the
   * normalised records via fn_internal_system_sync_run (signal → correlation →
   * risk case). Idempotent — re-pulled findings report as deduped.
   */
  async sync(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const id = Number(req.params.id);
      const row = (await db.callFunction(
        'fn_internal_system_get',
        [id],
        ctx(req),
      )) as { id: number; systemCode: string };

      if (!hasConnectorAdapter(row.systemCode)) {
        res.status(422).json({
          error: {
            code: 'CONNECTOR_NOT_AVAILABLE',
            message:
              'This connector is registry-only — no data adapter is configured yet. Sync is available for SAP S/4HANA Finance, ServiceNow ITSM, and Oracle Primavera P6.',
          },
        });
        return;
      }

      const records = fetchConnectorRecords(row.systemCode) ?? [];
      const result = await db.callFunction(
        'fn_internal_system_sync_run',
        [req.user!.id, id, records],
        ctx(req),
      );

      req.logger.info(
        {
          action: 'admin.internalSystems.sync',
          userId: req.user?.id,
          systemCode: row.systemCode,
          duration: Date.now() - start,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.internalSystems.sync', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};
