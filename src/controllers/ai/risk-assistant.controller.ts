/**
 * M15 / CR-G — POST /api/v1/ai/risk-assistant/ask
 *
 * AI Risk Assistant SSE streaming Q&A endpoint.
 * Per-persona prompt variant (6 variants from migration 187).
 * Per-call ACL: resolves caller's read-allowed contract_ids via fn_contract_list
 * BEFORE building LLM context.
 *
 * Permission gate: ai.invoke.risk_assistant
 *   — enforced at route layer (authorise middleware) BEFORE SSE headers are set
 *     so permission failures return 403 JSON, not SSE.
 *
 * Body validation: riskAssistantAskSchema applied BEFORE SSE headers (Zod errors → 400 JSON).
 * Query validation: riskAssistantQuerySchema (stream=false → non-streaming fallback).
 *
 * SENSITIVE fields (never in logs):
 *   - req.body.query (natural language question)
 *   - req.body.filters (ACL-narrowing context)
 *   - SSE response chunks
 *
 * Error routing:
 *   - 400  — Zod validation failure (pre-SSE)
 *   - 401  — JWT missing / invalid
 *   - 403  — ai.invoke.risk_assistant denied (pre-SSE)
 *   - 429  — rate limit exceeded (pre-SSE, Retry-After header set)
 *   - SSE event:error — LLM provider failure after stream opened
 */
import type { NextFunction, Request, Response } from 'express';
import { riskAssistantAskSchema, riskAssistantQuerySchema } from '../../schemas/risk-assistant.schemas';
import type { RiskAssistantAskInput } from '../../schemas/risk-assistant.schemas';
import { riskAssistantService } from '../../services/ai/risk-assistant.service';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import { RateLimitError } from '../../utils/errors.util';
import type { RiskAssistantSSEEvent } from '../../types/risk-assistant.types';

const PROMPT_ID_PREFIX = 'risk_assistant.qa_';

const sseFrame = (evt: RiskAssistantSSEEvent): string =>
  `event: ${String(evt.event)}\ndata: ${JSON.stringify(evt.data)}\n\n`;

/**
 * POST /api/v1/ai/risk-assistant/ask
 * Streams AI Risk Assistant response as SSE. Falls back to JSON when ?stream=false.
 */
export const riskAssistantController = {
  async ask(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const userId = req.user!.id;
    const userRole = req.user!.role;

    // --------------------------------------------------------
    // 1. Validate query params (stream flag) — before body parse
    // --------------------------------------------------------
    const { stream: isStreaming } = riskAssistantQuerySchema.parse(req.query);

    // --------------------------------------------------------
    // 2. Validate body — BEFORE SSE headers so failures → 400 JSON
    // --------------------------------------------------------
    let body: RiskAssistantAskInput;
    try {
      body = riskAssistantAskSchema.parse(req.body);
    } catch (err) {
      next(err);
      return;
    }

    // Derive persona from body or fall back to JWT role
    const persona: string = body.persona ?? (() => {
      if (userRole === 'contract_drafter' || userRole === 'contract_approver') return 'procurement';
      const roleMap: Record<string, string> = {
        executive: 'executive',
        legal_counsel: 'legal',
        compliance_esg: 'compliance',
        operations: 'operations',
        finance_treasury: 'finance_treasury',
        platform_admin: 'executive',
      };
      return roleMap[userRole] ?? 'executive';
    })();

    const promptId = `${PROMPT_ID_PREFIX}${persona}`;

    req.logger.info({
      action: 'riskAssistant.ask',
      method: req.method,
      path: req.path,
      userId,
      persona,
      promptId,
      // query and filters are SENSITIVE — never logged
    });

    // --------------------------------------------------------
    // 3. Rate-limit check (pre-SSE so exceeded → 429 JSON)
    // --------------------------------------------------------
    let limit;
    try {
      limit = await checkRateLimit(userId, promptId);
    } catch (err) {
      next(err);
      return;
    }
    if (!limit.allowed) {
      res.setHeader('Retry-After', String(limit.retryAfterSeconds));
      await recordAiTelemetry({
        requestId: req.requestId,
        promptId,
        mode: 'qa',
        actorUserId: userId,
        entityType: 'risk_assistant_query',
        entityId: null,
        language: 'en',
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: isStreaming,
        outcome: 'rate_limited',
        latencyMs: Date.now() - startTime,
      });
      next(new RateLimitError('AI Risk Assistant rate limit exceeded'));
      return;
    }

    // --------------------------------------------------------
    // 4. All pre-flight checks passed — open SSE or JSON path
    // --------------------------------------------------------
    if (isStreaming) {
      res.status(200);
      res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
      res.setHeader('Cache-Control', 'no-cache, no-transform');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no');
      res.flushHeaders?.();
    }

    const abortController = new AbortController();
    let stillOpen = true;

    if (isStreaming) {
      req.on('close', () => {
        if (stillOpen) {
          abortController.abort();
          stillOpen = false;
        }
      });
    }

    try {
      const askOptions = {
        userId,
        userRole,
        persona,
        promptId,
        query: body.query,
        filters: body.filters,
        requestId: req.requestId,
        tenantId: req.tenantId,
        abortSignal: abortController.signal,
        isStreaming,
      };

      if (isStreaming) {
        // ---- SSE streaming path ----
        for await (const evt of riskAssistantService.askStream(askOptions)) {
          if (!stillOpen) break;
          try {
            res.write(sseFrame(evt));
          } catch {
            /* client disconnected mid-stream */
            break;
          }
          // After done event — close stream
          if (evt.event === 'done' || evt.event === 'error') {
            break;
          }
        }
        stillOpen = false;
        try {
          res.end();
        } catch {
          /* swallow */
        }

        req.logger.info({
          action: 'riskAssistant.ask',
          userId,
          persona,
          duration: Date.now() - startTime,
          statusCode: 200,
          mode: 'sse',
          // token counts logged by service via telemetry
        });
      } else {
        // ---- Non-streaming fallback path ----
        const result = await riskAssistantService.askSync(askOptions);
        res.status(200).json({ success: true, data: result });

        req.logger.info({
          action: 'riskAssistant.ask',
          userId,
          persona,
          duration: Date.now() - startTime,
          statusCode: 200,
          mode: 'sync',
        });
      }
    } catch (error) {
      const errorType = (error as Error).name ?? 'UNKNOWN';

      req.logger.error({
        action: 'riskAssistant.ask',
        userId,
        persona,
        duration: Date.now() - startTime,
        errorType,
      });

      if (isStreaming && res.headersSent) {
        // SSE already opened — emit error event and close
        try {
          const errEvt: RiskAssistantSSEEvent = {
            event: 'error',
            data: {
              code: error instanceof RateLimitError ? 'rate_limit_exceeded' : 'ai_provider_error',
              message: error instanceof Error ? error.message : 'AI provider error',
            },
          };
          res.write(sseFrame(errEvt));
          res.end();
        } catch {
          /* swallow */
        }
        stillOpen = false;
      } else {
        next(error);
      }
    }
  },
};
