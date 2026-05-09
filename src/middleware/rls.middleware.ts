/**
 * RLS context middleware.
 *
 * Production approach (per DB Implementation handoff §3): every fn_ call
 * for an authenticated request runs inside its own transaction with
 * `SET LOCAL app.current_user_id = <jwt.sub>` and (M7+) `SET LOCAL
 * app.current_tenant_id = <jwt.tenantId | ADNOC_FALLBACK>`. Those GUCs
 * drive every RLS policy in M0..M7 (no `USING(true)` policies anywhere).
 *
 * Because pg pool clients are shared, we deliberately set both GUCs on a
 * per-call basis inside `database/client.ts` `callFunction(..., { actorId,
 * tenantId })` rather than via this middleware. This middleware exists to:
 *
 *   1. Mark the request as RLS-bound (defensive — catches future code that
 *      forgets to pass actorId).
 *   2. Resolve `req.tenantId` from the JWT `tenantId` claim (multi-tenant
 *      pilot) OR fall back to the ADNOC seed UUID per Q-DA4 single-tenant
 *      demo, so every controller has a consistent value to forward to
 *      `db.callFunction({ tenantId })`.
 *
 * Always use AFTER `authenticate`.
 */
import type { NextFunction, Request, Response } from 'express';

/**
 * M7 — Q-DA4 single-tenant demo fallback. ADNOC seed tenant UUID inserted by
 * migration 101. Used until the JWT carries a `tenantId` claim (pilot
 * multi-tenancy work — out of scope for M7).
 */
export const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

interface MaybeTenantedUser {
  tenantId?: string;
}

export const rlsMiddleware = (req: Request, _res: Response, next: NextFunction): void => {
  if (req.user?.id !== undefined) {
    req.authUserId = req.user.id;
  }
  // M7 — resolve tenant context. Future: pull from JWT claim. Today: fallback.
  const userTenant = (req.user as MaybeTenantedUser | undefined)?.tenantId;
  req.tenantId = typeof userTenant === 'string' && userTenant.length > 0
    ? userTenant
    : ADNOC_TENANT_ID;
  next();
};
