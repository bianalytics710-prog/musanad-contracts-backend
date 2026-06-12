/**
 * Types for the AI Chat Orchestrator (prompt-driven actions via floating chatbot).
 *
 * Mirrors the SSE envelope shape of risk-assistant.types.ts but with a richer
 * event set (resolverUsed / proposal / receipt) that the FE proposal card
 * needs to render.
 */

export type MentionKind = 'user' | 'contract' | 'party' | 'prospect';

export interface ChatMention {
  id: string;
  kind: MentionKind;
  /** Display label used in chip text (e.g. "Hala Al Marri" or "CT-2026-000028"). */
  label: string;
  /** Internal record id for user/contract/party. NULL for kind='prospect' (free-text). */
  refId: number | null;
}

export interface ChatMessage {
  role: 'user' | 'assistant';
  /** Rendered message text. For user messages, may include @[Label](kind:id) markup. */
  content: string;
}

export interface ChatActionCatalogRow {
  code: string;
  kind: 'resolver' | 'write_action';
  label: string;
  descriptionForLlm: string;
  parametersSchema: Record<string, unknown>;
  requiredPermission: string;
  handlerId: string;
  isDestructive: boolean;
  sortOrder: number;
  enabledByDefault: boolean;
  tenantOverride: boolean | null;
  effectiveEnabled: boolean;
}

export interface ChatActionRegistryEnvelope {
  data: ChatActionCatalogRow[];
}

export interface ChatProposalPreviewParam {
  /** Slug-style key (drafter / sourceContract / counterparty / instruction). */
  key: string;
  /** Human label for the param row. */
  label: string;
  /** Raw textual value if no mention. */
  text?: string;
  /** When the param resolves to a known entity, a chip is rendered. */
  mention?: ChatMention;
}

export interface ChatProposalReceipt {
  /** Headline confirmation copy. */
  message: string;
  /** Internal route the FE links to after success (e.g. /app/work). */
  link?: string;
  /** Echo of the params, redacted as needed, for the FE to render in the success card. */
  params?: Record<string, unknown>;
}

export type ChatSSEEvent =
  | { event: 'token'; data: { token: string } }
  | { event: 'resolverUsed'; data: { code: string; label: string; arguments: Record<string, unknown> } }
  | {
      event: 'proposal';
      data: {
        proposalId: string;
        actionCode: string;
        actionLabel: string;
        previewParams: ChatProposalPreviewParam[];
        rawParams: Record<string, unknown>;
      };
    }
  | { event: 'receipt'; data: { proposalId: string; receipt: ChatProposalReceipt } }
  | { event: 'done'; data: { requestLogId: string } }
  | {
      event: 'error';
      data: { code: 'ai_provider_error' | 'rate_limit_exceeded' | 'no_actions_available'; message: string };
    };

export interface ChatAskOptions {
  userId: number;
  userPermissions: ReadonlyArray<string>;
  userRole: string;
  messages: ChatMessage[];
  mentions: ChatMention[];
  tenantId?: string;
  abortSignal?: AbortSignal;
}

export interface ChatHandlerContext {
  userId: number;
  userPermissions: ReadonlyArray<string>;
  tenantId?: string;
}
