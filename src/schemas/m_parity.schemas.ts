// ============================================================
// R-LC9-2 — Zod schemas for the M_parity create endpoints
// (parties / templates / clauses / obligations).
//
// S2-16 alignment: every key MUST match the FE input shape (camelCase)
// AND the controller-to-fn parameter mapping in
// src/services/m_parity.service.ts (CreatePartyInput / CreateTemplateInput
// / CreateClauseInput / CreateObligationInput).
// ============================================================
import { z } from 'zod';
import { PositiveBigIntSchema } from './contracts.schemas';

// ------------------------------------------------------------
// 1. Path params shared by /:id endpoints
// ------------------------------------------------------------

export const IdParamSchema = z.object({
  id: PositiveBigIntSchema,
});
export type IdParamInferred = z.infer<typeof IdParamSchema>;

// ------------------------------------------------------------
// 2. POST /api/v1/parties → fn_party_create
// ------------------------------------------------------------

export const CreatePartySchema = z.object({
  partyType: z.enum(['individual', 'company'], {
    errorMap: () => ({ message: 'Invalid party_type' }),
  }),
  nameEn: z.string({ required_error: 'nameEn is required' }).trim().min(1).max(200),
  nameAr: z.string().trim().max(200).nullable().optional(),
  tradeLicenseNumber: z.string().trim().max(80).nullable().optional(),
  tradeLicenseIssuer: z.string().trim().max(120).nullable().optional(),
  emirate: z.string().trim().max(40).nullable().optional(),
  freeZone: z.string().trim().max(80).nullable().optional(),
  country: z.string().trim().max(80).nullable().optional(),
  contactEmail: z.string().email('Invalid email').nullable().optional(),
  contactPhone: z.string().trim().max(40).nullable().optional(),
  registeredAddress: z.string().trim().max(500).nullable().optional(),
  notes: z.string().trim().max(2000).nullable().optional(),
});
export type CreatePartyInferred = z.infer<typeof CreatePartySchema>;

// ------------------------------------------------------------
// 3. POST /api/v1/templates → fn_template_create
// ------------------------------------------------------------

export const CreateTemplateSchema = z.object({
  nameEn: z.string({ required_error: 'nameEn is required' }).trim().min(1).max(200),
  contractType: z
    .string({ required_error: 'contractType is required' })
    .trim()
    .min(1)
    .max(50),
  language: z
    .enum(['en', 'ar', 'bilingual'], { errorMap: () => ({ message: 'invalid language' }) })
    .optional(),
  nameAr: z.string().trim().max(200).nullable().optional(),
  descriptionEn: z.string().trim().max(2000).nullable().optional(),
  descriptionAr: z.string().trim().max(2000).nullable().optional(),
  bodyEn: z.string().max(50000).nullable().optional(),
  bodyAr: z.string().max(50000).nullable().optional(),
  regulatoryTags: z.array(z.string().trim().max(60)).max(20).optional(),
  placeholders: z
    .array(
      z.object({
        key: z
          .string()
          .trim()
          .min(1)
          .max(60)
          .regex(/^[a-z][a-z0-9_]*$/, 'key must be snake_case'),
        labelEn: z.string().trim().min(1).max(120),
        labelAr: z.string().trim().max(120).nullable().optional(),
        kind: z.enum(['party', 'date', 'currency', 'number', 'text']),
        required: z.boolean(),
      }),
    )
    .max(60)
    .optional(),
  regulatoryReference: z.string().trim().max(200).nullable().optional(),
});
export type CreateTemplateInferred = z.infer<typeof CreateTemplateSchema>;

// All fields optional — partial PATCH.
export const UpdateTemplateSchema = CreateTemplateSchema.partial().extend({
  // Explicitly allow null for nullable fields so the client can clear them.
  nameEn: z.string().trim().min(1).max(200).optional(),
  contractType: z.string().trim().min(1).max(50).optional(),
});
export type UpdateTemplateInferred = z.infer<typeof UpdateTemplateSchema>;

// POST /api/v1/templates/extract-from-contract
export const ExtractTemplateFromContractSchema = z.object({
  filename: z.string().trim().min(1).max(255),
  extractedText: z.string().min(50).max(200000),
  contractTypeHint: z.string().trim().max(50).nullable().optional(),
});
export type ExtractTemplateFromContractInferred = z.infer<
  typeof ExtractTemplateFromContractSchema
>;

// POST /api/v1/clauses/extract-from-contract
export const ExtractClausesFromContractSchema = z.object({
  filename: z.string().trim().min(1).max(255),
  extractedText: z.string().min(100).max(200000),
});
export type ExtractClausesFromContractInferred = z.infer<
  typeof ExtractClausesFromContractSchema
>;

// ------------------------------------------------------------
// 4. POST /api/v1/clauses → fn_clause_create
// ------------------------------------------------------------

export const CreateClauseSchema = z.object({
  category: z.string({ required_error: 'category is required' }).trim().min(1).max(40),
  titleEn: z.string({ required_error: 'titleEn is required' }).trim().min(1).max(200),
  bodyEn: z.string({ required_error: 'bodyEn is required' }).trim().min(1).max(50000),
  variant: z
    .enum(['standard', 'alternative', 'fallback'], {
      errorMap: () => ({ message: 'invalid variant' }),
    })
    .optional(),
  titleAr: z.string().trim().max(200).nullable().optional(),
  bodyAr: z.string().trim().max(50000).nullable().optional(),
  legalCommentaryEn: z.string().trim().max(10000).nullable().optional(),
  legalCommentaryAr: z.string().trim().max(10000).nullable().optional(),
  regulatoryRefs: z.array(z.string().trim().max(120)).max(20).optional(),
});
export type CreateClauseInferred = z.infer<typeof CreateClauseSchema>;

// ------------------------------------------------------------
// 5. POST /api/v1/obligations → fn_obligation_create
// ------------------------------------------------------------

export const CreateObligationSchema = z.object({
  contractId: PositiveBigIntSchema,
  titleEn: z.string({ required_error: 'titleEn is required' }).trim().min(1).max(200),
  obligationType: z.enum(
    ['payment', 'delivery', 'reporting', 'renewal', 'compliance', 'notice', 'other'],
    { errorMap: () => ({ message: 'invalid obligation_type' }) },
  ),
  // ISO 8601 date (YYYY-MM-DD). Accept both empty string + null + undefined.
  dueDate: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'dueDate must be YYYY-MM-DD')
    .nullable()
    .optional(),
  recurrence: z
    .enum(['once', 'monthly', 'quarterly', 'annually'], {
      errorMap: () => ({ message: 'invalid recurrence' }),
    })
    .optional(),
  responsibleParty: z
    .enum(['our_party', 'counterparty', 'both'], {
      errorMap: () => ({ message: 'invalid responsibleParty' }),
    })
    .optional(),
  titleAr: z.string().trim().max(200).nullable().optional(),
  descriptionEn: z.string().trim().max(2000).nullable().optional(),
  descriptionAr: z.string().trim().max(2000).nullable().optional(),
  assigneeUserId: PositiveBigIntSchema.nullable().optional(),
  status: z
    .enum(['open', 'in_progress', 'completed', 'overdue', 'waived'], {
      errorMap: () => ({ message: 'invalid status' }),
    })
    .optional(),
});
export type CreateObligationInferred = z.infer<typeof CreateObligationSchema>;

// POST /api/v1/obligations/:id/flag
export const FlagObligationSchema = z.object({
  note: z.string().trim().max(2000).nullable().optional(),
});
export type FlagObligationInferred = z.infer<typeof FlagObligationSchema>;
