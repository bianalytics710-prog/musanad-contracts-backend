/**
 * library-embedding.service.ts
 *
 * After a Drafter creates / updates a contract_template or contract_clause
 * row, kick off a text-embedding-3-small embedding of the body and store it
 * via fn_template_set_embedding / fn_clause_set_embedding. So the LIBRARY
 * stays similarity-searchable as it grows.
 *
 * Non-blocking by design: the create returns immediately; embedding runs in
 * the background. If OPENAI_API_KEY is absent or the call fails, the row
 * just has NULL body_embedding (excluded from match queries).
 */

import { db } from '../database/client';
import { getOpenAIClient } from './ai/_shared/openai-client';
import { env } from '../utils/env-validation.util';
import { logger } from '../utils/logger.util';

const EMBED_MODEL = 'text-embedding-3-small';

const toPgVector = (arr: number[]): string =>
  '[' + arr.map((x) => x.toFixed(8)).join(',') + ']';

async function generateEmbedding(input: string): Promise<number[] | null> {
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
        action: 'libraryEmbedding.generate',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Library embedding generation failed (non-blocking)',
    );
    return null;
  }
}

/**
 * Embed a template (nameEn + bodyEn) and persist via fn_template_set_embedding.
 * Awaited so the FE sees the up-to-date row immediately after create, but
 * any failure is swallowed (logged-only).
 */
export const embedAndSetTemplate = async (
  actorId: number,
  templateId: number,
  nameEn: string,
  bodyEn: string | null,
): Promise<void> => {
  if (!env().OPENAI_API_KEY) return;
  const src = `${nameEn}\n\n${bodyEn ?? ''}`;
  const emb = await generateEmbedding(src);
  if (!emb) return;
  try {
    await db.callFunction(
      'fn_template_set_embedding',
      [actorId, templateId, toPgVector(emb)],
      { actorId },
    );
  } catch (err) {
    logger.warn(
      {
        action: 'libraryEmbedding.setTemplate',
        templateId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_template_set_embedding failed (non-blocking)',
    );
  }
};

/** Embed a clause (titleEn + bodyEn) and persist via fn_clause_set_embedding. */
export const embedAndSetClause = async (
  actorId: number,
  clauseId: number,
  titleEn: string,
  bodyEn: string,
): Promise<void> => {
  if (!env().OPENAI_API_KEY) return;
  const src = `${titleEn}\n\n${bodyEn}`;
  const emb = await generateEmbedding(src);
  if (!emb) return;
  try {
    await db.callFunction(
      'fn_clause_set_embedding',
      [actorId, clauseId, toPgVector(emb)],
      { actorId },
    );
  } catch (err) {
    logger.warn(
      {
        action: 'libraryEmbedding.setClause',
        clauseId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'fn_clause_set_embedding failed (non-blocking)',
    );
  }
};
