/**
 * Anthropic stub. Future swap for OpenAI primary (decisions.md G7).
 *
 * The `@anthropic-ai/sdk` package is installed (so types resolve and a
 * future implementer doesn't need to touch package.json), but no live
 * calls are wired. All methods throw NotImplementedError so a misconfigured
 * AI_PROVIDER=anthropic deployment fails fast and obviously.
 *
 * MIGRATION CHECKLIST (when enabling Anthropic):
 *   1. Set ANTHROPIC_API_KEY in env.
 *   2. Set ANTHROPIC_MODEL_DEFAULT=claude-sonnet-4-6 (or current production model).
 *   3. Set ANTHROPIC_MODEL_FAST=claude-haiku-4-5-20251001 (or current fast tier).
 *   4. Replace each `throw new NotImplementedError(...)` below with the real
 *      Anthropic Messages-API call. Map prompt → messages[].content blocks.
 *   5. Update generateJSON to use Anthropic's tool-use schema enforcement
 *      OR fall back to JSON-mode prompting + zod validation.
 *   6. Update generateStream to use Anthropic's SSE stream — different
 *      delta event shape than OpenAI.
 *   7. Update README.md "Stack" table.
 */
import type { ZodSchema } from 'zod';
import { NotImplementedError } from '../../utils/errors.util';
import type { AIOpts, AIProvider, AIResponse } from './index';

export class AnthropicStubProvider implements AIProvider {
  public readonly name = 'anthropic' as const;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async generate(_prompt: string, _opts: AIOpts = {}): Promise<AIResponse> {
    throw new NotImplementedError(
      'Anthropic provider is stubbed. Set AI_PROVIDER=openai or implement anthropic.provider.ts.',
    );
  }

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async generateJSON<T>(
    _prompt: string,
    _schema: ZodSchema<T>,
    _opts: AIOpts = {},
  ): Promise<T> {
    throw new NotImplementedError(
      'Anthropic provider is stubbed. Set AI_PROVIDER=openai or implement anthropic.provider.ts.',
    );
  }

  // eslint-disable-next-line require-yield, @typescript-eslint/no-unused-vars
  async *generateStream(_prompt: string, _opts: AIOpts = {}): AsyncIterable<string> {
    throw new NotImplementedError(
      'Anthropic provider is stubbed. Set AI_PROVIDER=openai or implement anthropic.provider.ts.',
    );
  }
}
