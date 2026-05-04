/**
 * AI telemetry helper — wraps fn_ai_request_log_create.
 *
 * Every AI invocation emits ONE ai_request_log row in a controller `finally`
 * block — even on cache_hit (cache_hit=true, tokens_input=NULL,
 * cost_usd_micros=0).
 *
 * Per DN-1 of M4 api-contracts.json + AC-S10-07: error_message is
 * pre-sanitized at the controller (Pino redact path) before reaching here.
 * fn_ai_request_log_create does NOT re-redact.
 *
 * Sensitive data:
 *   - ai_prompt_payload is NOT a parameter (defence-in-depth — not even
 *     reachable). Verified at fn signature time.
 *   - error_message is pre-redacted per AC-S10-07; fn_audit_trigger v_redact_fields
 *     extension (migration 041) is a defence-in-depth safety net.
 */
import { randomUUID } from 'node:crypto';
import { db } from '../../../database/client';
import { logger } from '../../../utils/logger.util';
import type {
  AiInsightEntityType,
  AiLanguage,
  AiProvider,
  AiRequestLogCreateResult,
  AiRequestOutcome,
  M4PromptId,
} from '../../../types/ai.types';

export interface AiTelemetryRecord {
  /** Pre-generated UUID; controller MAY reuse req.requestId for correlation. */
  requestId?: string;
  promptId: M4PromptId | string;
  mode?: string | null;
  /** NULL for public-endpoint (signed-PDF-token) requests. */
  actorUserId?: number | null;
  entityType?: AiInsightEntityType | string | null;
  entityId?: number | null;
  language: AiLanguage;
  provider: AiProvider;
  modelUsed: string;
  tokensInput?: number | null;
  tokensOutput?: number | null;
  costUsdMicros?: number | null;
  latencyMs?: number | null;
  cacheHit: boolean;
  streamMode: boolean;
  outcome: AiRequestOutcome;
  errorClass?: string | null;
  /** Pre-redacted at controller per AC-S10-07. */
  errorMessage?: string | null;
}

/**
 * Append a telemetry row. Best-effort — failure here is logged but never
 * propagated; the user-facing response has already shipped by the time this
 * runs in the controller's finally{} block.
 */
export const recordAiTelemetry = async (
  rec: AiTelemetryRecord,
): Promise<AiRequestLogCreateResult | null> => {
  const requestId = rec.requestId ?? randomUUID();
  try {
    const result = await db.callFunction<AiRequestLogCreateResult>(
      'fn_ai_request_log_create',
      [
        requestId,
        rec.promptId,
        rec.mode ?? null,
        rec.actorUserId ?? null,
        rec.entityType ?? null,
        rec.entityId ?? null,
        rec.language,
        rec.provider,
        rec.modelUsed,
        rec.tokensInput ?? null,
        rec.tokensOutput ?? null,
        rec.costUsdMicros ?? null,
        rec.latencyMs ?? null,
        rec.cacheHit,
        rec.streamMode,
        rec.outcome,
        rec.errorClass ?? null,
        rec.errorMessage ?? null,
      ],
      // fn is DEFINER + neondb_owner-only; pool already authenticates as
      // neondb_owner via DATABASE_URL. Pass actorId so RLS GUC is set when
      // present (used by fn_audit_trigger to populate changed_by).
      rec.actorUserId !== null && rec.actorUserId !== undefined
        ? { actorId: rec.actorUserId }
        : {},
    );
    return result;
  } catch (err) {
    logger.error(
      {
        action: 'aiTelemetry.record_failed',
        promptId: rec.promptId,
        outcome: rec.outcome,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        // err.message may include raw PG text — logger redacts known sensitive keys.
        message: err instanceof Error ? err.message : String(err),
      },
      'Failed to append ai_request_log row (non-fatal)',
    );
    return null;
  }
};
