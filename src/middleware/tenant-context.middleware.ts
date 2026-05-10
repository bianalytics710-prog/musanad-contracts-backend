/**
 * tenant-context.middleware — re-export shim of `rls.middleware.ts`.
 *
 * Per OPEN-DECISION-J (CR-C M10): the existing rls.middleware.ts already
 * resolves the tenant context (JWT `tenantId` claim → ADNOC fallback) and
 * exposes `req.tenantId` consumed by every controller via
 * `db.callFunction({ tenantId })`. There is no functional gap; this shim
 * exists for naming clarity so admin-cockpit routes can import a
 * tenant-named middleware without re-introducing the rls implementation
 * detail at the call site.
 *
 * If the tenant-resolution policy ever diverges from the RLS-context one
 * (e.g. multi-tenant pilot with explicit tenant routing), the shim becomes
 * the surgery point — replace this file's body with a dedicated middleware
 * and call sites stay untouched.
 */
export { rlsMiddleware as tenantContextMiddleware, ADNOC_TENANT_ID } from './rls.middleware';
