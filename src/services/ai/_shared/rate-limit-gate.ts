/**
 * AI rate-limit pre-flight gate (S9).
 *
 * Wraps fn_ai_request_log_check_rate_limit. Returns the rate-limit verdict
 * and — if denied — the retryAfterSeconds for the Retry-After header.
 *
 * Per DN-4 of M4 db-design.md: this is a PRE-FLIGHT gate, NOT M3's GATE/COMMIT
 * pattern. Cost of slight over-allow on same-second double-fire is acceptable
 * for M4 endpoints (low contention). Codex memory L-historical TOCTOU note:
 * upgrade if cost telemetry shows abuse.
 */
import { db } from '../../../database/client';
import type { AiRateLimitCheckResult, M4PromptId } from '../../../types/ai.types';

export interface RateLimitVerdict {
  allowed: boolean;
  remainingHour: number;
  remainingDay: number;
  retryAfterSeconds: number;
}

/**
 * Pre-flight check via fn_ai_request_log_check_rate_limit.
 *
 * NOTE: actorUserId is REQUIRED (the fn_ raises 23503 when prompt missing or
 * NULL). Public-endpoint paths (S5 signed-PDF-token) MUST NOT call this gate
 * — they enforce their own per-token rate-limit at the controller.
 *
 * The fn returns `{data: {allowed, ...}}` (M4 envelope convention) so we
 * unwrap `.data` here. Reading the top-level keys directly silently denies
 * every request because `result.allowed` is undefined → Boolean(undefined)
 * is false (this exact bug bricked the AI panel during M_parity Round 2
 * verification).
 */
export const checkRateLimit = async (
  actorUserId: number,
  promptId: M4PromptId | string,
): Promise<RateLimitVerdict> => {
  const raw = await db.callFunction<{ data?: AiRateLimitCheckResult } | AiRateLimitCheckResult | null>(
    'fn_ai_request_log_check_rate_limit',
    [actorUserId, promptId],
    { actorId: actorUserId },
  );
  const result =
    raw && typeof raw === 'object' && 'data' in raw && raw.data
      ? (raw.data as AiRateLimitCheckResult)
      : (raw as AiRateLimitCheckResult | null);
  return {
    allowed: Boolean(result?.allowed),
    remainingHour: Number(result?.remainingHour ?? 0),
    remainingDay: Number(result?.remainingDay ?? 0),
    retryAfterSeconds: Number(result?.retryAfterSeconds ?? 1),
  };
};
