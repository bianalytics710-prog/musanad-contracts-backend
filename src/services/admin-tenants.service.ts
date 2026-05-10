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
