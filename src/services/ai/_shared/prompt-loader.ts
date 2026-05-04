/**
 * M4 G7-compliant prompt loader.
 *
 * Reads prompt files VERBATIM from `prompts/<promptId>.txt` and substitutes
 * Mustache-style {{placeholder}} tokens at runtime. NEVER modifies the
 * prompt text — Lovable's prompts are the canonical AI artifacts, copied
 * byte-for-byte by Agent 7 from the extraction workspace.
 *
 * Mirrors the M3 loader in services/ai/openai-signer-qa.service.ts but is
 * shared across all 6 M4 prompts. Module-level cache: each prompt is read
 * once per process lifetime.
 *
 * Substitution policy (matches M3):
 *   - {{key}}   → value lookup in `vars`. Missing key → 'n/a'. NULL / undefined → 'n/a'.
 *   - Numbers + Dates are stringified via String(...).
 *   - Pure-data templating: NO HTML escaping (prompts are sent to OpenAI verbatim
 *     — escaping would corrupt the model's input).
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { M4PromptId } from '../../../types/ai.types';

type Stringable = string | number | boolean | null | undefined | Date;

const _cache = new Map<string, string>();

/**
 * Resolve the absolute prompt file path. Prompts live under <cwd>/prompts/
 * — same convention as M3.
 */
const promptPath = (promptId: M4PromptId | string): string =>
  path.resolve(process.cwd(), 'prompts', `${promptId}.txt`);

/**
 * Load the verbatim prompt template. Cached per process. Throws if the file
 * is missing — controllers map to 500.
 */
export const loadPrompt = async (promptId: M4PromptId | string): Promise<string> => {
  const key = String(promptId);
  const cached = _cache.get(key);
  if (cached !== undefined) return cached;
  const fullPath = promptPath(key);
  const raw = await readFile(fullPath, 'utf-8');
  _cache.set(key, raw);
  return raw;
};

/**
 * Render a template by substituting {{key}} placeholders. Pure-data; no
 * escaping. Missing keys collapse to 'n/a' so the prompt remains valid input
 * for OpenAI even when optional context fields are absent.
 */
export const renderPrompt = (
  template: string,
  vars: Record<string, Stringable>,
): string =>
  template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => {
    const v = vars[key];
    if (v === null || v === undefined) return 'n/a';
    if (v instanceof Date) return v.toISOString();
    return String(v);
  });

/** Test-only: reset the prompt cache. */
export const __resetPromptCacheForTests = (): void => {
  _cache.clear();
};
