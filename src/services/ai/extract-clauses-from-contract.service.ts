/**
 * extract-clauses-from-contract.service.ts
 *
 * Takes an uploaded contract's extracted text and asks gpt-4o-mini to
 * identify each substantive clause and return them as a list of clause
 * candidates the user can multi-select to add to the Clause Library.
 *
 * Each candidate has: category, titleEn, bodyEn, variant suggestion, optional
 * titleAr/bodyAr, optional legalCommentaryEn, optional regulatoryRefs.
 *
 * Always returns a usable structure. On LLM failure, falls back to a
 * heuristic that splits the body on numbered headings so the user can still
 * cherry-pick.
 */

import OpenAI from 'openai';
import { env } from '../../utils/env-validation.util';
import { getOpenAIClient } from './_shared/openai-client';

export interface ExtractClausesRequest {
  filename: string;
  extractedText: string;
}

export type ClauseVariant = 'standard' | 'alternative' | 'fallback';

export interface ClauseCandidate {
  category: string;
  titleEn: string;
  titleAr: string | null;
  bodyEn: string;
  bodyAr: string | null;
  variant: ClauseVariant;
  legalCommentaryEn: string | null;
  regulatoryRefs: string[];
}

export interface ExtractClausesResponse {
  candidates: ClauseCandidate[];
  warnings: string[];
}

// Aligned with the seed categories so the LLM stays in-vocabulary. Adding
// "other" as a safety valve for genuinely novel categories.
const KNOWN_CATEGORIES = [
  'assignment',
  'confidentiality',
  'data_protection',
  'definitions',
  'dispute_resolution',
  'force_majeure',
  'governing_law',
  'indemnity',
  'insurance',
  'intellectual_property',
  'liability',
  'non_compete',
  'notice',
  'payment',
  'representations',
  'severability',
  'term',
  'termination',
  'warranties',
  'other',
] as const;

const KNOWN_VARIANTS: ReadonlyArray<ClauseVariant> = [
  'standard',
  'alternative',
  'fallback',
];

const SYSTEM_PROMPT =
  'You are a contract clause extractor for a UAE contracts platform. ' +
  'Given a contract document text, identify each substantive clause and return ' +
  'them as a JSON array. Treat each numbered or titled section as one candidate. ' +
  'Skip preambles, signature blocks, party identification, recitals, and ' +
  'schedules — only return actual operative clauses. Preserve the original ' +
  'clause wording verbatim in bodyEn; do not paraphrase or rewrite. Identify ' +
  'the regulatory category the clause belongs to using ONLY the controlled ' +
  'vocabulary provided.';

const buildUserPrompt = (req: ExtractClausesRequest): string =>
  [
    'Source filename: ' + req.filename,
    '',
    'Return a JSON object exactly matching:',
    '{',
    '  "candidates": [',
    '    {',
    '      "category": one of ' + KNOWN_CATEGORIES.join('|') + ',',
    '      "titleEn": string (≤120 chars, short clause heading),',
    '      "titleAr": string | null (Arabic title if present in source),',
    '      "bodyEn": string (the full verbatim clause text in English),',
    '      "bodyAr": string | null (Arabic body if present in source),',
    '      "variant": "standard" | "alternative" | "fallback" (default "standard"),',
    '      "legalCommentaryEn": string | null (≤500 chars, one-paragraph practitioner note — optional),',
    '      "regulatoryRefs": string[] (UAE federal law citations referenced by this clause, e.g. ["Federal Decree-Law 33/2021"])',
    '    }',
    '  ]',
    '}',
    '',
    'Rules:',
    '- bodyEn must be the ORIGINAL clause text, verbatim. Do not summarise, paraphrase, or rewrite.',
    '- If a clause is short (one sentence), still include it as a candidate.',
    '- If a section is purely formatting (e.g. just "SCHEDULE B"), skip it.',
    '- variant is your judgement call: "standard" for the common-case wording, "alternative" for a notably looser/tighter formulation, "fallback" for last-resort wording.',
    '- regulatoryRefs should only contain headline citations that ALREADY APPEAR in the clause text.',
    '- Cap at 30 candidates total. Prefer quality over quantity.',
    '',
    'Document text:',
    '"""',
    req.extractedText.slice(0, 30000),
    '"""',
  ].join('\n');

const normaliseCategory = (input: unknown): string => {
  if (typeof input !== 'string') return 'other';
  const t = input.toLowerCase().trim().replace(/[\s-]+/g, '_');
  return (KNOWN_CATEGORIES as readonly string[]).includes(t) ? t : 'other';
};

const normaliseVariant = (input: unknown): ClauseVariant => {
  if (typeof input !== 'string') return 'standard';
  const v = input.toLowerCase().trim() as ClauseVariant;
  return KNOWN_VARIANTS.includes(v) ? v : 'standard';
};

const normaliseStringList = (raw: unknown, max: number): string[] => {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== 'string') continue;
    const t = item.trim();
    if (!t) continue;
    if (out.includes(t)) continue;
    out.push(t.slice(0, 120));
    if (out.length >= max) break;
  }
  return out;
};

const normaliseCandidates = (raw: unknown): ClauseCandidate[] => {
  if (!Array.isArray(raw)) return [];
  const out: ClauseCandidate[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const r = item as Record<string, unknown>;
    const titleEn = typeof r.titleEn === 'string' ? r.titleEn.trim() : '';
    const bodyEn = typeof r.bodyEn === 'string' ? r.bodyEn.trim() : '';
    if (titleEn.length === 0 || bodyEn.length < 20) continue;
    out.push({
      category: normaliseCategory(r.category),
      titleEn: titleEn.slice(0, 200),
      titleAr:
        typeof r.titleAr === 'string' && r.titleAr.trim().length > 0
          ? r.titleAr.trim().slice(0, 200)
          : null,
      bodyEn: bodyEn.slice(0, 50000),
      bodyAr:
        typeof r.bodyAr === 'string' && r.bodyAr.trim().length > 0
          ? r.bodyAr.trim().slice(0, 50000)
          : null,
      variant: normaliseVariant(r.variant),
      legalCommentaryEn:
        typeof r.legalCommentaryEn === 'string' &&
        r.legalCommentaryEn.trim().length > 0
          ? r.legalCommentaryEn.trim().slice(0, 2000)
          : null,
      regulatoryRefs: normaliseStringList(r.regulatoryRefs, 10),
    });
    if (out.length >= 30) break;
  }
  return out;
};

interface LlmExtraction {
  candidates?: unknown;
}

const callLlm = async (
  req: ExtractClausesRequest,
  client: OpenAI,
): Promise<LlmExtraction> => {
  const completion = await client.chat.completions.create({
    model: 'gpt-4o-mini',
    response_format: { type: 'json_object' },
    temperature: 0,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: buildUserPrompt(req) },
    ],
  });
  const raw = completion.choices[0]?.message?.content ?? '{}';
  return JSON.parse(raw) as LlmExtraction;
};

/**
 * Heuristic fallback — splits body on numbered headings (1., 2.1, ARTICLE N).
 * Coarse but lets the user still cherry-pick when the LLM is unavailable.
 */
const buildHeuristicFallback = (
  req: ExtractClausesRequest,
): ExtractClausesResponse => {
  const text = req.extractedText;
  // Split on a leading number-then-dot or on ARTICLE/SECTION headings.
  const parts = text.split(/(?=^\s*(?:\d+\.|ARTICLE\s+[IVX0-9]+|SECTION\s+\d+)\b)/im);
  const candidates: ClauseCandidate[] = [];
  for (const raw of parts) {
    const body = raw.trim();
    if (body.length < 60) continue;
    // First non-empty line up to 120 chars becomes the title.
    const firstLine = body.split(/\r?\n/)[0]?.trim() ?? '';
    const title = firstLine.slice(0, 120) || 'Untitled clause';
    candidates.push({
      category: 'other',
      titleEn: title,
      titleAr: null,
      bodyEn: body.slice(0, 50000),
      bodyAr: null,
      variant: 'standard',
      legalCommentaryEn: null,
      regulatoryRefs: [],
    });
    if (candidates.length >= 30) break;
  }
  return {
    candidates,
    warnings: [
      'OpenAI not configured or unreachable — used heading-based heuristic. Categories will all be "other"; review and re-categorise before saving.',
    ],
  };
};

export const extractClausesFromContract = async (
  req: ExtractClausesRequest,
): Promise<ExtractClausesResponse> => {
  if (!req.extractedText || req.extractedText.trim().length < 100) {
    return {
      candidates: [],
      warnings: ['Document text too short to extract clauses meaningfully.'],
    };
  }
  const e = env();
  if (!e.OPENAI_API_KEY) {
    return buildHeuristicFallback(req);
  }

  let llm: LlmExtraction;
  try {
    llm = await callLlm(req, getOpenAIClient());
  } catch {
    return buildHeuristicFallback(req);
  }

  const candidates = normaliseCandidates(llm.candidates);
  const warnings: string[] = [];
  if (candidates.length === 0) {
    return {
      ...buildHeuristicFallback(req),
      warnings: [
        'AI returned no usable clauses — fell back to heading-based heuristic.',
      ],
    };
  }
  if (candidates.filter((c) => c.category === 'other').length > candidates.length / 2) {
    warnings.push(
      'More than half of the detected clauses defaulted to category "other" — review categorisation before saving.',
    );
  }
  return { candidates, warnings };
};
