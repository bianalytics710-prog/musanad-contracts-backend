/**
 * M22 / CR-MIG-DRIVE — single combined controller for:
 *   - /api/v1/integrations/connectors          (catalog)
 *   - /api/v1/integrations/connections         (list / disconnect)
 *   - /api/v1/integrations/google-drive/*      (auth-url, callback)
 *   - /api/v1/migration/batches/*              (trigger / list / detail / records / progress / rollback / coverage-report)
 *   - /api/v1/admin/migration/purge-all*       (preview + execute)
 *
 * Logger entry/exit pattern matches demo-harness controller.
 * Sensitive fields (tokens) NEVER logged.
 */
import type { NextFunction, Request, Response } from 'express';
import { z } from 'zod';
import { db } from '../database/client';
import { pool } from '../database/config';
import { ApiError, ValidationError } from '../utils/errors.util';
import {
  buildAuthUrl,
  exchangeCodeForTokens,
  parseState,
} from '../services/google-drive.service';
import { encryptToken } from '../services/token-cipher.service';
import {
  triggerSync,
  processBatch,
  rollback,
  purgeAll,
} from '../services/migration-orchestrator.service';
import { env } from '../utils/env-validation.util';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

// ----------------------------------------------------------------
// Body schemas
// ----------------------------------------------------------------

const createBatchBodySchema = z.object({
  connectionId: z.number().int().positive(),
});

const rollbackBodySchema = z.object({
  reason: z.string().min(1).max(2000),
  confirmToken: z.string().regex(/^ROLLBACK_BATCH_\d+$/),
});

const purgeBodySchema = z.object({
  confirmToken: z.string().regex(/^PURGE_MIGRATION_\d{4}-\d{2}-\d{2}$/),
  acknowledgementChecked: z.literal(true),
});

const authUrlBodySchema = z.object({
  returnPath: z.string().optional(),
  folderId: z.string().min(8).optional(),
});

// ----------------------------------------------------------------

export const migrationController = {
  // ─── GET /integrations/connectors ─────────────────────────────────────────
  async listConnectorCatalog(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'migration.catalog.list', userId: req.user?.id });
    try {
      const r = await pool().query<{
        provider: string; display_name: string; tagline: string | null;
        status: string; phase: number; logo_key: string | null; sort_order: number;
      }>(
        `SELECT provider, display_name, tagline, status, phase, logo_key, sort_order
           FROM connector_catalog
          WHERE is_active = TRUE
          ORDER BY sort_order ASC, provider ASC`,
      );
      // Mark per-tenant connection presence
      const tenantId = req.tenantId ?? ADNOC_TENANT_ID;
      const conns = await pool().query<{ provider: string; n: string }>(
        `SELECT provider, COUNT(*)::text AS n
           FROM external_connection
          WHERE tenant_id = $1 AND is_active = TRUE AND status IN ('connected','token_expired')
          GROUP BY provider`,
        [tenantId],
      );
      const connSet = new Set(conns.rows.map((x: { provider: string }) => x.provider));
      res.status(200).json({
        success: true,
        data: r.rows.map((c: {
          provider: string; display_name: string; tagline: string | null;
          status: string; phase: number; logo_key: string | null; sort_order: number;
        }) => ({
          provider: c.provider,
          displayName: c.display_name,
          tagline: c.tagline,
          status: c.status,
          phase: c.phase,
          logoKey: c.logo_key,
          sortOrder: c.sort_order,
          isConnected: connSet.has(c.provider),
        })),
      });
      req.logger.info({ action: 'migration.catalog.list', duration: Date.now() - start, statusCode: 200 });
    } catch (err) {
      req.logger.error({ action: 'migration.catalog.list', errorType: errorTypeOf(err) });
      next(err);
    }
  },

  // ─── GET /integrations/connections ────────────────────────────────────────
  async listConnections(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'migration.connections.list', userId: req.user?.id });
    try {
      const result = await db.callFunction<unknown[]>(
        'fn_external_connection_list',
        [],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      res.status(200).json({ success: true, data: result });
      req.logger.info({ action: 'migration.connections.list', duration: Date.now() - start, statusCode: 200 });
    } catch (err) {
      req.logger.error({ action: 'migration.connections.list', errorType: errorTypeOf(err) });
      next(err);
    }
  },

  // ─── DELETE /integrations/connections/:id ─────────────────────────────────
  async disconnectConnection(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    const connId = parseInt(String(req.params['id']), 10);
    req.logger.info({ action: 'migration.connections.disconnect', userId: req.user?.id, connId });
    try {
      if (!Number.isFinite(connId) || connId <= 0) throw new ValidationError('Invalid connection id');
      await db.callFunction<void>(
        'fn_external_connection_disconnect',
        [connId, req.user!.id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      res.status(200).json({ success: true, data: { id: connId, status: 'disconnected' } });
      req.logger.info({ action: 'migration.connections.disconnect', duration: Date.now() - start, statusCode: 200 });
    } catch (err) {
      req.logger.error({ action: 'migration.connections.disconnect', errorType: errorTypeOf(err) });
      next(err);
    }
  },

  // ─── POST /integrations/google-drive/auth-url ─────────────────────────────
  async buildGoogleAuthUrl(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'migration.google.authUrl', userId: req.user?.id });
    try {
      const body = authUrlBodySchema.parse(req.body ?? {});
      const { url, state } = buildAuthUrl({
        tenantId: req.tenantId ?? ADNOC_TENANT_ID,
        userId: req.user!.id,
        returnPath: body.returnPath,
      });
      // Optionally remember the folder the user pre-picked (FE may send this)
      if (body.folderId) {
        res.cookie('m22.preselectedFolder', body.folderId, {
          httpOnly: true, sameSite: 'lax', secure: false, maxAge: 600_000,
        });
      }
      res.status(200).json({ success: true, data: { url, state } });
      req.logger.info({ action: 'migration.google.authUrl', duration: Date.now() - start, statusCode: 200 });
    } catch (err) {
      req.logger.error({ action: 'migration.google.authUrl', errorType: errorTypeOf(err) });
      next(err);
    }
  },

  // ─── GET /integrations/google-drive/callback ──────────────────────────────
  async handleGoogleCallback(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'migration.google.callback' });
    try {
      const code = String(req.query['code'] ?? '');
      const stateToken = String(req.query['state'] ?? '');
      if (!code || !stateToken) throw new ValidationError('code + state required');
      const state = parseState(stateToken);
      const tokens = await exchangeCodeForTokens(code);

      // Use the pre-selected folder if present; otherwise default to the
      // demo folder ID (Phase-1 convenience — admin can change later).
      const preselect = req.cookies?.['m22.preselectedFolder']
        ?? '1uAGWSPb6vvu43gO1dDSJAcxRYiZ5JGtm';
      res.clearCookie('m22.preselectedFolder');

      const encAccess = encryptToken(tokens.accessToken);
      const encRefresh = tokens.refreshToken ? encryptToken(tokens.refreshToken) : null;

      const connectionId = await db.callFunction<number>(
        'fn_external_connection_create',
        [
          'google_drive',
          'Google Drive (' + preselect.substring(0, 8) + '…)',
          preselect,
          'Drive folder',
          encAccess,
          encRefresh,
          tokens.expiresAt,
          tokens.scopes,
          state.userId,
        ],
        { actorId: state.userId, tenantId: state.tenantId },
      );

      // Redirect back into the SPA so the popup-opener can detect connect
      // and refresh the connection list.
      const returnUrl = `${state.returnPath || '/app/admin/migration'}?connected=1&connectionId=${connectionId}`;
      res.redirect(302, returnUrl);
      req.logger.info({ action: 'migration.google.callback', duration: Date.now() - start, statusCode: 302, connectionId });
    } catch (err) {
      req.logger.error({ action: 'migration.google.callback', errorType: errorTypeOf(err) });
      // For UX, redirect back with an error flag rather than JSON
      try {
        const fallback = `/app/admin/migration?connectError=${encodeURIComponent(
          err instanceof Error ? err.message.substring(0, 200) : 'unknown',
        )}`;
        res.redirect(302, fallback);
        return;
      } catch {
        next(err);
      }
    }
  },

  // ─── POST /migration/batches ──────────────────────────────────────────────
  async createBatch(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    req.logger.info({ action: 'migration.batches.create', userId: req.user?.id });
    try {
      const body = createBatchBodySchema.parse(req.body);
      const batchId = await triggerSync({
        connectionId: body.connectionId,
        actorId: req.user!.id,
        tenantId: req.tenantId ?? ADNOC_TENANT_ID,
      });

      // If the worker is disabled, process synchronously so the demo flow
      // works without waiting for the cron. The brief explicitly allows
      // manual trigger in Phase 1.
      if (!env().MIGRATION_SYNC_WORKER_ENABLED) {
        // fire-and-forget; client polls for progress
        void processBatch({
          batchId,
          tenantId: req.tenantId ?? ADNOC_TENANT_ID,
        }).catch((err) => {
          req.logger.error(
            { action: 'migration.batches.create.async', batchId, errorType: errorTypeOf(err) },
          );
        });
      }

      res.status(201).json({ success: true, data: { id: batchId } });
      req.logger.info({ action: 'migration.batches.create', duration: Date.now() - start, batchId, statusCode: 201 });
    } catch (err) {
      req.logger.error({ action: 'migration.batches.create', errorType: errorTypeOf(err) });
      next(err);
    }
  },

  // ─── GET /migration/batches ───────────────────────────────────────────────
  async listBatches(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const limit = parseInt(String(req.query['limit'] ?? '50'), 10);
      const offset = parseInt(String(req.query['offset'] ?? '0'), 10);
      const result = await db.callFunction<unknown>(
        'fn_migration_batch_list',
        [limit, offset],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      res.status(200).json({ success: true, data: result });
      req.logger.info({ action: 'migration.batches.list', duration: Date.now() - start });
    } catch (err) { next(err); }
  },

  // ─── GET /migration/batches/:id ───────────────────────────────────────────
  async getBatch(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const id = parseInt(String(req.params['id']), 10);
      if (!Number.isFinite(id)) throw new ValidationError('Invalid batch id');
      const result = await db.callFunction<unknown>(
        'fn_migration_batch_get_by_id',
        [id],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      res.status(200).json({ success: true, data: result });
    } catch (err) { next(err); }
  },

  // ─── GET /migration/batches/:id/records ───────────────────────────────────
  async listBatchRecords(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const id = parseInt(String(req.params['id']), 10);
      if (!Number.isFinite(id)) throw new ValidationError('Invalid batch id');
      const status = typeof req.query['status'] === 'string' ? req.query['status'] : null;
      const limit = parseInt(String(req.query['limit'] ?? '50'), 10);
      const offset = parseInt(String(req.query['offset'] ?? '0'), 10);
      const result = await db.callFunction<unknown>(
        'fn_migration_batch_list_records',
        [id, status, limit, offset],
        { actorId: req.user!.id, tenantId: req.tenantId ?? ADNOC_TENANT_ID },
      );
      res.status(200).json({ success: true, data: result });
    } catch (err) { next(err); }
  },

  // ─── GET /migration/batches/:id/progress (lightweight poll) ──────────────
  async getBatchProgress(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const id = parseInt(String(req.params['id']), 10);
      if (!Number.isFinite(id)) throw new ValidationError('Invalid batch id');
      const r = await pool().query<{
        status: string; files_discovered: number; files_imported: number;
        files_review: number; files_failed: number; files_skipped_duplicate: number;
      }>(
        `SELECT status, files_discovered, files_imported, files_review,
                files_failed, files_skipped_duplicate
           FROM migration_batch
          WHERE id = $1 AND tenant_id = $2`,
        [id, req.tenantId ?? ADNOC_TENANT_ID],
      );
      if (r.rowCount === 0) {
        res.status(404).json({ success: false, error: 'batch_not_found' });
        return;
      }
      const row = r.rows[0];
      const terminal = ['completed','completed_with_errors','rolled_back','failed'].includes(row.status);
      res.status(200).json({
        success: true,
        data: {
          status: row.status,
          terminal,
          counts: {
            discovered: Number(row.files_discovered),
            imported: Number(row.files_imported),
            review: Number(row.files_review),
            failed: Number(row.files_failed),
            skippedDuplicate: Number(row.files_skipped_duplicate),
          },
        },
      });
    } catch (err) { next(err); }
  },

  // ─── POST /migration/batches/:id/rollback ─────────────────────────────────
  async rollbackBatch(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const id = parseInt(String(req.params['id']), 10);
      const body = rollbackBodySchema.parse(req.body);
      if (body.confirmToken !== `ROLLBACK_BATCH_${id}`) {
        throw new ValidationError('Confirmation token must equal ROLLBACK_BATCH_<id>');
      }
      const result = await rollback({
        batchId: id,
        actorId: req.user!.id,
        reason: body.reason,
        tenantId: req.tenantId ?? ADNOC_TENANT_ID,
      });
      res.status(200).json({ success: true, data: result });
    } catch (err) { next(err); }
  },

  // ─── GET /migration/batches/:id/coverage-report ──────────────────────────
  async getCoverageReport(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const id = parseInt(String(req.params['id']), 10);
      if (!Number.isFinite(id)) throw new ValidationError('Invalid batch id');
      const batchR = await pool().query<{
        files_discovered: number; files_imported: number;
        files_review: number; files_failed: number;
        files_skipped_duplicate: number; status: string;
        started_at: Date; completed_at: Date | null;
        triggered_by_user_id: number | null;
      }>(
        `SELECT files_discovered, files_imported, files_review, files_failed,
                files_skipped_duplicate, status, started_at, completed_at, triggered_by_user_id
           FROM migration_batch WHERE id = $1 AND tenant_id = $2`,
        [id, req.tenantId ?? ADNOC_TENANT_ID],
      );
      if (batchR.rowCount === 0) {
        res.status(404).json({ success: false, error: 'batch_not_found' });
        return;
      }
      const recordsR = await pool().query<{
        source_file_name: string | null; status: string;
        contract_id: number | null; confidence_score_avg: string | null;
      }>(
        `SELECT source_file_name, status, contract_id, confidence_score_avg::text
           FROM migration_record
          WHERE migration_batch_id = $1
          ORDER BY id ASC LIMIT 500`,
        [id],
      );
      res.status(200).json({
        success: true,
        data: {
          batchId: id,
          summary: batchR.rows[0],
          records: recordsR.rows,
          coverageSentence: `${batchR.rows[0].files_discovered} files in source, ${
            batchR.rows[0].files_imported + batchR.rows[0].files_review + batchR.rows[0].files_failed
          } attempted, ${batchR.rows[0].files_skipped_duplicate} skipped as already-imported, ${
            batchR.rows[0].files_discovered -
              (batchR.rows[0].files_imported + batchR.rows[0].files_review + batchR.rows[0].files_failed + batchR.rows[0].files_skipped_duplicate)
          } missed.`,
        },
      });
    } catch (err) { next(err); }
  },

  // ─── POST /admin/migration/purge-all/preview ─────────────────────────────
  async purgePreview(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await purgeAll({
        actorId: req.user!.id, dryRun: true,
        tenantId: req.tenantId ?? ADNOC_TENANT_ID,
      });
      res.status(200).json({ success: true, data: result });
    } catch (err) { next(err); }
  },

  // ─── POST /admin/migration/purge-all ─────────────────────────────────────
  async purgeExecute(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const body = purgeBodySchema.parse(req.body);
      const today = new Date().toISOString().slice(0, 10);
      if (body.confirmToken !== `PURGE_MIGRATION_${today}`) {
        throw new ValidationError(
          `Confirmation token must equal PURGE_MIGRATION_${today}`,
        );
      }
      const result = await purgeAll({
        actorId: req.user!.id, dryRun: false,
        tenantId: req.tenantId ?? ADNOC_TENANT_ID,
      });
      res.status(200).json({ success: true, data: result });
    } catch (err) { next(err); }
  },
};
