/**
 * AI insight cache layer (S7).
 *
 * Read-through pattern:
 *   1. fn_ai_insight_get_cached — returns full row JSONB on hit, NULL on miss.
 *   2. On miss, controller calls provider then calls upsert.
 *   3. fn_ai_insight_upsert — soft-deactivates prior active row + inserts new.
 *
 * Cache key (S2-18 NULL-safe equality already applied inside fn_):
 *   (entity_type, entity_id, insight_type, language) + optional payload_hash
 *   for content-addressed lookup (S5 30d cache).
 *
 * Sensitive data:
 *   - The JSONB payload IS the AI response (may echo contract excerpts).
 *     Defence-in-depth redaction at fn_audit_trigger (migration 041).
 *     Pino redact catches `payload` at the controller log boundary as a
 *     safety net.
 */
import { createHash } from 'node:crypto';
import { db } from '../../../database/client';
import type {
  AiInsight,
  AiInsightEntityType,
  AiInsightPayload,
  AiInsightType,
  AiInsightUpsertResult,
  AiLanguage,
  AiProvider,
  M4PromptId,
} from '../../../types/ai.types';

// ------------------------------------------------------------
// payload_hash canonicalisation
// ------------------------------------------------------------

/**
 * Stable JSON stringify — keys sorted, primitives unchanged. Used so the
 * payload_hash is deterministic across re-orderings of fields in the
 * controller-built input object.
 */
const stableStringify = (value: unknown): string => {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((el) => stableStringify(el)).join(',')}]`;
  }
  const entries = Object.entries(value as Record<string, unknown>).sort((a, b) =>
    a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0,
  );
  return `{${entries
    .map(([k, v]) => `${JSON.stringify(k)}:${stableStringify(v)}`)
    .join(',')}}`;
};

/**
 * SHA-256 hex digest of canonicalised inputs. Caller passes prompt_id +
 * language + the payload-shape that uniquely identifies an AI request
 * (contract version, regulator title, stats, etc.). Same inputs → same hash.
 */
export const buildPayloadHash = (input: Record<string, unknown>): string => {
  const canon = stableStringify(input);
  return createHash('sha256').update(canon).digest('hex');
};

// ------------------------------------------------------------
// Cache lookup
// ------------------------------------------------------------

export interface CacheLookupArgs {
  entityType: AiInsightEntityType;
  entityId: number | null;
  insightType: AiInsightType;
  language: AiLanguage;
  /** Optional content-addressed lookup (S5). When provided, lookup pins to this hash. */
  payloadHash?: string | null;
  /** Pass through actorUserId for RLS context (fn is DEFINER but actor still informs audit). */
  actorUserId?: number | null;
}

/**
 * Lookup cached ai_insight row. Returns NULL on cache miss / expired row.
 * Controller treats NULL as miss → invokes provider.
 */
export const getCached = async (args: CacheLookupArgs): Promise<AiInsight | null> => {
  const result = await db.callFunction<AiInsight | null>(
    'fn_ai_insight_get_cached',
    [
      args.entityType,
      args.entityId,
      args.insightType,
      args.language,
      args.payloadHash ?? null,
    ],
    args.actorUserId !== null && args.actorUserId !== undefined
      ? { actorId: args.actorUserId }
      : {},
  );
  return result ?? null;
};

// ------------------------------------------------------------
// Cache upsert
// ------------------------------------------------------------

export interface CacheUpsertArgs {
  entityType: AiInsightEntityType;
  entityId: number | null;
  insightType: AiInsightType;
  language: AiLanguage;
  provider: AiProvider;
  modelUsed: string;
  payload: AiInsightPayload;
  payloadHash: string;
  promptId: M4PromptId | string;
  tokensInput?: number | null;
  tokensOutput?: number | null;
  costUsdMicros?: number | null;
  /** NULL → use ai_prompt.default_ttl_seconds. */
  ttlSeconds?: number | null;
  actorUserId?: number | null;
}

export const upsertCache = async (
  args: CacheUpsertArgs,
): Promise<AiInsightUpsertResult> => {
  const result = await db.callFunction<AiInsightUpsertResult>(
    'fn_ai_insight_upsert',
    [
      args.entityType,
      args.entityId,
      args.insightType,
      args.language,
      args.provider,
      args.modelUsed,
      args.payload,
      args.payloadHash,
      args.promptId,
      args.tokensInput ?? null,
      args.tokensOutput ?? null,
      args.costUsdMicros ?? null,
      args.ttlSeconds ?? null,
      args.actorUserId ?? null,
    ],
    args.actorUserId !== null && args.actorUserId !== undefined
      ? { actorId: args.actorUserId }
      : {},
  );
  return result;
};
