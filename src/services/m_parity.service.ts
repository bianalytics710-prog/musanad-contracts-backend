/**
 * M_parity service — thin DB-passthrough for the 4 entities introduced in
 * migration 058 (party / contract_template / contract_clause /
 * contract_obligation). Read-only this round (list + get).
 *
 * All 7 fn_'s are SECURITY INVOKER and gate on
 * 'contract.read.department' OR 'contract.edit'. The authenticated route
 * layer is sufficient — no separate authorise() at the route layer.
 */
import { db } from '../database/client';

export interface PartyListItem {
  id: number;
  partyType: 'individual' | 'company';
  nameEn: string;
  nameAr: string | null;
  tradeLicenseNumber: string | null;
  tradeLicenseIssuer: string | null;
  emirate: string | null;
  freeZone: string | null;
  country: string;
  contactEmail: string | null;
  contactPhone: string | null;
  createdAt: string;
}

export interface PartyDetail extends PartyListItem {
  registeredAddress: string | null;
  notes: string | null;
  updatedAt: string;
  recentContracts5: Array<{
    id: number;
    contractNumber: string;
    titleEn: string;
    status: string;
    valueAed: number | null;
    updatedAt: string;
  }>;
}

export interface PaginatedResult<T> {
  data: T[];
  pagination: { total: number; limit: number; offset: number };
}

export const listParties = (
  actorId: number,
  partyType?: string,
  search?: string,
  limit?: number,
  offset?: number,
): Promise<PaginatedResult<PartyListItem>> =>
  db.callFunction<PaginatedResult<PartyListItem>>(
    'fn_party_list',
    [actorId, partyType ?? null, search ?? null, limit ?? 100, offset ?? 0],
    { actorId },
  );

export const getPartyById = (
  actorId: number,
  partyId: number,
): Promise<PartyDetail> =>
  db.callFunction<PartyDetail>('fn_party_get_by_id', [actorId, partyId], {
    actorId,
  });

export interface TemplateListItem {
  id: number;
  nameEn: string;
  nameAr: string | null;
  contractType: string;
  descriptionEn: string | null;
  descriptionAr: string | null;
  language: 'en' | 'ar' | 'bilingual';
  regulatoryTags: string[];
  usageCount: number;
  createdAt: string;
}

export interface TemplateDetail extends TemplateListItem {
  bodyEn: string | null;
  bodyAr: string | null;
  updatedAt: string;
}

export const listTemplates = (
  actorId: number,
  contractType?: string,
  search?: string,
  limit?: number,
  offset?: number,
): Promise<PaginatedResult<TemplateListItem>> =>
  db.callFunction<PaginatedResult<TemplateListItem>>(
    'fn_template_list',
    [actorId, contractType ?? null, search ?? null, limit ?? 100, offset ?? 0],
    { actorId },
  );

export const getTemplateById = (
  actorId: number,
  templateId: number,
): Promise<TemplateDetail> =>
  db.callFunction<TemplateDetail>(
    'fn_template_get_by_id',
    [actorId, templateId],
    { actorId },
  );

export interface ClauseListItem {
  id: number;
  category: string;
  titleEn: string;
  titleAr: string | null;
  variant: 'standard' | 'alternative' | 'fallback';
  regulatoryRefs: string[];
  usageCount: number;
  createdAt: string;
}

export interface ClauseDetail extends ClauseListItem {
  bodyEn: string;
  bodyAr: string | null;
  legalCommentaryEn: string | null;
  legalCommentaryAr: string | null;
  updatedAt: string;
}

export const listClauses = (
  actorId: number,
  category?: string,
  variant?: string,
  search?: string,
  limit?: number,
  offset?: number,
): Promise<PaginatedResult<ClauseListItem>> =>
  db.callFunction<PaginatedResult<ClauseListItem>>(
    'fn_clause_list',
    [
      actorId,
      category ?? null,
      variant ?? null,
      search ?? null,
      limit ?? 100,
      offset ?? 0,
    ],
    { actorId },
  );

export const getClauseById = (
  actorId: number,
  clauseId: number,
): Promise<ClauseDetail> =>
  db.callFunction<ClauseDetail>('fn_clause_get_by_id', [actorId, clauseId], {
    actorId,
  });

export interface ObligationListItem {
  id: number;
  contractId: number;
  contractNumber: string;
  titleEn: string;
  titleAr: string | null;
  descriptionEn: string | null;
  obligationType: string;
  dueDate: string | null;
  recurrence: string;
  responsibleParty: string;
  assigneeUserId: number | null;
  status: 'open' | 'in_progress' | 'completed' | 'overdue' | 'waived';
  completedAt: string | null;
  createdAt: string;
}

export const listObligations = (
  actorId: number,
  status?: string,
  assigneeId?: number,
  limit?: number,
  offset?: number,
): Promise<PaginatedResult<ObligationListItem>> =>
  db.callFunction<PaginatedResult<ObligationListItem>>(
    'fn_obligation_list',
    [
      actorId,
      status ?? null,
      assigneeId ?? null,
      limit ?? 100,
      offset ?? 0,
    ],
    { actorId },
  );
