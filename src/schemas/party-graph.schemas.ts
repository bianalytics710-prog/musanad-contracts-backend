// ============================================================
// M9 — Counterparty Graph (CR-B) — Zod Schemas
//
// 8 net-new endpoints + extended PATCH /api/v1/parties/:id:
//   1. GET    /api/v1/parties/:id/relationships
//   2. POST   /api/v1/parties/:id/relationships
//   3. PATCH  /api/v1/parties/:id/relationships/:relId
//   4. DELETE /api/v1/parties/:id/relationships/:relId
//   5. GET    /api/v1/parties/:id/chain?direction=&maxDepth=
//   6. GET    /api/v1/parties/:id/chain-summary?maxDepth=
//   7. POST   /api/v1/admin/parties/sanctions-match
//   8. PATCH  /api/v1/parties/:id
//
// S2-16 alignment: every key matches the FE input shape (camelCase) AND
// the controller-to-fn parameter mapping in party-graph.service.ts.
// Authoritative checks live in fn_ bodies; Zod is the cheap first-line
// defence (AC-S1-03, AC-S1-06, AC-S5-04, AC-S6-03, AC-S7-08, AC-S9-02 etc).
// ============================================================
import { z } from 'zod';
import { PositiveBigIntSchema } from './contracts.schemas';

// ------------------------------------------------------------
// Shared closed-set enums (mirror DB CHECK constraints)
// ------------------------------------------------------------

export const relationshipTypeSchema = z.enum(
  ['parent', 'ubo', 'subsidiary', 'sub_contractor', 'jv', 'controlling_shareholder'],
  { errorMap: () => ({ message: 'Invalid relationshipType' }) },
);

export const relationshipSourceSchema = z.enum(
  ['dnb', 'sayari', 'manual', 'demo_seed'],
  { errorMap: () => ({ message: 'Invalid source' }) },
);

export const icvStatusSchema = z.enum(
  ['certified', 'expired', 'downgraded', 'pending', 'none'],
  { errorMap: () => ({ message: 'Invalid icvStatus' }) },
);

export const chainDirectionSchema = z.enum(['up', 'down', 'both'], {
  errorMap: () => ({ message: 'direction must be up | down | both' }),
});

// ------------------------------------------------------------
// Date / DateTime primitives
// ------------------------------------------------------------

const isoDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Must be ISO date (YYYY-MM-DD)');

const isoDateTimeSchema = z
  .string()
  .refine((s) => !Number.isNaN(Date.parse(s)), {
    message: 'Must be an ISO 8601 datetime string',
  });

// ------------------------------------------------------------
// Path params
// ------------------------------------------------------------

/** /:id where id is the anchor party id. */
export const partyIdParamSchema = z.object({
  id: PositiveBigIntSchema,
});
export type PartyIdParamInferred = z.infer<typeof partyIdParamSchema>;

/** /:id/relationships/:relId */
export const partyRelationshipIdParamSchema = z.object({
  id: PositiveBigIntSchema,
  relId: PositiveBigIntSchema,
});
export type PartyRelationshipIdParamInferred = z.infer<typeof partyRelationshipIdParamSchema>;

// ------------------------------------------------------------
// 1. GET /api/v1/parties/:id/relationships  (no body / query)
//    — only path param validation needed.
// ------------------------------------------------------------

// ------------------------------------------------------------
// 2. POST /api/v1/parties/:id/relationships
// ------------------------------------------------------------

export const createRelationshipSchema = z
  .object({
    childId: PositiveBigIntSchema,
    relationshipType: relationshipTypeSchema,
    ownershipPct: z.number().min(0).max(100).nullable().optional(),
    effectiveFrom: isoDateSchema.nullable().optional(),
    effectiveTo: isoDateSchema.nullable().optional(),
    source: relationshipSourceSchema.optional(),
    confidence: z.number().min(0).max(1).optional(),
    metadata: z.record(z.unknown()).optional(),
  })
  .refine(
    (data) => {
      if (
        data.effectiveFrom &&
        data.effectiveTo &&
        data.effectiveTo < data.effectiveFrom
      ) {
        return false;
      }
      return true;
    },
    { message: 'effectiveTo must be on or after effectiveFrom', path: ['effectiveTo'] },
  );
export type CreateRelationshipInferred = z.infer<typeof createRelationshipSchema>;

// ------------------------------------------------------------
// 3. PATCH /api/v1/parties/:id/relationships/:relId
//    parentId / childId silently dropped before forwarding (AC-S2-04).
// ------------------------------------------------------------

export const updateRelationshipSchema = z
  .object({
    relationshipType: relationshipTypeSchema.optional(),
    ownershipPct: z.number().min(0).max(100).nullable().optional(),
    effectiveFrom: isoDateSchema.nullable().optional(),
    effectiveTo: isoDateSchema.nullable().optional(),
    source: relationshipSourceSchema.optional(),
    confidence: z.number().min(0).max(1).optional(),
    metadata: z.record(z.unknown()).optional(),
  })
  .refine(
    (data) => {
      if (
        data.effectiveFrom &&
        data.effectiveTo &&
        data.effectiveTo < data.effectiveFrom
      ) {
        return false;
      }
      return true;
    },
    { message: 'effectiveTo must be on or after effectiveFrom', path: ['effectiveTo'] },
  );
export type UpdateRelationshipInferred = z.infer<typeof updateRelationshipSchema>;

// ------------------------------------------------------------
// 5. GET /api/v1/parties/:id/chain?direction=&maxDepth=
// ------------------------------------------------------------

export const partyChainTraverseQuerySchema = z.object({
  direction: chainDirectionSchema.optional(),
  // Coerce because query params arrive as strings.
  maxDepth: z.coerce
    .number()
    .int()
    .min(1, 'maxDepth must be >= 1')
    .max(10, 'maxDepth must be <= 10')
    .optional(),
});
export type PartyChainTraverseQueryInferred = z.infer<typeof partyChainTraverseQuerySchema>;

// ------------------------------------------------------------
// 6. GET /api/v1/parties/:id/chain-summary?maxDepth=
// ------------------------------------------------------------

export const partyChainSummaryQuerySchema = z.object({
  maxDepth: z.coerce
    .number()
    .int()
    .min(1, 'maxDepth must be >= 1')
    .max(10, 'maxDepth must be <= 10')
    .optional(),
});
export type PartyChainSummaryQueryInferred = z.infer<typeof partyChainSummaryQuerySchema>;

// ------------------------------------------------------------
// 7. POST /api/v1/admin/parties/sanctions-match
// ------------------------------------------------------------

const entityReferenceSchema = z.object({
  entityType: z.string().trim().min(1, 'entityType is required'),
  name: z.string().trim().min(1, 'name is required'),
  identifier: z.string().trim().min(1).optional(),
  partyId: z.number().int().positive().optional(),
});

export const partySanctionsMatchInputSchema = z.object({
  signalEntities: z
    .array(entityReferenceSchema)
    .min(1, 'signalEntities must contain at least one entry'),
  similarityThreshold: z
    .number()
    .min(0, 'similarityThreshold must be >= 0')
    .max(1, 'similarityThreshold must be <= 1')
    .optional(),
});
export type PartySanctionsMatchInputInferred = z.infer<typeof partySanctionsMatchInputSchema>;

// ------------------------------------------------------------
// 8. PATCH /api/v1/parties/:id (extends existing parties endpoints)
//
// `aliases` validated as array of non-empty strings — fn body re-checks
// (defence-in-depth; raises 22023 'invalid_aliases_shape' on shape mismatch).
//
// `parentId` / `uboId` accept null, positive integer, or omitted. Self-
// reference (parentId === id) caught by fn body (raises 22023). Sentinel
// mapping (null → -1) is a controller-side concern.
//
// sanctionsStatus / sanctionsLastChecked / sanctionsMatchSignalId are NOT
// in the schema. Even if forwarded, fn_party_update doesn't accept them
// (Q-DA4 defence-in-depth — AC-S9-05).
// ------------------------------------------------------------

export const partyUpdateSchema = z
  .object({
    nameEn: z.string().trim().min(1).max(200).optional(),
    nameAr: z.string().trim().max(200).nullable().optional(),
    emirate: z.string().trim().max(40).nullable().optional(),
    freeZone: z.string().trim().max(80).nullable().optional(),
    country: z.string().trim().max(60).nullable().optional(),
    contactEmail: z.string().email('Invalid email').max(255).nullable().optional(),
    contactPhone: z.string().trim().max(40).nullable().optional(),
    registeredAddress: z.string().trim().max(500).nullable().optional(),
    notes: z.string().trim().max(2000).nullable().optional(),
    tradeLicenseNumber: z.string().trim().max(80).nullable().optional(),
    tradeLicenseIssuer: z.string().trim().max(120).nullable().optional(),

    // M9 (CR-B) editable subset
    parentId: z.number().int().positive().nullable().optional(),
    uboId: z.number().int().positive().nullable().optional(),
    aliases: z.array(z.string().trim().min(1).max(200)).max(50).optional(),
    esgScore: z.number().int().min(0).max(100).nullable().optional(),
    icvStatus: icvStatusSchema.nullable().optional(),
    icvPct: z.number().min(0).max(100).nullable().optional(),
    icvLastChecked: isoDateTimeSchema.nullable().optional(),
    metadata: z.record(z.unknown()).optional(),
  })
  .refine((data) => Object.keys(data).length > 0, {
    message: 'At least one field must be provided for update',
  });
export type PartyUpdateInferred = z.infer<typeof partyUpdateSchema>;
