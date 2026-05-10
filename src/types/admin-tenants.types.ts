/**
 * CR-C — Tenant types (M7 EXTEND-IN-PLACE per NAMING-CONFLICT-1).
 *
 * Mirrors workspace types.ts §4. Migration 124 extends M7 baseline with
 * `name` (UNIQUE), `industry`, `risk_appetite` (CHECK enum), `data_region`.
 */
import type { ApiResponse, PaginationMeta } from './api.types';

export type TenantRiskAppetite = 'low' | 'standard' | 'high';

export const TENANT_RISK_APPETITES: ReadonlyArray<TenantRiskAppetite> = [
  'low',
  'standard',
  'high',
] as const;

/** fn_tenant_list data row (light projection — no audit cols). */
export interface TenantListItem {
  /** UUID v4 string. ADNOC seed = '00000000-0000-0000-0000-000000000001'. */
  id: string;
  name: string;
  slug: string;
  displayName: string;
  industry: string | null;
  riskAppetite: TenantRiskAppetite;
  dataRegion: string | null;
  configPack: string;
  isActive: boolean;
  createdAt: string;
}

/** fn_tenant_get_by_id JSONB output (full projection). NULL on miss → 404. */
export interface TenantDetail extends TenantListItem {
  updatedAt: string;
  createdBy: number | null;
  updatedBy: number | null;
}

/** fn_tenant_list wrapped envelope. */
export interface ListTenantsResponse {
  data: TenantListItem[];
  pagination: PaginationMeta;
}

export type ListTenantsApiResponse = ApiResponse<ListTenantsResponse>;
export type TenantDetailApiResponse = ApiResponse<TenantDetail>;
