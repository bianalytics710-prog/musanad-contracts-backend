/**
 * M15 / CR-G — AI Risk Assistant TypeScript Type Definitions (BE)
 *
 * SSE streaming Q&A endpoint types.
 * Permission gate: ai.invoke.risk_assistant
 *
 * SENSITIVE: query and filters are Pino-redacted. Token chunks and citation
 * excerpts are never logged at INFO level.
 */

// ============================================================
// 1. Request types
// ============================================================

/**
 * RiskAssistantAskRequest — POST /api/v1/ai/risk-assistant/ask request body.
 * Zod-validated from riskAssistantAskSchema.
 */
export interface RiskAssistantAskRequest {
  /**
   * Free-text natural-language question (max 2000 chars).
   * SENSITIVE — Pino-redacted from all logs.
   */
  query: string;
  /**
   * Dashboard persona context for prompt variant selection.
   * Maps to ai_prompt.prompt_id = 'risk_assistant.qa_<persona>'.
   * If omitted, derived from caller's primary role JWT claim.
   */
  persona?: 'executive' | 'legal_counsel' | 'compliance_esg' | 'operations' | 'finance_treasury' | 'procurement';
  /**
   * Optional ACL-narrowing + dashboard filter context.
   * SENSITIVE — Pino-redacted. Never log verbatim.
   */
  filters?: {
    contractIds?: string[];
    contractType?: string;
    emirate?: string;
    riskKind?: string;
  };
}

/** Supported persona values (must match ai_prompt.prompt_id suffix). */
export type RiskAssistantPersona = NonNullable<RiskAssistantAskRequest['persona']>;

// ============================================================
// 2. SSE event types
// ============================================================

/**
 * RiskAssistantSSEEvent — single SSE event emitted on text/event-stream.
 * Event types: 'token' | 'citation' | 'done' | 'error'.
 */
export interface RiskAssistantSSEEvent {
  event: 'token' | 'citation' | 'done' | 'error';
  data: {
    /** Partial LLM response text chunk (present on 'token' events). SENSITIVE — never log. */
    token?: string;
    /** Inline citation reference (present on 'citation' events). */
    citation?: RiskAssistantCitation;
    /** Structured error message (present on 'error' events). */
    error?: string;
    /**
     * Machine-readable error code (present on 'error' events).
     * e.g. 'rate_limit_exceeded' | 'ai_provider_error'
     */
    code?: string;
    /** Error message text (present on 'error' events). */
    message?: string;
    /**
     * ai_request_log.request_id for audit traceability (emitted on 'done' event).
     * UUID serialized as string.
     */
    requestLogId?: string;
  };
}

// ============================================================
// 3. Citation types
// ============================================================

/**
 * RiskAssistantCitation — inline citation chip payload.
 * BIGINT id fields serialized as string per project convention.
 */
export interface RiskAssistantCitation {
  /** Discriminator for FE chip rendering. */
  type: 'clause' | 'correlation' | 'signal' | 'contract';
  /** BIGINT-as-string — entity primary key. */
  id: string;
  /** Human-readable label for the chip. */
  label: string;
  /** FE navigation href. */
  href: string;
  /** Short excerpt from the cited entity (optional, for tooltip). SENSITIVE — never log. */
  excerpt?: string;
}

// ============================================================
// 4. Non-streaming fallback response
// ============================================================

/** Response shape when ?stream=false query param is provided. */
export interface RiskAssistantNonStreamingResponse {
  answer: string;
  citations: RiskAssistantCitation[];
}

// ============================================================
// 5. Internal service types
// ============================================================

/** Internal event structure emitted by risk-assistant.service.ts onEvent callback. */
export interface RiskAssistantServiceEvent {
  event: 'token' | 'citation' | 'done' | 'error';
  data: RiskAssistantSSEEvent['data'];
}

/** Options passed to riskAssistantService.ask(). */
export interface RiskAssistantAskOptions {
  query: string;
  personaCode: RiskAssistantPersona;
  filters?: RiskAssistantAskRequest['filters'];
  actorId: number;
  tenantId: string | undefined;
  stream: boolean;
  onEvent: (evt: RiskAssistantServiceEvent) => void;
}

/** ai_request_log.request_id is a UUID string. */
export type AiRequestLogId = string;

/** CR-G extension columns on ai_request_log (audit-only, never in API responses). */
export interface AiRequestLogCrgExtension {
  scopeHash: string | null;
  aclFilteredCount: number | null;
}
