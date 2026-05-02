/**
 * OpenAI implementation of AIProvider.
 *
 * Uses the official `openai` npm package. Streaming via SSE (server-sent
 * events) is supported for /api/ai/signer-qa-style endpoints — yields raw
 * delta chunks as strings.
 */
import OpenAI from 'openai';
import type { ZodSchema } from 'zod';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError, ValidationError } from '../../utils/errors.util';
import type { AIOpts, AIProvider, AIResponse } from './index';

export class OpenAIProvider implements AIProvider {
  public readonly name = 'openai' as const;
  private client: OpenAI;
  private defaultModel: string;
  private fastModel: string;

  constructor() {
    const e = env();
    if (!e.OPENAI_API_KEY) {
      throw new InternalError('OPENAI_API_KEY not configured');
    }
    this.client = new OpenAI({ apiKey: e.OPENAI_API_KEY });
    this.defaultModel = e.OPENAI_MODEL_DEFAULT;
    this.fastModel = e.OPENAI_MODEL_FAST;
  }

  async generate(prompt: string, opts: AIOpts = {}): Promise<AIResponse> {
    const model = opts.model ?? this.defaultModel;
    try {
      const completion = await this.client.chat.completions.create(
        {
          model,
          temperature: opts.temperature ?? 0.2,
          ...(opts.maxTokens ? { max_tokens: opts.maxTokens } : {}),
          messages: [
            ...(opts.system ? [{ role: 'system' as const, content: opts.system }] : []),
            { role: 'user', content: prompt },
          ],
        },
        opts.signal ? { signal: opts.signal } : undefined,
      );

      const text = completion.choices[0]?.message?.content ?? '';
      const result: AIResponse = { text, model };
      if (completion.usage) {
        result.usage = {
          promptTokens: completion.usage.prompt_tokens,
          completionTokens: completion.usage.completion_tokens,
          totalTokens: completion.usage.total_tokens,
        };
      }
      return result;
    } catch (err) {
      logger.error(
        {
          action: 'ai.openai.generate_failed',
          model,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'OpenAI generate failed',
      );
      throw new InternalError('AI provider error');
    }
  }

  async generateJSON<T>(
    prompt: string,
    schema: ZodSchema<T>,
    opts: AIOpts = {},
  ): Promise<T> {
    const model = opts.model ?? this.defaultModel;
    try {
      const completion = await this.client.chat.completions.create(
        {
          model,
          temperature: opts.temperature ?? 0,
          ...(opts.maxTokens ? { max_tokens: opts.maxTokens } : {}),
          response_format: { type: 'json_object' },
          messages: [
            ...(opts.system
              ? [{ role: 'system' as const, content: opts.system }]
              : [
                  {
                    role: 'system' as const,
                    content:
                      'You return STRICT JSON only — no commentary, no markdown fences.',
                  },
                ]),
            { role: 'user', content: prompt },
          ],
        },
        opts.signal ? { signal: opts.signal } : undefined,
      );

      const raw = completion.choices[0]?.message?.content ?? '';
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        throw new ValidationError('AI response was not valid JSON');
      }
      const result = schema.safeParse(parsed);
      if (!result.success) {
        throw new ValidationError('AI response did not match expected schema');
      }
      return result.data;
    } catch (err) {
      if (err instanceof ValidationError) throw err;
      logger.error(
        {
          action: 'ai.openai.generateJSON_failed',
          model,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'OpenAI generateJSON failed',
      );
      throw new InternalError('AI provider error');
    }
  }

  async *generateStream(prompt: string, opts: AIOpts = {}): AsyncIterable<string> {
    const model = opts.model ?? this.fastModel;
    try {
      const stream = await this.client.chat.completions.create(
        {
          model,
          temperature: opts.temperature ?? 0.2,
          ...(opts.maxTokens ? { max_tokens: opts.maxTokens } : {}),
          stream: true,
          messages: [
            ...(opts.system ? [{ role: 'system' as const, content: opts.system }] : []),
            { role: 'user', content: prompt },
          ],
        },
        opts.signal ? { signal: opts.signal } : undefined,
      );
      for await (const chunk of stream) {
        const delta = chunk.choices[0]?.delta?.content;
        if (typeof delta === 'string' && delta.length > 0) {
          yield delta;
        }
      }
    } catch (err) {
      logger.error(
        {
          action: 'ai.openai.stream_failed',
          model,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'OpenAI stream failed',
      );
      throw new InternalError('AI provider error');
    }
  }
}
