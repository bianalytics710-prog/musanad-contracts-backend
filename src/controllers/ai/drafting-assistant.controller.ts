/**
 * S2 — POST /api/v1/ai/drafting-assistant
 *
 * Modes:
 *   - chat / explain / rewrite → SSE streaming
 *   - suggest                  → non-streaming tool-call JSON
 *
 * EPHEMERAL — NO caching (Q4 lock).
 *
 * Sensitive logging:
 *   - selectedText / draftSummary / chatHistory NEVER logged at controller.
 *   - Pino redact safety net (logger.util.ts).
 */
import type { NextFunction, Request, Response } from 'express';
import {
  ApiError,
  RateLimitError,
} from '../../utils/errors.util';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import * as service from '../../services/ai/openai-drafting-assistant.service';
import type { AiDraftingAssistantRequestInput } from '../../schemas/ai.schemas';
import type { AiDraftingAssistantStreamChunk } from '../../types/ai.types';

const PROMPT_ID = service.PROMPT_ID;

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const sseFrame = (chunk: AiDraftingAssistantStreamChunk): string =>
  `data: ${JSON.stringify(chunk)}\n\n`;

export const draftingAssistantController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const body = req.body as AiDraftingAssistantRequestInput;
    const userId = req.user!.id;
    const isStreaming = body.mode !== 'suggest';

    req.logger.info(
      {
        action: 'aiDraftingAssistant.invoke',
        userId,
        method: req.method,
        path: req.path,
        mode: body.mode,
        contractType: body.contractType,
        language: body.language,
        // selectedText / draftSummary / chatHistory NEVER logged.
        selectedTextLen: body.selectedText?.length ?? 0,
        draftSummaryLen: body.draftSummary?.length ?? 0,
        chatHistoryTurns: body.chatHistory?.length ?? 0,
      },
      'Controller entry',
    );

    let outcome: 'success' | 'error' | 'timeout' | 'rate_limited' | 'cancelled' = 'error';
    let modelUsed = '';
    let tokensInput: number | null = null;
    let tokensOutput: number | null = null;
    let errorClass: string | null = null;
    let errorMessage: string | null = null;

    // Rate-limit gate
    let limit;
    try {
      limit = await checkRateLimit(userId, PROMPT_ID);
    } catch (err) {
      next(err);
      return;
    }
    if (!limit.allowed) {
      res.setHeader('Retry-After', String(limit.retryAfterSeconds));
      await recordAiTelemetry({
        promptId: PROMPT_ID,
        mode: body.mode,
        actorUserId: userId,
        language: body.language,
        provider: 'openai',
        modelUsed: 'unknown',
        cacheHit: false,
        streamMode: isStreaming,
        outcome: 'rate_limited',
        latencyMs: Date.now() - startTime,
      });
      next(new RateLimitError('AI rate limit exceeded'));
      return;
    }

    try {
      const ctx: service.DraftingAssistantContext = {
        mode: body.mode,
        contractType: body.contractType,
        partyA: body.partyA,
        partyB: body.partyB ?? '',
        draftSummary: body.draftSummary ?? '',
        existingClauseCategories: body.existingClauseCategories ?? [],
        language: body.language,
        ...(body.selectedText !== undefined ? { selectedText: body.selectedText } : {}),
        ...(body.tone !== undefined ? { tone: body.tone } : {}),
      };
      const systemPrompt = await service.buildSystemPrompt(ctx);

      if (body.mode === 'suggest') {
        // Non-streaming tool call
        const userMessage = `Suggest up to 4 clauses for ${body.contractType}. Existing clauses: ${ctx.existingClauseCategories.join(', ') || '(none)'}.`;
        const result = await service.suggestClauses({ systemPrompt, userMessage });
        modelUsed = result.modelUsed;
        tokensInput = result.tokensInput;
        tokensOutput = result.tokensOutput;
        outcome = 'success';
        res.status(200).json({ success: true, data: result.payload, requestId: req.requestId });
      } else {
        // SSE streaming
        res.status(200);
        res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
        res.setHeader('Cache-Control', 'no-cache, no-transform');
        res.setHeader('Connection', 'keep-alive');
        res.setHeader('X-Accel-Buffering', 'no');
        res.flushHeaders?.();

        const abortController = new AbortController();
        let stillOpen = true;
        req.on('close', () => {
          if (stillOpen) abortController.abort();
        });

        const userMessage =
          body.mode === 'explain' && body.selectedText
            ? `Explain this clause:\n\n${body.selectedText}`
            : body.mode === 'rewrite' && body.selectedText
              ? `Rewrite this clause in tone=${body.tone ?? 'balanced'}:\n\n${body.selectedText}`
              : 'Continue the conversation.';

        const { stream, tokensConsumed } = service.streamAssistant({
          systemPrompt,
          userMessage,
          ...(body.chatHistory ? { chatHistory: body.chatHistory } : {}),
          abortSignal: abortController.signal,
        });
        try {
          for await (const delta of stream) {
            if (!stillOpen) break;
            res.write(sseFrame({ type: 'token', delta }));
          }
        } catch (streamErr) {
          stillOpen = false;
          const code = streamErr instanceof RateLimitError ? 'rate_limit_exceeded' : 'ai_provider_error';
          const message = streamErr instanceof Error ? streamErr.message : 'AI provider error';
          try {
            res.write(sseFrame({ type: 'error', code, message }));
          } catch {
            /* swallow */
          }
          outcome = 'error';
          errorClass = streamErr instanceof Error ? streamErr.name : 'UNKNOWN';
          errorMessage = message;
          throw streamErr;
        }
        const finalTokens = tokensConsumed();
        modelUsed = 'gpt-4o';
        tokensOutput = finalTokens;
        outcome = 'success';
        try {
          res.write(sseFrame({ type: 'done', tokensConsumed: finalTokens }));
        } catch {
          /* swallow */
        }
        try {
          res.end();
        } catch {
          /* swallow */
        }
        stillOpen = false;
      }

      req.logger.info(
        {
          action: 'aiDraftingAssistant.invoke',
          userId,
          mode: body.mode,
          tokensInput,
          tokensOutput,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
    } catch (err) {
      outcome = 'error';
      errorClass = err instanceof Error ? err.name : 'UNKNOWN';
      errorMessage = err instanceof Error ? err.message : String(err);
      req.logger.error(
        {
          action: 'aiDraftingAssistant.invoke',
          userId,
          mode: body.mode,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      if (!isStreaming) {
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          mode: body.mode,
          actorUserId: userId,
          language: body.language,
          provider: 'openai',
          modelUsed: modelUsed || 'unknown',
          tokensInput,
          tokensOutput,
          cacheHit: false,
          streamMode: false,
          outcome: 'error',
          errorClass,
          errorMessage,
          latencyMs: Date.now() - startTime,
        });
        next(err);
        return;
      }
    } finally {
      if (isStreaming || outcome === 'success') {
        await recordAiTelemetry({
          promptId: PROMPT_ID,
          mode: body.mode,
          actorUserId: userId,
          language: body.language,
          provider: 'openai',
          modelUsed: modelUsed || 'unknown',
          tokensInput,
          tokensOutput,
          cacheHit: false, // EPHEMERAL — never cached
          streamMode: isStreaming,
          outcome,
          errorClass,
          errorMessage,
          latencyMs: Date.now() - startTime,
        });
      }
    }
  },
};
