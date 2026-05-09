/**
 * Rate limiting via rate-limiter-flexible (in-memory).
 *
 * Rates per `x-rateLimit` annotations on api-contracts.json operations:
 *   - login:    1000 / 15m per IP  (relaxed 2026-05-09 for demo + E2E testing;
 *                                   prod target is 5 / 15m — see LOGIN_RATE_LIMIT
 *                                   env override below)
 *   - refresh:  10 / 15m per IP
 *   - logout:   10 / 5m  per IP
 *   - auth-read: 60-120 / 1m per authenticated user
 *
 * Per-route override via env vars (defaults baked at module load):
 *   LOGIN_RATE_LIMIT, REFRESH_RATE_LIMIT, LOGOUT_RATE_LIMIT — points
 *   in their respective windows (parseInt; falls back to default if
 *   absent / non-numeric). Set LOGIN_RATE_LIMIT=5 in production.
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

const parseEnvInt = (name: string, fallback: number): number => {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
};
const loginLimiter = buildLimiter({
  points: parseEnvInt('LOGIN_RATE_LIMIT', 1000),
  durationSeconds: 15 * 60,
});
const refreshLimiter = buildLimiter({ points: 10, durationSeconds: 15 * 60 });
const logoutLimiter = buildLimiter({ points: 10, durationSeconds: 5 * 60 });
const authedReadLimiter = buildLimiter({ points: 120, durationSeconds: 60 });
const authedWriteLimiter = buildLimiter({ points: 60, durationSeconds: 60 });
// M3 — public signer namespace (verify_jwt=false). Coarser per-IP limit
// because callers are unauthenticated. The fn-level rate limits (per-session
// 20/h, per-invitation 50/h on signer Q&A) are enforced by the DB.
const publicSignerLimiter = buildLimiter({ points: 60, durationSeconds: 60 });
// R-PA7 — heavy export endpoints (e.g. /admin/audit/export streaming up to
// 50k rows). 5 exports per minute per user is generous enough for power
// users yet prevents accidental DoS via a hot-reload loop or scripted abuse.
const heavyExportLimiter = buildLimiter({ points: 5, durationSeconds: 60 });

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
/**
 * M3 — Public signer namespace rate limiter.
 *
 * Used by /api/v1/sign/* routes (verify_jwt=false). Per-IP because there is
 * no authenticated user. The fn_signer_qa_session_record_message GATE/COMMIT
 * pattern enforces additional, finer-grained limits (per-session 20/h,
 * per-invitation 50/h aggregate) inside the DB.
 */
export const publicSignerRateLimiter = consume(publicSignerLimiter, ipKey);

/**
 * R-PA7 — heavy export endpoints (CSV streaming etc.).
 *
 * Stricter than authedReadRateLimiter (120/min) because each request streams
 * up to 50k rows and pages through the DB ~250 times. 5/min/user is enough
 * for legitimate admin workflows but blocks accidental DoS.
 */
export const heavyExportRateLimiter = consume(heavyExportLimiter, userKey);
