// ============================================================
// M1c — Bulk & Manual Import — Zod Schemas (BE)
// Project: Musanad Contracts Hub (musanad-contracts)
//
// Mirrors api-contracts.json + types/import-batch.types.ts. Error messages
// match the AC-prescribed { field, message } envelopes so the M1a
// validation middleware emits the exact text each AC asserts.
//
// Naming: <TypeName>Schema. Type can be inferred via z.infer<typeof X>.
// ============================================================

import { z } from 'zod';
import { PositiveBigIntSchema } from './contracts.schemas';

// ------------------------------------------------------------
// 1. Enum schemas — map 1:1 to TS unions in types/import-batch.types.ts
// ------------------------------------------------------------

/** AC-S2-02: 4-value lifecycle enum. Message used when ?status= is invalid. */
export const ImportBatchStatusSchema = z.enum(
  ['in_progress', 'paused', 'completed', 'cancelled'],
  { errorMap: () => ({ message: 'Invalid status value' }) },
);

/** AC-S1-03: 3-value config enum. */
export const ImportBatchStatusModeSchema = z.enum(['active', 'draft', 'auto'], {
  errorMap: () => ({ message: 'Invalid statusMode' }),
});

// ------------------------------------------------------------
// 2. Config sub-schema (AC-S1-03)
// ------------------------------------------------------------

/**
 * ImportBatchConfig JSONB shape. fn_import_batch_create also validates
 * (defense in depth — Design Note D6).
 *
 * `.strict()` rejects unknown keys at the Zod boundary so the FE cannot
 * smuggle extra config keys past the BE — matches M1a UpdateContractDto
 * pattern.
 */
export const ImportBatchConfigSchema = z
  .object({
    contractType: z.string().trim().max(50).optional(),
    statusMode: ImportBatchStatusModeSchema,
    defaultCounterpartyId: PositiveBigIntSchema.optional(),
  })
  .strict();

// ------------------------------------------------------------
// 3. CreateImportBatchDto — POST /api/v1/import-batches (S1)
// ------------------------------------------------------------

/**
 * AC-S1-02: totalFiles must be >= 1.
 * AC-S1-03: config.statusMode in { active, draft, auto } when present.
 */
export const CreateImportBatchSchema = z
  .object({
    totalFiles: z
      .number({
        required_error: 'totalFiles must be at least 1',
        invalid_type_error: 'totalFiles must be at least 1',
      })
      .int()
      .min(1, 'totalFiles must be at least 1'),
    config: ImportBatchConfigSchema.optional(),
  })
  .strict();
export type CreateImportBatchInferred = z.infer<typeof CreateImportBatchSchema>;

// ------------------------------------------------------------
// 4. UpdateImportBatchDto — PATCH /api/v1/import-batches/:id (S2)
// ------------------------------------------------------------

/**
 * Counter deltas are SIGNED integers; fn_import_batch_update enforces
 * underflow/overflow guards (AC-S2-04 / AC-S2-05). Status transitions are
 * validated inside the fn_ (AC-S2-02).
 *
 * `.refine` ensures at least one field is provided so PATCH with empty
 * body is rejected (matches M1a update pattern + skill-api-patterns guidance).
 */
export const UpdateImportBatchSchema = z
  .object({
    status: ImportBatchStatusSchema.optional(),
    autoSavedDelta: z.number().int().optional(),
    reviewQueueDelta: z.number().int().optional(),
    manualEntryDelta: z.number().int().optional(),
    duplicatesSkippedDelta: z.number().int().optional(),
    erroredDelta: z.number().int().optional(),
  })
  .strict()
  .refine((v) => Object.keys(v).length > 0, {
    message: 'At least one field must be provided for update',
  });
export type UpdateImportBatchInferred = z.infer<typeof UpdateImportBatchSchema>;

// ------------------------------------------------------------
// 5. ImportBatchListQuery — GET /api/v1/import-batches (S3)
// ------------------------------------------------------------

/** AC-S3-05: limit must be in [1, 100]. */
export const ImportBatchListQuerySchema = z.object({
  page: z.coerce
    .number()
    .int()
    .min(1, 'Page must be >= 1')
    .optional()
    .default(1),
  limit: z.coerce
    .number()
    .int()
    .min(1, 'Limit must be between 1 and 100')
    .max(100, 'Limit must be between 1 and 100')
    .optional()
    .default(20),
  status: ImportBatchStatusSchema.optional(),
  initiatedBy: PositiveBigIntSchema.optional(),
});
export type ImportBatchListQueryInferred = z.infer<typeof ImportBatchListQuerySchema>;

// ------------------------------------------------------------
// 6. Path :id schema — /api/v1/import-batches/:id
// ------------------------------------------------------------

export const ImportBatchIdParamSchema = z.object({
  id: PositiveBigIntSchema,
});
export type ImportBatchIdParamInferred = z.infer<typeof ImportBatchIdParamSchema>;

// ------------------------------------------------------------
// 7. AI extract-contract-bulk — POST /api/v1/ai/extract-contract-bulk (S8)
// ------------------------------------------------------------

/**
 * AC-S8-01 / AC-S8-03 enforcement:
 *   - filename non-empty
 *   - fileSize non-negative integer
 *   - extractedText min 50 characters (AC-S8-03)
 *   - batchId positive bigint
 *
 * extractedText is treated as ai_prompt_payload per project.config.json
 * sensitiveFields and pino-redacted at the controller (AC-S8-06).
 */
export const ExtractContractBulkSchema = z
  .object({
    filename: z
      .string({ required_error: 'filename is required', invalid_type_error: 'filename is required' })
      .trim()
      .min(1, 'filename is required')
      .max(500, 'filename is too long'),
    fileSize: z
      .number({ required_error: 'fileSize is required', invalid_type_error: 'fileSize must be a non-negative integer' })
      .int()
      .nonnegative('fileSize must be a non-negative integer'),
    extractedText: z
      .string({
        required_error: 'extractedText must be at least 50 characters',
        invalid_type_error: 'extractedText must be at least 50 characters',
      })
      .min(50, 'extractedText must be at least 50 characters'),
    batchId: PositiveBigIntSchema,
  })
  .strict();
export type ExtractContractBulkInferred = z.infer<typeof ExtractContractBulkSchema>;
