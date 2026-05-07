// ============================================================
// R-DA9-2 — Zod schemas for contract comments + watch endpoints
// (R4 + R5 approver work that shipped with ad-hoc validation).
// ============================================================
import { z } from 'zod';
import { PositiveBigIntSchema } from './contracts.schemas';

// ------------------------------------------------------------
// Path params
// ------------------------------------------------------------

/** :id (contract) + :commentId path params, used by /resolve + DELETE. */
export const ContractCommentIdParamsSchema = z.object({
  id: PositiveBigIntSchema,
  commentId: PositiveBigIntSchema,
});
export type ContractCommentIdParamsInferred = z.infer<typeof ContractCommentIdParamsSchema>;

// ------------------------------------------------------------
// Query params — GET /api/v1/contracts/:id/comments
// ------------------------------------------------------------

export const CommentFilterSchema = z.enum(['all', 'unresolved', 'mine', 'mentions_me'], {
  errorMap: () => ({ message: 'filter must be one of all|unresolved|mine|mentions_me' }),
});

export const CommentListQuerySchema = z.object({
  filter: CommentFilterSchema.optional().default('all'),
});
export type CommentListQueryInferred = z.infer<typeof CommentListQuerySchema>;

// ------------------------------------------------------------
// Body — POST /api/v1/contracts/:id/comments
// ------------------------------------------------------------

export const CreateCommentSchema = z.object({
  body: z
    .string({ required_error: 'body is required' })
    .trim()
    .min(1, 'body must be at least 1 character')
    .max(4000, 'body must be at most 4000 characters'),
  parentId: PositiveBigIntSchema.nullable().optional(),
  mentionedUserIds: z.array(PositiveBigIntSchema).max(50).optional(),
});
export type CreateCommentInferred = z.infer<typeof CreateCommentSchema>;

// ------------------------------------------------------------
// Body — PUT /api/v1/contracts/:id/watch
// ------------------------------------------------------------

export const SetContractWatchSchema = z.object({
  watching: z.boolean({
    required_error: 'watching is required',
    invalid_type_error: 'watching must be a boolean',
  }),
});
export type SetContractWatchInferred = z.infer<typeof SetContractWatchSchema>;
