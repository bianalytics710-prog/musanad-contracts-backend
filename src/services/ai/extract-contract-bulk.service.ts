/**
 * extract-contract-bulk.service.ts — M1c S8 AI extraction STUB.
 *
 * Pure deterministic mock that derives a contract-shaped response from the
 * input text length. M4 will REPLACE this entire file's body with a real
 * OpenAI / Anthropic call WITHOUT changing the function signature OR the
 * response shape (AC-S8-07).
 *
 * Determinism rule (Q3-OI-B / AC-S8-04): same input → same output. The
 * confidence formula and field heuristics are pure functions of
 * extractedText so S5 routing tests are repeatable.
 *
 * Confidence formula (Q3-OI-B finalised here):
 *   confidence = round( min(95, max(20, extractedText.length / 100)) )
 *
 *   - 50 chars  → 20  (low — manual entry track)
 *   - 5000 chars → 50 (medium — review queue)
 *   - 8000 chars → 80 (high — auto-save)
 *   - 9500+ chars → 95 (capped)
 *
 * Reference: see also .claude/workspace/extraction/prompts/extract-contract-bulk.txt
 * (extracted Lovable Gemini prompt) for parity expectations when M4 lands.
 */

import type {
  ExtractContractBulkRequest,
  ExtractContractBulkResponse,
} from '../../types/import-batch.types';

/** Inclusive lower / upper bounds on the deterministic confidence formula. */
const CONFIDENCE_FLOOR = 20;
const CONFIDENCE_CEILING = 95;

/**
 * Deterministically derive importConfidence from the raw text length.
 * Pure function — same input always yields the same integer.
 */
export const computeStubConfidence = (text: string): number => {
  const raw = text.length / 100;
  const clamped = Math.min(CONFIDENCE_CEILING, Math.max(CONFIDENCE_FLOOR, raw));
  return Math.round(clamped);
};

/** Lowercase keyword → contractType bucket. First match wins. */
const CONTRACT_TYPE_KEYWORDS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bemploy(ment|ee)\b/i, 'employment'],
  [/\bnda\b|non-?disclosure/i, 'nda'],
  [/\b(lease|tenancy)\b/i, 'lease'],
  [/\bpartnership\b/i, 'partnership'],
  [/\blicens(e|ing)\b/i, 'license'],
  [/\b(vendor|supplier)\b/i, 'vendor'],
  [/\bservice\b/i, 'service'],
];

/**
 * Pick a contractType bucket from the extracted text. Returns 'service' as
 * the default — matches the dominant M1a contract_type and keeps the stub
 * predictable for tests that don't care about the type.
 */
const inferContractType = (text: string): string => {
  for (const [pattern, type] of CONTRACT_TYPE_KEYWORDS) {
    if (pattern.test(text)) return type;
  }
  return 'service';
};

/**
 * Build a deterministic mock contract-extraction response.
 *
 * The response mirrors a M1a CreateContractDto fragment with the M1c
 * extraction metadata appended (importConfidence, importWarnings,
 * detectedDuplicateContractNumber). Optional fields the real AI would
 * detect (party ids, dates, value) are left undefined here — the FE bulk-
 * import flow + S6 review queue surface the partial extraction to the user
 * for inline edit.
 */
export const buildStubExtraction = (
  req: ExtractContractBulkRequest,
): ExtractContractBulkResponse => {
  const importConfidence = computeStubConfidence(req.extractedText);

  // Title: first 80 chars of the extracted text, single-line, trimmed.
  const titleEn = req.extractedText
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);

  const contractType = inferContractType(req.extractedText);

  return {
    titleEn,
    contractType,
    importConfidence,
    importWarnings: [
      'AI extraction is a deterministic mock in M1c — replace in M4 with real provider response.',
    ],
    detectedDuplicateContractNumber: null,
  };
};
