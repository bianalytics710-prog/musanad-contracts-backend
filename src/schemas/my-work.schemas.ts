/**
 * Phase A (mig 640) — My Work unified inbox schema.
 *
 * The /api/v1/my-work endpoint sits alongside the existing /api/v1/work-orders
 * endpoint. Drafter's existing surface keeps calling /work-orders; Legal
 * Counsel, Contract Approver, Compliance, and other personas hit /my-work to
 * get a UNION of work_order + approval_step + risk_case + tpa_review +
 * advisory_draft rows.
 */
import { z } from 'zod';

export const MY_WORK_TYPES = [
  // Existing materialised work_order types (drafter / exec)
  'contract_draft_request',
  'contract_returned',
  'comment_response',
  // Synthesized types from sister tables
  'approval_awaiting',
  'risk_case_assigned',
  'third_party_review',
  'advisory_draft',
] as const;

export const MY_WORK_STATUSES = [
  'open',
  'in_progress',
  'completed',
  'cancelled',
] as const;

export const listMyWorkQuerySchema = z.object({
  status: z
    .string()
    .optional()
    .transform((v) => (v ? v.split(',').filter(Boolean) : undefined))
    .pipe(z.array(z.enum(MY_WORK_STATUSES)).optional()),
  type: z
    .string()
    .optional()
    .transform((v) => (v ? v.split(',').filter(Boolean) : undefined))
    .pipe(z.array(z.enum(MY_WORK_TYPES)).optional()),
  search: z.string().trim().max(200).optional(),
  limit: z.coerce.number().int().positive().max(500).default(100),
  page: z.coerce.number().int().positive().default(1),
});

export type ListMyWorkQuery = z.infer<typeof listMyWorkQuerySchema>;

// mig 684 — personal work-status overlay (to_do/in_progress/done/blocked).
// workItemId is the synthesized My Work row id (negative for synthesized
// rows per mig 640), so int but NOT necessarily positive.
export const PERSONAL_WORK_STATUSES = [
  'to_do',
  'in_progress',
  'done',
  'blocked',
] as const;

export const setMyWorkStatusSchema = z.object({
  workItemId: z.coerce.number().int(),
  status: z.enum(PERSONAL_WORK_STATUSES),
});

export type SetMyWorkStatus = z.infer<typeof setMyWorkStatusSchema>;
