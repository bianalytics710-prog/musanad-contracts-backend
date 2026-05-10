/**
 * CR-C — Branding service (S11).
 *
 * Uploads logo / favicon to Supabase Storage at
 *   `branding/<tenantId>/<sha256-prefix>-<filename>`
 * (Q4 — supabase storage decision; see project-artifacts/decisions/M10.json).
 *
 * Persists the resulting URI as branding.logo_uri or branding.favicon_uri
 * via fn_system_setting_set. Returns both the supabase://-prefixed ref AND
 * a short-lived signed URL for FE preview.
 *
 * File-type / size validation is enforced in the controller (PNG / SVG only,
 * <= 2 MB; AC-S11-05). The bucket name is shared with contract-attachments
 * via a `branding/` path prefix to avoid bucket sprawl.
 */
import { createHash } from 'node:crypto';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { InternalError } from '../utils/errors.util';
import {
  signDownloadUrl,
  uploadAttachment,
} from './supabase-storage.service';
import type {
  BrandingAssetKind,
  BrandingUploadResult,
} from '../types/admin-branding.types';

const sanitizeFilename = (raw: string): string =>
  raw
    .replace(/[ -]/g, '')
    .replace(/[\\/]/g, '_')
    .slice(0, 200);

/**
 * Build the storage path:
 *   branding/<tenantId>/<sha256-prefix>-<sanitised-filename>
 * The sha256 prefix is the first 12 hex chars of SHA-256(buffer) — collision
 * probability is negligible for the volume of branding assets.
 */
const buildStoragePath = (
  tenantId: string,
  filename: string,
  buffer: Buffer,
): string => {
  const hash = createHash('sha256').update(buffer).digest('hex').slice(0, 12);
  const safe = sanitizeFilename(filename);
  return `branding/${tenantId}/${hash}-${safe}`;
};

const KIND_TO_KEY: Record<BrandingAssetKind, string> = {
  logo: 'branding.logo_uri',
  favicon: 'branding.favicon_uri',
};

export const uploadBrandingAsset = async (args: {
  actorId: number;
  tenantId: string;
  kind: BrandingAssetKind;
  filename: string;
  mimeType: string;
  buffer: Buffer;
}): Promise<BrandingUploadResult> => {
  const storagePath = buildStoragePath(
    args.tenantId,
    args.filename,
    args.buffer,
  );

  // Upload to the contract-attachments bucket under a branding/ prefix. The
  // bucket is private; signed URLs grant time-bounded read.
  await uploadAttachment({
    storagePath,
    buffer: args.buffer,
    mimeType: args.mimeType,
  });

  const supabaseUri = `supabase://contract-attachments/${storagePath}`;

  // Persist the URI to system_setting so FE picks it up on next render.
  const settingKey = KIND_TO_KEY[args.kind];
  try {
    await db.callFunction<unknown>(
      'fn_system_setting_set',
      [settingKey, JSON.stringify(supabaseUri), args.actorId],
      { actorId: args.actorId },
    );
  } catch (err) {
    logger.error(
      {
        action: 'admin.branding.persistUri.failed',
        actorId: args.actorId,
        kind: args.kind,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to persist branding URI to system_setting',
    );
    throw err instanceof Error
      ? err
      : new InternalError('Failed to persist branding URI');
  }

  // Generate a signed URL for immediate FE preview. 1-hour TTL — long enough
  // for the admin to validate the image renders, short enough to bound the
  // surface if the URL leaks into a screenshot.
  let signedUrl: string | undefined;
  try {
    signedUrl = await signDownloadUrl({
      storagePath,
      filename: sanitizeFilename(args.filename),
      ttlSeconds: 3600,
    });
  } catch (err) {
    // Non-fatal — the upload + persist succeeded; FE can re-fetch via a
    // download URL endpoint later. Log + continue.
    logger.warn(
      {
        action: 'admin.branding.signUrl.failed',
        actorId: args.actorId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Failed to generate signed URL for branding preview',
    );
  }

  return signedUrl !== undefined
    ? { kind: args.kind, uri: supabaseUri, signedUrl }
    : { kind: args.kind, uri: supabaseUri };
};
