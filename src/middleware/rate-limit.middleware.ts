/**
 * Rate limiting via rate-limiter-flexible (in-memory).
 *
 * Rates per `x-rateLimit` annotations on api-contracts.json operations:
 *   - login:    5 / 15m  per IP
 *   - refresh:  10 / 15m per IP
 *   - logout:   10 / 5m  per IP
 *   - auth-read: 60-120 / 1m per authenticated user
 *
 * IP source (CRX-6):
 *   We rely on Express `req.ip`, which honours `app.set('trust proxy', 1)`
 *   set in src/server.ts. This means a single reverse proxy hop is trusted;
 *   X-Forwarded-For from outside that boundary is ignored. Do NOT manually
 *   parse X-Forwarded-For here — trust-proxy already does it correctly and
 *   bypassing it re-introduces the spoofing bypass.
 *
 * Scaling:
 *   RateLimiterMemory is per-process — quota leaks across replicas. Before
 *   scaling beyond 1 replica, swap to RateLimiterRedis (already a transitive
 *   dep of rate-limiter-flexible) keyed by the same per-IP / per-user keys.
 */
import type { NextFunction, Request, Response } from 'express';
import { RateLimiterMemory } from 'rate-limiter-flexible';
import { RateLimitError } from '../utils/errors.util';

interface LimiterCfg {
  points: number;
  durationSeconds: number;
}

const buildLimiter = (cfg: LimiterCfg): RateLimiterMemory =>
  new RateLimiterMemory({
    points: cfg.points,
    duration: cfg.durationSeconds,
  });

const loginLimiter = buildLimiter({ points: 5, durationSeconds: 15 * 60 });
const refreshLimiter = buildLimiter({ points: 10, durationSeconds: 15 * 60 });
const logoutLimiter = buildLimiter({ points: 10, durationSeconds: 5 * 60 });
const authedReadLimiter = buildLimiter({ points: 120, durationSeconds: 60 });
const authedWriteLimiter = buildLimiter({ points: 60, durationSeconds: 60 });

// req.ip honours `app.set('trust proxy', 1)`. We MUST NOT read X-Forwarded-For
// directly: that bypasses the trust-proxy hop count and lets attackers spoof
// the source IP, defeating the per-IP login limit (CRX-6).
const ipKey = (req: Request): string => req.ip || req.socket.remoteAddress || 'unknown';

const userKey = (req: Request): string =>
  req.user?.id ? `u:${req.user.id}` : `ip:${ipKey(req)}`;

/**
 * Test-mode bypass: when NODE_ENV=test the rate limiter is a no-op.
 *
 * Rationale: integration tests legitimately exceed the per-user write
 * quota (60/min) when exercising every M1a story in a single suite. The
 * limiter is a defense for production traffic — its correctness is
 * verified by separate unit tests that target the limiter directly. Test
 * suites should not be written around it.
 */
const isTestEnv = (): boolean => process.env.NODE_ENV === 'test';

const consume =
  (limiter: RateLimiterMemory, keyFn: (req: Request) => string) =>
  async (req: Request, _res: Response, next: NextFunction): Promise<void> => {
    if (isTestEnv()) {
      next();
      return;
    }
    try {
      await limiter.consume(keyFn(req));
      next();
    } catch {
      next(new RateLimitError('Too many requests, please try again later'));
    }
  };

export const loginRateLimiter = consume(loginLimiter, ipKey);
export const refreshRateLimiter = consume(refreshLimiter, ipKey);
export const logoutRateLimiter = consume(logoutLimiter, ipKey);
export const authedReadRateLimiter = consume(authedReadLimiter, userKey);
export const authedWriteRateLimiter = consume(authedWriteLimiter, userKey);
