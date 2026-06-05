/**
 * Admin Sidebar Order routes — mig 539.
 *
 *   GET /api/v1/admin/sidebar-order   — read the per-role override map
 *   PUT /api/v1/admin/sidebar-order   — replace the map
 *
 * Both endpoints gated by admin.sidebar.manage. The auth payload also
 * embeds the current override map via /auth/me so the sidebar can render
 * without a separate fetch — see auth.controller integration.
 */
import { Router } from 'express';
import { sidebarOrderController } from '../../../controllers/sidebar-order.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';

const router = Router();

// GET is open to any authenticated user — the sidebar of every role needs to
// read the override map to render correctly. Data is non-sensitive (just
// module ordering preferences). PUT remains admin-only below.
router.get(
  '/',
  authenticate,
  sidebarOrderController.get,
);

router.put(
  '/',
  authenticate,
  authorise(['admin.sidebar.manage']),
  authedWriteRateLimiter,
  sidebarOrderController.set,
);

export default router;
