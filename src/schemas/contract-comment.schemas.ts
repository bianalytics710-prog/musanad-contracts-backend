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

// 687 — anchored redline comments. A comment may be pinned to a clause +
// quoted passage of the document. `commentKind` defaults to 'general' so
// every existing caller (free-chat composer, approval request-info) keeps
// working unchanged. When commentKind === 'redline' the fn_ enforces that an
// anchor (clause id or quote) is present, except for replies (parentId set).
export const CreateCommentSchema = z
  .object({
    body: z
      .string({ required_error: 'body is required' })
      .trim()
      .min(1, 'body must be at least 1 character')
      .max(4000, 'body must be at most 4000 characters'),
    parentId: PositiveBigIntSchema.nullable().optional(),
    mentionedUserIds: z.array(PositiveBigIntSchema).max(50).optional(),
    commentKind: z.enum(['general', 'redline']).optional().default('general'),
    anchorClauseId: z.string().trim().max(120).nullable().optional(),
    anchorClauseHeading: z.string().trim().max(300).nullable().optional(),
    anchorQuote: z.string().trim().max(2000).nullable().optional(),
    anchorSide: z.enum(['en', 'ar']).nullable().optional(),
    anchorVersionNumber: z.number().int().positive().nullable().optional(),
  })
  .refine(
    (v) =>
      v.commentKind !== 'redline' ||
      v.parentId != null ||
      (v.anchorClauseId != null && v.anchorClauseId !== '') ||
      (v.anchorQuote != null && v.anchorQuote !== ''),
    {
      message: 'a redline comment must reference a clause or quoted text',
      path: ['anchorQuote'],
    },
  );
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
