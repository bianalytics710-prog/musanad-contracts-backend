/**
 * Export rate limiter — M1b N4 / AC-S4-09 / AC-S5-10.
 *
 * 30 req/min/user for the heavy export endpoints (PDF + XLSX). These spawn
 * Puppeteer (Chromium ~50-100MB/req) and exceljs streaming workbooks (can
 * run minutes for large filter sets). Sharing budget with the standard
 * authedReadRateLimiter would let an attacker exhaust resources cheaply.
 *
 * Configurable via EXPORT_RATE_LIMIT_PER_MIN env var (default 30). The
 * keying mirrors M0 authedReadLimiter — per-user when authenticated,
 * per-IP otherwise (auth middleware should run before this so req.user is
 * populated; the IP fallback is purely defensive).
 *
 * Implementation: rate-limiter-flexible RateLimiterMemory. Same in-memory
 * scaling caveat as the other limiters — swap to RateLimiterRedis before
 * scaling beyond 1 replica.
 */
import type { NextFunction, Request, Response } from 'express';
import { RateLimiterMemory } from 'rate-limiter-flexible';
import { RateLimitError } from '../utils/errors.util';

const DEFAULT_POINTS = 30;
const DURATION_SECONDS = 60;

const parsePoints = (): number => {
  const raw = process.env.EXPORT_RATE_LIMIT_PER_MIN;
  if (!raw) return DEFAULT_POINTS;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_POINTS;
  return n;
};

const exportLimiter = new RateLimiterMemory({
  points: parsePoints(),
  duration: DURATION_SECONDS,
});

const ipKey = (req: Request): string => req.ip || req.socket.remoteAddress || 'unknown';

const userKey = (req: Request): string => (req.user?.id ? `u:${req.user.id}` : `ip:${ipKey(req)}`);

const isTestEnv = (): boolean => process.env.NODE_ENV === 'test';

export const exportRateLimiter = async (
  req: Request,
  _res: Response,
  next: NextFunction,
): Promise<void> => {
  // Test-mode bypass — same rationale as the M0 limiters: integration suites
  // legitimately exceed quotas; production correctness is unit-tested.
  if (isTestEnv()) {
    next();
    return;
  }
  try {
    await exportLimiter.consume(userKey(req));
    next();
  } catch {
    next(new RateLimitError('Too many requests, please try again later'));
  }
};
