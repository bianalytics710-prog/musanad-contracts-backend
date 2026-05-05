/**
 * /api/v1/admin/health — M6 S12 admin observability probe.
 *
 * Distinct from M0's public liveness endpoint at /api/health (no version
 * prefix; no auth). This NEW endpoint is admin-scoped and requires JWT +
 * platform_admin / Super Admin role.
 *
 *   GET /api/v1/admin/health → fn_health_check (S12)
 *
 * Role gate: platform_admin / Super Admin (fn body raises 42501 → 403).
 * fn_ stays SECURITY INVOKER per ARCH-NEW-3 option (c) — db.latestMigration
 * depends on the schema_migrations_select_admin SELECT policy added in
 * migration 054 (without it, MAX(version) returns NULL on a non-superuser
 * pool connection).
 *
 * No query / body parameters — endpoint takes no input.
 *
 * Rate limit: authedReadRateLimiter (120/min/user) — same as other admin
 * observability endpoints.
 */
import { Router } from 'express';
import { authenticate } from '../../../middleware/auth.middleware';
import { authedReadRateLimiter } from '../../../middleware/rate-limit.middleware';
import { adminHealthController } from '../../../controllers/dashboards.controller';

const router = Router();

router.use(authenticate);

router.get('/', authedReadRateLimiter, adminHealthController.health);

export default router;
