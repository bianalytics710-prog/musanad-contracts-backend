/**
 * M20 / CR-L — Report Templates + Runs controller.
 *
 * User-mode endpoints:
 *   GET    /api/v1/reports/templates                       (report.read)
 *   POST   /api/v1/reports/templates/:id/run               (report.read)
 *   GET    /api/v1/reports/runs/:id                        (report.read)
 *
 * Admin-mode endpoints:
 *   GET    /api/v1/admin/reports/templates                 (report.template.manage)
 *   GET    /api/v1/admin/reports/templates/:id             (report.template.manage)
 *   POST   /api/v1/admin/reports/templates                 (report.template.manage)
 *   PUT    /api/v1/admin/reports/templates/:id             (report.template.manage)
 *   DELETE /api/v1/admin/reports/templates/:id             (report.template.manage)
 *
 * Worker-only (DEFINER fns; internal routes guarded by middleware):
 *   GET    /api/v1/admin/reports/runs/pending              (worker pickup)
 *   POST   /api/v1/admin/reports/runs/:id/complete         (worker terminal hand-off)
 *   GET    /api/v1/admin/reports/data/<slug>               (worker raw-data fetch)
 *
 * fn signatures (per db-design.md §2 + §3 + DB Impl handover):
 *   fn_report_template_list(p_actor_id, p_admin_mode) -> JSONB
 *   fn_report_template_get_by_id(p_actor_id, p_id) -> JSONB
 *   fn_report_template_create(p_actor_id, p_template_id, p_display_name_en,
 *       p_display_name_ar, p_description, p_report_kind, p_data_source,
 *       p_parameter_schema, p_assigned_roles, p_is_scheduled,
 *       p_schedule_cron, p_schedule_recipients) -> JSONB
 *   fn_report_template_update — partial (NULL = no-change)
 *   fn_report_template_delete(p_actor_id, p_id) -> JSONB
 *   fn_report_run_trigger(p_actor_id, p_template_id, p_parameters, p_format,
 *       p_triggered_by) -> JSONB
 *   fn_report_run_complete(p_run_id, p_status, p_output_uri,
 *       p_output_size_bytes, p_error_message) -> JSONB
 *   fn_report_run_get_by_id(p_actor_id, p_run_id) -> JSONB
 *   fn_report_run_pending_get(p_limit) -> JSONB
 *   fn_report_data_<slug>(p_actor_id, p_parameters) -> JSONB
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  listReportTemplatesSchema,
  createReportTemplateSchema,
  updateReportTemplateSchema,
  IMMUTABLE_REPORT_TEMPLATE_FIELDS,
  triggerReportRunSchema,
  completeReportRunSchema,
  reportRunPendingQuerySchema,
  reportDataRequestSchema,
} from '../schemas/report.schemas';
import { signDownloadUrl } from '../services/supabase-storage.service';

// All 24 valid data-fn slugs, mirrored from types.ts ReportDataSourceSlug.
// Used as a path param allow-list for the worker-only data-fn endpoint.
const REPORT_DATA_SLUGS = new Set([
  'executive_weekly_brief',
  'executive_monthly_board',
  'executive_avar_trend',
  'executive_top10_exposures',
  'legal_advisory_queue',
  'legal_clause_review_backlog',
  'legal_fm_eligibility',
  'legal_regulatory_digest',
  'procurement_supplier_scorecard',
  'procurement_supplier_scorecard_detail',
  'procurement_icv_compliance',
  'procurement_sla_breach',
  'operations_risk_board_snapshot',
  'operations_delivery_delay',
  'operations_penalty_exposure',
  'finance_fx_exposure',
  'finance_price_review_queue',
  'finance_payment_delay',
  'compliance_sanctions_exposure',
  'compliance_subcontractor_chain',
  'compliance_audit_rights',
  'admin_system_health',
  'admin_audit_chain_verification',
  'admin_source_health_snapshot',
]);

interface ReportRunDetailResult {
  runId?: number;
  status?: string;
  format?: string;
  startedAt?: string | null;
  completedAt?: string | null;
  outputSizeBytes?: number | null;
  errorMessage?: string | null;
  outputUri?: string | null;
  [k: string]: unknown;
}

export const reportController = {
  // ============================================================
  // GET /api/v1/reports/templates
  // GET /api/v1/admin/reports/templates  (adminMode forced true)
  // ============================================================
  listTemplates: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_template_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = listReportTemplatesSchema.parse(req.query);
      const adminMode = params.adminMode === true;

      // Defense in depth — admin-mode also requires report.template.manage.
      if (adminMode && !req.user!.permissions.includes('report.template.manage')) {
        throw new ApiError(
          403,
          'FORBIDDEN',
          'report.template.manage required for admin mode',
        );
      }

      const result = await db.callFunction(
        'fn_report_template_list',
        [req.user!.id, adminMode],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_report_template_list',
        userId: req.user?.id,
        adminMode,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_template_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // Forced-admin variant — used by /api/v1/admin/reports/templates.
  listTemplatesAdmin: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_template_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const result = await db.callFunction(
        'fn_report_template_list',
        [req.user!.id, true],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_report_template_list',
        userId: req.user?.id,
        adminMode: true,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_template_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/admin/reports/templates/:id
  // ============================================================
  getTemplateById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_template_get_by_id',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction(
        'fn_report_template_get_by_id',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'template_not_found', 'Report template not found');

      req.logger.info({
        action: 'fn_report_template_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_template_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/admin/reports/templates
  // ============================================================
  createTemplate: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_template_create',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = createReportTemplateSchema.parse(req.body);
      // fn_report_template_create signature (migration 263):
      //   (p_actor_id, p_template_id, p_display_name_en, p_report_kind,
      //    p_data_source, p_assigned_roles, p_display_name_ar, p_description,
      //    p_parameter_schema, p_is_scheduled, p_schedule_cron, p_schedule_recipients)
      // DEFECT-CRKL-INT-3 fix (2026-05-15): positions 4..9 previously misaligned —
      // reportKind ('excel') was bound to p_assigned_roles (JSONB) → type error
      // and 400 on every call. Keep this comment + named tags inline.
      const result = await db.callFunction(
        'fn_report_template_create',
        [
          req.user!.id,                                                              // p_actor_id
          data.templateId,                                                           // p_template_id
          data.displayNameEn,                                                        // p_display_name_en
          data.reportKind,                                                           // p_report_kind
          data.dataSource,                                                           // p_data_source
          JSON.stringify(data.assignedRoles),                                        // p_assigned_roles
          data.displayNameAr ?? null,                                                // p_display_name_ar
          data.description ?? null,                                                  // p_description
          data.parameterSchema ? JSON.stringify(data.parameterSchema) : '{}',        // p_parameter_schema
          data.isScheduled ?? false,                                                 // p_is_scheduled
          data.scheduleCron ?? null,                                                 // p_schedule_cron
          data.scheduleRecipients ? JSON.stringify(data.scheduleRecipients) : null,  // p_schedule_recipients
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_report_template_create',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_template_create',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // PUT /api/v1/admin/reports/templates/:id
  // ============================================================
  updateTemplate: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_template_update',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      // Immutable-field rejection BEFORE fn_ call.
      const bodyKeys = Object.keys((req.body ?? {}) as Record<string, unknown>);
      const rejectedFields = bodyKeys.filter((k) =>
        (IMMUTABLE_REPORT_TEMPLATE_FIELDS as ReadonlyArray<string>).includes(k),
      );
      if (rejectedFields.length > 0) {
        throw new ApiError(
          400,
          'immutable_field',
          `Immutable fields cannot be updated: ${rejectedFields.join(', ')}`,
        );
      }

      const data = updateReportTemplateSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_report_template_update',
        [
          req.user!.id,
          id,
          data.displayNameEn ?? null,
          data.displayNameAr ?? null,
          data.description ?? null,
          data.dataSource ?? null,
          data.parameterSchema ? JSON.stringify(data.parameterSchema) : null,
          data.assignedRoles ? JSON.stringify(data.assignedRoles) : null,
          data.isScheduled ?? null,
          data.scheduleCron ?? null,
          data.scheduleRecipients ? JSON.stringify(data.scheduleRecipients) : null,
          data.enabled ?? null,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'template_not_found', 'Report template not found');

      req.logger.info({
        action: 'fn_report_template_update',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_template_update',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // DELETE /api/v1/admin/reports/templates/:id (soft delete)
  // ============================================================
  deleteTemplate: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_template_delete',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction(
        'fn_report_template_delete',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'template_not_found', 'Report template not found');

      req.logger.info({
        action: 'fn_report_template_delete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_template_delete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/reports/templates/:id/run — manual trigger
  // ============================================================
  triggerRun: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_run_trigger',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = triggerReportRunSchema.parse(req.body);

      // Per api-contracts §validationNote: force triggeredBy='manual' for
      // user-facing endpoint. The scheduler service account uses a separate
      // internal path (and 'scheduled' is rejected upstream by the fn for
      // non-system actors anyway).
      const triggeredBy = 'manual';

      // fn_report_run_trigger signature (migration 264):
      //   (p_actor_id, p_template_id, p_format, p_parameters, p_triggered_by)
      // DEFECT-CRKL-INT-2 fix (2026-05-15): format and parameters were swapped
      // — the JSONB parameters got bound to p_format TEXT → 400 on every call.
      // Keep this comment + named tags inline.
      const result = await db.callFunction(
        'fn_report_run_trigger',
        [
          req.user!.id,                                              // p_actor_id
          id,                                                        // p_template_id
          data.format,                                               // p_format
          data.parameters ? JSON.stringify(data.parameters) : '{}',  // p_parameters
          triggeredBy,                                               // p_triggered_by
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_report_run_trigger',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 202,
      });
      res.status(202).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_run_trigger',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/reports/runs/:id — poll status / get signed URL
  // ============================================================
  getRunById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_run_get_by_id',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction<ReportRunDetailResult | null>(
        'fn_report_run_get_by_id',
        [req.user!.id, id],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      if (!result) throw new ApiError(404, 'run_not_found', 'Report run not found');

      // Mint a 60s signed URL when complete + outputUri populated. The fn
      // already gated visibility (triggered-by-self OR report.run.read.all).
      let signedUrl: string | null = null;
      let signedUrlExpiresAt: string | null = null;
      const outputUri = typeof result.outputUri === 'string' ? result.outputUri : null;
      if (result.status === 'complete' && outputUri) {
        try {
          const fileName = outputUri.split('/').pop() ?? 'report';
          signedUrl = await signDownloadUrl({
            storagePath: outputUri,
            filename: fileName,
            ttlSeconds: 60,
          });
          signedUrlExpiresAt = new Date(Date.now() + 60_000).toISOString();
        } catch (mintErr) {
          req.logger.warn(
            {
              action: 'fn_report_run_get_by_id.signFailed',
              userId: req.user?.id,
              runId: id,
              errorType: (mintErr as Error).name,
            },
            'Failed to mint signed URL for report run',
          );
        }
      }

      // Never echo outputUri raw — only the signed URL.
      const responsePayload = { ...result };
      delete responsePayload.outputUri;

      req.logger.info({
        action: 'fn_report_run_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json({
        ...responsePayload,
        signedUrl,
        signedUrlExpiresAt,
      });
    } catch (error) {
      req.logger.error({
        action: 'fn_report_run_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/admin/reports/runs/pending (INTERNAL — worker pickup)
  // ============================================================
  pendingRuns: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_run_pending_get',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = reportRunPendingQuerySchema.parse(req.query);
      // DEFINER fn — cross-tenant. Worker authentication enforced at middleware.
      const result = await db.callFunction(
        'fn_report_run_pending_get',
        [params.limit],
        { actorId: req.user!.id },
      );

      req.logger.info({
        action: 'fn_report_run_pending_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_run_pending_get',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // POST /api/v1/admin/reports/runs/:id/complete (INTERNAL — worker terminal)
  // ============================================================
  completeRun: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_report_run_complete',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const data = completeReportRunSchema.parse(req.body);
      const result = await db.callFunction(
        'fn_report_run_complete',
        [
          id,
          data.status,
          data.outputUri ?? null,
          data.outputSizeBytes ?? null,
          data.errorMessage ?? null,
        ],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: 'fn_report_run_complete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_report_run_complete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  // ============================================================
  // GET /api/v1/admin/reports/data/:slug (INTERNAL — worker raw data)
  // Single dispatcher handler for all 24 data fns.
  // ============================================================
  getReportData: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    const slug = req.params.slug ?? '';
    const fnName = `fn_report_data_${slug}`;

    req.logger.info({
      action: fnName,
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      if (!REPORT_DATA_SLUGS.has(slug)) {
        throw new ApiError(404, 'unknown_slug', `Unknown report data slug: ${slug}`);
      }

      const data = reportDataRequestSchema.parse(req.body ?? {});
      const result = await db.callFunction(
        fnName,
        [req.user!.id, data.parameters ? JSON.stringify(data.parameters) : '{}'],
        { actorId: req.user!.id, tenantId: req.tenantId },
      );

      req.logger.info({
        action: fnName,
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: fnName,
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
