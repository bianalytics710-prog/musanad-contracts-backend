/**
 * /api/v1/ai/chat/mentions/{users|contracts|parties} — typeahead controllers.
 *
 * Power the FE @user / #contract / ~party mention dropdowns inside the
 * floating chatbot textarea. Permission-filtered against the caller's
 * read scope — drafter @-typeahead never returns platform_admins, etc.
 *
 * Parties endpoint always appends a synthetic `prospect` row when q is
 * non-empty so the FE can render the "+ Create new prospect" affordance.
 */
import type { NextFunction, Request, Response } from 'express';
import { db } from '../../database/client';
import { mentionQuerySchema } from '../../schemas/chat-mentions.schemas';

interface UserRow {
  id: number;
  firstName?: string | null;
  lastName?: string | null;
  email?: string | null;
  fullName?: string | null;
  roleName?: string | null;
  openWorkOrders?: number | null;
}

interface ContractRow {
  id: number;
  contract_number?: string | null;
  contractNumber?: string | null;
  title_en?: string | null;
  titleEn?: string | null;
  counterparty_name?: string | null;
  counterpartyName?: string | null;
}

interface PartyRow {
  id: number;
  nameEn?: string | null;
  partyType?: string | null;
}

function ilike(value: unknown, query: string): boolean {
  if (typeof value !== 'string') return false;
  return value.toLowerCase().includes(query.toLowerCase());
}

function asArray<T>(envelope: unknown): T[] {
  if (envelope && typeof envelope === 'object') {
    const top = envelope as { data?: unknown; items?: unknown };
    if (Array.isArray(top.data)) return top.data as T[];
    if (Array.isArray(top.items)) return top.items as T[];
    if (top.data && typeof top.data === 'object' && Array.isArray((top.data as { data?: unknown }).data)) {
      return ((top.data as { data: T[] }).data) ?? [];
    }
  }
  return [];
}

export const chatMentionsController = {
  // ─── GET /api/v1/ai/chat/mentions/users ─────────────────────
  async users(req: Request, res: Response, next: NextFunction): Promise<void> {
    const userId = req.user!.id;
    const userPerms = new Set(req.user!.permissions ?? []);
    try {
      const { q, limit } = mentionQuerySchema.parse(req.query);
      // Use the assignable_drafters list when the caller has work.create
      // (exec / platform_admin) — that's the natural population for @-
      // mentions during request_similar_contract. Otherwise fall back to
      // requestor_options (broader: any active user).
      const useDrafters = userPerms.has('work.create');
      const envelope = await db.callFunction<unknown>(
        useDrafters ? 'fn_work_order_assignable_drafters' : 'fn_work_order_requestor_options',
        [userId],
        { actorId: userId, tenantId: req.tenantId },
      );

      const rows = useDrafters
        ? asArray<UserRow>(envelope)
        : asArray<UserRow>(envelope);

      const trimmed = q.trim();
      const narrowed = trimmed
        ? rows.filter((r) => {
            const full = r.fullName ?? `${r.firstName ?? ''} ${r.lastName ?? ''}`.trim();
            return ilike(full, trimmed) || ilike(r.email, trimmed);
          })
        : rows;

      res.json({
        kind: 'user',
        results: narrowed.slice(0, limit).map((r) => ({
          id: r.id,
          label: (r.fullName ?? `${r.firstName ?? ''} ${r.lastName ?? ''}`.trim()) || r.email || '—',
          subLabel: r.roleName ?? r.email ?? undefined,
          meta: r.openWorkOrders != null ? { openWorkOrders: r.openWorkOrders } : undefined,
        })),
      });
    } catch (err) {
      next(err);
    }
  },

  // ─── GET /api/v1/ai/chat/mentions/contracts ─────────────────
  async contracts(req: Request, res: Response, next: NextFunction): Promise<void> {
    const userId = req.user!.id;
    const userRole = req.user!.role;
    try {
      const { q, limit } = mentionQuerySchema.parse(req.query);
      // fn_contract_list accepts a search term as $13 (per current arg layout).
      // We piggyback on it so the result is RLS-scoped to the caller's
      // read perimeter without us needing a separate fn_.
      const envelope = await db.callFunction<{ data?: ContractRow[]; pagination?: unknown } | null>(
        'fn_contract_list',
        [
          1, // page
          Math.max(limit * 3, 25), // pageSize: oversample so the local ILIKE has room
          null, // status
          null, // contractType
          null, // counterpartyId
          null, // draftedBy
          null, // approvedBy
          null, null, null, null, // date filters
          null, // tags
          q.trim() || null, // search
          userId,
          userRole,
          null, null, null, // import filters
          null, // language
          null, // governing_law / emirate
          null, // sort
          null, // riskBucket
        ],
        { actorId: userId, tenantId: req.tenantId },
      );

      const rows: ContractRow[] = envelope?.data ?? [];
      const trimmed = q.trim();
      const narrowed = trimmed
        ? rows.filter((r) => {
            const num = r.contractNumber ?? r.contract_number;
            const title = r.titleEn ?? r.title_en;
            return ilike(num, trimmed) || ilike(title, trimmed);
          })
        : rows;

      res.json({
        kind: 'contract',
        results: narrowed.slice(0, limit).map((r) => ({
          id: r.id,
          label: r.contractNumber ?? r.contract_number ?? `#${r.id}`,
          subLabel: r.titleEn ?? r.title_en ?? r.counterpartyName ?? r.counterparty_name ?? undefined,
        })),
      });
    } catch (err) {
      next(err);
    }
  },

  // ─── GET /api/v1/ai/chat/mentions/parties ───────────────────
  async parties(req: Request, res: Response, next: NextFunction): Promise<void> {
    const userId = req.user!.id;
    try {
      const { q, limit } = mentionQuerySchema.parse(req.query);
      const envelope = await db.callFunction<unknown>(
        'fn_party_dropdown_list',
        [userId],
        { actorId: userId, tenantId: req.tenantId },
      );
      const rows = asArray<PartyRow>(envelope);
      const trimmed = q.trim();
      const narrowed = trimmed ? rows.filter((r) => ilike(r.nameEn, trimmed)) : rows;
      const results: Array<{
        id: number | null;
        label: string;
        subLabel?: string;
        isProspect?: boolean;
        prospectName?: string;
      }> = narrowed.slice(0, limit).map((r) => ({
        id: r.id,
        label: r.nameEn ?? `#${r.id}`,
        subLabel: r.partyType ?? undefined,
      }));
      if (trimmed.length > 0) {
        results.push({
          id: null,
          label: `+ Create new prospect: "${trimmed}"`,
          isProspect: true,
          prospectName: trimmed,
        });
      }
      res.json({
        kind: 'party',
        results,
      });
    } catch (err) {
      next(err);
    }
  },
};
