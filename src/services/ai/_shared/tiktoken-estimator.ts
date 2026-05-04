/**
 * Token estimator (heuristic).
 *
 * BE-OI-2 lesson from M3: M3's openai-signer-qa.service.ts used a +1
 * fallback when usage was missing from the OpenAI stream. M4 ships a
 * better-than-+1 estimator so cost telemetry stays meaningful even when
 * the upstream stream omits the usage chunk.
 *
 * Heuristic:
 *   tokens ≈ ceil(charLength / 4)
 *
 * The 4-chars-per-token approximation is OpenAI's published rule of thumb
 * for English. Arabic averages closer to ~6 char/token but the over-count
 * here is acceptable for cost-telemetry purposes (over-counts are safer
 * than under-counts for budget alerts).
 *
 * If `tiktoken` is later added as a dependency, swap the body of `estimate`
 * to `encoder.encode(text).length` — call sites stay unchanged.
 */

const CHARS_PER_TOKEN = 4;
const MIN_TOKENS = 1;

/**
 * Estimate the number of tokens consumed by a string. Returns at least 1.
 */
export const estimateTokens = (text: string | null | undefined): number => {
  if (!text) return MIN_TOKENS;
  const len = text.length;
  if (len === 0) return MIN_TOKENS;
  return Math.max(MIN_TOKENS, Math.ceil(len / CHARS_PER_TOKEN));
};

/**
 * Estimate (input, output) tokens. `prompt` is the full prompt sent to the
 * model (system + user + tool defs); `completion` is the model's reply.
 */
export const estimateUsage = (
  prompt: string,
  completion: string | null | undefined,
): { promptTokens: number; completionTokens: number; totalTokens: number } => {
  const promptTokens = estimateTokens(prompt);
  const completionTokens = estimateTokens(completion ?? '');
  return {
    promptTokens,
    completionTokens,
    totalTokens: promptTokens + completionTokens,
  };
};
