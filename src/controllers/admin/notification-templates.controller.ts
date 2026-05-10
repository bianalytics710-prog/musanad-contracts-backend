/**
 * CR-C — Admin Notification Templates Controller (S12, S13).
 *
 *   GET    /api/v1/admin/notification-templates           → fn_notification_template_list
 *   GET    /api/v1/admin/notification-templates/:id       → fn_notification_template_get_by_id
 *   PATCH  /api/v1/admin/notification-templates/:id       → fn_notification_template_update
 *   POST   /api/v1/admin/notification-templates/render    → fn_notification_template_render
 *
 * Permission: notification.template.manage. Tenant-scoped via req.tenantId
 * resolved by tenant-context.middleware (re-export of rls.middleware).
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError, NotFoundError } from '../../utils/errors.util';
import * as svc from '../../services/admin-notification-templates.service';
import type {
  NotificationTemplateListQueryInferred,
  NotificationTemplateRenderBodyInferred,
  NotificationTemplateUpdateBodyInferred,
} from '../../schemas/admin-notification-templates.schemas';
import type {
  NotificationTemplateChannel,
  NotificationTemplateUpdateDto,
  RenderLocale,
} from '../../types/admin-notification-templates.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminNotificationTemplatesController = {
  async list(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.notificationTemplates.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as NotificationTemplateListQueryInferred;
      const result = await svc.listNotificationTemplates(
        req.user!.id,
        req.tenantId,
        q.page ?? 1,
        q.limit ?? 20,
        q.channel ?? null,
        q.search ?? null,
      );
      req.logger.info(
        {
          action: 'admin.notificationTemplates.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          rowCount: result?.data?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.notificationTemplates.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async getById(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.notificationTemplates.getById',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const id = Number(req.params.id);
      const result = await svc.getNotificationTemplateById(
        req.user!.id,
        req.tenantId,
        id,
      );
      if (result === null || result === undefined) {
        throw new NotFoundError('template_not_found', { id: 'template_not_found' });
      }
      req.logger.info(
        {
          action: 'admin.notificationTemplates.getById',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          templateRowId: id,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.notificationTemplates.getById',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async update(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.notificationTemplates.update',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const id = Number(req.params.id);
      const body = req.body as NotificationTemplateUpdateBodyInferred;
      const dto: NotificationTemplateUpdateDto = {};
      if (body.subjectEn !== undefined) dto.subjectEn = body.subjectEn;
      if (body.subjectAr !== undefined) dto.subjectAr = body.subjectAr;
      if (body.bodyEn !== undefined) dto.bodyEn = body.bodyEn;
      if (body.bodyAr !== undefined) dto.bodyAr = body.bodyAr;
      if (body.parameterSchema !== undefined) dto.parameterSchema = body.parameterSchema;
      const result = await svc.updateNotificationTemplate(
        req.user!.id,
        req.tenantId,
        id,
        dto,
      );
      req.logger.info(
        {
          action: 'admin.notificationTemplates.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          templateRowId: id,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.notificationTemplates.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async render(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.notificationTemplates.render',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as NotificationTemplateRenderBodyInferred;
      const result = await svc.renderNotificationTemplate(
        req.user!.id,
        req.tenantId,
        body.templateId,
        body.channel as NotificationTemplateChannel,
        body.locale as RenderLocale,
        body.parameters,
      );
      req.logger.info(
        {
          action: 'admin.notificationTemplates.render',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          missingParametersCount: result?.missingParameters?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.notificationTemplates.render',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },
};
