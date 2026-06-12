/**
 * /api/v1/ai/chat/* — controllers.
 *
 * Mirrors the SSE plumbing of risk-assistant.controller.ts. Three endpoints:
 *
 *   POST /ai/chat/ask        — SSE generator (text tokens, resolverUsed, proposal, done, error)
 *   POST /ai/chat/execute    — confirm + run a write_action proposal, return receipt
 *   POST /ai/chat/reject     — dismiss a pending proposal
 *
 * Permission gate: ai.invoke.risk_assistant (existing — every floating
 * chatbot caller has this). Per-action permissions are checked at
 * proposal time (in the orchestrator) and again at execute time (in the
 * handler) as defence-in-depth.
 */
import type { NextFunction, Request, Response } from 'express';
import { chatOrchestratorService } from '../../services/ai/chat-orchestrator.service';
import {
  chatAskSchema,
  chatExecuteSchema,
  chatRejectSchema,
  chatStreamFlagSchema,
} from '../../schemas/chat-orchestrator.schemas';
import type { ChatSSEEvent } from '../../types/chat-orchestrator.types';
import { checkRateLimit } from '../../services/ai/_shared/rate-limit-gate';
import { RateLimitError } from '../../utils/errors.util';

const PROMPT_ID = 'chat_orchestrator.system';

const sseFrame = (evt: ChatSSEEvent): string =>
  `event: ${String(evt.event)}\ndata: ${JSON.stringify({ event: evt.event, data: evt.data })}\n\n`;

export const chatOrchestratorController = {
  async ask(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const userId = req.user!.id;
    const userRole = req.user!.role;
    const userPermissions = req.user!.permissions ?? [];

    const { stream } = chatStreamFlagSchema.parse(req.query);

    let body;
    try {
      body = chatAskSchema.parse(req.body);
    } catch (err) {
      next(err);
      return;
    }

    req.logger.info({
      action: 'chatOrchestrator.ask',
      method: req.method,
      path: req.path,
      userId,
      role: userRole,
      // messages/mentions are SENSITIVE — never logged
    });

    let limit;
    try {
      limit = await checkRateLimit(userId, PROMPT_ID);
    } catch (err) {
      next(err);
      return;
    }
    if (!limit.allowed) {
      res.setHeader('Retry-After', String(limit.retryAfterSeconds));
      next(new RateLimitError('Chat Orchestrator rate limit exceeded'));
      return;
    }

    if (!stream) {
      // Sync fallback: collect tokens + proposal into one JSON payload.
      try {
        const events: ChatSSEEvent[] = [];
        for await (const evt of chatOrchestratorService.askStream({
          userId,
          userPermissions,
          userRole,
          messages: body.messages,
          mentions: body.mentions,
          tenantId: req.tenantId,
        })) {
          events.push(evt);
        }
        res.status(200).json({ success: true, events });
        req.logger.info({
          action: 'chatOrchestrator.ask',
          userId,
          duration: Date.now() - startTime,
          statusCode: 200,
          mode: 'sync',
        });
      } catch (err) {
        next(err);
      }
      return;
    }

    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    const abortController = new AbortController();
    let stillOpen = true;
    req.on('close', () => {
      if (stillOpen) {
        abortController.abort();
        stillOpen = false;
      }
    });

    try {
      for await (const evt of chatOrchestratorService.askStream({
        userId,
        userPermissions,
        userRole,
        messages: body.messages,
        mentions: body.mentions,
        tenantId: req.tenantId,
        abortSignal: abortController.signal,
      })) {
        if (!stillOpen) break;
        try {
          res.write(sseFrame(evt));
        } catch {
          break;
        }
        if (evt.event === 'done' || evt.event === 'error') break;
      }
      stillOpen = false;
      try {
        res.end();
      } catch {
        /* swallow */
      }
      req.logger.info({
        action: 'chatOrchestrator.ask',
        userId,
        duration: Date.now() - startTime,
        statusCode: 200,
        mode: 'sse',
      });
    } catch (err) {
      req.logger.error({
        action: 'chatOrchestrator.ask',
        userId,
        duration: Date.now() - startTime,
        errorType: (err as Error).name,
      });
      if (res.headersSent) {
        try {
          res.write(
            sseFrame({
              event: 'error',
              data: { code: 'ai_provider_error', message: 'Chat orchestrator failed.' },
            }),
          );
          res.end();
        } catch {
          /* swallow */
        }
      } else {
        next(err);
      }
    }
  },

  async execute(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const userId = req.user!.id;
    const userPermissions = req.user!.permissions ?? [];
    let body;
    try {
      body = chatExecuteSchema.parse(req.body);
    } catch (err) {
      next(err);
      return;
    }
    req.logger.info({
      action: 'chatOrchestrator.execute',
      method: req.method,
      path: req.path,
      userId,
      proposalId: body.proposalId,
    });
    try {
      const result = await chatOrchestratorService.executeProposal(body.proposalId, {
        userId,
        userPermissions,
        tenantId: req.tenantId,
      });
      req.logger.info({
        action: 'chatOrchestrator.execute',
        userId,
        duration: Date.now() - startTime,
        statusCode: 200,
        actionCode: result.actionCode,
      });
      res.json(result);
    } catch (err) {
      req.logger.error({
        action: 'chatOrchestrator.execute',
        userId,
        duration: Date.now() - startTime,
        errorType: (err as Error).name,
      });
      next(err);
    }
  },

  async reject(req: Request, res: Response, next: NextFunction): Promise<void> {
    const userId = req.user!.id;
    const userPermissions = req.user!.permissions ?? [];
    let body;
    try {
      body = chatRejectSchema.parse(req.body);
    } catch (err) {
      next(err);
      return;
    }
    try {
      await chatOrchestratorService.rejectProposal(body.proposalId, body.reason ?? null, {
        userId,
        userPermissions,
        tenantId: req.tenantId,
      });
      res.json({ proposalId: body.proposalId, outcome: 'rejected' });
    } catch (err) {
      next(err);
    }
  },
};
