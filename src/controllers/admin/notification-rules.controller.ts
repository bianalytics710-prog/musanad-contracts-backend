/**
 * Notification Rules controller — Platform Admin trigger-rule registry.
 *
 * Thin pass-through over fn_notification_rule_* + fn_notification_event_type_list
 * (mig 580). Drives /app/admin/notification-rules.
 *
 *   GET    /api/v1/admin/notification-rules
 *   POST   /api/v1/admin/notification-rules
 *   GET    /api/v1/admin/notification-rules/event-types
 *   PATCH  /api/v1/admin/notification-rules/:id/enabled
 *   PUT    /api/v1/admin/notification-rules/:id
 *   DELETE /api/v1/admin/notification-rules/:id
 *
 * Route ordering: '/event-types' + '/:id/enabled' must come BEFORE the bare
 * '/:id' PUT/DELETE so Express does not capture 'event-types' or
 * 'enabled' as the id parameter.
 *
 * Permission: platform.notifications.manage (route-layer + fn body).
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../../database/client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

interface UpsertInput {
  eventType: string;
  templateId: string;
  channel: string;
  isEnabled: boolean;
  audience: Record<string, unknown>;
  condition: Record<string, unknown> | null;
  priority: string;
  cooldownMinutes: number;
  description: string | null;
}

function readUpsert(req: Request): UpsertInput {
  const b = req.body as Record<string, unknown>;
  return {
    eventType: String(b.eventType ?? ''),
    templateId: String(b.templateId ?? ''),
    channel: String(b.channel ?? ''),
    isEnabled: typeof b.isEnabled === 'boolean' ? b.isEnabled : true,
    audience: (b.audience && typeof b.audience === 'object'
      ? (b.audience as Record<string, unknown>)
      : {}),
    condition:
      b.condition && typeof b.condition === 'object'
        ? (b.condition as Record<string, unknown>)
        : null,
    priority: typeof b.priority === 'string' ? b.priority : 'medium',
    cooldownMinutes:
      typeof b.cooldownMinutes === 'number' ? b.cooldownMinutes : 0,
    description: typeof b.description === 'string' ? b.description : null,
  };
}

const ctx = (req: Request) => ({
  actorId: req.user!.id,
  tenantId: req.tenantId ?? ADNOC_TENANT_ID,
});

const errorType = (e: unknown): string =>
  e instanceof Error ? e.name : 'UNKNOWN';

interface UpsertV2Input {
  module: string;
  name: string;
  description: string | null;
  eventType: string;
  isEnabled: boolean;
  priority: string;
  condition: Record<string, unknown> | null;
  cooldownMinutes: number;
  dedupeKey: string | null;
  ordering: number;
  channels: Array<{
    channel: string;
    templateSlug: string;
    subjectOverride: string | null;
    bodyOverride: string | null;
  }>;
  recipients: Array<{
    recipientType: string;
    recipientValue: string;
  }>;
}

function readUpsertV2(req: Request): UpsertV2Input {
  const b = req.body as Record<string, unknown>;
  return {
    module: String(b.module ?? ''),
    name: String(b.name ?? ''),
    description: typeof b.description === 'string' ? b.description : null,
    eventType: String(b.eventType ?? ''),
    isEnabled: b.isEnabled !== false,
    priority: typeof b.priority === 'string' ? b.priority : 'medium',
    condition:
      b.condition && typeof b.condition === 'object' && !Array.isArray(b.condition)
        ? (b.condition as Record<string, unknown>)
        : null,
    cooldownMinutes:
      typeof b.cooldownMinutes === 'number' ? b.cooldownMinutes : 0,
    dedupeKey: typeof b.dedupeKey === 'string' ? b.dedupeKey : null,
    ordering: typeof b.ordering === 'number' ? b.ordering : 100,
    channels: Array.isArray(b.channels)
      ? (b.channels as Array<Record<string, unknown>>).map((c) => ({
          channel: String(c.channel ?? ''),
          templateSlug: String(c.templateSlug ?? ''),
          subjectOverride:
            typeof c.subjectOverride === 'string' ? c.subjectOverride : null,
          bodyOverride: typeof c.bodyOverride === 'string' ? c.bodyOverride : null,
        }))
      : [],
    recipients: Array.isArray(b.recipients)
      ? (b.recipients as Array<Record<string, unknown>>).map((r) => ({
          recipientType: String(r.recipientType ?? ''),
          recipientValue: String(r.recipientValue ?? ''),
        }))
      : [],
  };
}

export const notificationRulesController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const eventType =
        typeof req.query.eventType === 'string' ? req.query.eventType : null;
      const channel =
        typeof req.query.channel === 'string' ? req.query.channel : null;
      const search =
        typeof req.query.search === 'string' ? req.query.search : null;
      const result = await db.callFunction(
        'fn_notification_rule_list',
        [eventType, channel, search],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.list',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.list', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async eventTypes(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const result = await db.callFunction(
        'fn_notification_event_type_list',
        [],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.eventTypes',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.eventTypes', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  async setEnabled(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const id = Number(req.params.id);
      const b = req.body as Record<string, unknown>;
      const isEnabled = b.isEnabled === true;
      const result = await db.callFunction(
        'fn_notification_rule_set_enabled',
        [req.user!.id, id, isEnabled],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.setEnabled',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
          isEnabled,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.setEnabled', errorType: errorType(e) },
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
        'fn_notification_rule_upsert',
        [
          req.user!.id,
          null,
          input.eventType,
          input.templateId,
          input.channel,
          input.isEnabled,
          input.audience,
          input.condition,
          input.priority,
          input.cooldownMinutes,
          input.description,
        ],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.create',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.create', errorType: errorType(e) },
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
        'fn_notification_rule_upsert',
        [
          req.user!.id,
          id,
          input.eventType,
          input.templateId,
          input.channel,
          input.isEnabled,
          input.audience,
          input.condition,
          input.priority,
          input.cooldownMinutes,
          input.description,
        ],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.update',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.update', errorType: errorType(e) },
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
        'fn_notification_rule_deactivate',
        [req.user!.id, id],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.deactivate',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.deactivate', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },

  // ─── v2 endpoints ──────────────────────────────────────────────────────

  async modules(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await db.callFunction(
        'fn_notification_module_list',
        [],
        ctx(req),
      );
      res.status(200).json(result);
    } catch (e) {
      next(e);
    }
  },

  async contextResolvers(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const result = await db.callFunction(
        'fn_notification_context_resolver_list',
        [],
        ctx(req),
      );
      res.status(200).json(result);
    } catch (e) {
      next(e);
    }
  },

  async getDetail(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const id = Number(req.params.id);
      const result = await db.callFunction(
        'fn_notification_rule_get_detail',
        [id],
        ctx(req),
      );
      res.status(200).json(result);
    } catch (e) {
      next(e);
    }
  },

  async upsertV2(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    try {
      const isUpdate = req.params.id !== undefined;
      const id = isUpdate ? Number(req.params.id) : null;
      const input = readUpsertV2(req);
      const result = await db.callFunction(
        'fn_notification_rule_upsert_v2',
        [
          req.user!.id,
          id,
          ctx(req).tenantId,  // tenant_id; pass own tenant by default (fn caller can pass NULL for system default if extended later)
          input.module,
          input.name,
          input.description,
          input.eventType,
          input.isEnabled,
          input.priority,
          input.condition,
          input.cooldownMinutes,
          input.dedupeKey,
          input.ordering,
          input.channels,
          input.recipients,
        ],
        ctx(req),
      );
      req.logger.info(
        {
          action: 'admin.notificationRules.upsertV2',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: isUpdate ? 200 : 201,
        },
        'Controller exit',
      );
      res.status(isUpdate ? 200 : 201).json(result);
    } catch (e) {
      req.logger.error(
        { action: 'admin.notificationRules.upsertV2', errorType: errorType(e) },
        'Controller error',
      );
      next(e);
    }
  },
};
