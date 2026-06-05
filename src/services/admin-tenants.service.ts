/**
 * CR-C — Tenants service (S8).
 *
 * Thin db.callFunction passthroughs for fn_tenant_list / fn_tenant_get_by_id.
 * Permission gate (`tenant.read`) lives inside the fn_ bodies.
 */
import { db } from '../database/client';
import type {
  ListTenantsResponse,
  TenantDetail,
} from '../types/admin-tenants.types';

export const listTenants = (
  actorId: number,
  page: number,
  limit: number,
  search: string | null,
): Promise<ListTenantsResponse> =>
  db.callFunction<ListTenantsResponse>(
    'fn_tenant_list',
    [page, limit, search],
    { actorId },
  );

export const getTenantById = (
  actorId: number,
  id: string,
): Promise<TenantDetail | null> =>
  db.callFunction<TenantDetail | null>(
    'fn_tenant_get_by_id',
    [id],
    { actorId },
  );

// R-IL — Platform Admin tenant creation (mig 573).
export interface CreateTenantInput {
  slug: string;
  displayName: string;
  name: string;
  industryId: number;
  configPack?: string | null;
  riskAppetite?: string | null;
  dataRegion?: string | null;
}

export interface CreateTenantResult {
  id: string;
  slug: string;
  displayName: string;
  name: string;
  industryId: number;
  industryCode: string;
}

export const createTenant = (
  actorId: number,
  input: CreateTenantInput,
): Promise<CreateTenantResult> =>
  db.callFunction<CreateTenantResult>(
    'fn_tenant_create',
    [
      input.slug,
      input.displayName,
      input.name,
      input.industryId,
      input.configPack ?? 'default',
      input.riskAppetite ?? 'standard',
      input.dataRegion ?? null,
    ],
    { actorId },
  );
