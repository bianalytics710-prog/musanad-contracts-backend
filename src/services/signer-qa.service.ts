/**
 * M3 Signer Q&A service — thin DB-passthrough for the two token-bearer
 * Q&A fn_ calls.
 *
 * Both fn_ are SECURITY DEFINER + GRANT EXECUTE TO PUBLIC — they
 * authenticate via session_token / invitation_token hash internally. No
 * actorId is set (anonymous external-signer caller).
 *
 * The OpenAI streaming integration lives in openai-signer-qa.service.ts —
 * this module never touches OpenAI directly.
 */
import { db } from '../database/client';
import type {
  SignerQaSessionStartData,
  SignerQaRecordMessageData,
  SignerQaRecordMessageMode,
  SignatureLanguage,
} from '../types/signature.types';

interface FnEnvelope<T> {
  data: T;
}

const unwrap = <T>(env: FnEnvelope<T> | null | undefined): T | null =>
  env && typeof env === 'object' && 'data' in env ? env.data : null;

/**
 * S11 — POST /api/v1/sign/:invitationToken/qa/session → fn_signer_qa_session_start
 *
 * Returns plaintext session token ONCE. Sliding-window soft-deactivate when
 * 5+ active sessions per invitation (Gate 2 AN-12 Option A).
 */
export const sessionStart = async (
  invitationTokenPlain: string,
  language: SignatureLanguage | null,
): Promise<SignerQaSessionStartData | null> => {
  const env = await db.callFunction<FnEnvelope<SignerQaSessionStartData> | null>(
    'fn_signer_qa_session_start',
    [invitationTokenPlain, language ?? 'en'],
    {}, // no actorId — token-bearer
  );
  return unwrap(env);
};

/**
 * S12 — fn_signer_qa_session_record_message — GATE/COMMIT two-call pattern.
 *
 * GATE: pre-AI, p_tokens_consumed = 0, reserves a rate-limit slot. RAISES
 *       'rate_limit_exceeded' (P0001 → 429) when limit hit.
 * COMMIT: post-AI, p_tokens_consumed = actual tokens consumed.
 */
export const recordMessage = async (
  sessionTokenPlain: string,
  tokensConsumed: number,
  mode: SignerQaRecordMessageMode,
): Promise<SignerQaRecordMessageData | null> => {
  const env = await db.callFunction<FnEnvelope<SignerQaRecordMessageData> | null>(
    'fn_signer_qa_session_record_message',
    [sessionTokenPlain, tokensConsumed, mode],
    {}, // no actorId — token-bearer
  );
  return unwrap(env);
};
