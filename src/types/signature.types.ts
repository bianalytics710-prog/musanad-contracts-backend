// ============================================================
// M3 — Signatures + Signer Q&A AI — TypeScript Type Definitions
//
// Project:   Musanad Contracts Hub (musanad-contracts)
// Module:    M3 (M0 + M1a + M1b + M1c + M2 shipped)
// Generator: Agent 5 (Contract Generator) → Agent 7 (BE Implementation port)
//
// Source-of-truth: .claude/workspace/current-module/types.ts
// This file is the BE copy with import paths rewritten to live next to the
// other M0..M2 types in src/types/.
//
// Conventions:
//   - JSONB output keys are camelCase (matches fn_ output) — TS keys mirror.
//   - Date/time fields are ISO-8601 strings.
//   - Token plaintext fields are marked @once-only — never persisted, never
//     re-derivable. Persisted columns are *_token_hash; *_token_hash is
//     NEVER projected by any read path.
//   - Sensitive fields excluded from response shapes per AC-S4-10 / AC-S6-04 /
//     AC-S6-05: signer_phone, signature_data, signature_image_url.
// ============================================================

import type { ApiResponse } from './api.types';
import type {
  ActivityType as M2ActivityType,
  ContractStatus,
  UserRef,
} from './contracts.types';

export type { ApiResponse, UserRef, ContractStatus };

// ------------------------------------------------------------
// 2. Cross-module union extension — ActivityType (AE-1)
// ------------------------------------------------------------

/**
 * AE-1 — ContractActivity.activityType union widened 14 → 20 values
 * (M3 addition). Mirrors the contract_activity_activity_type_check
 * extended in migration 032 + the fn_contract_activity_create whitelist.
 */
export type M3ActivityTypeExtension =
  | 'sent_for_signature'
  | 'signer_viewed'
  | 'signer_signed'
  | 'signer_declined'
  | 'fully_executed'
  | 'signature_invalidated';

/**
 * Full M3 ContractActivity.activityType union — M2 14 + M3 6 = 20 values.
 * Note: the M2 ActivityType union in contracts.types.ts has already been
 * extended with M3 values in M3 BE Impl, so M2ActivityType already covers
 * 20 values. This re-export keeps the public API of this module stable.
 */
export type ActivityType = M2ActivityType;

/**
 * Compile-time const tuple mirroring the migration 032 IN-list.
 * Exported for tests + audit-config wiring.
 */
export const M3_ACTIVITY_TYPE_EXTENSIONS = [
  'sent_for_signature',
  'signer_viewed',
  'signer_signed',
  'signer_declined',
  'fully_executed',
  'signature_invalidated',
] as const;

// ------------------------------------------------------------
// 3. M3 enum unions
// ------------------------------------------------------------

export type SignerSide = 'employer' | 'counterparty' | 'witness';

export type SignatureMethod = 'uae_pass' | 'ds_otp' | 'drawn' | 'typed';

export type UaePassVerificationLevel = 'basic' | 'verified' | 'premium';

export type SignatureInvitationStatus =
  | 'pending'
  | 'viewed'
  | 'signed'
  | 'declined'
  | 'expired'
  | 'cancelled';

export type SignatureEventType =
  | 'viewed'
  | 'signed'
  | 'declined'
  | 'expired'
  | 'cancelled'
  | 'resent';

export type SignatureLanguage = 'en' | 'ar';

export type SignerQaRecordMessageMode = 'GATE' | 'COMMIT';

// ------------------------------------------------------------
// 4. M3 sensitive-field name registry
// ------------------------------------------------------------

export const M3_SENSITIVE_FIELD_EXTENSIONS = [
  'invitation_token_hash',
  'session_token_hash',
  'signature_data',
  'signature_image_url',
] as const;

export type M3SensitiveFieldName = typeof M3_SENSITIVE_FIELD_EXTENSIONS[number];

// ------------------------------------------------------------
// 5. M3 permissions registry
// ------------------------------------------------------------

export const M3_NEW_PERMISSIONS = [
  'signature.send',
  'signature.cancel',
  'signature.read.all',
] as const;

export type M3PermissionCode = typeof M3_NEW_PERMISSIONS[number];

// ------------------------------------------------------------
// 6. signature_party_side — reference / lookup
// ------------------------------------------------------------

export interface SignaturePartySide {
  code: SignerSide;
  labelEn: string;
  labelAr: string;
  sortOrder: number;
  isActive: boolean;
}

// ------------------------------------------------------------
// 7. signature_method — reference / lookup
// ------------------------------------------------------------

export interface SignatureMethodRef {
  code: SignatureMethod;
  labelEn: string;
  labelAr: string;
  verificationStrength: 1 | 2 | 3 | 4;
  isEnabled: boolean;
  isActive: boolean;
}

// ------------------------------------------------------------
// 8. signature_party — owned entity (S1)
// ------------------------------------------------------------

export interface SignaturePartyInput {
  signerSide: SignerSide;
  signerUserId?: number | null;
  signerNameEn: string;
  signerNameAr?: string | null;
  signerEmail?: string | null;
  signerPhone?: string | null;
  signerPartyId?: number | null;
  stepOrder: number;
  isRequired?: boolean;
}

export interface SignatureParty {
  id: number;
  signerSide: SignerSide;
  signerNameEn: string;
  signerNameAr: string | null;
  signerEmail: string | null;
  stepOrder: number;
  isRequired: boolean;
  /**
   * Active signature_invitation row id for this party, or null when no
   * invitation has been issued yet (or the invitation row was rolled back
   * to inactive). Added by migration 038 so the Signatures tab can target
   * POST /signature-invitations/:id/cancel.
   */
  currentInvitationId: number | null;
  currentInvitationStatus: SignatureInvitationStatus | null;
  invitationSentAt: string | null;
  signedAt: string | null;
  declinedAt: string | null;
  lastEventType: SignatureEventType | null;
  signatureMethod: SignatureMethod | null;
  uaePassVerificationLevel: UaePassVerificationLevel | null;
}

// ------------------------------------------------------------
// 9. signature_invitation projections
// ------------------------------------------------------------

export interface SignatureSendInvitationItem {
  signaturePartyId: number;
  invitationId?: number;
  /** @once-only */
  invitationTokenPlaintext: string;
  expiresAt: string;
  signerEmail: string | null;
}

export interface SignaturePublicView {
  invitation: {
    id: number;
    status: SignatureInvitationStatus;
    expiresAt: string;
    viewCount: number;
    language: SignatureLanguage;
  };
  signer: {
    side: SignerSide;
    nameEn: string;
    nameAr: string | null;
    email: string | null;
  };
  contract: {
    id: number;
    contractNumber: string;
    titleEn: string;
    titleAr: string | null;
    contractType: string;
    valueAed: number | null;
    startDate: string | null;
    endDate: string | null;
    ourPartyName: string | null;
    counterpartyName: string | null;
    aiSummaryEn: string | null;
    aiSummaryAr: string | null;
    bodyEnExcerpt: string | null;
    bodyArExcerpt: string | null;
  };
  availableMethods: SignatureMethodRef[];
}

// ------------------------------------------------------------
// 10. fn_signature_party_create_bulk — DTO + response (S1)
// ------------------------------------------------------------

export interface SignaturePartyCreateBulkDto {
  signers: SignaturePartyInput[];
}

export interface SignaturePartyCreateBulkData {
  signatureParties: SignatureParty[];
  createdCount: number;
  skippedCount: number;
}

export type SignaturePartyCreateBulkResponse = ApiResponse<SignaturePartyCreateBulkData>;

// ------------------------------------------------------------
// 11. fn_signature_send_for_signature — request + response (S2)
// ------------------------------------------------------------

export type SendForSignatureDto = Record<string, never>;

export interface SendForSignatureData {
  contractId: number;
  newStatus: ContractStatus;
  invitations: SignatureSendInvitationItem[];
}

export type SendForSignatureResponse = ApiResponse<SendForSignatureData>;

// ------------------------------------------------------------
// 12. fn_signature_invitation_resend — DTO + response (S7)
// ------------------------------------------------------------

export interface ResendInvitationDto {
  reason?: string;
}

export interface ResendInvitationData {
  newInvitationId: number;
  /** @once-only */
  invitationTokenPlaintext: string;
  expiresAt: string;
}

export type ResendInvitationResponse = ApiResponse<ResendInvitationData>;

// ------------------------------------------------------------
// 13. fn_signature_invitation_cancel — DTO + response (S8)
// ------------------------------------------------------------

export interface CancelInvitationDto {
  reason: string;
}

export interface CancelInvitationData {
  invitationId: number;
  status: SignatureInvitationStatus;
  contractRolledBack: boolean;
}

export type CancelInvitationResponse = ApiResponse<CancelInvitationData>;

// ------------------------------------------------------------
// 14. fn_signature_get_by_invitation_token — request + response (S3)
// ------------------------------------------------------------

export interface SignaturePublicGetParams {
  invitationToken: string;
}

export type SignaturePublicViewResponse = ApiResponse<SignaturePublicView>;

// ------------------------------------------------------------
// 15. fn_signature_sign — DTO + response (S4)
// ------------------------------------------------------------

export interface SignContractDto {
  signatureMethod: SignatureMethod;
  signatureData?: string | null;
  signatureImageUrl?: string | null;
  uaePassVerificationLevel?: UaePassVerificationLevel | null;
  metadata?: Record<string, unknown> | null;
}

export interface RemainingSignerSummary {
  signaturePartyId: number;
  signerSide: SignerSide;
  status: SignatureInvitationStatus;
}

export interface SignContractData {
  invitationId: number;
  status: SignatureInvitationStatus;
  signedAt: string;
  stepCompleted: boolean;
  contractNewStatus: ContractStatus | null;
  remainingSigners: RemainingSignerSummary[];
}

export type SignContractResponse = ApiResponse<SignContractData>;

// ------------------------------------------------------------
// 16. fn_signature_decline — DTO + response (S5)
// ------------------------------------------------------------

export interface DeclineContractDto {
  declineReason: string;
}

export interface DeclineContractData {
  invitationId: number;
  status: SignatureInvitationStatus;
  contractNewStatus: ContractStatus | null;
}

export type DeclineContractResponse = ApiResponse<DeclineContractData>;

// ------------------------------------------------------------
// 17. fn_signature_list_for_contract — response (S6)
// ------------------------------------------------------------

export interface SignatureStepProgress {
  stepOrder: number;
  totalRequired: number;
  signedCount: number;
  declinedCount: number;
  pendingCount: number;
}

export interface SignatureListData {
  contractId: number;
  currentStatus: ContractStatus;
  signers: SignatureParty[];
  stepProgress: SignatureStepProgress[];
}

export type SignatureListResponse = ApiResponse<SignatureListData>;

// ------------------------------------------------------------
// 18. fn_signature_invitation_expire_due — cron return shape (S9)
// ------------------------------------------------------------

export interface SignatureInvitationExpireDueData {
  expiredInvitations: number;
  contractsHalted: number;
}

export type SignatureInvitationExpireDueResponse = ApiResponse<SignatureInvitationExpireDueData>;

// ------------------------------------------------------------
// 19. signer_qa_session — start DTO + response (S11)
// ------------------------------------------------------------

export interface SignerQaSessionStartDto {
  language?: SignatureLanguage;
}

export interface SignerQaRateLimitMeta {
  maxMessagesPerHour: number;
  remaining: number;
}

export interface SignerQaSessionStartData {
  /** @once-only */
  sessionTokenPlaintext: string;
  sessionId: number;
  rateLimit: SignerQaRateLimitMeta;
  language: SignatureLanguage;
}

export type SignerQaSessionStartResponse = ApiResponse<SignerQaSessionStartData>;

// ------------------------------------------------------------
// 20. signer_qa_session — record-message DTO + response (S12)
// ------------------------------------------------------------

export interface SignerQaRecordMessageDto {
  mode: SignerQaRecordMessageMode;
  tokensConsumed: number;
  /** Sensitive — pino-redacted; never persisted (G7 / DN-11). */
  userMessage?: string | null;
}

export interface SignerQaRecordMessageData {
  messageCount: number;
  tokensConsumed: number;
  rateLimitRemaining: number;
  mode: SignerQaRecordMessageMode;
}

export type SignerQaRecordMessageResponse = ApiResponse<SignerQaRecordMessageData>;

/**
 * SSE chunk shape for POST /api/v1/sign/:invitationToken/qa/message.
 *
 * Wire format per chunk: `data: <JSON>\n\n`
 *
 * Three chunk variants:
 *   - { type: 'token',  delta: '...' }       — streaming AI tokens
 *   - { type: 'done',   tokensConsumed: N }  — terminal; controller follows
 *                                                with COMMIT call
 *   - { type: 'error',  code: '...' }        — terminal; emitted instead
 */
export type SignerQaMessageStreamChunk =
  | { type: 'token'; delta: string }
  | { type: 'done'; tokensConsumed: number }
  | { type: 'error'; code: string; message?: string; retryAfterSeconds?: number };

// ------------------------------------------------------------
// 21. Path-param shapes used across endpoints
// ------------------------------------------------------------

export interface ContractIdParam {
  id: string;
}

export interface SignaturePartyIdParam {
  id: string;
}

export interface SignatureInvitationIdParam {
  id: string;
}

export interface InvitationTokenParam {
  invitationToken: string;
}
