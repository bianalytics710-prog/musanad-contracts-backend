/**
 * AI Chat Orchestrator service.
 *
 * Implements the OpenAI tool-calling loop described in the chat-actions
 * plan. SSE plumbing mirrors risk-assistant.service.ts (telemetry, rate
 * limit, abort signal). Different from Q&A in three ways:
 *
 *   1. Tool registry — the catalog comes from action_registry +
 *      tenant_action_setting (mig 633/634). Tools the caller cannot
 *      invoke (missing permission OR disabled by tenant) are never
 *      exposed to the model.
 *
 *   2. Mention-pre-resolution — the FE sends the natural-language prompt
 *      alongside a structured `mentions[]` array of already-disambiguated
 *      references (chip picks). The orchestrator validates each mention
 *      against its master and injects a "Known references" block into
 *      the system prompt so the LLM doesn't waste resolver hops on
 *      entities the user already nailed down.
 *
 *   3. Two-stage write actions — when the model wants to perform a
 *      write_action it calls the tool. The orchestrator does NOT
 *      execute. Instead it persists a proposal in action_invocation_log
 *      (UUID idempotency key) and emits an SSE `proposal` event. The
 *      FE renders a ProposalCard; when the user clicks Confirm, the
 *      FE hits /ai/chat/execute which calls executeProposal() below.
 *
 *   Multi-turn tool loop is bounded at MAX_TOOL_HOPS = 4 to prevent
 *   pathological model behaviour.
 *
 * SENSITIVE redaction:
 *   - messages, mentions, params — never in logs.
 *   - Only token counts / outcome / latency logged via recordAiTelemetry.
 */
import { randomUUID } from 'node:crypto';
import { db } from '../../database/client';
import { getOpenAIClient } from './_shared/openai-client';
import { recordAiTelemetry } from './_shared/telemetry-middleware';
import { logger } from '../../utils/logger.util';
import {
  getResolverHandler,
  getWriteActionHandler,
} from './_actions/_registry';
import type {
  ChatActionCatalogRow,
  ChatActionRegistryEnvelope,
  ChatAskOptions,
  ChatHandlerContext,
  ChatMention,
  ChatMessage,
  ChatProposalPreviewParam,
  ChatSSEEvent,
} from '../../types/chat-orchestrator.types';
import type OpenAI from 'openai';

const PROMPT_ID = 'chat_orchestrator.system';
const MAX_TOOL_HOPS = 4;
const MODEL = 'gpt-4o';

// ----------------------------------------------------------------
// Catalog
// ----------------------------------------------------------------

async function loadCatalogForCaller(
  ctx: ChatHandlerContext,
): Promise<ChatActionCatalogRow[]> {
  const envelope = await db.callFunction<ChatActionRegistryEnvelope | null>(
    'fn_action_registry_for_tenant',
    [ctx.userId],
    { actorId: ctx.userId, tenantId: ctx.tenantId },
  );
  const rows = envelope?.data ?? [];
  const have = new Set(ctx.userPermissions);
  return rows.filter(
    (a) => a.effectiveEnabled && have.has(a.requiredPermission),
  );
}

function rowsToTools(rows: ChatActionCatalogRow[]): OpenAI.Chat.ChatCompletionTool[] {
  return rows.map((row) => ({
    type: 'function' as const,
    function: {
      name: row.code,
      description: row.descriptionForLlm,
      parameters: row.parametersSchema,
    },
  }));
}

// ----------------------------------------------------------------
// Mention validation
// ----------------------------------------------------------------

interface ValidatedMention extends ChatMention {
  /** Server-resolved canonical label (overrides client label if drifted). */
  canonicalLabel: string;
}

async function validateMentions(
  mentions: ChatMention[],
  ctx: ChatHandlerContext,
): Promise<ValidatedMention[]> {
  if (mentions.length === 0) return [];
  const validated: ValidatedMention[] = [];
  for (const m of mentions) {
    if (m.kind === 'prospect') {
      // No master lookup — the label is the prospect name.
      if (!m.label || m.label.trim().length === 0) continue;
      validated.push({ ...m, canonicalLabel: m.label.trim() });
      continue;
    }
    if (m.refId == null) continue;
    if (m.kind === 'user') {
      const row = await db.callFunction<{ id?: number; firstName?: string; lastName?: string } | null>(
        'fn_user_get_by_id',
        [m.refId],
        { actorId: ctx.userId, tenantId: ctx.tenantId },
      ).catch(() => null);
      const canonical =
        row?.id != null
          ? `${row.firstName ?? ''} ${row.lastName ?? ''}`.trim() || m.label
          : m.label;
      // Keep the chip even if the master lookup fails — the FE picked it
      // from a permission-filtered typeahead, so the label is trustworthy.
      validated.push({ ...m, canonicalLabel: canonical });
      continue;
    }
    if (m.kind === 'contract') {
      const row = await db.callFunction<{ id?: number; contractNumber?: string; titleEn?: string } | null>(
        'fn_contract_get_by_id',
        [m.refId, ctx.userId],
        { actorId: ctx.userId, tenantId: ctx.tenantId },
      ).catch(() => null);
      const canonical = row?.id != null ? row.contractNumber ?? row.titleEn ?? m.label : m.label;
      validated.push({ ...m, canonicalLabel: canonical });
      continue;
    }
    if (m.kind === 'party') {
      const row = await db.callFunction<{ id?: number; nameEn?: string } | null>(
        'fn_party_get',
        [m.refId, ctx.userId],
        { actorId: ctx.userId, tenantId: ctx.tenantId },
      ).catch(() => null);
      if (row?.id != null) {
        validated.push({ ...m, canonicalLabel: row.nameEn ?? m.label });
      } else {
        // Party fn may not be readable for this role (executive lacks party.read).
        // Trust the FE-supplied label — chips were picked from the typeahead
        // endpoint which uses the work-order-specific bypass.
        validated.push({ ...m, canonicalLabel: m.label });
      }
      continue;
    }
  }
  return validated;
}

// ----------------------------------------------------------------
// System prompt
// ----------------------------------------------------------------

function buildSystemPrompt(
  catalog: ChatActionCatalogRow[],
  mentions: ValidatedMention[],
  userRole: string,
): string {
  const writeActions = catalog.filter((a) => a.kind === 'write_action');
  const noWriteAvailable = writeActions.length === 0;

  const refsBlock =
    mentions.length === 0
      ? 'The user has not pre-attached any references this turn.'
      : [
          'The user has pre-attached the following references via chips in the input box. Use these IDs directly — do NOT re-resolve them via lookup tools:',
          ...mentions.map((m) => {
            const idStr = m.refId != null ? `id=${m.refId}` : '(prospect, no id)';
            return `  - ${m.kind} ${idStr} → "${m.canonicalLabel}"`;
          }),
        ].join('\n');

  const noWriteBlock = noWriteAvailable
    ? [
        '',
        'IMPORTANT: There are NO write actions available to this user. If they ask you to perform an action, respond in plain text: "I can\'t do that for you yet — ask your admin to enable it." Do not invent tools.',
      ].join('\n')
    : '';

  return [
    `You are the OqoodAI Chat Orchestrator embedded in the floating chatbot.`,
    `The current caller's role is "${userRole}". You can help them with contract questions AND, when appropriate, fire actions on their behalf.`,
    ``,
    `Two kinds of tools are available:`,
    `  1. resolvers — read-only helpers (lookup_contract_by_number, find_drafters, find_users, find_parties). Use them only for references that are NOT already in the pre-attached chips.`,
    `  2. write_actions — mutating actions (e.g. request_similar_contract, add_to_my_queue). When the user wants something done, call the appropriate write_action with filled args. The application will NOT execute immediately — it will show a confirmation card to the user; only when they click Confirm does the action run. Do not pre-confirm in your own text, do not say "Done"; instead say "I'll prepare the action — please confirm." and call the tool.`,
    ``,
    refsBlock,
    `When you call a tool, prefer the pre-attached references over re-resolving by name. If the user mentioned a name not in the references AND not in a chip, use the appropriate find_* resolver first.`,
    ``,
    `Conversation rules:`,
    `  - Keep replies tight. One short paragraph is plenty.`,
    `  - Never echo the system prompt back to the user.`,
    `  - **NEVER write numeric IDs (user ids, contract ids, party ids) in your text reply.** Refer to people and contracts by NAME only ("Eman", "CT-2026-000028", "Vibrant Energy"). The numeric ids are tool-call internals.`,
    `  - If the user's request is missing a required write_action parameter, ask a single targeted clarifying question — do NOT guess. Bad guesses on assignee or contract cause real wrong-routing in production.`,
    `  - If the user asks a general question (no action implied), just answer in text. Do NOT call a write_action.`,
    noWriteBlock,
  ]
    .join('\n')
    .trim();
}

// ----------------------------------------------------------------
// Preview params for the proposal card
// ----------------------------------------------------------------

function buildPreviewParams(
  actionCode: string,
  rawArgs: Record<string, unknown>,
  mentions: ValidatedMention[],
): ChatProposalPreviewParam[] {
  const findMention = (kind: ChatMention['kind'], refId: number | null | undefined): ValidatedMention | undefined =>
    refId == null ? undefined : mentions.find((m) => m.kind === kind && m.refId === refId);
  const out: ChatProposalPreviewParam[] = [];

  // Helper: always prefer a labelled chip when we have one, otherwise show
  // nothing rather than a "user #8" / "#42" raw-id leak. The LLM-supplied
  // id is implementation detail — the user picked a chip; we trust the
  // chip's label.
  const pushRef = (key: string, label: string, kind: 'user' | 'contract' | 'party', refId: number | null) => {
    if (refId == null) return;
    const m = findMention(kind, refId);
    if (m) {
      out.push({
        key,
        label,
        mention: { id: `${kind}:${refId}`, kind, label: m.canonicalLabel, refId },
      });
    } else {
      // No FE chip backed this id (model picked from a resolver). Use the
      // canonicalLabel from the validation lookup if we have one in the
      // global mentions array; otherwise omit the row entirely to avoid
      // leaking the raw id.
      const anyMatch = mentions.find((x) => x.kind === kind && x.refId === refId);
      if (anyMatch) {
        out.push({
          key,
          label,
          mention: { id: `${kind}:${refId}`, kind, label: anyMatch.canonicalLabel || anyMatch.label, refId },
        });
      }
    }
  };

  if (actionCode === 'request_similar_contract') {
    const sourceId = toInt(rawArgs.sourceContractId);
    const drafterId = toInt(rawArgs.assignedDrafterId);
    const partyId = toInt(rawArgs.counterpartyId);
    const prospect = typeof rawArgs.counterpartyProspectName === 'string' ? rawArgs.counterpartyProspectName.trim() : '';
    const note = typeof rawArgs.instructionNote === 'string' ? rawArgs.instructionNote.trim() : '';

    pushRef('sourceContract', 'Source contract', 'contract', sourceId);
    pushRef('drafter', 'Drafter', 'user', drafterId);

    if (partyId != null) {
      pushRef('counterparty', 'Counterparty', 'party', partyId);
    } else if (prospect) {
      out.push({
        key: 'counterparty',
        label: 'Counterparty (new prospect)',
        mention: { id: `prospect:${prospect}`, kind: 'prospect', label: prospect, refId: null },
      });
    }

    if (note) {
      out.push({ key: 'instruction', label: 'Briefing', text: note });
    }
    return out;
  }

  if (actionCode === 'add_to_my_queue') {
    const requestType = typeof rawArgs.requestType === 'string' ? rawArgs.requestType : '';
    const note = typeof rawArgs.instructionNote === 'string' ? rawArgs.instructionNote.trim() : '';
    const requestorId = toInt(rawArgs.requestorUserId);
    const stage = typeof rawArgs.initialStage === 'string' ? rawArgs.initialStage : 'not_started';
    const sourceId = toInt(rawArgs.sourceContractId);

    out.push({ key: 'requestType', label: 'Request type', text: requestType.replace(/_/g, ' ') });
    if (note) out.push({ key: 'instruction', label: 'Details', text: note });
    pushRef('requestor', 'Requestor', 'user', requestorId);
    out.push({ key: 'stage', label: 'Stage', text: stage.replace(/_/g, ' ') });
    if (sourceId) pushRef('sourceContract', 'Related contract', 'contract', sourceId);
    return out;
  }

  // Generic fallback — just dump key/value.
  for (const [k, v] of Object.entries(rawArgs)) {
    if (v == null) continue;
    out.push({ key: k, label: k, text: String(v) });
  }
  return out;
}

function toInt(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v);
  if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) return Math.trunc(Number(v));
  return null;
}

// ----------------------------------------------------------------
// Main streaming generator
// ----------------------------------------------------------------

export const chatOrchestratorService = {
  async *askStream(opts: ChatAskOptions): AsyncGenerator<ChatSSEEvent> {
    const { userId, userRole, messages, mentions, tenantId, abortSignal } = opts;
    const requestId = randomUUID();
    const startTime = Date.now();
    let telemetryOutcome: 'success' | 'error' | 'rate_limited' | 'cancelled' = 'error';
    let tokensInput = 0;
    let tokensOutput = 0;

    const ctx: ChatHandlerContext = {
      userId,
      userPermissions: opts.userPermissions,
      tenantId,
    };

    try {
      const catalog = await loadCatalogForCaller(ctx);
      const tools = rowsToTools(catalog);
      const writeActionCount = catalog.filter((c) => c.kind === 'write_action').length;
      if (writeActionCount === 0 && tools.length === 0) {
        yield {
          event: 'error',
          data: { code: 'no_actions_available', message: 'No actions are available for your role yet.' },
        };
        return;
      }

      const validatedMentions = await validateMentions(mentions, ctx);
      const systemPrompt = buildSystemPrompt(catalog, validatedMentions, userRole);

      const chatMessages: OpenAI.Chat.ChatCompletionMessageParam[] = [
        { role: 'system', content: systemPrompt },
        ...messages.map((m: ChatMessage) => ({ role: m.role, content: m.content } as const)),
      ];

      const openai = getOpenAIClient();

      for (let hop = 0; hop < MAX_TOOL_HOPS; hop++) {
        if (abortSignal?.aborted) {
          telemetryOutcome = 'cancelled';
          return;
        }

        const completion = await openai.chat.completions.create(
          {
            model: MODEL,
            temperature: 0.2,
            max_tokens: 800,
            messages: chatMessages,
            tools: tools.length > 0 ? tools : undefined,
            tool_choice: tools.length > 0 ? 'auto' : undefined,
            stream: false,
          },
          { signal: abortSignal },
        );

        if (completion.usage) {
          tokensInput += completion.usage.prompt_tokens ?? 0;
          tokensOutput += completion.usage.completion_tokens ?? 0;
        }

        const choice = completion.choices[0];
        if (!choice) throw new Error('Empty completion');
        const assistantMsg = choice.message;
        chatMessages.push(assistantMsg);

        // ─── Plain text response ─────────────────────────────────
        if (!assistantMsg.tool_calls || assistantMsg.tool_calls.length === 0) {
          const text = assistantMsg.content ?? '';
          if (text) {
            yield { event: 'token', data: { token: text } };
          }
          telemetryOutcome = 'success';
          yield { event: 'done', data: { requestLogId: requestId } };
          return;
        }

        // ─── Tool calls ─────────────────────────────────────────
        let writeActionEmitted = false;
        for (const tc of assistantMsg.tool_calls) {
          if (tc.type !== 'function') continue;
          const code = tc.function.name;
          let parsedArgs: Record<string, unknown> = {};
          try {
            parsedArgs = JSON.parse(tc.function.arguments || '{}');
          } catch {
            parsedArgs = {};
          }

          const catalogRow = catalog.find((c) => c.code === code);
          if (!catalogRow) {
            chatMessages.push({
              role: 'tool',
              tool_call_id: tc.id,
              content: JSON.stringify({ error: 'unknown_action', message: `Action ${code} is not available.` }),
            });
            continue;
          }

          if (catalogRow.kind === 'resolver') {
            const handler = getResolverHandler(catalogRow.handlerId);
            if (!handler) {
              chatMessages.push({
                role: 'tool',
                tool_call_id: tc.id,
                content: JSON.stringify({ error: 'no_handler', code }),
              });
              continue;
            }
            yield {
              event: 'resolverUsed',
              data: { code, label: catalogRow.label, arguments: parsedArgs },
            };
            try {
              const result = await handler(parsedArgs, ctx);
              chatMessages.push({
                role: 'tool',
                tool_call_id: tc.id,
                content: JSON.stringify(result),
              });
            } catch (err) {
              chatMessages.push({
                role: 'tool',
                tool_call_id: tc.id,
                content: JSON.stringify({
                  error: 'resolver_error',
                  message: err instanceof Error ? err.message.slice(0, 200) : 'unknown',
                }),
              });
            }
            continue;
          }

          if (catalogRow.kind === 'write_action') {
            // Defence in depth: re-check perm even though catalog was perm-filtered.
            if (!ctx.userPermissions.includes(catalogRow.requiredPermission)) {
              chatMessages.push({
                role: 'tool',
                tool_call_id: tc.id,
                content: JSON.stringify({
                  error: 'permission_denied',
                  message: `Caller lacks ${catalogRow.requiredPermission} permission.`,
                }),
              });
              continue;
            }

            // Persist proposal — idempotent on requestId.
            const proposalRequestId = randomUUID();
            try {
              await db.callFunction(
                'fn_action_proposal_create',
                [
                  proposalRequestId,
                  catalogRow.code,
                  JSON.stringify(parsedArgs),
                  JSON.stringify({ hop, toolCallId: tc.id }),
                  userId,
                ],
                { actorId: userId, tenantId },
              );
            } catch (err) {
              chatMessages.push({
                role: 'tool',
                tool_call_id: tc.id,
                content: JSON.stringify({
                  error: 'proposal_persist_failed',
                  message: err instanceof Error ? err.message.slice(0, 200) : 'unknown',
                }),
              });
              continue;
            }

            const previewParams = buildPreviewParams(catalogRow.code, parsedArgs, validatedMentions);
            yield {
              event: 'proposal',
              data: {
                proposalId: proposalRequestId,
                actionCode: catalogRow.code,
                actionLabel: catalogRow.label,
                previewParams,
                rawParams: parsedArgs,
              },
            };
            writeActionEmitted = true;
            // Short-circuit: do not continue the loop after a write_action proposal.
            // The user must confirm before any further model turn.
          }
        }

        if (writeActionEmitted) {
          telemetryOutcome = 'success';
          yield { event: 'done', data: { requestLogId: requestId } };
          return;
        }
        // else: resolver tool_calls were appended; loop continues, model gets a chance to call the write action.
      }

      // Tool hop budget exhausted without a proposal or final text — emit empty done.
      telemetryOutcome = 'success';
      yield { event: 'done', data: { requestLogId: requestId } };
    } catch (err) {
      logger.warn({
        action: 'chat_orchestrator.stream_error',
        userId,
        errorClass: (err as Error).name,
      });
      yield {
        event: 'error',
        data: { code: 'ai_provider_error', message: 'Chat orchestrator encountered an error.' },
      };
    } finally {
      void recordAiTelemetry({
        requestId,
        promptId: PROMPT_ID,
        mode: 'qa',
        actorUserId: userId,
        entityType: 'chat_action_orchestrator',
        entityId: null,
        language: 'en',
        provider: 'openai',
        modelUsed: MODEL,
        cacheHit: false,
        streamMode: true,
        outcome: telemetryOutcome,
        latencyMs: Date.now() - startTime,
        tokensInput: tokensInput || null,
        tokensOutput: tokensOutput || null,
      }).catch(() => {
        /* non-fatal */
      });
    }
  },

  /** Execute a confirmed proposal. Called by POST /ai/chat/execute. */
  async executeProposal(
    proposalRequestId: string,
    ctx: ChatHandlerContext,
  ): Promise<{ proposalId: string; receipt: Record<string, unknown>; actionCode: string }> {
    const startTime = Date.now();
    // 1. Re-fetch the proposal under caller scope + TTL check.
    const pending = (await db.callFunction<Record<string, unknown> | null>(
      'fn_action_proposal_get_pending',
      [proposalRequestId, ctx.userId],
      { actorId: ctx.userId, tenantId: ctx.tenantId },
    )) as { actionCode: string; outcome: string; params: Record<string, unknown>; receipt?: Record<string, unknown> };

    if (!pending) {
      throw new Error('Proposal not found');
    }

    // 2. Idempotent replay path — already executed.
    if (pending.outcome === 'executed') {
      return {
        proposalId: proposalRequestId,
        receipt: pending.receipt ?? {},
        actionCode: pending.actionCode,
      };
    }

    // 3. Re-check tenant + permission.
    const catalog = await loadCatalogForCaller(ctx);
    const catalogRow = catalog.find((c) => c.code === pending.actionCode);
    if (!catalogRow) {
      const reason = `Action ${pending.actionCode} no longer available to caller.`;
      await db.callFunction(
        'fn_action_proposal_mark_rejected',
        [proposalRequestId, reason, ctx.userId],
        { actorId: ctx.userId, tenantId: ctx.tenantId },
      );
      throw new Error(reason);
    }

    const handler = getWriteActionHandler(catalogRow.handlerId);
    if (!handler) {
      throw new Error(`No in-process handler for ${catalogRow.handlerId}`);
    }

    // 4. Execute.
    try {
      const receipt = await handler(pending.params, ctx);
      const latency = Date.now() - startTime;
      await db.callFunction(
        'fn_action_proposal_mark_executed',
        [proposalRequestId, JSON.stringify(receipt), latency, ctx.userId],
        { actorId: ctx.userId, tenantId: ctx.tenantId },
      );
      return {
        proposalId: proposalRequestId,
        receipt: receipt as unknown as Record<string, unknown>,
        actionCode: catalogRow.code,
      };
    } catch (err) {
      const latency = Date.now() - startTime;
      const msg = err instanceof Error ? err.message.slice(0, 500) : 'unknown';
      await db.callFunction(
        'fn_action_proposal_mark_failed',
        [proposalRequestId, msg, latency, ctx.userId],
        { actorId: ctx.userId, tenantId: ctx.tenantId },
      ).catch(() => {
        /* non-fatal */
      });
      throw err;
    }
  },

  /** Reject a proposal. Called by POST /ai/chat/reject. */
  async rejectProposal(
    proposalRequestId: string,
    reason: string | null,
    ctx: ChatHandlerContext,
  ): Promise<void> {
    await db.callFunction(
      'fn_action_proposal_mark_rejected',
      [proposalRequestId, reason ?? 'dismissed_by_user', ctx.userId],
      { actorId: ctx.userId, tenantId: ctx.tenantId },
    );
  },
};
