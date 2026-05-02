/**
 * AIProvider abstraction (decisions.md G7).
 *
 * Backed by OpenAI primary; Anthropic stub for future swap. Selected via
 * AI_PROVIDER env var. The 10 AI features in feature modules import from
 * here — they never instantiate provider clients directly.
 *
 * Singleton — `getAIProvider()` returns the same instance for the lifetime
 * of the process.
 */
import type { ZodSchema } from 'zod';
import { env } from '../../utils/env-validation.util';
import { OpenAIProvider } from './openai.provider';
import { AnthropicStubProvider } from './anthropic.provider';

export interface AIOpts {
  /** override env-default model — optional */
  model?: string;
  /** temperature 0-2, default 0.2 */
  temperature?: number;
  /** maxTokens (output cap), provider-specific default */
  maxTokens?: number;
  /** system / instructions prompt */
  system?: string;
  /** soft timeout (ms), provider may not honour */
  timeoutMs?: number;
  /** abort signal */
  signal?: AbortSignal;
}

export interface AIResponse {
  text: string;
  model: string;
  usage?: {
    promptTokens?: number;
    completionTokens?: number;
    totalTokens?: number;
  };
}

export interface AIProvider {
  readonly name: 'openai' | 'anthropic';
  generate(prompt: string, opts?: AIOpts): Promise<AIResponse>;
  generateJSON<T>(prompt: string, schema: ZodSchema<T>, opts?: AIOpts): Promise<T>;
  generateStream(prompt: string, opts?: AIOpts): AsyncIterable<string>;
}

let _instance: AIProvider | null = null;

export const getAIProvider = (): AIProvider => {
  if (_instance) return _instance;
  const e = env();
  if (e.AI_PROVIDER === 'anthropic') {
    _instance = new AnthropicStubProvider();
  } else {
    _instance = new OpenAIProvider();
  }
  return _instance;
};

/** Reset (used by tests). */
export const _resetAIProvider = (): void => {
  _instance = null;
};
