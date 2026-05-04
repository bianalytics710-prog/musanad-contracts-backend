/**
 * OpenAI streaming integration for the Signer Q&A endpoint (S12).
 *
 * Responsibilities:
 *   - Read prompt template from `prompts/ai-signer-qa.txt` (verbatim per G7)
 *   - Interpolate contract context + language at runtime
 *   - Stream chat completion tokens via the openai SDK
 *   - Yield deltas (string) for the controller to forward as SSE chunks
 *   - Return total tokens consumed (best-effort from upstream usage object)
 *
 * Sensitive data:
 *   - The system prompt + user message together form the `ai_prompt_payload`
 *     surface area (project.config.json sensitiveFields). NEVER log them at
 *     this layer. Pino redaction patterns also catch them at the controller
 *     boundary as a safety net.
 *   - Plaintext tokens (invitation, session) NEVER reach this module.
 *
 * Determinism:
 *   - `temperature` defaults to 0.4 (warm-but-precise per the prompt). The
 *     prompt itself enforces "max 100 words" + "non-advisory" boundaries.
 *   - `max_tokens` capped at 200 (AC-S12-06 defense-in-depth — well below
 *     the 100-word ceiling but allows whitespace/markdown).
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import OpenAI from 'openai';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import type { SignaturePublicView } from '../../types/signature.types';

// Module-level prompt cache. Loaded lazily on first invocation.
let _promptTemplate: string | null = null;

const PROMPT_RELATIVE_PATH = path.join('prompts', 'ai-signer-qa.txt');

/**
 * Load the verbatim prompt template (G7 — no modification of the prompt
 * text). The template uses Mustache-style {{placeholders}} which we
 * substitute at runtime with the contract context. We DO NOT use a real
 * templating library here because (a) the prompt set is small + stable, and
 * (b) anything that auto-escapes / re-encodes the prompt could violate G7.
 */
const loadPrompt = async (): Promise<string> => {
  if (_promptTemplate !== null) return _promptTemplate;
  const cwd = process.cwd();
  const fullPath = path.resolve(cwd, PROMPT_RELATIVE_PATH);
  const raw = await readFile(fullPath, 'utf-8');
  _promptTemplate = raw;
  return raw;
};

const renderTemplate = (
  template: string,
  vars: Record<string, string | number | null | undefined>,
): string => {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    const v = vars[key];
    if (v === null || v === undefined) return 'n/a';
    return String(v);
  });
};

/**
 * Build the system prompt for a given invitation context. Keeps the prompt
 * body byte-for-byte identical to the file on disk except where the
 * Mustache-style placeholders are replaced.
 */
export const buildSystemPrompt = async (
  view: SignaturePublicView,
): Promise<string> => {
  const tmpl = await loadPrompt();
  const langName = view.invitation.language === 'ar' ? 'Arabic' : 'English';
  // body excerpt is already truncated to 4000 chars by fn_ (DN-7).
  const bodyEn = view.contract.bodyEnExcerpt ?? '';
  return renderTemplate(tmpl, {
    contractNumber: view.contract.contractNumber,
    contractType: view.contract.contractType,
    titleEn: view.contract.titleEn,
    ourPartyNameEn: view.contract.ourPartyName,
    counterpartyNameEn: view.contract.counterpartyName ?? view.signer.nameEn,
    valueAed: view.contract.valueAed,
    startDate: view.contract.startDate,
    endDate: view.contract.endDate,
    aiSummaryEn: view.contract.aiSummaryEn ?? '(none)',
    bodyEn,
    langName,
  });
};

// ------------------------------------------------------------
// OpenAI client — lazy singleton
// ------------------------------------------------------------

let _client: OpenAI | null = null;
const getClient = (): OpenAI => {
  if (!_client) {
    const e = env();
    if (!e.OPENAI_API_KEY) {
      throw new Error('OPENAI_API_KEY is not configured — required for signer Q&A');
    }
    _client = new OpenAI({ apiKey: e.OPENAI_API_KEY });
  }
  return _client;
};

// ------------------------------------------------------------
// Streaming
// ------------------------------------------------------------

export interface StreamSignerQaArgs {
  systemPrompt: string;
  userMessage: string;
  /** Pass through invitation language so model picks reply language. */
  language: 'en' | 'ar';
  /** AbortSignal from the HTTP request — SSE drops if client disconnects. */
  abortSignal?: AbortSignal;
}

export interface StreamSignerQaResult {
  /** Async iterator of token deltas (strings). */
  stream: AsyncGenerator<string, void, void>;
  /** Promise that resolves to total tokens consumed once the stream completes. */
  tokensConsumed: () => number;
}

/**
 * Invoke OpenAI chat.completions with streaming enabled. Returns an async
 * iterator of `delta.content` strings + a `tokensConsumed()` accessor that
 * is final only after the iterator has been fully consumed.
 *
 * Errors propagate as exceptions out of the iterator. The controller is
 * responsible for emitting an SSE `error` chunk in that case.
 */
export const streamSignerQa = (args: StreamSignerQaArgs): StreamSignerQaResult => {
  let totalTokens = 0;
  const tokensConsumed = (): number => totalTokens;

  async function* iterate(): AsyncGenerator<string, void, void> {
    const e = env();
    const model = e.OPENAI_MODEL_DEFAULT;
    const client = getClient();

    const stream = await client.chat.completions.create(
      {
        model,
        // AC-S12-06 defense-in-depth: ~150 tokens ≈ 100 words.
        max_tokens: 200,
        temperature: 0.4,
        stream: true,
        stream_options: { include_usage: true },
        messages: [
          { role: 'system', content: args.systemPrompt },
          { role: 'user', content: args.userMessage },
        ],
      },
      args.abortSignal ? { signal: args.abortSignal } : undefined,
    );

    for await (const chunk of stream) {
      // Each chunk has choices[0].delta.content (token text) and may
      // include `usage` on the final chunk when stream_options.include_usage.
      const delta = chunk.choices[0]?.delta?.content;
      if (typeof delta === 'string' && delta.length > 0) {
        yield delta;
      }
      // The final chunk carries usage when include_usage=true. The OpenAI
      // SDK type defines `usage` on the chunk in stream-mode; we read
      // total_tokens defensively.
      const usage = (chunk as { usage?: { total_tokens?: number } }).usage;
      if (usage && typeof usage.total_tokens === 'number') {
        totalTokens = usage.total_tokens;
      }
    }

    // Fallback when upstream did not emit a usage chunk — log and use 0.
    if (totalTokens === 0) {
      logger.warn(
        { action: 'openaiSignerQa.usage_missing', model },
        'OpenAI stream completed without usage chunk; tokensConsumed=0 reported to fn_ COMMIT',
      );
    }
  }

  return {
    stream: iterate(),
    tokensConsumed,
  };
};
