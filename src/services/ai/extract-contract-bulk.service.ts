/**
 * extract-contract-bulk.service.ts — M1c S8 → M4-replaced.
 *
 * Real OpenAI extraction for the bulk-import flow. Replaces the original
 * M1c deterministic mock without changing the DTO contract (AC-S8-07).
 *
 *   POST /api/v1/ai/extract-contract-bulk → extractContractData()
 *
 * Pipeline:
 *   1. If OPENAI_API_KEY is set, call gpt-4o-mini with response_format=json
 *      to pull title / contractType / counterpartyName / dates / value /
 *      governingLaw / emirate from the extracted document text. Always set
 *      bodyEn to the full extracted text (we don't ask the LLM to summarise —
 *      preserving the original body matters for downstream signing + audit).
 *   2. Resolve counterpartyName → counterpartyId via party.name_en /
 *      aliases. No fuzzy matching; ILIKE substring only, single best row.
 *   3. If OPENAI_API_KEY is absent OR the LLM call errors out, fall back to
 *      a heuristic stub (slightly smarter than the original — NDA detection
 *      runs before employment so the Reliance/Indian-Ocean NDA stops landing
 *      as an employment stub).
 *
 * Sensitive logging:
 *   The request body field extractedText is treated as ai_prompt_payload
 *   per project.config.json sensitiveFields. We pass derived metadata only
 *   into req.logger; the LLM response is never echoed verbatim into logs.
 */

import OpenAI from 'openai';
import type {
  ExtractContractBulkRequest,
  ExtractContractBulkResponse,
} from '../../types/import-batch.types';
import { env } from '../../utils/env-validation.util';
import { getOpenAIClient } from './_shared/openai-client';
import { pool } from '../../database/config';

const CONFIDENCE_FLOOR = 20;
const CONFIDENCE_CEILING = 95;

/** Pure function — same input always yields the same integer. */
export const computeStubConfidence = (text: string): number => {
  const raw = text.length / 100;
  const clamped = Math.min(CONFIDENCE_CEILING, Math.max(CONFIDENCE_FLOOR, raw));
  return Math.round(clamped);
};

// NDA detection runs BEFORE employment now — the original ordering misfired
// when an NDA clause referenced "employees" inside its need-to-know list.
const CONTRACT_TYPE_KEYWORDS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bnda\b|non[\s-]?disclosure|confidentiality agreement/i, 'nda'],
  [/\bepc\b|engineering[ ,]+procurement[ ,]+and[ ,]+construction/i, 'epc'],
  [/master[\s-]+services agreement|\bmsa\b/i, 'master_services'],
  [/time[\s-]+charter|vessel charter|\bvlcc\b|\btankers?\b/i, 'vessel_charter'],
  [/concession agreement/i, 'concession'],
  [/term sale|crude (sale|spot)|\bspot purchase\b/i, 'term_sale'],
  [/\blng\b|gas (sales|spa)|gas[\s-]+supply/i, 'gas_spa'],
  [/change[\s-]order/i, 'change_order'],
  [/employment agreement|employment contract|\bemployee handbook\b/i, 'employment'],
  [/\b(lease|tenancy)\b/i, 'lease'],
  [/\bpartnership\b/i, 'partnership'],
  [/\blicens(e|ing)\b/i, 'license'],
  [/\b(vendor|supplier)\b/i, 'vendor'],
  [/\bservice\b/i, 'services'],
];

const inferContractType = (text: string): string => {
  for (const [pattern, type] of CONTRACT_TYPE_KEYWORDS) {
    if (pattern.test(text)) return type;
  }
  return 'services';
};

/** Allow-list passed to the LLM and used to normalise its response. */
const KNOWN_CONTRACT_TYPES = [
  'nda',
  'employment',
  'master_services',
  'services',
  'epc',
  'gas_spa',
  'term_sale',
  'vessel_charter',
  'concession',
  'change_order',
  'lease',
  'partnership',
  'license',
  'vendor',
  'other',
] as const;

const KNOWN_GOVERNING_LAWS = [
  'uae_federal',
  'dubai',
  'abu_dhabi',
  'sharjah',
  'difc',
  'adgm',
  'english',
  'other',
] as const;

interface LlmExtraction {
  titleEn?: string | null;
  titleAr?: string | null;
  contractType?: string | null;
  counterpartyName?: string | null;
  startDate?: string | null;
  endDate?: string | null;
  valueAed?: number | null;
  currency?: string | null;
  governingLaw?: string | null;
  emirate?: string | null;
  detectedContractNumber?: string | null;
  confidence?: number | null;
}

/** Look up a party id by name. ILIKE substring match against name_en. */
const resolveCounterpartyId = async (
  name: string | null | undefined,
  tenantId: string,
): Promise<number | null> => {
  if (!name || name.trim().length < 3) return null;
  const trimmed = name.trim();
  // party.is_active is filtered via FORCE ROW LEVEL SECURITY scoped by
  // app.current_tenant_id. We use a dedicated connection so SET LOCAL only
  // affects this query.
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    await client.query(
      "SELECT set_config('app.current_tenant_id', $1, true)",
      [tenantId],
    );
    // aliases is JSONB (array form like ["RIL", "Reliance"]); the `?` operator
    // tests whether the right-hand string exists as a top-level array element.
    const res = await client.query<{ id: string }>(
      `SELECT id::TEXT
         FROM party
        WHERE is_active = TRUE
          AND (
            name_en ILIKE $1
            OR name_en ILIKE $2
            OR (aliases IS NOT NULL AND aliases ? $3)
          )
        ORDER BY
          CASE WHEN lower(name_en) = lower($3) THEN 0 ELSE 1 END,
          length(name_en) ASC
        LIMIT 1`,
      [trimmed, '%' + trimmed + '%', trimmed],
    );
    await client.query('COMMIT');
    if (res.rows.length === 0) return null;
    const id = Number.parseInt(res.rows[0].id, 10);
    return Number.isFinite(id) ? id : null;
  } catch {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* ignore */
    }
    return null;
  } finally {
    client.release();
  }
};

const SYSTEM_PROMPT =
  'You are a contract metadata extractor for a UAE contracts platform. ' +
  'Read the document text and return a JSON object with the requested fields. ' +
  'Use null when a field is genuinely not present — do not hallucinate. ' +
  'Use ISO YYYY-MM-DD for all dates. For value, return the AED amount as a ' +
  'plain number (no currency symbol, no commas); if the contract has no ' +
  'monetary value (e.g. an NDA), return null.';

const buildUserPrompt = (req: ExtractContractBulkRequest): string =>
  [
    'Document filename: ' + req.filename,
    '',
    'Required JSON shape:',
    '{',
    '  "titleEn": string (≤120 chars, English title — prefer "Type — Discloser × Recipient (Purpose)" framing),',
    '  "titleAr": string | null (Arabic title if the document includes one, else null),',
    '  "contractType": one of ' + KNOWN_CONTRACT_TYPES.join('|') + ',',
    '  "counterpartyName": string | null (the non-ADNOC party — the external entity),',
    '  "startDate": ISO date | null (effective date of the contract),',
    '  "endDate": ISO date | null (expiry / termination date, if explicit),',
    '  "valueAed": number | null (AED-equivalent total value; null for NDAs / non-monetary),',
    '  "currency": 3-letter ISO code (default "AED" if unclear),',
    '  "governingLaw": one of ' + KNOWN_GOVERNING_LAWS.join('|') + ' | null,',
    '  "emirate": one of "Abu Dhabi"|"Dubai"|"Sharjah"|"Ajman"|"Fujairah"|"Ras Al Khaimah"|"Umm Al Quwain" | null,',
    '  "detectedContractNumber": string | null (the document\'s own contract reference if present),',
    '  "confidence": integer 0..100 (how complete and reliable is the extraction)',
    '}',
    '',
    'Document text (truncated to ~15k chars if longer):',
    '"""',
    req.extractedText.slice(0, 15000),
    '"""',
  ].join('\n');

const callLlm = async (
  req: ExtractContractBulkRequest,
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

const normaliseContractType = (input: string | null | undefined): string => {
  if (!input) return 'other';
  const t = input.toLowerCase().trim().replace(/\s+/g, '_');
  return (KNOWN_CONTRACT_TYPES as readonly string[]).includes(t) ? t : 'other';
};

const normaliseGoverningLaw = (
  input: string | null | undefined,
): string | undefined => {
  if (!input) return undefined;
  const v = input.toLowerCase().trim().replace(/\s+/g, '_');
  return (KNOWN_GOVERNING_LAWS as readonly string[]).includes(v) ? v : undefined;
};

const normaliseCurrency = (
  input: string | null | undefined,
): string | undefined => {
  if (!input) return 'AED';
  const v = input.toUpperCase().trim();
  return /^[A-Z]{3}$/.test(v) ? v : 'AED';
};

const normaliseIsoDate = (
  input: string | null | undefined,
): string | undefined => {
  if (!input) return undefined;
  const v = input.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
  const parsed = new Date(v);
  if (!Number.isFinite(parsed.getTime())) return undefined;
  return parsed.toISOString().slice(0, 10);
};

const normaliseValueAed = (
  input: number | null | undefined,
): number | undefined => {
  if (input === null || input === undefined) return undefined;
  return Number.isFinite(input) && input >= 0 ? Number(input) : undefined;
};

/** Heuristic fallback when OpenAI is unavailable. */
const buildHeuristicFallback = (
  req: ExtractContractBulkRequest,
): ExtractContractBulkResponse => {
  const titleEn = req.extractedText
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 120);
  const contractType = inferContractType(req.extractedText);
  return {
    titleEn,
    contractType,
    bodyEn: req.extractedText,
    currency: 'AED',
    importConfidence: computeStubConfidence(req.extractedText),
    importWarnings: [
      'OpenAI not configured — extraction used keyword heuristics only. Review counterparty, dates, and value before saving.',
    ],
    detectedDuplicateContractNumber: null,
  };
};

/** Single ADNOC tenant id — used to scope party lookups under FORCE RLS. */
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

/**
 * Replaces the M1c deterministic stub with a real LLM extraction.
 *
 * Signature kept compatible with the FE contract (AC-S8-07): same request DTO
 * in, same response DTO out. counterpartyName resolved internally to
 * counterpartyId. bodyEn is always populated with the full extracted text.
 */
export const extractContractData = async (
  req: ExtractContractBulkRequest,
  tenantId: string = ADNOC_TENANT_ID,
): Promise<ExtractContractBulkResponse> => {
  const e = env();
  if (!e.OPENAI_API_KEY) {
    return buildHeuristicFallback(req);
  }

  let llm: LlmExtraction;
  try {
    llm = await callLlm(req, getOpenAIClient());
  } catch {
    // Fall back to heuristic on any OpenAI error — never block the import.
    return buildHeuristicFallback(req);
  }

  const counterpartyId = await resolveCounterpartyId(
    llm.counterpartyName,
    tenantId,
  );
  const warnings: string[] = [];
  if (llm.counterpartyName && counterpartyId === null) {
    warnings.push(
      'Counterparty "' +
        llm.counterpartyName +
        '" not found in party register — please link manually.',
    );
  }

  const confidence =
    typeof llm.confidence === 'number'
      ? Math.min(
          CONFIDENCE_CEILING,
          Math.max(CONFIDENCE_FLOOR, Math.round(llm.confidence)),
        )
      : computeStubConfidence(req.extractedText);

  const titleEn =
    (llm.titleEn ?? '').trim().slice(0, 120) ||
    req.extractedText.replace(/\s+/g, ' ').trim().slice(0, 120);

  return {
    titleEn,
    titleAr: llm.titleAr ?? undefined,
    contractType: normaliseContractType(llm.contractType),
    counterpartyId: counterpartyId ?? undefined,
    valueAed: normaliseValueAed(llm.valueAed),
    currency: normaliseCurrency(llm.currency),
    startDate: normaliseIsoDate(llm.startDate),
    endDate: normaliseIsoDate(llm.endDate),
    emirate: llm.emirate ?? undefined,
    governingLaw: normaliseGoverningLaw(llm.governingLaw) as
      | ExtractContractBulkResponse['governingLaw']
      | undefined,
    bodyEn: req.extractedText,
    importConfidence: confidence,
    importWarnings: warnings.length > 0 ? warnings : null,
    detectedDuplicateContractNumber: null,
  };
};

/**
 * Kept for back-compat with M1c integration tests + the original controller
 * import path. Now delegates to the heuristic fallback (synchronous) so the
 * deterministic property still holds for any caller that hasn't migrated to
 * the async extractContractData() entry point.
 */
export const buildStubExtraction = (
  req: ExtractContractBulkRequest,
): ExtractContractBulkResponse => buildHeuristicFallback(req);
