/**
 * Read-only resolver tools for the AI Chat Orchestrator.
 *
 * Each resolver is the inside-loop equivalent of a typeahead endpoint:
 * the model calls one to disambiguate an entity reference, the result
 * goes back into the chat thread, and the model continues toward a
 * write_action proposal.
 *
 * Resolvers DO NOT require user confirmation — they only read. They
 * reuse the same fn_'s that the corresponding REST endpoints hit, so the
 * caller's RLS scope is preserved and authentic permission gates apply.
 *
 * NOTE: each resolver returns a PLAIN object (not a JSON string) so the
 * orchestrator can feed it into the OpenAI tool_calls loop as-is.
 */
import { db } from '../../../database/client';
import type { ChatHandlerContext } from '../../../types/chat-orchestrator.types';

interface CountedRow {
  id: number;
  [k: string]: unknown;
}

function asArray<T = CountedRow>(envelope: unknown): T[] {
  if (envelope && typeof envelope === 'object') {
    if (Array.isArray((envelope as { data?: unknown[] }).data)) {
      return ((envelope as { data: T[] }).data) ?? [];
    }
    // Some fn_'s nest twice: {data:{data:[...]}}.
    const inner = (envelope as { data?: { data?: unknown[] } }).data;
    if (inner && Array.isArray(inner.data)) {
      return (inner.data as T[]) ?? [];
    }
  }
  return [];
}

function ilikeMatch(value: unknown, query: string | undefined): boolean {
  if (!query) return true;
  if (typeof value !== 'string') return false;
  return value.toLowerCase().includes(query.toLowerCase());
}

export const resolverHandlers = {
  /** Look up a contract by its number. Wraps fn_work_order_contract_lookup. */
  async lookup_contract_by_number(
    args: { number?: string },
    ctx: ChatHandlerContext,
  ): Promise<Record<string, unknown>> {
    const number = (args.number ?? '').trim();
    if (!number) {
      return { found: false, reason: 'empty_query' };
    }
    const result = await db.callFunction<Record<string, unknown> | null>(
      'fn_work_order_contract_lookup',
      [ctx.userId, number],
      { actorId: ctx.userId, tenantId: ctx.tenantId },
    );
    return (result as Record<string, unknown>) ?? { found: false };
  },

  /** List drafters the caller can assign work to. Wraps fn_work_order_assignable_drafters. */
  async find_drafters(
    args: { query?: string },
    ctx: ChatHandlerContext,
  ): Promise<Record<string, unknown>> {
    const envelope = await db.callFunction<unknown>(
      'fn_work_order_assignable_drafters',
      [ctx.userId],
      { actorId: ctx.userId, tenantId: ctx.tenantId },
    );
    const rows = asArray<Record<string, unknown>>(envelope);
    const q = (args.query ?? '').trim();
    const narrowed = q ? rows.filter((r) => ilikeMatch(r.fullName, q) || ilikeMatch(r.email, q)) : rows;
    return {
      results: narrowed.slice(0, 25).map((r) => ({
        id: r.id,
        fullName: r.fullName,
        email: r.email,
        openWorkOrders: r.openWorkOrders ?? 0,
      })),
      totalAvailable: rows.length,
    };
  },

  /** Search active users (any role). Wraps fn_work_order_requestor_options + filter. */
  async find_users(
    args: { query?: string },
    ctx: ChatHandlerContext,
  ): Promise<Record<string, unknown>> {
    const q = (args.query ?? '').trim();
    if (!q) return { results: [], reason: 'empty_query' };
    const envelope = await db.callFunction<{ items?: Record<string, unknown>[] } | null>(
      'fn_work_order_requestor_options',
      [ctx.userId],
      { actorId: ctx.userId, tenantId: ctx.tenantId },
    );
    const items = envelope?.items ?? [];
    const narrowed = items.filter((u) => {
      const full = `${u.firstName ?? ''} ${u.lastName ?? ''}`.trim();
      return ilikeMatch(full, q) || ilikeMatch(u.email, q);
    });
    return {
      results: narrowed.slice(0, 25).map((u) => ({
        id: u.id,
        firstName: u.firstName,
        lastName: u.lastName,
        email: u.email,
        roleName: u.roleName,
      })),
    };
  },

  /** Search counterparty parties. Wraps fn_work_order_counterparty_options + filter. */
  async find_parties(
    args: { query?: string },
    ctx: ChatHandlerContext,
  ): Promise<Record<string, unknown>> {
    const q = (args.query ?? '').trim();
    if (!q) return { results: [], reason: 'empty_query' };
    const envelope = await db.callFunction<unknown>(
      'fn_work_order_counterparty_options',
      [ctx.userId],
      { actorId: ctx.userId, tenantId: ctx.tenantId },
    );
    const rows = asArray<Record<string, unknown>>(envelope);
    const narrowed = rows.filter((p) => ilikeMatch(p.nameEn, q));
    return {
      results: narrowed.slice(0, 25).map((p) => ({
        id: p.id,
        nameEn: p.nameEn,
        partyType: p.partyType,
      })),
      hintForProspect:
        narrowed.length === 0
          ? `No party named "${q}" exists. If this is a brand-new counterparty, pass counterpartyProspectName="${q}" to the write action instead of counterpartyId.`
          : undefined,
    };
  },
} as const;

export type ResolverHandlerId = keyof typeof resolverHandlers;
