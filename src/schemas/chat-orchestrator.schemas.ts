/**
 * Zod schemas for the AI Chat Orchestrator endpoints.
 */
import { z } from 'zod';

const mentionKindEnum = z.enum(['user', 'contract', 'party', 'prospect']);

export const chatMentionSchema = z.object({
  id: z.string().min(1).max(80),
  kind: mentionKindEnum,
  label: z.string().min(1).max(200),
  refId: z.number().int().positive().nullable(),
});

export const chatMessageSchema = z.object({
  role: z.enum(['user', 'assistant']),
  content: z.string().max(8000),
});

export const chatAskSchema = z.object({
  messages: z.array(chatMessageSchema).min(1).max(20),
  mentions: z.array(chatMentionSchema).max(20).default([]),
});

export const chatExecuteSchema = z.object({
  proposalId: z.string().uuid(),
});

export const chatRejectSchema = z.object({
  proposalId: z.string().uuid(),
  reason: z.string().max(500).optional(),
});

export const chatStreamFlagSchema = z.object({
  stream: z
    .union([z.literal('true'), z.literal('false')])
    .optional()
    .transform((v) => (v === 'false' ? false : true)),
});

export type ChatAskBody = z.infer<typeof chatAskSchema>;
export type ChatExecuteBody = z.infer<typeof chatExecuteSchema>;
export type ChatRejectBody = z.infer<typeof chatRejectSchema>;
