/**
 * analyze-template-upload.service.ts
 *
 * One-shot analyzer for "New Template — from a contract". Runs:
 *   1. extractTemplateFromContract → redacted body + placeholder catalog.
 *   2. extractClausesFromContract  → clause candidates.
 *   3. text-embedding-3-small      → embed the redacted body + each clause.
 *   4. fn_template_match_candidates → top N similar library templates.
 *   5. fn_clause_library_match_each → best library match per clause.
 *
 * Returns a single response shape the FE consumes to render the
 * match-decision step + clause cross-check card.
 *
 * Failure mode: embedding / DB match calls are wrapped — on failure the
 * response still includes the extracted template + clauses so the user can
 * fall back to the existing flow ("Save as new template").
 */

import { db } from '../../database/client';
import { getOpenAIClient } from './_shared/openai-client';
import {
  extractTemplateFromContract,
  type ExtractTemplateResponse,
} from './extract-template-from-contract.service';
import {
  extractClausesFromContract,
  type ClauseCandidate,
} from './extract-clauses-from-contract.service';
import { env } from '../../utils/env-validation.util';
import { logger } from '../../utils/logger.util';

const EMBED_MODEL = 'text-embedding-3-small';
const TEMPLATE_MATCH_LIMIT = 5;
const TEMPLATE_MATCH_MIN_SIMILARITY = 0.50;

export interface AnalyzeTemplateUploadRequest {
  actorId: number;
  filename: string;
  extractedText: string;
  contractTypeHint?: string | null;
}

export interface TemplateMatchRow {
  templateId: number;
  nameEn: string;
  nameAr: string | null;
  contractType: string;
  descriptionEn: string | null;
  /**
   * 0..1 cosine similarity of the uploaded body to this library template's
   * body embedding. Captures *structural* / boilerplate similarity — section
   * ordering, common phrases, scaffolding — not legal substance.
   *
   * Kept for backward compatibility. New code should prefer
   * `compositeScore`, which blends this with `clauseCoverage` so a
   * structurally-familiar contract with bespoke clauses no longer reads
   * as "85% match".
   */
  similarity: number;
  /**
   * v607 — composite match score = 0.4 × similarity (structure) +
   *   0.6 × clauseCoverage (substance). Only populated on the TOP row
   *   returned by analyzeTemplateUpload (other rows leave it null). FE
   *   pill should render this when present.
   */
  compositeScore?: number | null;
  /**
   * v607 — share of the uploaded contract's extracted clauses that
   * matched an existing library clause at or above the clauseMatch
   * threshold. 0..1. Only populated on the TOP row.
   */
  clauseCoverage?: number | null;
  /** v607 — total clauses extracted from the upload. Top row only. */
  clauseTotal?: number | null;
  /** v607 — number of those clauses found in the library. Top row only. */
  clauseKnown?: number | null;
  usageCount: number;
}

export interface ClauseCrossCheckRow extends ClauseCandidate {
  /** 0..1 cosine similarity to closest library clause; 0 if none. */
  bestSimilarity: number;
  bestMatchId: number | null;
  bestMatchTitle: string | null;
  bestMatchCategory: string | null;
  /** Convenience: bestSimilarity < clause-match-threshold ⇒ NEW. */
  isNewToLibrary: boolean;
}

export type MatchClassification = 'exact' | 'extend_candidate' | 'no_match';

export interface AnalyzeTemplateUploadResponse {
  /** The redacted-template extraction (unchanged shape from the existing flow). */
  template: ExtractTemplateResponse;
  /** Top template matches (>= extend threshold), or empty array. */
  templateMatches: TemplateMatchRow[];
  /** Convenience: classification derived from the top match. */
  topMatchClassification: MatchClassification;
  /** Configured thresholds — FE renders the % bands and chooses copy. */
  thresholds: {
    exact: number;
    extend: number;
    clauseMatch: number;
  };
  /** Each clause from the source + its closest library match + new/known flag. */
  clauseCrossCheck: ClauseCrossCheckRow[];
  /** Roll-up warnings to surface in the UI. */
  warnings: string[];
}

const toPgVector = (arr: number[]): string =>
  '[' + arr.map((x) => x.toFixed(8)).join(',') + ']';

async function embed(input: string): Promise<number[] | null> {
  const trimmed = input.slice(0, 24000);
  if (trimmed.trim().length === 0) return null;
  try {
    const openai = getOpenAIClient();
    const r = await openai.embeddings.create({
      model: EMBED_MODEL,
      input: trimmed,
    });
    return r.data[0]?.embedding ?? null;
  } catch (err) {
    logger.warn(
      {
        action: 'analyzeTemplateUpload.embed',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Embedding call failed (non-blocking)',
    );
    return null;
  }
}

// Defaults match the rows seeded by mig 575 system_setting. If you want to
// tune at runtime, switch this to read from fn_system_setting_list — the
// permission gate there is platform_admin only, so we'd need a side-car
// reader (out-of-scope for v1).
const DEFAULT_THRESHOLDS = { exact: 0.95, extend: 0.50, clauseMatch: 0.85 } as const;

/**
 * v607 — Composite-aware classifier.
 *
 * Before: classified using only `top.similarity` (the structure cosine).
 * That let a contract with familiar boilerplate but bespoke clauses earn
 * an 85% "exact / extend candidate" label.
 *
 * After: when `compositeScore` is populated, we classify against THAT.
 * Falls back to `similarity` for callers that bypass clause extraction
 * (e.g. OPENAI_API_KEY missing). Exact stays gated on the high bar so
 * the "duplicate" message only fires when both structure and clauses
 * strongly overlap.
 */
function classifyTopMatch(
  top: TemplateMatchRow | undefined,
  thresholds: { exact: number; extend: number },
): MatchClassification {
  if (!top) return 'no_match';
  const score = typeof top.compositeScore === 'number' ? top.compositeScore : top.similarity;
  if (score >= thresholds.exact) return 'exact';
  if (score >= thresholds.extend) return 'extend_candidate';
  return 'no_match';
}

export const analyzeTemplateUpload = async (
  req: AnalyzeTemplateUploadRequest,
): Promise<AnalyzeTemplateUploadResponse> => {
  const warnings: string[] = [];
  const thresholds = DEFAULT_THRESHOLDS;

  // (1) Template extraction — never fails (heuristic fallback inside).
  const template = await extractTemplateFromContract({
    filename: req.filename,
    extractedText: req.extractedText,
    contractTypeHint: req.contractTypeHint ?? null,
  });
  for (const w of template.warnings) warnings.push(w);

  // (2) Clause extraction — also resilient. Catch + degrade if it throws.
  let clauseCandidates: ClauseCandidate[] = [];
  try {
    const r = await extractClausesFromContract({
      filename: req.filename,
      extractedText: req.extractedText,
    });
    clauseCandidates = r.candidates;
    for (const w of r.warnings) warnings.push(w);
  } catch (err) {
    logger.warn(
      {
        action: 'analyzeTemplateUpload.extractClauses',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Clause extraction failed inside analyzer (non-blocking)',
    );
    warnings.push('Clause extraction failed — clause-library cross-check was skipped.');
  }

  // Short-circuit: if OPENAI key absent, skip embeddings + matches.
  const e = env();
  let templateMatches: TemplateMatchRow[] = [];
  let clauseCrossCheck: ClauseCrossCheckRow[] = clauseCandidates.map((c) => ({
    ...c,
    bestSimilarity: 0,
    bestMatchId: null,
    bestMatchTitle: null,
    bestMatchCategory: null,
    isNewToLibrary: true,
  }));

  if (!e.OPENAI_API_KEY) {
    warnings.push('OPENAI_API_KEY not configured — similarity matching skipped.');
    return {
      template,
      templateMatches,
      topMatchClassification: 'no_match',
      thresholds,
      clauseCrossCheck,
      warnings,
    };
  }

  // (3) Embed the template body — used for fn_template_match_candidates.
  const templateBodySource = `${template.nameEn}\n\n${template.bodyEnRedacted}`;
  const templateEmbedding = await embed(templateBodySource);

  // (4) Top-N library template matches.
  if (templateEmbedding) {
    try {
      const matchResp = await db.callFunction<{ data: TemplateMatchRow[] }>(
        'fn_template_match_candidates',
        [
          req.actorId,
          toPgVector(templateEmbedding),
          TEMPLATE_MATCH_LIMIT,
          TEMPLATE_MATCH_MIN_SIMILARITY,
        ],
        { actorId: req.actorId },
      );
      templateMatches = matchResp.data ?? [];
    } catch (err) {
      logger.warn(
        {
          action: 'analyzeTemplateUpload.templateMatch',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          errorMessage: err instanceof Error ? err.message : String(err),
        },
        'Template match query failed (non-blocking)',
      );
      warnings.push('Template similarity query failed — proceeding without matches.');
    }
  } else {
    warnings.push('Could not embed the uploaded template — similarity matching skipped.');
  }

  // (5) Embed each clause candidate + run fn_clause_library_match_each.
  if (clauseCandidates.length > 0) {
    const embedded: Array<{ idx: number; embedding: string | null }> = [];
    for (let i = 0; i < clauseCandidates.length; i++) {
      const c = clauseCandidates[i];
      const src = `${c.titleEn}\n\n${c.bodyEn}`;
      const emb = await embed(src);
      embedded.push({ idx: i, embedding: emb ? toPgVector(emb) : null });
    }
    try {
      const payload = embedded.map((e) => ({
        idx: e.idx,
        embedding: e.embedding,
      }));
      // callFunction auto-serialises arrays-of-objects to JSONB; passing the
      // raw array avoids double-encoding.
      const matches = await db.callFunction<{
        data: Array<{
          idx: number;
          matchId: number | null;
          matchTitle: string | null;
          matchCategory: string | null;
          similarity: number;
        }>;
      }>('fn_clause_library_match_each', [req.actorId, payload], {
        actorId: req.actorId,
      });
      const matchByIdx = new Map(matches.data.map((m) => [m.idx, m]));
      clauseCrossCheck = clauseCandidates.map((c, idx) => {
        const m = matchByIdx.get(idx);
        const sim = m ? Number(m.similarity) : 0;
        return {
          ...c,
          bestSimilarity: sim,
          bestMatchId: m?.matchId ?? null,
          bestMatchTitle: m?.matchTitle ?? null,
          bestMatchCategory: m?.matchCategory ?? null,
          isNewToLibrary: sim < thresholds.clauseMatch,
        };
      });
    } catch (err) {
      logger.warn(
        {
          action: 'analyzeTemplateUpload.clauseMatch',
          errorType: err instanceof Error ? err.name : 'UNKNOWN',
          errorMessage: err instanceof Error ? err.message : String(err),
        },
        'Clause match query failed (non-blocking)',
      );
      warnings.push('Clause-library cross-check failed — every clause is shown as new.');
    }
  }

  // v607 — composite score for the top template match.
  //
  // Mix:
  //   compositeScore = 0.4 × structureSim + 0.6 × clauseCoverage
  //
  // where clauseCoverage = (known library clauses) / (total extracted).
  // Clauses are weighted higher than structure because clauses carry the
  // legal substance — structure is scaffolding. Special cases:
  //   • Zero clauses extracted → fall back to structureSim (we have no
  //     clause signal to blend in).
  //   • No top template match → nothing to stamp.
  //   • OPENAI_API_KEY missing path also skips this branch — top would
  //     already be undefined or `similarity = 0`.
  const STRUCTURE_WEIGHT = 0.4;
  const CLAUSE_WEIGHT = 0.6;
  if (templateMatches.length > 0) {
    const top = templateMatches[0];
    const clauseTotal = clauseCrossCheck.length;
    const clauseKnown = clauseCrossCheck.filter((c) => !c.isNewToLibrary).length;
    const clauseCoverage = clauseTotal > 0 ? clauseKnown / clauseTotal : null;
    const composite =
      clauseCoverage === null
        ? top.similarity
        : STRUCTURE_WEIGHT * top.similarity + CLAUSE_WEIGHT * clauseCoverage;
    templateMatches[0] = {
      ...top,
      compositeScore: Number(composite.toFixed(4)),
      clauseCoverage: clauseCoverage === null ? null : Number(clauseCoverage.toFixed(4)),
      clauseTotal,
      clauseKnown,
    };
  }

  const topMatchClassification = classifyTopMatch(templateMatches[0], thresholds);

  return {
    template,
    templateMatches,
    topMatchClassification,
    thresholds,
    clauseCrossCheck,
    warnings,
  };
};
