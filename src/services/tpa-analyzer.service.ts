/**
 * TPA — Third-Party Agreement Analyzer Service.
 *
 * Pipeline:
 *   1. Extract text from uploaded buffer (pdf-parse for PDF, mammoth for DOCX).
 *   2. Load ADNOC playbook (clauses with standard / fallback / non-negotiables).
 *   3. Call gpt-4o JSON-mode with playbook + agreement text; receive per-clause
 *      findings + overall verdict + executive summary.
 *   4. Return shape consumed by fn_tpa_review_record_analysis.
 *
 * SENSITIVE:
 *   - extractedText, aiRationale, aiSuggestedRedline — Pino-redacted.
 *   - openaiApiKey via env() — never logged.
 */
import { createHash } from 'node:crypto';
import { logger } from '../utils/logger.util';
import { InternalError } from '../utils/errors.util';
import { getOpenAIClient } from './ai/_shared/openai-client';
import { recordAiTelemetry } from './ai/_shared/telemetry-middleware';

const MODEL_VERSION = 'gpt-4o';
const MAX_AGREEMENT_CHARS = 60_000;

// ----------------------------------------------------------------
// Types
// ----------------------------------------------------------------

export type AiVerdict = 'accept' | 'amend' | 'reject' | 'missing' | 'info';
export type AiSeverity = 'low' | 'medium' | 'high' | 'critical';
export type OverallVerdict = 'accept' | 'amend' | 'reject';
export type OverallRisk = 'low' | 'medium' | 'high' | 'critical';

export interface PlaybookClauseInput {
  id: number;
  clauseKey: string;
  clauseTitle: string;
  displayOrder: number;
  criticality: 'non_negotiable' | 'high' | 'medium' | 'low';
  standardPosition: string;
  fallbackPosition: string | null;
  nonNegotiables: string[];
  redFlags: string[];
}

export interface PlaybookInput {
  id: number;
  agreementType: string;
  name: string;
  clauses: PlaybookClauseInput[];
}

export interface TpaFinding {
  playbookClauseId: number | null;
  clauseKey: string;
  clauseTitle: string;
  displayOrder: number;
  extractedText: string | null;
  extractedLocation: string | null;
  aiVerdict: AiVerdict;
  aiRationale: string;
  aiSeverity: AiSeverity | null;
  aiSuggestedRedline: string | null;
  aiConflictsWith: string[];
}

export interface TpaAnalysisResult {
  findings: TpaFinding[];
  overallVerdict: OverallVerdict;
  overallRisk: OverallRisk;
  riskScore: number;
  executiveSummary: string;
  modelVersion: string;
  promptHash: string;
}

// ----------------------------------------------------------------
// Extraction — PDF (pdf-parse) + DOCX (mammoth)
// ----------------------------------------------------------------

export async function extractTextFromBuffer(
  buffer: Buffer,
  mime: string,
): Promise<{ text: string; pageCount: number | null; engine: string }> {
  if (
    mime === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
    mime === 'application/msword'
  ) {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mammoth = require('mammoth') as {
      extractRawText: (opts: { buffer: Buffer }) => Promise<{ value: string }>;
    };
    const result = await mammoth.extractRawText({ buffer });
    return { text: result.value ?? '', pageCount: null, engine: 'mammoth_docx' };
  }

  if (mime === 'application/pdf') {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const pdfParse = require('pdf-parse') as (
      buf: Buffer,
    ) => Promise<{ text: string; numpages: number }>;
    const parsed = await pdfParse(buffer);
    return {
      text: parsed.text ?? '',
      pageCount: parsed.numpages ?? 1,
      engine: 'digital_pdf',
    };
  }

  if (mime === 'text/plain') {
    return { text: buffer.toString('utf-8'), pageCount: null, engine: 'text_passthrough' };
  }

  throw new InternalError(`Unsupported MIME type: ${mime}`);
}

// ----------------------------------------------------------------
// LLM analysis (gpt-4o JSON-mode)
// ----------------------------------------------------------------

const SYSTEM_PROMPT = `You are ADNOC's senior contracts counsel reviewing a third-party agreement against ADNOC's standard playbook. Your role is to:

1. For EACH playbook clause provided, find the corresponding clause in the agreement (if present).
2. Classify each clause as exactly one of:
   - "accept"  — agreement language matches ADNOC's standard, or falls inside the playbook's acceptable fallback range. No change needed.
   - "amend"   — the counterparty's clause IS workable with specific surgical changes (e.g. swap "5 years" for "3 years", insert a missing carve-out, tighten a definition). Pick this when ADNOC wants the clause to exist, just with different wording. ALWAYS produce a self-contained replacement clause as aiSuggestedRedline.
   - "reject"  — the counterparty's clause is so fundamentally misaligned with ADNOC posture that ADNOC asks them to DELETE it from the agreement entirely (the topic will be re-addressed separately, or its absence is acceptable). Pick this when redlining the clause line-by-line would be more work than a clean replacement and the counterparty's framing is structurally wrong. Set aiSuggestedRedline to null.
   - "missing" — the playbook clause topic is not addressed in the agreement at all. Set extractedText to null and produce aiSuggestedRedline with ADNOC's standard wording (this is the insertion ADNOC wants added to the agreement).
3. Quote the exact text from the agreement (extractedText) when the clause exists. Null otherwise.
4. Be conservative with "reject" — prefer "amend" when a redline can fix the issue. Specifically:
   - If the fix is a SURGICAL CHANGE (swap a country name, swap "5 years" for "3 years", insert a missing carve-out, tighten a definition, add a missing exception) → use "amend" even if the playbook clause is tagged non_negotiable.
   - Use "reject" ONLY when the counterparty's entire structural framing of the clause is so misaligned that line-by-line redlining would be more work than a clean wholesale replacement (e.g. a Dispute Resolution clause that mandates a foreign arbitral seat + foreign institutional rules + a 3-arbitrator panel when ADNOC requires Abu Dhabi-seated ADGM arbitration with a sole arbitrator — the entire mechanic needs to go).
   - As a rule of thumb: across an entire 12-clause review, expect 0-1 "reject" findings; the rest of the non-negotiable violations should be "amend".
   - Worked example A — Governing Law clause says "laws of <foreign country>": this is AMEND, not reject. ADNOC counter-proposes "laws of the UAE as applied in Abu Dhabi" (or ADGM as fallback) — this is a surgical substitution. Generate the swap as aiSuggestedRedline.
   - Worked example B — Dispute Resolution clause says "LCIA-administered arbitration seated in London before three arbitrators": this is REJECT, not amend. The seat, the rules, the panel composition and the language are all wrong; ADNOC requires Abu Dhabi-seated ADGM arbitration with a sole arbitrator. The structural rewrite is so deep that ADNOC asks the counterparty to delete the clause entirely and use ADNOC's standard wording in negotiations. Set aiSuggestedRedline to null.
5. Set aiSeverity from {"low","medium","high","critical"} based on commercial risk.
6. Populate aiConflictsWith with the specific non_negotiables or red_flags that were triggered.
7. Be concise but specific in aiRationale — 1-3 sentences explaining what is wrong and why.

After processing all playbook clauses, also:
- Set overallVerdict: "reject" if ANY clause is "reject"; "amend" if any "amend"/"missing" but none "reject"; "accept" if all "accept".
- Set overallRisk: "critical" if any non_negotiable is breached or any reject; "high" if 3+ amends or 2+ high-criticality amends; "medium" if 1-2 amends; "low" if only minor amends/missing or accepts.
- Set riskScore 0-100 (higher = worse): start at 0, add 25 per reject, 12 per amend (or 18 if high/non_negotiable criticality), 5 per missing (or 10 if high), 0 per accept, capped at 100.
- Write executiveSummary: a 3-5 sentence summary suitable for an in-house counsel reading on her phone — what the headline issues are, what cannot ship as drafted, and what the recommended next step is.

Return STRICT JSON matching the schema. Do not include any commentary outside the JSON.`;

function buildUserPrompt(args: {
  playbook: PlaybookInput;
  counterpartyName: string;
  agreementTitle: string;
  agreementText: string;
}): string {
  const playbookSummary = args.playbook.clauses
    .map(
      (c) =>
        `### ${c.clauseTitle} (${c.clauseKey}, criticality=${c.criticality})
STANDARD: ${c.standardPosition}
FALLBACK: ${c.fallbackPosition ?? '(no fallback — only standard is acceptable)'}
NON-NEGOTIABLES: ${c.nonNegotiables.length ? c.nonNegotiables.map((n) => `- ${n}`).join('\n') : '(none)'}
RED FLAGS: ${c.redFlags.length ? c.redFlags.map((r) => `- ${r}`).join('\n') : '(none)'}`,
    )
    .join('\n\n');

  return `ADNOC PLAYBOOK — ${args.playbook.name} (agreement type: ${args.playbook.agreementType})

${playbookSummary}

---

COUNTERPARTY AGREEMENT FROM: ${args.counterpartyName}
AGREEMENT TITLE: ${args.agreementTitle}

AGREEMENT TEXT:
"""
${args.agreementText.slice(0, MAX_AGREEMENT_CHARS)}
"""

Return JSON with the following exact shape:
{
  "findings": [
    {
      "playbookClauseId": <number from playbook>,
      "clauseKey": "<clause_key from playbook>",
      "clauseTitle": "<human-readable title>",
      "displayOrder": <number from playbook>,
      "extractedText": "<verbatim quote from agreement, or null if missing>",
      "extractedLocation": "<clause number or section reference, e.g. 'Clause 2' or 'Section 7'>",
      "aiVerdict": "accept|amend|reject|missing|info",
      "aiRationale": "<1-3 sentences>",
      "aiSeverity": "low|medium|high|critical|null",
      "aiSuggestedRedline": "<replacement language for amend/reject, or null>",
      "aiConflictsWith": ["<which non_negotiable or red_flag was triggered>"]
    }
  ],
  "overallVerdict": "accept|amend|reject",
  "overallRisk": "low|medium|high|critical",
  "riskScore": <0-100>,
  "executiveSummary": "<3-5 sentences>"
}`;
}

// ----------------------------------------------------------------
// Main entry point
// ----------------------------------------------------------------

export async function analyseAgreementAgainstPlaybook(args: {
  agreementText: string;
  playbook: PlaybookInput;
  counterpartyName: string;
  agreementTitle: string;
  actorUserId: number;
  reviewId: number;
}): Promise<TpaAnalysisResult> {
  const startMs = Date.now();
  const client = getOpenAIClient();

  if (!args.agreementText || args.agreementText.trim().length < 200) {
    throw new InternalError('Agreement text is too short — extraction may have failed');
  }

  const userPrompt = buildUserPrompt({
    playbook: args.playbook,
    counterpartyName: args.counterpartyName,
    agreementTitle: args.agreementTitle,
    agreementText: args.agreementText,
  });

  const promptHash = createHash('sha256')
    .update(SYSTEM_PROMPT + '\n' + userPrompt)
    .digest('hex')
    .slice(0, 32);

  let response;
  try {
    response = await client.chat.completions.create({
      model: MODEL_VERSION,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0.1,
      max_tokens: 8000,
    });
  } catch (err) {
    void recordAiTelemetry({
      promptId: 'tpa-analyzer',
      mode: 'classification',
      actorUserId: args.actorUserId,
      entityType: 'tpa_review',
      entityId: args.reviewId,
      language: 'en',
      provider: 'openai',
      modelUsed: MODEL_VERSION,
      tokensInput: null,
      tokensOutput: null,
      costUsdMicros: null,
      latencyMs: Date.now() - startMs,
      cacheHit: false,
      streamMode: false,
      outcome: 'error',
      errorClass: err instanceof Error ? err.name : 'UnknownError',
      errorMessage: err instanceof Error ? err.message : String(err),
    });
    throw new InternalError(
      `tpa-analyzer: gpt-4o call failed — ${err instanceof Error ? err.message : 'unknown'}`,
    );
  }

  const raw = response.choices[0]?.message?.content ?? '';
  if (!raw) {
    throw new InternalError('tpa-analyzer: empty response from gpt-4o');
  }

  let parsed: {
    findings?: unknown;
    overallVerdict?: unknown;
    overallRisk?: unknown;
    riskScore?: unknown;
    executiveSummary?: unknown;
  };
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    logger.warn(
      { action: 'tpaAnalyzer.parse_failed', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'gpt-4o JSON parse failed',
    );
    throw new InternalError('tpa-analyzer: gpt-4o returned invalid JSON');
  }

  // Validate + coerce
  const findingsArr = Array.isArray(parsed.findings) ? parsed.findings : [];
  const findings: TpaFinding[] = findingsArr.map((f: unknown) => {
    const ff = f as Record<string, unknown>;
    const conflicts = Array.isArray(ff.aiConflictsWith)
      ? (ff.aiConflictsWith as unknown[]).map((x) => String(x))
      : [];
    return {
      playbookClauseId:
        typeof ff.playbookClauseId === 'number'
          ? ff.playbookClauseId
          : ff.playbookClauseId
            ? Number(ff.playbookClauseId)
            : null,
      clauseKey: String(ff.clauseKey ?? ''),
      clauseTitle: String(ff.clauseTitle ?? 'Untitled clause'),
      displayOrder: typeof ff.displayOrder === 'number' ? ff.displayOrder : 100,
      extractedText: ff.extractedText ? String(ff.extractedText) : null,
      extractedLocation: ff.extractedLocation ? String(ff.extractedLocation) : null,
      aiVerdict: normaliseVerdict(ff.aiVerdict),
      aiRationale: String(ff.aiRationale ?? ''),
      aiSeverity: normaliseSeverity(ff.aiSeverity),
      aiSuggestedRedline: ff.aiSuggestedRedline ? String(ff.aiSuggestedRedline) : null,
      aiConflictsWith: conflicts,
    };
  });

  const result: TpaAnalysisResult = {
    findings,
    overallVerdict: normaliseOverallVerdict(parsed.overallVerdict),
    overallRisk: normaliseOverallRisk(parsed.overallRisk),
    riskScore: clampScore(parsed.riskScore),
    executiveSummary: String(parsed.executiveSummary ?? ''),
    modelVersion: MODEL_VERSION,
    promptHash,
  };

  void recordAiTelemetry({
    promptId: 'tpa-analyzer',
    mode: 'classification',
    actorUserId: args.actorUserId,
    entityType: 'tpa_review',
    entityId: args.reviewId,
    language: 'en',
    provider: 'openai',
    modelUsed: MODEL_VERSION,
    tokensInput: response.usage?.prompt_tokens ?? null,
    tokensOutput: response.usage?.completion_tokens ?? null,
    costUsdMicros: null,
    latencyMs: Date.now() - startMs,
    cacheHit: false,
    streamMode: false,
    outcome: 'success',
  });

  return result;
}

function normaliseVerdict(v: unknown): AiVerdict {
  const s = String(v ?? '').toLowerCase();
  if (s === 'accept' || s === 'amend' || s === 'reject' || s === 'missing' || s === 'info') return s;
  return 'info';
}
function normaliseSeverity(v: unknown): AiSeverity | null {
  const s = String(v ?? '').toLowerCase();
  if (s === 'low' || s === 'medium' || s === 'high' || s === 'critical') return s;
  return null;
}
function normaliseOverallVerdict(v: unknown): OverallVerdict {
  const s = String(v ?? '').toLowerCase();
  if (s === 'accept' || s === 'amend' || s === 'reject') return s;
  return 'amend';
}
function normaliseOverallRisk(v: unknown): OverallRisk {
  const s = String(v ?? '').toLowerCase();
  if (s === 'low' || s === 'medium' || s === 'high' || s === 'critical') return s;
  return 'medium';
}
function clampScore(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return 50;
  return Math.max(0, Math.min(100, Math.round(n)));
}
