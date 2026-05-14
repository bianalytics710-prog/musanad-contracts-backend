/**
 * CR-J — Demo Time-Freeze Middleware.
 *
 * Per-request: reads X-Demo-Time-Now header OR session-stored GUC value and
 * sets app.demo.time_now via SET LOCAL on the DB client.
 *
 * Mounted globally for /api/v1/admin/demo/* routes only (not all routes —
 * time-freeze must not bleed into non-demo paths).
 *
 * The GUC app.demo.time_now is consumed by fn_demo_now() which is called by
 * any fn_ that needs demo-time-aware logic. Legacy fn_'s that call now()
 * directly are tracked under DEBT-CRIJ-1.
 *
 * X-Demo-Time-Now header value: ISO 8601 datetime string.
 * If header is missing or unparseable, no GUC is set (fn_demo_now falls back
 * to real now() per its COALESCE logic).
 */
import type { NextFunction, Request, Response } from 'express';
import { logger } from '../utils/logger.util';

/** Header name clients may send to drive time-freeze in the request context */
const DEMO_TIME_HEADER = 'x-demo-time-now';

/**
 * demoTimeFreezeMiddleware — attach to /api/v1/admin/demo/* router.
 *
 * Reads X-Demo-Time-Now header. If present and parseable as a TIMESTAMPTZ,
 * attaches the parsed ISO string to req for controller use (controllers
 * pass it to db.callFunction via options if needed). The fn_demo_time_freeze_set
 * DB-side path handles the persistent GUC — this middleware handles
 * per-request transient override from the header.
 */
export const demoTimeFreezeMiddleware = (
  req: Request,
  _res: Response,
  next: NextFunction,
): void => {
  const headerValue = req.headers[DEMO_TIME_HEADER];
  if (typeof headerValue === 'string' && headerValue.length > 0) {
    const parsed = new Date(headerValue);
    if (!isNaN(parsed.getTime())) {
      // Attach to req for downstream controller usage
      (req as Request & { demoTimeNow?: string }).demoTimeNow = parsed.toISOString();
      logger.debug(
        { path: req.path, demoTimeNow: parsed.toISOString() },
        'Demo time-freeze header applied',
      );
    }
  }
  next();
};
