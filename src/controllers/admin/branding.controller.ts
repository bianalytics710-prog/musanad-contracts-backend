/**
 * CR-C — Admin Branding Controller (S11).
 *
 *   GET   /api/v1/admin/branding         → composed branding.* SmtpConfig-style projection
 *   PATCH /api/v1/admin/branding         → patches branding.* keys (color, footer, etc.)
 *   POST  /api/v1/admin/branding/upload  → multer single-file upload, persists URI
 *
 * Permission: branding.manage. Tenant-scoped via req.tenantId for the upload
 * path.
 *
 * File-type / size enforcement (AC-S11-05): PNG / SVG only, <= 2MB. We
 * validate at the controller level rather than via multer fileFilter so
 * the error envelope matches { field: 'logo'|'favicon', message:
 * 'invalid_file_type_or_size' } per the contract.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import {
  ApiError,
  ValidationError,
} from '../../utils/errors.util';
import * as svc from '../../services/admin-branding.service';
import type {
  BrandingPatchBodyInferred,
  BrandingUploadFormInferred,
} from '../../schemas/admin-branding.schemas';
import type { BrandingAssetKind } from '../../types/admin-branding.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const MAX_BRANDING_BYTES = 2 * 1024 * 1024; // 2MB cap per AC-S11-05
const ALLOWED_MIMES = new Set(['image/png', 'image/svg+xml']);

interface SystemSettingRow {
  key: string;
  value: unknown;
  description: string | null;
  category: string;
  isSecret: boolean;
  updatedAt: string;
}
interface SystemSettingListResponse {
  settings: SystemSettingRow[];
}

const BRANDING_KEYS = {
  logoUri: 'branding.logo_uri',
  faviconUri: 'branding.favicon_uri',
  colorPrimary: 'branding.color_primary',
  colorAccent: 'branding.color_accent',
  footerEn: 'branding.footer_en',
  footerAr: 'branding.footer_ar',
} as const;

const PATCH_FIELD_TO_KEY: Record<keyof BrandingPatchBodyInferred, string> = {
  colorPrimary: BRANDING_KEYS.colorPrimary,
  colorAccent: BRANDING_KEYS.colorAccent,
  footerEn: BRANDING_KEYS.footerEn,
  footerAr: BRANDING_KEYS.footerAr,
  logoUri: BRANDING_KEYS.logoUri,
  faviconUri: BRANDING_KEYS.faviconUri,
};

export const adminBrandingController = {
  /**
   * Composed read of branding.* settings. Returns the values directly (not
   * the full system_setting envelope) for FE convenience — matches the
   * shape FE BrandingTab expects.
   */
  async get(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.branding.get',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await db.callFunction<SystemSettingListResponse>(
        'fn_system_setting_list',
        ['branding'],
        { actorId: req.user!.id },
      );
      const byKey = new Map<string, unknown>();
      for (const r of result?.settings ?? []) {
        byKey.set(r.key, r.value);
      }
      const composed = {
        logoUri: byKey.get(BRANDING_KEYS.logoUri) ?? null,
        faviconUri: byKey.get(BRANDING_KEYS.faviconUri) ?? null,
        colorPrimary: byKey.get(BRANDING_KEYS.colorPrimary) ?? null,
        colorAccent: byKey.get(BRANDING_KEYS.colorAccent) ?? null,
        footerEn: byKey.get(BRANDING_KEYS.footerEn) ?? null,
        footerAr: byKey.get(BRANDING_KEYS.footerAr) ?? null,
      };
      req.logger.info(
        {
          action: 'admin.branding.get',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(composed);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.branding.get',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async patch(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.branding.patch',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as BrandingPatchBodyInferred;
      const keys = Object.keys(body) as Array<keyof BrandingPatchBodyInferred>;
      for (const k of keys) {
        if (body[k] === undefined) continue;
        const settingKey = PATCH_FIELD_TO_KEY[k];
        await db.callFunction<unknown>(
          'fn_system_setting_set',
          [settingKey, JSON.stringify(body[k]), req.user!.id],
          { actorId: req.user!.id },
        );
      }
      req.logger.info(
        {
          action: 'admin.branding.patch',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          fieldCount: keys.length,
        },
        'Controller exit',
      );
      res.status(200).json({ success: true, fieldsUpdated: keys.length });
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.branding.patch',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  async upload(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.branding.upload',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const body = req.body as BrandingUploadFormInferred;
      const kind = body.kind as BrandingAssetKind;
      const file = (req as Request & { file?: Express.Multer.File }).file;

      if (!file) {
        throw new ValidationError('file required', {
          [kind]: 'invalid_file_type_or_size',
        });
      }
      if (!ALLOWED_MIMES.has(file.mimetype)) {
        throw new ValidationError('invalid file type', {
          [kind]: 'invalid_file_type_or_size',
        });
      }
      if (file.size > MAX_BRANDING_BYTES) {
        throw new ValidationError('file exceeds 2MB cap', {
          [kind]: 'invalid_file_type_or_size',
        });
      }
      if (!req.tenantId) {
        // Should never happen — tenant-context middleware always sets a value.
        throw new ValidationError('tenant context required', {
          _root: 'tenant_context_missing',
        });
      }

      const result = await svc.uploadBrandingAsset({
        actorId: req.user!.id,
        tenantId: req.tenantId,
        kind,
        filename: file.originalname,
        mimeType: file.mimetype,
        buffer: file.buffer,
      });

      req.logger.info(
        {
          action: 'admin.branding.upload',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          kind,
          uri: result.uri,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.branding.upload',
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
