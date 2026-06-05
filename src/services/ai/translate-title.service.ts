/**
 * translate-title.service.ts
 *
 * One-shot translation between EN ↔ AR for contract titles. Tight prompt,
 * `temperature: 0`, max ~100 tokens — cheap and fast (~150-300 ms p50).
 *
 * Used by /api/v1/ai/translate-title on Compose Step 2 to auto-fill the
 * Arabic title when the drafter blurs the English title. Never throws —
 * returns { translated: null } on any failure so the FE can fall back to
 * manual entry without surfacing a stack trace.
 */
import OpenAI from 'openai';
import { env } from '../../utils/env-validation.util';
import { getOpenAIClient } from './_shared/openai-client';
import { logger } from '../../utils/logger.util';

export type SupportedLang = 'en' | 'ar';

export interface TranslateTitleRequest {
  text: string;
  source: SupportedLang;
  target: SupportedLang;
}

export interface TranslateTitleResponse {
  translated: string | null;
  model: string | null;
  latencyMs: number;
  warnings: string[];
}

const MODEL = 'gpt-4o-mini';
const MAX_INPUT = 200; // contract titles — anything longer is almost certainly wrong input.

const SYSTEM_PROMPT =
  'You translate UAE contract titles between English and Arabic. Output ONLY ' +
  'the translation — no quotes, no explanation, no transliteration in brackets. ' +
  'Preserve proper nouns (company names, jurisdictions, regulator codes like ' +
  'MoHRE, DIFC, ADGM, Ejari) in their original form. Use formal UAE legal ' +
  'register. Do NOT add prefixes like "Contract:" or "Title:".';

const buildUserPrompt = (req: TranslateTitleRequest): string => {
  const dir = req.source === 'en' ? 'English → Arabic' : 'Arabic → English';
  return [
    `Translate the following contract title (${dir}):`,
    '',
    req.text.trim(),
  ].join('\n');
};

const callLlm = async (
  req: TranslateTitleRequest,
  client: OpenAI,
): Promise<string | null> => {
  const completion = await client.chat.completions.create({
    model: MODEL,
    temperature: 0,
    max_tokens: 120,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: buildUserPrompt(req) },
    ],
  });
  const raw = completion.choices[0]?.message?.content ?? '';
  // Strip stray wrapping quotes / labels the model sometimes emits.
  const cleaned = raw
    .trim()
    .replace(/^["'“”«»]+|["'“”«»]+$/g, '')
    .replace(/^(Title|العنوان|Contract|عقد)\s*[:\-—]\s*/i, '')
    .trim();
  return cleaned.length > 0 ? cleaned : null;
};

export const translateTitle = async (
  req: TranslateTitleRequest,
): Promise<TranslateTitleResponse> => {
  const start = Date.now();
  const warnings: string[] = [];

  const text = (req.text ?? '').trim();
  if (text.length === 0) {
    return { translated: null, model: null, latencyMs: 0, warnings: ['empty input'] };
  }
  if (text.length > MAX_INPUT) {
    return {
      translated: null,
      model: null,
      latencyMs: 0,
      warnings: [`input too long (>${MAX_INPUT} chars)`],
    };
  }
  if (req.source === req.target) {
    return { translated: text, model: null, latencyMs: 0, warnings: [] };
  }

  if (!env().OPENAI_API_KEY) {
    warnings.push('OPENAI_API_KEY not configured');
    return { translated: null, model: null, latencyMs: 0, warnings };
  }

  try {
    const translated = await callLlm({ ...req, text }, getOpenAIClient());
    return {
      translated,
      model: MODEL,
      latencyMs: Date.now() - start,
      warnings,
    };
  } catch (err) {
    logger.warn(
      {
        action: 'translateTitle',
        source: req.source,
        target: req.target,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'translateTitle LLM call failed (non-blocking)',
    );
    return {
      translated: null,
      model: MODEL,
      latencyMs: Date.now() - start,
      warnings: [...warnings, 'translation failed'],
    };
  }
};
