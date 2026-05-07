/**
 * R-LC7-D1 — Impact Watch AI endpoints.
 *
 *   POST /api/v1/ai/impact-signals/:id/explain
 *     Plain-language explanation of an impact signal + per-contract impact.
 *
 *   POST /api/v1/ai/impact-signals/:id/suggest-amendment
 *     Redline-ready amendment language for an impact signal (optionally
 *     scoped to a single impacted contract).
 *
 * Both endpoints fetch the signal + its impacted contracts via
 * fn_impact_signal_get, then call the AIProvider's generateJSON to get a
 * Zod-validated structured response. Permission gate: ai.invoke.regulatory.
 *
 * Sensitive logging: signal title / description and contract titles are
 * passed to the LLM but are NEVER logged at the controller layer; pino
 * redact safety-net catches them via existing 'ai_prompt_payload' rules.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { ApiError, NotFoundError } from '../../utils/errors.util';
import { getAIProvider } from '../../integrations/ai';
import {
  aiImpactSignalExplainToolSchema,
  aiImpactSignalSuggestAmendmentToolSchema,
  type AiImpactSignalExplainPayload,
  type AiImpactSignalExplainRequestInput,
  type AiImpactSignalIdParamInferred,
  type AiImpactSignalSuggestAmendmentPayload,
  type AiImpactSignalSuggestAmendmentRequestInput,
} from '../../schemas/ai.schemas';

interface ImpactedContract {
  id: number;
  contractId: number;
  contractNumber: string;
  titleEn: string;
  impactScore: number;
  status: 'pending' | 'reviewed' | 'amended' | 'dismissed';
  reviewedAt: string | null;
}

interface ImpactSignal {
  id: number;
  extId: string;
  category: string;
  source: string;
  severity: string;
  titleEn: string;
  titleAr: string | null;
  descriptionEn: string | null;
  descriptionAr: string | null;
  affectedClauseCategories: string[];
  publishedDate: string;
  effectiveDate: string | null;
  complianceDeadline: string | null;
  impactedContracts: ImpactedContract[];
}

const langName = (lang: 'en' | 'ar' | 'bilingual'): string =>
  lang === 'ar' ? 'Arabic' : lang === 'bilingual' ? 'Bilingual (English + Arabic)' : 'English';

const stringifyContracts = (contracts: ImpactedContract[]): string =>
  contracts
    .map(
      (c) =>
        `- contractId=${c.contractId} | ${c.contractNumber} | ${c.titleEn} | impactScore=${c.impactScore}`,
    )
    .join('\n');

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

const fetchSignal = async (signalId: number, actorId: number): Promise<ImpactSignal> => {
  const signal = await db.callFunction<ImpactSignal>(
    'fn_impact_signal_get',
    [actorId, signalId],
    { actorId },
  );
  if (!signal) throw new NotFoundError('Impact signal not found');
  return signal;
};

export const impactSignalAiController = {
  /** POST /api/v1/ai/impact-signals/:id/explain */
  async explain(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'aiImpactSignalExplain.invoke', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id: signalId } = req.params as unknown as AiImpactSignalIdParamInferred;
      const { language } = req.body as AiImpactSignalExplainRequestInput;
      const actorId = req.user!.id;

      const signal = await fetchSignal(signalId, actorId);

      const system = `You are a UAE compliance counsel advising in-house legal teams. \
Produce concise, executive-grade explanations of impact signals. Tone: professional, \
precise, plain-language. NO speculation, NO marketing language, NO references to your \
identity as an AI. Respond in ${langName(language)}.

Output STRICT JSON in exactly this shape:
{
  "summary": "2-3 sentences explaining what the signal is and why it was flagged",
  "whyItMatters": "2-3 sentences on the practical legal/operational consequences for affected contracts",
  "perContractImpacts": [
    { "contractId": <number>, "contractNumber": "<string>", "explanation": "1-2 sentences on the contract-specific impact" }
  ]
}

Constraints:
- summary ≤ 600 characters
- whyItMatters ≤ 600 characters
- One perContractImpacts entry per impacted contract, ≤ 400 chars each
- contractId and contractNumber MUST match the input contract list exactly
- Do not invent contracts that are not in the input`;

      const userPrompt = `Impact signal:
- ID: ${signal.id}
- External ID: ${signal.extId}
- Category: ${signal.category}
- Severity: ${signal.severity}
- Source: ${signal.source}
- Title (EN): ${signal.titleEn}
- Title (AR): ${signal.titleAr ?? 'n/a'}
- Description (EN): ${signal.descriptionEn ?? 'n/a'}
- Description (AR): ${signal.descriptionAr ?? 'n/a'}
- Affected clause categories: ${signal.affectedClauseCategories.join(', ') || 'n/a'}
- Published: ${signal.publishedDate}
- Effective: ${signal.effectiveDate ?? 'n/a'}
- Compliance deadline: ${signal.complianceDeadline ?? 'n/a'}

Impacted contracts (${signal.impactedContracts.length}):
${stringifyContracts(signal.impactedContracts) || '(none)'}

Generate the explanation. Return JSON only.`;

      const provider = getAIProvider();
      const payload = await provider.generateJSON<AiImpactSignalExplainPayload>(
        userPrompt,
        aiImpactSignalExplainToolSchema,
        { system, temperature: 0.2, maxTokens: 1500 },
      );

      res.setHeader('Cache-Control', 'private, no-store');
      res.status(200).json({ success: true, data: payload, requestId: req.requestId });

      req.logger.info(
        {
          action: 'aiImpactSignalExplain.invoke',
          signalId,
          impactedCount: signal.impactedContracts.length,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
    } catch (err) {
      req.logger.error(
        {
          action: 'aiImpactSignalExplain.invoke',
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  /** POST /api/v1/ai/impact-signals/:id/suggest-amendment */
  async suggestAmendment(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'aiImpactSignalSuggestAmendment.invoke', userId: req.user?.id, method: req.method, path: req.path },
      'Controller entry',
    );
    try {
      const { id: signalId } = req.params as unknown as AiImpactSignalIdParamInferred;
      const { language, contractId } = req.body as AiImpactSignalSuggestAmendmentRequestInput;
      const actorId = req.user!.id;

      const signal = await fetchSignal(signalId, actorId);

      // Optional contract scope — narrow to a specific impacted contract.
      let scopedContracts = signal.impactedContracts;
      if (contractId !== undefined) {
        scopedContracts = signal.impactedContracts.filter((c) => c.contractId === contractId);
        if (scopedContracts.length === 0) {
          throw new NotFoundError(
            `Contract ${contractId} is not linked to impact signal ${signalId}`,
          );
        }
      }

      const system = `You are a UAE-qualified contracts lawyer drafting redline-ready \
amendment language. Generate amendment snippets that a counterparty could accept \
without further negotiation. Tone: formal contract drafting. Respond in ${langName(language)}.

Output STRICT JSON in exactly this shape:
{
  "amendmentSnippets": [
    {
      "clauseAnchor": "<short clause name, e.g. force-majeure | termination | governing-law | data-protection | confidentiality | indemnity | non-compete | compensation | working-hours | term>",
      "rationale": "1-2 sentences on why this amendment is needed in light of the signal",
      "suggestedText": "Drop-in replacement or insert clause text, ready for counterparty review"
    }
  ]
}

Constraints:
- 1 to 6 amendmentSnippets
- clauseAnchor ≤ 60 chars, lowercase with hyphens
- rationale ≤ 600 chars
- suggestedText ≤ 3000 chars; use formal contract language; no markdown
- If the signal is informational only and requires no amendment, return one snippet with clauseAnchor="no-amendment-needed" and explain in rationale.`;

      const userPrompt = `Impact signal:
- ID: ${signal.id}
- Category: ${signal.category}
- Severity: ${signal.severity}
- Source: ${signal.source}
- Title (EN): ${signal.titleEn}
- Description (EN): ${signal.descriptionEn ?? 'n/a'}
- Affected clause categories: ${signal.affectedClauseCategories.join(', ') || 'n/a'}
- Effective date: ${signal.effectiveDate ?? 'n/a'}
- Compliance deadline: ${signal.complianceDeadline ?? 'n/a'}

${
  contractId !== undefined
    ? `Scoped to contract ${scopedContracts[0]!.contractNumber} — ${scopedContracts[0]!.titleEn} (impactScore=${scopedContracts[0]!.impactScore}).`
    : `Across ${scopedContracts.length} impacted contract(s):\n${stringifyContracts(scopedContracts)}`
}

Generate redline-ready amendment language. Return JSON only.`;

      const provider = getAIProvider();
      const payload = await provider.generateJSON<AiImpactSignalSuggestAmendmentPayload>(
        userPrompt,
        aiImpactSignalSuggestAmendmentToolSchema,
        { system, temperature: 0.3, maxTokens: 2000 },
      );

      res.setHeader('Cache-Control', 'private, no-store');
      res.status(200).json({ success: true, data: payload, requestId: req.requestId });

      req.logger.info(
        {
          action: 'aiImpactSignalSuggestAmendment.invoke',
          signalId,
          contractScope: contractId ?? 'all',
          snippetCount: payload.amendmentSnippets.length,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
    } catch (err) {
      req.logger.error(
        {
          action: 'aiImpactSignalSuggestAmendment.invoke',
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },
};
