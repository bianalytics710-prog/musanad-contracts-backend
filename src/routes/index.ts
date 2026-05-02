/**
 * Top-level router. Mounts:
 *   - /api/v1/*   — versioned API (v1 router)
 *   - /api/health — unversioned liveness probe (M0 spec line 447)
 */
import { Router } from 'express';
import type { Request, Response } from 'express';
import v1Router from './v1';
import { healthCheck } from '../database/client';

const router = Router();

router.use('/v1', v1Router);

// Health endpoint at /api/health (no version prefix per M0 spec line 447).
// Hits the DB to confirm reachability — returns 503 if DB is unreachable.
const startedAt = Date.now();
router.get('/health', async (req: Request, res: Response) => {
  const dbOk = await healthCheck();
  const status = dbOk ? 'ok' : 'unhealthy';
  const code = dbOk ? 200 : 503;

  res.status(code).json({
    status,
    db: dbOk ? 'reachable' : 'unreachable',
    uptime: Math.round((Date.now() - startedAt) / 1000),
    version: process.env.npm_package_version ?? '0.1.0',
    timestamp: new Date().toISOString(),
    requestId: req.requestId,
  });
});

export default router;
