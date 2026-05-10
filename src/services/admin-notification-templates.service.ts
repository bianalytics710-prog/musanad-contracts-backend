/**
 * CR-C — Notification Templates service (S12, S13).
 *
 * Thin db.callFunction passthroughs. Tenant-scoped — every call forwards
 * `req.tenantId` so the fn body's app.current_tenant_id GUC is set.
 */
import { db } from '../database/client';
import type {
  ListNotificationTemplatesResponse,
  NotificationTemplate,
  NotificationTemplateChannel,
  NotificationTemplateRenderResult,
  NotificationTemplateUpdateDto,
  RenderLocale,
} from '../types/admin-notification-templates.types';

export const listNotificationTemplates = (
  actorId: number,
  tenantId: string | undefined,
  page: number,
  limit: number,
  channel: string | null,
  search: string | null,
): Promise<ListNotificationTemplatesResponse> =>
  db.callFunction<ListNotificationTemplatesResponse>(
    'fn_notification_template_list',
    [page, limit, channel, search],
    { actorId, tenantId },
  );

export const getNotificationTemplateById = (
  actorId: number,
  tenantId: string | undefined,
  id: number,
): Promise<NotificationTemplate | null> =>
  db.callFunction<NotificationTemplate | null>(
    'fn_notification_template_get_by_id',
    [id],
    { actorId, tenantId },
  );

export const updateNotificationTemplate = (
  actorId: number,
  tenantId: string | undefined,
  id: number,
  dto: NotificationTemplateUpdateDto,
): Promise<NotificationTemplate> =>
  db.callFunction<NotificationTemplate>(
    'fn_notification_template_update',
    [
      id,
      dto.subjectEn ?? null,
      dto.subjectAr ?? null,
      dto.bodyEn ?? null,
      dto.bodyAr ?? null,
      dto.parameterSchema ?? null,
    ],
    { actorId, tenantId },
  );

export const renderNotificationTemplate = (
  actorId: number,
  tenantId: string | undefined,
  templateId: string,
  channel: NotificationTemplateChannel,
  locale: RenderLocale,
  parameters: Record<string, string | number | boolean>,
): Promise<NotificationTemplateRenderResult> =>
  db.callFunction<NotificationTemplateRenderResult>(
    'fn_notification_template_render',
    [templateId, channel, locale, parameters],
    { actorId, tenantId },
  );
