/**
 * CR-C — Branding upload types (S11).
 *
 * Mirrors workspace types.ts §9. BE uploads to Supabase Storage at
 * `branding/<tenant_id>/<filename>` (Q4) and persists the resulting URI as
 * branding.logo_uri / branding.favicon_uri via fn_system_setting_set.
 */
import type { ApiResponse } from './api.types';

export type BrandingAssetKind = 'logo' | 'favicon';

export const BRANDING_ASSET_KINDS: ReadonlyArray<BrandingAssetKind> = [
  'logo',
  'favicon',
] as const;

export interface BrandingUploadResult {
  kind: BrandingAssetKind;
  /** supabase://branding/<tenant_id>/<filename> reference. */
  uri: string;
  /** Optional pre-signed URL for immediate FE preview. */
  signedUrl?: string;
}

export type BrandingUploadApiResponse = ApiResponse<BrandingUploadResult>;
