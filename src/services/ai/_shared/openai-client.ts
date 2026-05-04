/**
 * Shared OpenAI client — lazy singleton.
 *
 * M3 introduced openai-signer-qa.service.ts which built its own per-module
 * client (3-cron / 3-instance generalization threshold reached). Per DN-5 of
 * M4 db-design.md and the Q2 lock (per-prompt service modules), M4 services
 * still own their tactical concerns (max_tokens, response_format, streaming
 * vs non-streaming) but share the OpenAI SDK instance.
 *
 * Sensitive data:
 *   - API key sourced from env() — not logged here. logger.util.ts redacts
 *     openaiApiKey / openai_api_key universally.
 */
import OpenAI from 'openai';
import { env } from '../../../utils/env-validation.util';
import { InternalError } from '../../../utils/errors.util';

let _client: OpenAI | null = null;

/**
 * Get the shared OpenAI client. Throws InternalError if OPENAI_API_KEY is
 * not configured — controllers map this to a 500 with a sanitized message.
 */
export const getOpenAIClient = (): OpenAI => {
  if (!_client) {
    const e = env();
    if (!e.OPENAI_API_KEY) {
      throw new InternalError('OPENAI_API_KEY is not configured');
    }
    _client = new OpenAI({ apiKey: e.OPENAI_API_KEY });
  }
  return _client;
};

/** Reset the cached client (test-only utility). */
export const __resetOpenAIClientForTests = (): void => {
  _client = null;
};
