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
};
