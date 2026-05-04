// ============================================================
// M3 — Signatures + Signer Q&A AI — Zod Schemas
// Source-of-truth: .claude/workspace/current-module/schemas.ts
// BE-side copy mounted next to other module schemas.
// ============================================================

import { z } from 'zod';

// ------------------------------------------------------------
// 1. Local primitives
// ------------------------------------------------------------

const NonEmptyString = (msg: string, max?: number): z.ZodString => {
  let s = z
    .string({ required_error: msg, invalid_type_error: msg })
    .trim()
    .min(1, msg);
  if (max !== undefined) s = s.max(max, msg);
  return s;
};

const PositiveIntegerSchema = z
  .number({ required_error: 'Required', invalid_type_error: 'Must be a number' })
  .int('Must be an integer')
  .positive('Must be positive');

const PositiveBigIntStringSchema = z
  .string({ required_error: 'Required', invalid_type_error: 'Must be a string' })
  .regex(/^\d+$/, 'Must be a positive integer')
  .refine((s) => Number(s) > 0, 'Must be a positive integer');

/**
 * Plaintext token shape — base64url-ish, >= 32 bytes (43 chars). The DB
 * hashes inside the fn_; controller never re-derives. Permissive char set
 * + min length because token contents are cryptographically-secure-random.
 */
const TokenPlaintextSchema = z
  .string({ required_error: 'Required', invalid_type_error: 'Required' })
  .min(32, 'Invalid token')
  .max(512, 'Invalid token');

// ------------------------------------------------------------
// 2. Enum schemas
// ------------------------------------------------------------

export const SignerSideSchema = z.enum(['employer', 'counterparty', 'witness']);
export const SignatureMethodSchema = z.enum(['uae_pass', 'ds_otp', 'drawn', 'typed']);
export const UaePassVerificationLevelSchema = z.enum(['basic', 'verified', 'premium']);
export const SignatureInvitationStatusSchema = z.enum([
  'pending',
  'viewed',
  'signed',
  'declined',
  'expired',
  'cancelled',
]);
export const SignatureEventTypeSchema = z.enum([
  'viewed',
  'signed',
  'declined',
  'expired',
  'cancelled',
  'resent',
]);
export const SignatureLanguageSchema = z.enum(['en', 'ar']);
export const SignerQaRecordMessageModeSchema = z.enum(['GATE', 'COMMIT']);

// ------------------------------------------------------------
// 3. Path-param schemas
// ------------------------------------------------------------

export const ContractIdParamSchema = z
  .object({
    id: PositiveBigIntStringSchema,
  })
  .strict();

export const SignaturePartyIdParamSchema = z
  .object({
    id: PositiveBigIntStringSchema,
  })
  .strict();

export const SignatureInvitationIdParamSchema = z
  .object({
    id: PositiveBigIntStringSchema,
  })
  .strict();

export const InvitationTokenParamSchema = z
  .object({
    invitationToken: TokenPlaintextSchema,
  })
  .strict();

// ------------------------------------------------------------
// 4. signature_party — input schemas (S1)
// ------------------------------------------------------------

export const SignaturePartyInputSchema = z
  .object({
    signerSide: SignerSideSchema,
    signerUserId: PositiveIntegerSchema.nullable().optional(),
    signerNameEn: NonEmptyString('Required', 200),
    signerNameAr: z.string().trim().max(200).nullable().optional(),
    signerEmail: z
      .string()
      .trim()
      .max(255)
      .regex(/^[^@\s]+@[^@\s]+\.[^@\s]+$/, 'Invalid email format')
      .nullable()
      .optional(),
    signerPhone: z.string().trim().max(40).nullable().optional(),
    signerPartyId: PositiveIntegerSchema.nullable().optional(),
    stepOrder: z
      .number({ required_error: 'Required', invalid_type_error: 'Must be a number' })
      .int('Must be an integer')
      .min(1, 'Must be >= 1'),
    isRequired: z.boolean().optional(),
  })
  .strict();

export const SignaturePartyCreateBulkDtoSchema = z
  .object({
    signers: z
      .array(SignaturePartyInputSchema)
      .min(1, 'At least one signer is required')
      .max(20, 'A maximum of 20 signers is supported'),
  })
  .strict()
  .superRefine((dto, ctx) => {
    const hasRequiredEmployer = dto.signers.some(
      (s) => s.signerSide === 'employer' && s.isRequired !== false,
    );
    if (!hasRequiredEmployer) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['signers'],
        message: 'At least one employer signer is required',
      });
    }
  });

// ------------------------------------------------------------
// 5. send-for-signature — request schema (S2)
// ------------------------------------------------------------

export const SendForSignatureDtoSchema = z.object({}).strict();

// ------------------------------------------------------------
// 6. resend-invitation — DTO (S7)
// ------------------------------------------------------------

export const ResendInvitationDtoSchema = z
  .object({
    reason: z.string().trim().max(2000).optional(),
  })
  .strict();

// ------------------------------------------------------------
// 7. cancel-invitation — DTO (S8)
// ------------------------------------------------------------

export const CancelInvitationDtoSchema = z
  .object({
    reason: NonEmptyString('Cancel reason is required', 2000),
  })
  .strict();

// ------------------------------------------------------------
// 8. sign — DTO (S4)
// ------------------------------------------------------------

export const SignContractDtoSchema = z
  .object({
    signatureMethod: SignatureMethodSchema,
    signatureData: z.string().trim().max(1_048_576).nullable().optional(),
    signatureImageUrl: z
      .string()
      .trim()
      .max(2048)
      .url('Invalid URL')
      .nullable()
      .optional(),
    uaePassVerificationLevel: UaePassVerificationLevelSchema.nullable().optional(),
    metadata: z.record(z.unknown()).nullable().optional(),
  })
  .strict()
  .superRefine((dto, ctx) => {
    const method = dto.signatureMethod;

    if (method === 'typed') {
      const v = dto.signatureData?.trim() ?? '';
      if (v.length < 2) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['signatureData'],
          message: 'Required for typed/drawn methods',
        });
      }
    }

    if (method === 'drawn') {
      const v = dto.signatureData?.trim() ?? '';
      if (v.length < 2) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['signatureData'],
          message: 'Required for typed/drawn methods',
        });
      }
      if (!dto.signatureImageUrl) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['signatureImageUrl'],
          message: 'Required for drawn method',
        });
      }
    }

    if (method === 'uae_pass') {
      if (!dto.uaePassVerificationLevel) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['uaePassVerificationLevel'],
          message: 'Required when method=uae_pass',
        });
      }
    }

    if (method === 'ds_otp') {
      const m = dto.metadata as Record<string, unknown> | null | undefined;
      const otpReceipt = m?.otpReceipt;
      if (typeof otpReceipt !== 'string' || otpReceipt.trim().length === 0) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['metadata', 'otpReceipt'],
          message: 'Required for ds_otp method',
        });
      }
    }
  });

// ------------------------------------------------------------
// 9. decline — DTO (S5)
// ------------------------------------------------------------

export const DeclineContractDtoSchema = z
  .object({
    declineReason: z
      .string({
        required_error: 'Decline reason must be at least 5 characters',
        invalid_type_error: 'Decline reason must be at least 5 characters',
      })
      .trim()
      .min(5, 'Decline reason must be at least 5 characters')
      .max(2000, 'Decline reason exceeds 2000 characters'),
  })
  .strict();

// ------------------------------------------------------------
// 10. signer-qa session start — DTO (S11)
// ------------------------------------------------------------

export const SignerQaSessionStartDtoSchema = z
  .object({
    language: SignatureLanguageSchema.optional(),
  })
  .strict();

// ------------------------------------------------------------
// 11. signer-qa record message — discriminated DTO (S12)
// ------------------------------------------------------------

export const SignerQaRecordMessageDtoSchema = z
  .object({
    mode: SignerQaRecordMessageModeSchema,
    tokensConsumed: z
      .number({ required_error: 'Required', invalid_type_error: 'Must be a number' })
      .int('Must be an integer')
      .min(0, 'Must be >= 0'),
    userMessage: z.string().trim().max(8000).nullable().optional(),
  })
  .strict()
  .superRefine((dto, ctx) => {
    if (dto.mode === 'GATE') {
      if (dto.tokensConsumed !== 0) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['tokensConsumed'],
          message: 'Must be 0 in GATE mode',
        });
      }
      const hasUserMessage =
        typeof dto.userMessage === 'string' && dto.userMessage.trim().length > 0;
      if (!hasUserMessage) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['userMessage'],
          message: 'Required in GATE mode',
        });
      }
    } else {
      // COMMIT
      if (dto.tokensConsumed <= 0) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['tokensConsumed'],
          message: 'Must be > 0 in COMMIT mode',
        });
      }
      if (
        dto.userMessage !== undefined &&
        dto.userMessage !== null &&
        dto.userMessage !== ''
      ) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['userMessage'],
          message: 'Must be omitted in COMMIT mode',
        });
      }
    }
  });

// ------------------------------------------------------------
// 12. Inferred types — for BE controller imports
// ------------------------------------------------------------

export type ContractIdParamInferred = z.infer<typeof ContractIdParamSchema>;
export type SignaturePartyIdParamInferred = z.infer<typeof SignaturePartyIdParamSchema>;
export type SignatureInvitationIdParamInferred = z.infer<
  typeof SignatureInvitationIdParamSchema
>;
export type InvitationTokenParamInferred = z.infer<typeof InvitationTokenParamSchema>;
export type SignaturePartyInputInferred = z.infer<typeof SignaturePartyInputSchema>;
export type SignaturePartyCreateBulkDtoInferred = z.infer<
  typeof SignaturePartyCreateBulkDtoSchema
>;
export type SendForSignatureDtoInferred = z.infer<typeof SendForSignatureDtoSchema>;
export type ResendInvitationDtoInferred = z.infer<typeof ResendInvitationDtoSchema>;
export type CancelInvitationDtoInferred = z.infer<typeof CancelInvitationDtoSchema>;
export type SignContractDtoInferred = z.infer<typeof SignContractDtoSchema>;
export type DeclineContractDtoInferred = z.infer<typeof DeclineContractDtoSchema>;
export type SignerQaSessionStartDtoInferred = z.infer<typeof SignerQaSessionStartDtoSchema>;
export type SignerQaRecordMessageDtoInferred = z.infer<
  typeof SignerQaRecordMessageDtoSchema
>;
