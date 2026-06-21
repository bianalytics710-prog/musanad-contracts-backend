/**
 * extract-template-from-contract.service.ts
 *
 * Takes an uploaded contract's extracted text and asks gpt-4.1 to
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
 *
 * 2026-06-12 — Model + prompt overhaul. Was gpt-4o-mini with a 13-item
 * "canonical keys when natural" suggestion that biased the model toward a
 * generic services-style placeholder set regardless of input (an MNDA body
 * produced `service_provider_name` + `fee_amount` despite the text using
 * "Discloser" / "Recipient" and having no fee). The prompt and model are now
 * tuned for grounded extraction: gpt-4.1 reads the document and names each
 * placeholder after the role label the document actually uses. No canonical
 * key suggestions, no list to pattern-match into. Two contracts of the same
 * type with different content now produce different placeholder sets,
 * preserving the "mirror this specific document" intent of Compose-draft.
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
  /** Arabic template name — populated when the source is Arabic/bilingual, else null. */
  nameAr: string | null;
  descriptionEn: string;
  /** Arabic description — populated when the source is Arabic/bilingual, else null. */
  descriptionAr: string | null;
  contractType: string;
  language: 'en' | 'ar' | 'bilingual';
  bodyEnRedacted: string;
  /**
   * Redacted body in Arabic, carrying the SAME {{snake_case_key}} placeholders
   * as bodyEnRedacted. Populated when the source is Arabic/bilingual so the
   * editor's Arabic body field renders with content; null for English-only
   * sources. bodyEnRedacted always carries the English (translated) body so
   * downstream embedding/matching stays English-to-English.
   */
  bodyArRedacted: string | null;
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

// 2026-06-12 — Prompt rewritten for grounded extraction. The prior version
// handed the model a 13-item "canonical keys when natural" list which biased
// gpt-4o-mini to pattern-match into that list regardless of document content.
// The new prompt instead instructs the model to NAME each placeholder after
// the literal role label the document uses ("Discloser" → discloser_name;
// "Service Provider" → service_provider_name) and to skip anything that
// isn't actually in the body. No suggested key list, no canonical hint.
const SYSTEM_PROMPT =
  'You are a contract template extractor for a UAE contracts platform. Your job is to read a ' +
  'specific contract document and produce a redacted template that mirrors THAT document — not a ' +
  'generic template for its contract type. Two NDAs with different terms should produce different ' +
  'placeholder sets.\n\n' +
  'For every entity-specific value (party names, addresses, trade-licence numbers, Emirates IDs, ' +
  'dates, monetary amounts, terms in years, jurisdictions, party-specific governing-law citations) ' +
  'replace the value with a Mustache placeholder {{snake_case_key}}. Name each key after how the ' +
  'document itself refers to that role. For example, if the document says "Discloser" / ' +
  '"Recipient" use discloser_name / recipient_name; if it says "Service Provider" / "Client" use ' +
  'service_provider_name / client_name; if it says "Employer" / "Employee" use employer_name / ' +
  'employee_name; if it says "Contractor" / "Owner" use contractor_name / owner_name. Match the ' +
  'document.\n\n' +
  'Grounding rules:\n' +
  '- DO NOT invent placeholders for content that is not in the document. If the document never ' +
  'mentions a fee, do not emit fee_amount. If it never mentions a trade licence, do not emit ' +
  'trade_license_number. Every placeholder you emit must correspond to a literal value you can ' +
  'point to in the source text.\n' +
  '- DO NOT redact: section headings, generic legal phrases, universal statute citations (e.g. ' +
  '"Federal Decree-Law 33/2021"), or boilerplate that any contract of this type would carry.\n' +
  '- Preserve markdown headings (# / ##), numbered clauses, paragraph structure, and the order of ' +
  'the document.\n' +
  '- Distinguish placeholders that the drafter MUST fill (required=true) from those that are ' +
  'genuinely optional (required=false).\n\n' +
  'BILINGUAL OUTPUT — this platform is bilingual (English + Arabic):\n' +
  '- bodyEnRedacted must ALWAYS be the ENGLISH redacted body. If the source document is in ' +
  'Arabic, translate it faithfully and completely into English first, then redact. Never leave ' +
  'bodyEnRedacted empty and never put Arabic prose in it.\n' +
  '- When the source document is in Arabic or bilingual, ALSO return bodyArRedacted: the FULL ' +
  'Arabic redacted body, plus nameAr and descriptionAr. When the source is English-only, set ' +
  'bodyArRedacted, nameAr and descriptionAr to null.\n' +
  '- CRITICAL: use the EXACT SAME {{snake_case_key}} placeholder tokens (same keys, same spelling) ' +
  'in both bodyEnRedacted and bodyArRedacted, so a single placeholder catalog applies to both ' +
  'bodies. Keys are always lowercase ASCII snake_case regardless of document language.';

const buildUserPrompt = (req: ExtractTemplateRequest): string =>
  [
    'Source filename: ' + req.filename,
    req.contractTypeHint ? 'Source contract type (from our records): ' + req.contractTypeHint : '',
    '',
    'Read the document below carefully, then return a JSON object exactly matching:',
    '{',
    '  "nameEn": string (≤120 chars, a template name IN ENGLISH reflecting THIS document — no party names),',
    '  "nameAr": string | null (the template name in Arabic when the source is Arabic/bilingual; else null),',
    '  "descriptionEn": string (≤300 chars, what THIS template is for, in English),',
    '  "descriptionAr": string | null (the description in Arabic when the source is Arabic/bilingual; else null),',
    '  "contractType": one of ' + KNOWN_CONTRACT_TYPES.join('|') + ',',
    '  "language": "en" | "ar" | "bilingual",',
    '  "regulatoryReference": string | null (headline citation if the document carries one),',
    '  "bodyEnRedacted": string (the FULL document body IN ENGLISH — translate from Arabic if needed — with every entity-specific value swapped to {{snake_case_key}}),',
    '  "bodyArRedacted": string | null (the FULL document body in Arabic with the SAME {{snake_case_key}} tokens, when the source is Arabic/bilingual; else null),',
    '  "placeholders": [',
    '    {',
    '      "key": "snake_case_key" (named after the role the document uses; must appear in bodyEnRedacted),',
    '      "labelEn": "Human label",',
    '      "labelAr": "ترجمة بالعربية" (null if unsure),',
    '      "kind": one of ' + KNOWN_KINDS.join('|') + ',',
    '      "required": boolean',
    '    }',
    '  ]',
    '}',
    '',
    'Final checks before you respond:',
    '- Every placeholder key must be unique, snake_case, and ACTUALLY appear in bodyEnRedacted (and, when you return bodyArRedacted, in bodyArRedacted too — identical tokens in both).',
    '- Every placeholder you emit must be grounded in a specific span of the source text.',
    '- If the document is short (<400 chars), still return a usable structure with whatever ' +
      'placeholders are genuinely present.',
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
  nameAr?: string | null;
  descriptionEn?: string | null;
  descriptionAr?: string | null;
  contractType?: string | null;
  language?: string | null;
  regulatoryReference?: string | null;
  bodyEnRedacted?: string | null;
  bodyArRedacted?: string | null;
  placeholders?: unknown;
}

const callLlm = async (
  req: ExtractTemplateRequest,
  client: OpenAI,
): Promise<LlmExtraction> => {
  // 2026-06-12 — gpt-4.1 for grounded extraction. The prior gpt-4o-mini was
  // observed to pattern-match into a suggested canonical-key list (emitting
  // service_provider_name + fee_amount on an MNDA with no fee mention) — this
  // model + the rewritten prompt above name placeholders after the literal
  // role labels in the source document instead.
  const completion = await client.chat.completions.create({
    model: 'gpt-4.1',
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
    nameAr: null,
    descriptionEn:
      'Imported from ' +
      req.filename +
      ' using heuristic redaction (OpenAI was unavailable). Review carefully before saving.',
    descriptionAr: null,
    contractType: normaliseContractType(req.contractTypeHint),
    language: 'en',
    regulatoryReference: null,
    bodyEnRedacted: body,
    bodyArRedacted: null,
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

  const bodyAr =
    typeof llm.bodyArRedacted === 'string' && llm.bodyArRedacted.trim().length >= 50
      ? llm.bodyArRedacted.trim()
      : null;

  const rawPh = normalisePlaceholders(llm.placeholders);
  // A placeholder is legitimate if it appears in EITHER redacted body — the
  // same {{token}} should be present in both, but we union to be tolerant.
  const { kept, orphaned } = dropOrphans(rawPh, body + '\n' + (bodyAr ?? ''));

  const language =
    llm.language === 'ar' || llm.language === 'bilingual' ? llm.language : 'en';

  const warnings: string[] = [];
  if (language !== 'en' && !bodyAr) {
    warnings.push(
      'The document looks Arabic but the AI did not return an Arabic body — the Arabic body field may be empty. Review before saving.',
    );
  }
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
    nameAr:
      typeof llm.nameAr === 'string' && llm.nameAr.trim().length > 0
        ? llm.nameAr.trim().slice(0, 200)
        : null,
    descriptionEn:
      typeof llm.descriptionEn === 'string' && llm.descriptionEn.trim().length > 0
        ? llm.descriptionEn.trim().slice(0, 300)
        : 'Imported from ' + req.filename + '.',
    descriptionAr:
      typeof llm.descriptionAr === 'string' && llm.descriptionAr.trim().length > 0
        ? llm.descriptionAr.trim().slice(0, 2000)
        : null,
    contractType: normaliseContractType(llm.contractType ?? req.contractTypeHint),
    language: language as 'en' | 'ar' | 'bilingual',
    regulatoryReference:
      typeof llm.regulatoryReference === 'string' &&
      llm.regulatoryReference.trim().length > 0
        ? llm.regulatoryReference.trim()
        : null,
    bodyEnRedacted: body,
    bodyArRedacted: bodyAr,
    placeholders: kept,
    warnings,
  };
};
