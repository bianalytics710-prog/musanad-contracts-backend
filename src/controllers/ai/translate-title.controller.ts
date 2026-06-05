/**
 * POST /api/v1/ai/translate-title
 *
 * One-shot EN ↔ AR translation for contract titles. Used by Compose Step 2
 * to auto-fill the AR title when the drafter blurs the EN field.
 *
 * Permission: contract.edit OR contract.draft (anyone who can author a
 * contract should be able to translate its title — gated at the route).
 * Telemetry: ai_request_log via recordAiTelemetry, mode='title_translate'.
 * Never 5xxs on translation failure — returns { translated: null } so the
 * FE falls back to manual input.
 */
import type { NextFunction, Request, Response } from 'express';
import { translateTitle } from '../../services/ai/translate-title.service';
import { recordAiTelemetry } from '../../services/ai/_shared/telemetry-middleware';
import type { AiTranslateTitleRequestInput } from '../../schemas/ai.schemas';

const PROMPT_ID = 'title-translate-v1';

const errorType = (e: unknown): string =>
  e instanceof Error ? e.name : 'UNKNOWN';

export const translateTitleController = {
  async invoke(req: Request, res: Response, next: NextFunction): Promise<void> {
    const start = Date.now();
    const body = req.body as AiTranslateTitleRequestInput;
    req.logger.info(
      {
        action: 'ai.translateTitle',
        userId: req.user?.id,
        source: body.source,
        target: body.target,
        textLength: body.text.length,
      },
      'Controller entry',
    );

    let outcome: 'success' | 'error' = 'success';
    let errorClass: string | null = null;

    try {
      const result = await translateTitle({
        text: body.text,
        source: body.source,
        target: body.target,
      });

      if (!result.translated) {
        outcome = 'error';
        errorClass = result.warnings[0] ?? 'no_output';
      }

      req.logger.info(
        {
          action: 'ai.translateTitle',
          userId: req.user?.id,
          duration: Date.now() - start,
          statusCode: 200,
          translatedLength: result.translated?.length ?? 0,
          model: result.model,
        },
        'Controller exit',
      );

      // Always 200 — caller treats null translated as soft fallback.
      res.status(200).json(result);
    } catch (e) {
      outcome = 'error';
      errorClass = errorType(e);
      req.logger.error(
        {
          action: 'ai.translateTitle',
          userId: req.user?.id,
          duration: Date.now() - start,
          errorType: errorClass,
        },
        'Controller error',
      );
      next(e);
    } finally {
      // Best-effort telemetry — don't await so the response stays fast.
      void recordAiTelemetry({
        promptId: PROMPT_ID,
        mode: 'title_translate',
        actorUserId: req.user?.id ?? null,
        entityType: null,
        entityId: null,
        language: body.target,
        provider: 'openai',
        modelUsed: 'gpt-4o-mini',
        tokensInput: null,
        tokensOutput: null,
        costUsdMicros: null,
        latencyMs: Date.now() - start,
        cacheHit: false,
        streamMode: false,
        outcome,
        errorClass,
      }).catch(() => undefined);
    }
  },
};
