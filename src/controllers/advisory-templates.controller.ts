/**
 * M16 / CR-H — Advisory Templates controller.
 *
 * CRUD for advisory_template. One db.callFunction() per method.
 * DD-6: PATCH enforces immutable-field rejection BEFORE fn_ call.
 * ERRCODE mapping: 22023→400, 23505→409, 42501→403, P0002→404, 23514→422.
 */
import type { Request, Response, NextFunction } from 'express';
import { db } from '../database/client';
import { ApiError } from '../utils/errors.util';
import {
  listAdvisoryTemplatesSchema,
  createAdvisoryTemplateSchema,
  updateAdvisoryTemplateSchema,
  IMMUTABLE_TEMPLATE_FIELDS,
} from '../schemas/advisory-templates.schemas';

export const advisoryTemplatesController = {

  list: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_template_list',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const params = listAdvisoryTemplatesSchema.parse(req.query);
      const result = await db.callFunction('fn_advisory_template_list', [
        req.user!.id,
        params.draftType ?? null,
        params.search ?? null,
        params.isActive,
        params.page,
        params.limit,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_template_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_template_list',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  getById: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_template_get_by_id',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_advisory_template_get_by_id', [
        req.user!.id,
        id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'template_not_found', 'Advisory template not found');

      req.logger.info({
        action: 'fn_advisory_template_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_template_get_by_id',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  create: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_template_create',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const data = createAdvisoryTemplateSchema.parse(req.body);
      const result = await db.callFunction('fn_advisory_template_create', [
        req.user!.id,
        data.templateId,
        data.displayNameEn,
        data.displayNameAr,
        data.description ?? null,
        data.draftType,
        data.bodyTemplateEn,
        data.bodyTemplateAr,
        data.parameterSchema ? JSON.stringify(data.parameterSchema) : '{}',
        data.assignedApproverRole,
        data.dispatchChannels ? JSON.stringify(data.dispatchChannels) : '["email","teams_capture","slack_capture"]',
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      req.logger.info({
        action: 'fn_advisory_template_create',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 201,
      });
      res.status(201).json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_template_create',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  update: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_template_update',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      // DD-6: immutable-field pre-check before fn_ call
      const bodyKeys = Object.keys(req.body as Record<string, unknown>);
      const rejectedFields = bodyKeys.filter((k) =>
        (IMMUTABLE_TEMPLATE_FIELDS as ReadonlyArray<string>).includes(k),
      );
      if (rejectedFields.length > 0) {
        throw new ApiError(400, 'immutable_field', `Immutable fields cannot be updated: ${rejectedFields.join(', ')}`);
      }

      const data = updateAdvisoryTemplateSchema.parse(req.body);
      const result = await db.callFunction('fn_advisory_template_update', [
        req.user!.id,
        id,
        data.displayNameEn ?? null,
        data.displayNameAr ?? null,
        data.description ?? null,
        data.bodyTemplateEn ?? null,
        data.bodyTemplateAr ?? null,
        data.parameterSchema ? JSON.stringify(data.parameterSchema) : null,
        data.assignedApproverRole ?? null,
        data.dispatchChannels ? JSON.stringify(data.dispatchChannels) : null,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'template_not_found', 'Advisory template not found');

      req.logger.info({
        action: 'fn_advisory_template_update',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 200,
      });
      res.json(result);
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_template_update',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },

  delete: async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const startTime = Date.now();
    req.logger.info({
      action: 'fn_advisory_template_delete',
      method: req.method,
      path: req.path,
      userId: req.user?.id,
    });

    try {
      const id = parseInt(req.params.id ?? '', 10);
      if (isNaN(id) || id <= 0) throw new ApiError(400, 'invalid_id', 'Invalid ID format');

      const result = await db.callFunction('fn_advisory_template_delete', [
        req.user!.id,
        id,
      ], { actorId: req.user!.id, tenantId: req.tenantId });

      if (!result) throw new ApiError(404, 'template_not_found', 'Advisory template not found');

      req.logger.info({
        action: 'fn_advisory_template_delete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        statusCode: 204,
      });
      res.status(204).end();
    } catch (error) {
      req.logger.error({
        action: 'fn_advisory_template_delete',
        userId: req.user?.id,
        duration: Date.now() - startTime,
        errorType: (error as Error).name,
      });
      next(error);
    }
  },
};
