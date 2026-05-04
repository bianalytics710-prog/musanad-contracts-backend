/**
 * S2 — OpenAI integration for /api/v1/ai/drafting-assistant.
 *
 * Modes:
 *   - chat, explain, rewrite → SSE streaming
 *   - suggest                → non-streaming tool-call JSON (max 4 suggestions)
 *
 * EPHEMERAL — NO caching (Q4 lock — drafting assistant is interactive).
 *
 * Sensitive data:
 *   - selectedText, draftSummary, chatHistory[].content all flow through
 *     ai_prompt_payload — NEVER logged at controller. Pino redact safety net.
 */
import path from 'node:path';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';
import { InternalError, ValidationError } from '../../utils/errors.util';
import { getOpenAIClient } from './_shared/openai-client';
import { loadPrompt, renderPrompt } from './_shared/prompt-loader';
import { estimateUsage } from './_shared/tiktoken-estimator';
import { aiDraftingAssistantSuggestToolSchema } from '../../schemas/ai.schemas';
import type {
  AiDraftingAssistantChatTurn,
  AiDraftingAssistantMode,
  AiDraftingAssistantSuggestResponse,
  AiDraftingAssistantTone,
  AiLanguage,
} from '../../types/ai.types';

export const PROMPT_ID = 'ai-drafting-assistant' as const;
export const PROMPT_FILE = path.join('prompts', 'ai-drafting-assistant.txt');

export interface DraftingAssistantContext {
  mode: AiDraftingAssistantMode;
  contractType: string;
  partyA: string;
  partyB: string;
  draftSummary: string;
  existingClauseCategories: string[];
  language: AiLanguage;
  selectedText?: string;
  tone?: AiDraftingAssistantTone;
}

export const buildSystemPrompt = async (
  ctx: DraftingAssistantContext,
): Promise<string> => {
  const tmpl = await loadPrompt(PROMPT_ID);
  return renderPrompt(tmpl, {
    mode: ctx.mode,
    contractType: ctx.contractType,
    partyA: ctx.partyA,
    partyB: ctx.partyB || '(none)',
    draftSummary: ctx.draftSummary,
    existingClauseCategories: ctx.existingClauseCategories.join(', ') || '(none)',
    language: ctx.language,
    langName: ctx.language === 'ar' ? 'Arabic' : ctx.language === 'bilingual' ? 'Bilingual' : 'English',
    tone: ctx.tone ?? 'balanced',
    selectedText: ctx.selectedText ?? '',
  });
};

// ------------------------------------------------------------
// Streaming (chat / explain / rewrite)
// ------------------------------------------------------------

export interface StreamArgs {
  systemPrompt: string;
  /** For mode='chat' the controller composes from the request body. */
  userMessage: string;
  chatHistory?: AiDraftingAssistantChatTurn[];
  abortSignal?: AbortSignal;
}

export interface StreamResult {
  stream: AsyncGenerator<string, void, void>;
  tokensConsumed: () => number;
}

export const streamAssistant = (args: StreamArgs): StreamResult => {
  let totalTokens = 0;
  let collected = '';
  const tokensConsumed = (): number => totalTokens;

  async function* iterate(): AsyncGenerator<string, void, void> {
    const e = env();
    const model = e.OPENAI_MODEL_DEFAULT;
    const client = getOpenAIClient();

    const messages: Array<{ role: 'system' | 'user' | 'assistant'; content: string }> = [
      { role: 'system', content: args.systemPrompt },
    ];
    if (args.chatHistory && args.chatHistory.length > 0) {
      for (const turn of args.chatHistory) {
        messages.push({ role: turn.role, content: turn.content });
      }
    }
    messages.push({ role: 'user', content: args.userMessage });

    let stream;
    try {
      stream = await client.chat.completions.create(
        {
          model,
          temperature: 0.4,
          max_tokens: 4000,
          stream: true,
          stream_options: { include_usage: true },
          messages,
        },
        args.abortSignal ? { signal: args.abortSignal } : undefined,
      );
    } catch (err) {
      logger.error(
        {
          action: 'aiDraftingAssistant.stream_init_failed',
          model,
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
        },
        'OpenAI stream init failed',
      );
      throw new InternalError('AI provider error');
    }

    for await (const chunk of stream) {
      const delta = chunk.choices[0]?.delta?.content;
      if (typeof delta === 'string' && delta.length > 0) {
        collected += delta;
        yield delta;
      }
      const usage = (chunk as { usage?: { total_tokens?: number } }).usage;
      if (usage && typeof usage.total_tokens === 'number') {
        totalTokens = usage.total_tokens;
      }
    }

    if (totalTokens === 0) {
      const promptText = messages.map((m) => m.content).join('\n');
      const est = estimateUsage(promptText, collected);
      totalTokens = est.totalTokens;
    }
  }

  return { stream: iterate(), tokensConsumed };
};

// ------------------------------------------------------------
// Non-streaming suggest (tool call)
// ------------------------------------------------------------

export interface SuggestResult {
  payload: AiDraftingAssistantSuggestResponse;
  tokensInput: number;
  tokensOutput: number;
  modelUsed: string;
}

export const suggestClauses = async (args: {
  systemPrompt: string;
  userMessage: string;
  abortSignal?: AbortSignal;
}): Promise<SuggestResult> => {
  const e = env();
  const model = e.OPENAI_MODEL_DEFAULT;
  const client = getOpenAIClient();
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model,
        temperature: 0.4,
        max_tokens: 4000,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: args.systemPrompt },
          { role: 'user', content: args.userMessage },
        ],
      },
      args.abortSignal ? { signal: args.abortSignal } : undefined,
    );
  } catch (err) {
    logger.error(
      {
        action: 'aiDraftingAssistant.suggest_failed',
        model,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'OpenAI suggest call failed',
    );
    throw new InternalError('AI provider error');
  }
  const raw = completion.choices[0]?.message?.content ?? '';
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ValidationError('AI response was not valid JSON');
  }
  const validated = aiDraftingAssistantSuggestToolSchema.safeParse(parsed);
  if (!validated.success) {
    throw new ValidationError('AI response did not match suggest schema');
  }

  const promptTokens = completion.usage?.prompt_tokens;
  const completionTokens = completion.usage?.completion_tokens;
  const tokensInput =
    typeof promptTokens === 'number'
      ? promptTokens
      : estimateUsage(args.systemPrompt + args.userMessage, '').promptTokens;
  const tokensOutput =
    typeof completionTokens === 'number'
      ? completionTokens
      : estimateUsage('', raw).completionTokens;

  return {
    payload: { suggestions: validated.data.suggestions },
    tokensInput,
    tokensOutput,
    modelUsed: model,
  };
};
