/**
 * M3 Signature service — thin DB-passthrough.
 *
 * Each method calls a single fn_ via db.callFunction and returns the parsed
 * JSONB. No business logic. Sensitive fields (signatureData / signatureImageUrl
 * / invitation_token plaintext / session_token plaintext) are pino-redacted at
 * the wire layer (logger.util.ts SENSITIVE_PATHS covers them).
 *
 * Token-bearer fn_ wrappers (fn_signature_get_by_invitation_token,
 * fn_signature_sign, fn_signature_decline, fn_signer_qa_session_start,
 * fn_signer_qa_session_record_message) are called WITHOUT actorId — these
 * are SECURITY DEFINER functions GRANTed to PUBLIC and they authenticate via
 * token hash internally. Setting app.current_user_id is unnecessary (and
 * would be misleading because the caller is anonymous). The cron driver is
 * the one place that DOES set app.current_user_id = '0' via the SYSTEM_ACTOR
 * sentinel (see signature-expiration.cron.service.ts).
 */
import { db } from '../database/client';
import type {
  CancelInvitationData,
  DeclineContractData,
  ResendInvitationData,
  SendForSignatureData,
  SignContractData,
  SignaturePartyCreateBulkData,
  SignaturePublicView,
  SignatureInvitationExpireDueData,
  SignatureListData,
  SignaturePartyInput,
  SignatureMethod,
  UaePassVerificationLevel,
} from '../types/signature.types';

interface FnEnvelope<T> {
  data: T;
}

const unwrap = <T>(env: FnEnvelope<T> | null | undefined): T | null =>
  env && typeof env === 'object' && 'data' in env ? env.data : null;

// ------------------------------------------------------------
// JWT-authenticated services (S1, S2, S6, S7, S8)
// ------------------------------------------------------------

/** S1 — POST /api/v1/contracts/:id/signature-parties → fn_signature_party_create_bulk */
export const createPartiesBulk = async (
  actorId: number,
  contractId: number,
  signers: SignaturePartyInput[],
): Promise<SignaturePartyCreateBulkData | null> => {
  const env = await db.callFunction<FnEnvelope<SignaturePartyCreateBulkData> | null>(
    'fn_signature_party_create_bulk',
    [contractId, signers, actorId],
    { actorId },
  );
  return unwrap(env);
};

/** S2 — POST /api/v1/contracts/:id/send-for-signature → fn_signature_send_for_signature */
export const sendForSignature = async (
  actorId: number,
  contractId: number,
): Promise<SendForSignatureData | null> => {
  const env = await db.callFunction<FnEnvelope<SendForSignatureData> | null>(
    'fn_signature_send_for_signature',
    [contractId, actorId],
    { actorId },
  );
  return unwrap(env);
};

/** S7 — POST /api/v1/signature-parties/:id/resend → fn_signature_invitation_resend */
export const resendInvitation = async (
  actorId: number,
  signaturePartyId: number,
  reason: string | null,
): Promise<ResendInvitationData | null> => {
  const env = await db.callFunction<FnEnvelope<ResendInvitationData> | null>(
    'fn_signature_invitation_resend',
    [signaturePartyId, actorId, reason],
    { actorId },
  );
  return unwrap(env);
};

/** S8 — POST /api/v1/signature-invitations/:id/cancel → fn_signature_invitation_cancel */
export const cancelInvitation = async (
  actorId: number,
  signatureInvitationId: number,
  reason: string,
): Promise<CancelInvitationData | null> => {
  const env = await db.callFunction<FnEnvelope<CancelInvitationData> | null>(
    'fn_signature_invitation_cancel',
    [signatureInvitationId, actorId, reason],
    { actorId },
  );
  return unwrap(env);
};

/** S6 — GET /api/v1/contracts/:id/signatures → fn_signature_list_for_contract */
export const listForContract = async (
  actorId: number,
  contractId: number,
  actorRole?: string | null,
): Promise<SignatureListData | null> => {
  const env = await db.callFunction<FnEnvelope<SignatureListData> | null>(
    'fn_signature_list_for_contract',
    [contractId, actorId, actorRole ?? null],
    { actorId },
  );
  return unwrap(env);
};

// ------------------------------------------------------------
// Token-bearer (verify_jwt=false) services (S3, S4, S5)
// ------------------------------------------------------------

/**
 * S3 — GET /api/v1/sign/:invitationToken → fn_signature_get_by_invitation_token
 *
 * Returns null when invitation is unknown / expired / cancelled (controller
 * maps to 410 with single generic message per AC-S3-04).
 */
export const getByInvitationToken = async (
  invitationTokenPlain: string,
): Promise<SignaturePublicView | null> => {
  const env = await db.callFunction<FnEnvelope<SignaturePublicView> | null>(
    'fn_signature_get_by_invitation_token',
    [invitationTokenPlain],
    {}, // no actorId — token-bearer
  );
  return unwrap(env);
};

interface SignArgs {
  invitationTokenPlain: string;
  signatureMethod: SignatureMethod;
  signatureData: string | null;
  signatureImageUrl: string | null;
  uaePassVerificationLevel: UaePassVerificationLevel | null;
  ipAddress: string | null;
  userAgent: string | null;
  metadata: Record<string, unknown> | null;
}

/** S4 — POST /api/v1/sign/:invitationToken/sign → fn_signature_sign */
export const sign = async (args: SignArgs): Promise<SignContractData | null> => {
  const env = await db.callFunction<FnEnvelope<SignContractData> | null>(
    'fn_signature_sign',
    [
      args.invitationTokenPlain,
      args.signatureMethod,
      args.signatureData,
      args.signatureImageUrl,
      args.uaePassVerificationLevel,
      args.ipAddress,
      args.userAgent,
      args.metadata,
    ],
    {}, // no actorId — token-bearer
  );
  return unwrap(env);
};

interface DeclineArgs {
  invitationTokenPlain: string;
  declineReason: string;
  ipAddress: string | null;
  userAgent: string | null;
}

/** S5 — POST /api/v1/sign/:invitationToken/decline → fn_signature_decline */
export const decline = async (args: DeclineArgs): Promise<DeclineContractData | null> => {
  const env = await db.callFunction<FnEnvelope<DeclineContractData> | null>(
    'fn_signature_decline',
    [args.invitationTokenPlain, args.declineReason, args.ipAddress, args.userAgent],
    {}, // no actorId — token-bearer
  );
  return unwrap(env);
};

// ------------------------------------------------------------
// Cron-only (S9)
// ------------------------------------------------------------

/**
 * S9 — fn_signature_invitation_expire_due — invoked only by the cron driver
 * (src/services/signature-expiration.cron.service.ts). Caller MUST set
 * app.current_user_id = '0' (SYSTEM_ACTOR sentinel) before invocation —
 * fn_contract_activity_create coerces the '0' to NULL via the canonical M2
 * 031 path (S2-20).
 */
export const expireInvitationsBatch = async (
  actorId: number,
  batchSize: number,
): Promise<SignatureInvitationExpireDueData | null> => {
  const env = await db.callFunction<FnEnvelope<SignatureInvitationExpireDueData> | null>(
    'fn_signature_invitation_expire_due',
    [batchSize],
    { actorId }, // 0 — SYSTEM_ACTOR_ID sentinel
  );
  return unwrap(env);
};
