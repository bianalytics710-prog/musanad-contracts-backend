/**
 * Admin audit controller (R-PA5).
 *
 *   GET /api/v1/admin/audit         → fn_audit_log_list (paginated)
 *   GET /api/v1/admin/audit/export  → fn_audit_log_list batched into CSV
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';

interface AuditLogRow {
  id: number;
  tableName: string;
  recordId: number | null;
  action: 'INSERT' | 'UPDATE' | 'DELETE';
  changedBy: number | null;
  changedByName: string | null;
  changedByEmail: string | null;
  changedAt: string;
  contractId: number | null;
  contractNumber: string | null;
  oldValues: unknown;
  newValues: unknown;
}

interface AuditLogListResponse {
  data: AuditLogRow[];
  pagination: { page: number; limit: number; total: number; totalPages: number };
}

interface ListQuery {
  page?: number;
  limit?: number;
  tableName?: string;
  action?: 'INSERT' | 'UPDATE' | 'DELETE';
  changedBy?: number;
  dateFrom?: Date;
  dateTo?: Date;
  contractId?: number;
}

const CSV_PAGE_SIZE = 200;
const CSV_MAX_ROWS = 50_000;

const csvEscape = (cell: unknown): string => {
  if (cell === null || cell === undefined) return '';
  const s =
    typeof cell === 'string'
      ? cell
      : cell instanceof Date
        ? cell.toISOString()
        : typeof cell === 'object'
          ? JSON.stringify(cell)
          : String(cell);
  if (/[",\r\n]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
};

const HEADER = [
  'id',
  'changedAt',
  'tableName',
  'recordId',
  'contractId',
  'contractNumber',
  'action',
  'changedBy',
  'changedByName',
  'changedByEmail',
  'oldValues',
  'newValues',
];

export const adminAuditController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.audit.list', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const q = req.query as unknown as ListQuery;
      const result = await db.callFunction<AuditLogListResponse>(
        'fn_audit_log_list',
        [
          q.page ?? 1,
          q.limit ?? 50,
          q.tableName ?? null,
          q.action ?? null,
          q.changedBy ?? null,
          q.dateFrom ?? null,
          q.dateTo ?? null,
          q.contractId ?? null,
        ],
        { actorId: req.user!.id },
      );

      req.logger.info(
        {
          action: 'admin.audit.list',
          userId: req.user?.id,
          rowCount: result?.data?.length ?? 0,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'admin.audit.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError ? error.code : error instanceof Error ? error.name : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  // R-PA7: BE-02 documented waiver — this method calls db.callFunction() in a
  // loop (up to ~250 calls per export, paged at 200 rows/call). Streaming
  // a single fn_audit_log_export wrapping a cursor would be the canonical
  // single-call shape but PG cursors don't compose cleanly with our
  // db.callFunction adapter. Acceptable here because:
  //   * /admin/audit/export is gated by audit.read (admin-only).
  //   * heavyExportRateLimiter caps to 5 exports/min/user.
  //   * 50k row hard cap bounds total work.
  //   * Errors after headers flushed are caught locally (no next(err) bubble
  //     into the global handler with res.headersSent === true).
  async exportCsv(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'admin.audit.export', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );

    try {
      const q = req.query as unknown as ListQuery;
      res.setHeader('Content-Type', 'text/csv; charset=utf-8');
      res.setHeader(
        'Content-Disposition',
        `attachment; filename="audit-log-${new Date().toISOString().slice(0, 10)}.csv"`,
      );
      res.write('﻿'); // UTF-8 BOM for Excel
      res.write(HEADER.join(',') + '\n');

      let page = 1;
      let written = 0;
      while (written < CSV_MAX_ROWS) {
        const result = await db.callFunction<AuditLogListResponse>(
          'fn_audit_log_list',
          [
            page,
            CSV_PAGE_SIZE,
            q.tableName ?? null,
            q.action ?? null,
            q.changedBy ?? null,
            q.dateFrom ?? null,
            q.dateTo ?? null,
            q.contractId ?? null,
          ],
          { actorId: req.user!.id },
        );
        if (!result?.data?.length) break;
        for (const row of result.data) {
          res.write(
            [
              row.id,
              row.changedAt,
              row.tableName,
              row.recordId,
              row.contractId,
              row.contractNumber,
              row.action,
              row.changedBy,
              row.changedByName,
              row.changedByEmail,
              row.oldValues,
              row.newValues,
            ]
              .map(csvEscape)
              .join(',') + '\n',
          );
          written++;
          if (written >= CSV_MAX_ROWS) break;
        }
        if (page >= result.pagination.totalPages) break;
        page += 1;
      }
      res.end();

      req.logger.info(
        {
          action: 'admin.audit.export',
          userId: req.user?.id,
          rowCount: written,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
    } catch (error) {
      req.logger.error(
        {
          action: 'admin.audit.export',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType:
            error instanceof ApiError ? error.code : error instanceof Error ? error.name : 'UNKNOWN',
          headersSent: res.headersSent,
        },
        'Controller error',
      );
      // R-PA7: once we've started flushing CSV bytes the global error
      // handler can't emit a JSON envelope on top of a partial stream.
      // Append a sentinel row and close cleanly instead of bubbling to
      // next(error) — the FE download will end visibly truncated.
      if (res.headersSent) {
        try {
          res.write('# ERROR: export truncated due to server error\n');
        } catch {
          /* ignore — connection may already be torn down */
        }
        res.end();
        return;
      }
      next(error);
    }
  },
};
