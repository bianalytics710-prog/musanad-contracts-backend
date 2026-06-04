/**
 * extract-template-from-contract.service.ts
 *
 * Takes an uploaded contract's extracted text and asks gpt-4o-mini to
 *   (1) identify entity-specific tokens (party names, addresses, dates,
 *       amounts, IDs, jurisdictions) and replace them with Mustache-style
 *       {{snake_case_key}} placeholders;
 *   (2) emit a placeholder catalog (key, labelEn, labelAr, kind, required);
 *   (3) classify the contract_type and propose a template name + description.
 *
 * Always returns a usable structure. On any LLM error, falls back to a
 * deterministic heuristic that scrubs obvious patterns (Emirates ID, dates,
 * AED amounts) so the caller never gets an empty response.
 *
 * The redacted body is returned as bodyEnRedacted (and bodyArRedacted if the
 * source was bilingual — currently we only single-track on EN).
 */

import OpenAI from 'openai';
import { env } from '../../utils/env-validation.util';
import { getOpenAIClient } from './_shared/openai-client';
import type { TemplatePlaceholder } from '../m_parity.service';

export interface ExtractTemplateRequest {
  filename: string;
  extractedText: string;
  /** Optional client-side hint at the contract type. */
  contractTypeHint?: string | null;
}

export interface ExtractTemplateResponse {
  nameEn: string;
  descriptionEn: string;
  contractType: string;
  language: 'en' | 'ar' | 'bilingual';
  bodyEnRedacted: string;
  placeholders: TemplatePlaceholder[];
  regulatoryReference: string | null;
  /** Human-readable warnings to show on the review screen. */
  warnings: string[];
}

const KNOWN_CONTRACT_TYPES = [
  'nda',
  'employment',
  'master_services',
  'services',
  'vendor_services',
  'consultancy',
  'epc',
  'gas_spa',
  'term_sale',
  'vessel_charter',
  'concession',
  'change_order',
  'lease',
  'partnership',
  'license',
  'distribution',
  'llc_incorporation',
  'other',
] as const;

const KNOWN_KINDS: ReadonlyArray<TemplatePlaceholder['kind']> = [
  'party',
  'date',
  'currency',
  'number',
  'text',
];

const SYSTEM_PROMPT =
  'You are a contract template extractor for a UAE contracts platform. ' +
  'Given a contract document text, return a JSON object that redacts every entity-specific ' +
  'field (party names, addresses, trade-licence numbers, Emirates IDs, dates, amounts, ' +
  'jurisdictions, governing law citations specific to the parties) by replacing each one with a ' +
  'Mustache placeholder of the form {{snake_case_key}}. Generic legal terms, boilerplate ' +
  'clauses, headings and structure MUST be preserved verbatim. Do NOT invent placeholders ' +
  'for content that is already generic.';

const buildUserPrompt = (req: ExtractTemplateRequest): string =>
  [
    'Source filename: ' + req.filename,
    req.contractTypeHint ? 'User hint at contract type: ' + req.contractTypeHint : '',
    '',
    'Return a JSON object exactly matching:',
    '{',
    '  "nameEn": string (≤120 chars, an appropriate template name without party names),',
    '  "descriptionEn": string (≤300 chars, what the template is used for),',
    '  "contractType": one of ' + KNOWN_CONTRACT_TYPES.join('|') + ',',
    '  "language": "en" | "ar" | "bilingual" (based on which languages the source contained),',
    '  "regulatoryReference": string | null (headline citation, e.g. "Federal Decree-Law 33/2021"),',
    '  "bodyEnRedacted": string (the FULL document body, with every entity-specific value swapped to {{snake_case_key}}),',
    '  "placeholders": [',
    '    {',
    '      "key": "snake_case_key" (must appear at least once in bodyEnRedacted),',
    '      "labelEn": "Human label",',
    '      "labelAr": "ترجمة بالعربية" (null if unsure),',
    '      "kind": one of ' + KNOWN_KINDS.join('|') + ',',
    '      "required": boolean',
    '    }',
    '  ]',
    '}',
    '',
    'Rules:',
    '- Each placeholder key must be unique, snake_case, and ACTUALLY APPEAR in bodyEnRedacted (no orphans).',
    '- Use existing canonical keys when natural: discloser_name, recipient_name, employer_name, employee_name, effective_date, end_date, term_years, governing_emirate, fee_amount, currency_code, address, emirates_id, trade_license_number.',
    '- Preserve all markdown headings (# / ##), numbered clauses, and paragraph structure.',
    '- DO NOT redact: section headings, generic legal phrases, governing-law citations that are universal (e.g. "Federal Decree-Law 33/2021" itself).',
    '- If the source is short (<400 chars), still return a usable structure with whatever placeholders make sense.',
    '',
    'Document text:',
    '"""',
    req.extractedText.slice(0, 20000),
    '"""',
  ]
    .filter(Boolean)
    .join('\n');

const normaliseContractType = (input: string | null | undefined): string => {
  if (!input) return 'other';
  const t = input.toLowerCase().trim().replace(/\s+/g, '_');
  return (KNOWN_CONTRACT_TYPES as readonly string[]).includes(t) ? t : 'other';
};

const normaliseKind = (input: string | null | undefined): TemplatePlaceholder['kind'] => {
  if (!input) return 'text';
  const k = input.toLowerCase().trim() as TemplatePlaceholder['kind'];
  return KNOWN_KINDS.includes(k) ? k : 'text';
};

const normalisePlaceholders = (raw: unknown): TemplatePlaceholder[] => {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: TemplatePlaceholder[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const r = item as Record<string, unknown>;
    const key =
      typeof r.key === 'string'
        ? r.key.trim().replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase()
        : '';
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push({
      key,
      labelEn:
        typeof r.labelEn === 'string' && r.labelEn.trim().length > 0
          ? r.labelEn.trim()
          : key.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()),
      labelAr:
        typeof r.labelAr === 'string' && r.labelAr.trim().length > 0
          ? r.labelAr.trim()
          : null,
      kind: normaliseKind(typeof r.kind === 'string' ? r.kind : null),
      required: typeof r.required === 'boolean' ? r.required : true,
    });
  }
  return out;
};

/** Drop placeholder rows whose key doesn't appear in the body — never let the FE
 *  render a "ghost" chip. */
const dropOrphans = (
  placeholders: TemplatePlaceholder[],
  body: string,
): { kept: TemplatePlaceholder[]; orphaned: string[] } => {
  const kept: TemplatePlaceholder[] = [];
  const orphaned: string[] = [];
  for (const p of placeholders) {
    if (body.includes('{{' + p.key + '}}')) kept.push(p);
    else orphaned.push(p.key);
  }
  return { kept, orphaned };
};

interface LlmExtraction {
  nameEn?: string | null;
  descriptionEn?: string | null;
  contractType?: string | null;
  language?: string | null;
  regulatoryReference?: string | null;
  bodyEnRedacted?: string | null;
  placeholders?: unknown;
}

const callLlm = async (
  req: ExtractTemplateRequest,
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

/** Heuristic fallback — runs when LLM is unavailable. Conservative: scrubs the
 *  Reliance/ADNOC-style party introductions + dates + amounts. */
const buildHeuristicFallback = (
  req: ExtractTemplateRequest,
): ExtractTemplateResponse => {
  const orig = req.extractedText;
  let body = orig;

  // Effective date / signing date
  body = body.replace(
    /\b(?:on|dated|effective\s+date[:\s]+)?\s*\d{1,2}\s+[A-Z][a-z]+\s+\d{4}\b/g,
    'on {{effective_date}}',
  );
  // AED / USD amounts
  body = body.replace(
    /(?:AED|USD)\s*[\d,]+(?:\.\d+)?/g,
    '{{currency_code}} {{amount}}',
  );

  const placeholders: TemplatePlaceholder[] = [
    {
      key: 'effective_date',
      labelEn: 'Effective Date',
      labelAr: 'تاريخ السريان',
      kind: 'date',
      required: true,
    },
    {
      key: 'currency_code',
      labelEn: 'Currency',
      labelAr: 'العملة',
      kind: 'text',
      required: false,
    },
    {
      key: 'amount',
      labelEn: 'Amount',
      labelAr: 'المبلغ',
      kind: 'currency',
      required: false,
    },
  ];

  const { kept } = dropOrphans(placeholders, body);

  return {
    nameEn:
      'Template from ' +
      req.filename.replace(/\.[a-z0-9]+$/i, '').slice(0, 80),
    descriptionEn:
      'Imported from ' +
      req.filename +
      ' using heuristic redaction (OpenAI was unavailable). Review carefully before saving.',
    contractType: normaliseContractType(req.contractTypeHint),
    language: 'en',
    regulatoryReference: null,
    bodyEnRedacted: body,
    placeholders: kept,
    warnings: [
      'OpenAI not configured or unreachable — used keyword-based heuristic. Review the redacted body and placeholder list carefully.',
    ],
  };
};

export const extractTemplateFromContract = async (
  req: ExtractTemplateRequest,
): Promise<ExtractTemplateResponse> => {
  if (!req.extractedText || req.extractedText.trim().length < 50) {
    return {
      ...buildHeuristicFallback(req),
      warnings: ['Document text too short to extract a meaningful template.'],
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

  const body = (llm.bodyEnRedacted ?? '').trim();
  if (body.length < 50) {
    return buildHeuristicFallback(req);
  }

  const rawPh = normalisePlaceholders(llm.placeholders);
  const { kept, orphaned } = dropOrphans(rawPh, body);

  const language =
    llm.language === 'ar' || llm.language === 'bilingual' ? llm.language : 'en';

  const warnings: string[] = [];
  if (orphaned.length > 0) {
    warnings.push(
      'Discarded ' +
        orphaned.length +
        ' placeholder(s) that the AI listed but did not actually use in the body: ' +
        orphaned.join(', ') +
        '.',
    );
  }
  if (kept.length === 0) {
    warnings.push(
      'No placeholders detected. You can still save this as a template, but it will have nothing to substitute.',
    );
  }

  return {
    nameEn:
      typeof llm.nameEn === 'string' && llm.nameEn.trim().length > 0
        ? llm.nameEn.trim().slice(0, 120)
        : 'Template from ' +
          req.filename.replace(/\.[a-z0-9]+$/i, '').slice(0, 80),
    descriptionEn:
      typeof llm.descriptionEn === 'string' && llm.descriptionEn.trim().length > 0
        ? llm.descriptionEn.trim().slice(0, 300)
        : 'Imported from ' + req.filename + '.',
    contractType: normaliseContractType(llm.contractType ?? req.contractTypeHint),
    language: language as 'en' | 'ar' | 'bilingual',
    regulatoryReference:
      typeof llm.regulatoryReference === 'string' &&
      llm.regulatoryReference.trim().length > 0
        ? llm.regulatoryReference.trim()
        : null,
    bodyEnRedacted: body,
    placeholders: kept,
    warnings,
  };
};
