/**
 * Signer Q&A controllers — token-bearer (verify_jwt=false).
 *
 * Two endpoints covered:
 *   - POST /api/v1/sign/:invitationToken/qa/session  — S11 (sessionStart)
 *   - POST /api/v1/sign/:invitationToken/qa/message  — S12 (recordMessage SSE)
 *
 * S12 design (AN-2 rateLimitProtocol / DN-10):
 *   1. Validate Zod (mode discriminator, X-Session-Token header)
 *   2. fn_signer_qa_session_record_message(GATE) — reserves rate-limit slot.
 *      RAISES rate_limit_exceeded → translatePgError → 429.
 *   3. Re-fetch invitation context via fn_signature_get_by_invitation_token
 *      (so the system prompt can be built without persisting transcript).
 *      If GET returns NULL emit { type:'error', code:'invitation_invalid_or_expired' }.
 *   4. Build system prompt from prompts/ai-signer-qa.txt + contract context.
 *   5. Stream OpenAI gpt-4o response — yield SSE token chunks.
 *   6. On stream end: fn_signer_qa_session_record_message(COMMIT) with
 *      actual tokensConsumed + emit final 'done' chunk.
 *   7. On any mid-stream error: emit 'error' chunk + close.
 *
 * Sensitive data (AC-S12-09):
 *   - userMessage carries the user prompt (ai_prompt_payload alias). NEVER
 *     log at the controller layer. Pino redaction applies as safety net.
 *   - System prompt content is not logged.
 *   - sessionTokenPlaintext / invitationTokenPlaintext NEVER logged
 *     (pino-redacted both in req.headers.x-session-token and req.params).
 */
import type { NextFunction, Request, Response } from 'express';
import * as signatureService from '../services/signature.service';
import * as signerQaService from '../services/signer-qa.service';
import {
  buildSystemPrompt,
  streamSignerQa,
} from '../services/ai/openai-signer-qa.service';
import { ApiError, GoneError, RateLimitError, ValidationError } from '../utils/errors.util';
import type {
  InvitationTokenParamInferred,
  SignerQaRecordMessageDtoInferred,
  SignerQaSessionStartDtoInferred,
} from '../schemas/signature.schemas';
import type { SignerQaMessageStreamChunk } from '../types/signature.types';

const tokenMarker = (token: string | undefined): string => {
  if (!token || token.length < 8) return '[REDACTED]';
  return `${token.slice(0, 4)}…(${token.length}c)`;
};

/** Extract X-Session-Token header. Throws ValidationError if missing/invalid. */
const requireSessionToken = (req: Request): string => {
  const raw = req.header('X-Session-Token');
  if (typeof raw !== 'string' || raw.length < 32 || raw.length > 512) {
    throw new ValidationError('X-Session-Token header is required', {
      'X-Session-Token': 'Required',
    });
  }
  return raw;
};

/** Format a single SSE event line — `data: <JSON>\n\n`. */
const sseFrame = (chunk: SignerQaMessageStreamChunk): string =>
  `data: ${JSON.stringify(chunk)}\n\n`;

export const signerQaController = {
  /**
   * S11 — POST /api/v1/sign/:invitationToken/qa/session → fn_signer_qa_session_start
   *
   * Sliding-window soft-deactivate when 5+ active sessions per invitation
   * is enforced inside the fn_ (Gate 2 AN-12 Option A). Plaintext session
   * token returned ONCE.
   */
  async sessionStart(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const { invitationToken } = req.params as unknown as InvitationTokenParamInferred;
    req.logger.info(
      {
        action: 'signerQa.sessionStart',
        method: req.method,
        path: req.path,
        invitationTokenMarker: tokenMarker(invitationToken),
      },
      'Controller entry',
    );
    try {
      const body = req.body as SignerQaSessionStartDtoInferred;
      const result = await signerQaService.sessionStart(invitationToken, body.language ?? null);
      if (!result) {
        throw new GoneError('Invitation is invalid or expired');
      }
      req.logger.info(
        {
          action: 'signerQa.sessionStart',
          invitationTokenMarker: tokenMarker(invitationToken),
          sessionId: result.sessionId,
          language: result.language,
          duration: Date.now() - startTime,
          statusCode: 201,
        },
        'Controller exit',
      );
      res.status(201).json({ success: true, data: result, requestId: req.requestId });
    } catch (error) {
      req.logger.warn(
        {
          action: 'signerQa.sessionStart',
          invitationTokenMarker: tokenMarker(invitationToken),
          duration: Date.now() - startTime,
          errorType: error instanceof Error ? error.name : 'UNKNOWN',
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * S12 — POST /api/v1/sign/:invitationToken/qa/message — SSE
   *
   * Discriminator: `mode='GATE'` (with userMessage) → opens streaming.
   *                `mode='COMMIT'` is internal-only (BE → DB after stream
   *                ends). The wire-level COMMIT entry-point is intentionally
   *                NOT exposed — the FE always sends GATE; the controller
   *                drives COMMIT itself once the SSE stream completes.
   *
   * SSE behaviour (AC-S12-02):
   *   - 200 OK + Content-Type: text/event-stream
   *   - Cache-Control: no-cache; Connection: keep-alive; X-Accel-Buffering: no
   *   - Each token: `data: {"type":"token","delta":"..."}\n\n`
   *   - Terminal:   `data: {"type":"done","tokensConsumed":N}\n\n`
   *   - On error:   `data: {"type":"error","code":"...","message":"..."}\n\n`
   */
  async recordMessage(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    const { invitationToken } = req.params as unknown as InvitationTokenParamInferred;
    const body = req.body as SignerQaRecordMessageDtoInferred;

    // Defense-in-depth: COMMIT is server-internal only. Reject if the
    // client attempts COMMIT directly.
    if (body.mode === 'COMMIT') {
      next(
        new ValidationError('mode=COMMIT is server-internal only', {
          mode: 'Only mode=GATE is accepted on this endpoint',
        }),
      );
      return;
    }

    req.logger.info(
      {
        action: 'signerQa.recordMessage',
        method: req.method,
        path: req.path,
        invitationTokenMarker: tokenMarker(invitationToken),
        mode: body.mode,
        // userMessage NOT logged (sensitive — AC-S12-09)
        userMessageLen:
          typeof body.userMessage === 'string' ? body.userMessage.length : 0,
      },
      'Controller entry',
    );

    let sessionToken: string;
    try {
      sessionToken = requireSessionToken(req);
    } catch (err) {
      next(err);
      return;
    }

    // ---------------------------------------------------------
    // Step 1 — fn_ GATE (RAISES on rate-limit; translatePgError → 429).
    // We do this BEFORE flipping the response into SSE mode so
    // ApiError → JSON envelope still works.
    // ---------------------------------------------------------
    try {
      const gate = await signerQaService.recordMessage(sessionToken, 0, 'GATE');
      if (!gate) {
        throw new GoneError('Session is invalid or expired');
      }
    } catch (error) {
      req.logger.warn(
        {
          action: 'signerQa.recordMessage.gate_failed',
          invitationTokenMarker: tokenMarker(invitationToken),
          errorType: error instanceof ApiError ? error.code : 'UNKNOWN',
        },
        'GATE call failed before AI invocation',
      );
      next(error);
      return;
    }

    // ---------------------------------------------------------
    // Step 2 — Re-fetch invitation context (signer-safe view).
    // The fn_signature_get_by_invitation_token also bumps view_count + may
    // emit a 'viewed' event the first time. Acceptable side effect because
    // the signer is interacting with the contract Q&A drawer.
    // ---------------------------------------------------------
    let view;
    try {
      view = await signatureService.getByInvitationToken(invitationToken);
    } catch (err) {
      next(err);
      return;
    }
    if (!view) {
      next(new GoneError('Invitation is invalid or expired'));
      return;
    }

    // ---------------------------------------------------------
    // Step 3 — Flip into SSE mode + stream OpenAI tokens.
    // Past this point we cannot use next(error) — the response is already
    // committed to text/event-stream. Errors must be emitted as SSE
    // {type:'error',...} chunks instead.
    // ---------------------------------------------------------
    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no'); // disable nginx buffering
    // Ensure compression middleware does not buffer SSE.
    res.flushHeaders?.();

    let tokensConsumed = 0;
    let stillOpen = true;

    const closeStream = (): void => {
      if (stillOpen) {
        stillOpen = false;
        try {
          res.end();
        } catch {
          /* noop */
        }
      }
    };

    // Detect client disconnect to abort the upstream OpenAI request.
    const abortController = new AbortController();
    req.on('close', () => {
      if (stillOpen) {
        abortController.abort();
      }
    });

    try {
      const systemPrompt = await buildSystemPrompt(view);
      const userMessage =
        typeof body.userMessage === 'string' ? body.userMessage : '';

      const { stream, tokensConsumed: getTokens } = streamSignerQa({
        systemPrompt,
        userMessage,
        language: view.invitation.language,
        abortSignal: abortController.signal,
      });

      for await (const delta of stream) {
        if (!stillOpen) break;
        const chunk: SignerQaMessageStreamChunk = { type: 'token', delta };
        res.write(sseFrame(chunk));
      }

      tokensConsumed = getTokens();

      // ------------------------------------------------------
      // Step 4 — fn_ COMMIT (records actual usage). Best-effort —
      // we still emit the 'done' chunk even if COMMIT fails (the
      // user has already received the AI body; COMMIT is bookkeeping).
      // ------------------------------------------------------
      try {
        // tokensConsumed must be > 0 for COMMIT mode validation in fn_.
        // Fall back to 1 when upstream usage is unavailable so the COMMIT
        // call itself doesn't 22023 (the rate-limit accounting still
        // increments by the GATE reservation).
        const commitTokens = tokensConsumed > 0 ? tokensConsumed : 1;
        await signerQaService.recordMessage(sessionToken, commitTokens, 'COMMIT');
      } catch (commitErr) {
        req.logger.warn(
          {
            action: 'signerQa.recordMessage.commit_failed',
            invitationTokenMarker: tokenMarker(invitationToken),
            errorType:
              commitErr instanceof ApiError
                ? commitErr.code
                : commitErr instanceof Error
                  ? commitErr.name
                  : 'UNKNOWN',
            tokensConsumed,
          },
          'fn_ COMMIT failed (non-fatal — session over-counts by 1)',
        );
      }

      const done: SignerQaMessageStreamChunk = { type: 'done', tokensConsumed };
      res.write(sseFrame(done));

      req.logger.info(
        {
          action: 'signerQa.recordMessage',
          invitationTokenMarker: tokenMarker(invitationToken),
          tokensConsumed,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'SSE stream complete',
      );
    } catch (err) {
      const code =
        err instanceof RateLimitError
          ? 'rate_limit_exceeded'
          : err instanceof GoneError
            ? 'invitation_invalid_or_expired'
            : 'ai_provider_error';
      const message = err instanceof Error ? err.message : 'AI provider error';
      try {
        const errChunk: SignerQaMessageStreamChunk = { type: 'error', code, message };
        if (stillOpen) res.write(sseFrame(errChunk));
      } catch {
        /* swallow write error during stream cleanup */
      }
      req.logger.warn(
        {
          action: 'signerQa.recordMessage.stream_error',
          invitationTokenMarker: tokenMarker(invitationToken),
          tokensConsumed,
          duration: Date.now() - startTime,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          code,
        },
        'SSE stream error',
      );
    } finally {
      closeStream();
    }
  },
};
