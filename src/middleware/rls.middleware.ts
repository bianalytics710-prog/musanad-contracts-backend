/**
 * RLS context middleware.
 *
 * Production approach (per DB Implementation handoff §3): every fn_ call
 * for an authenticated request runs inside its own transaction with
 * `SET LOCAL app.current_user_id = <jwt.sub>`. That GUC drives every RLS
 * policy in M0 (no `USING(true)` policies anywhere).
 *
 * Because pg pool clients are shared, we deliberately set the GUC on a
 * per-call basis inside `database/client.ts` `callFunction(..., { actorId })`
 * rather than via this middleware. This middleware exists to:
 *
 *   1. Mark the request as RLS-bound (defensive — catches future code that
 *      forgets to pass actorId).
 *   2. Provide a single chokepoint for future expansion (multi-tenant
 *      tenant_id, audit-actor name, etc.).
 *
 * Always use AFTER `authenticate`.
 */
import type { NextFunction, Request, Response } from 'express';

export const rlsMiddleware = (req: Request, _res: Response, next: NextFunction): void => {
  if (req.user?.id !== undefined) {
    req.authUserId = req.user.id;
  }
  next();
};
