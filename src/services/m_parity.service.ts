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

export interface CreatePartyInput {
  partyType: 'individual' | 'company';
  nameEn: string;
  nameAr?: string | null;
  tradeLicenseNumber?: string | null;
  tradeLicenseIssuer?: string | null;
  emirate?: string | null;
  freeZone?: string | null;
  country?: string | null;
  contactEmail?: string | null;
  contactPhone?: string | null;
  registeredAddress?: string | null;
  notes?: string | null;
}

export const createParty = (
  actorId: number,
  input: CreatePartyInput,
): Promise<PartyDetail> =>
  db.callFunction<PartyDetail>(
    'fn_party_create',
    [
      actorId,
      input.partyType,
      input.nameEn,
      input.nameAr ?? null,
      input.tradeLicenseNumber ?? null,
      input.tradeLicenseIssuer ?? null,
      input.emirate ?? null,
      input.freeZone ?? null,
      input.country ?? 'United Arab Emirates',
      input.contactEmail ?? null,
      input.contactPhone ?? null,
      input.registeredAddress ?? null,
      input.notes ?? null,
    ],
    { actorId },
  );

export type TemplatePlaceholderKind = 'party' | 'date' | 'currency' | 'number' | 'text';

export interface TemplatePlaceholder {
  key: string;
  labelEn: string;
  labelAr?: string | null;
  kind: TemplatePlaceholderKind;
  required: boolean;
}

export interface TemplateListItem {
  id: number;
  nameEn: string;
  nameAr: string | null;
  contractType: string;
  descriptionEn: string | null;
  descriptionAr?: string | null;
  language: 'en' | 'ar' | 'bilingual';
  regulatoryTags: string[];
  regulatoryReference: string | null;
  usageCount: number;
  placeholderCount: number;
  updatedAt: string;
}

export interface TemplateDetail {
  id: number;
  nameEn: string;
  nameAr: string | null;
  contractType: string;
  descriptionEn: string | null;
  descriptionAr: string | null;
  language: 'en' | 'ar' | 'bilingual';
  regulatoryTags: string[];
  regulatoryReference: string | null;
  placeholders: TemplatePlaceholder[];
  bodyEn: string | null;
  bodyAr: string | null;
  usageCount: number;
  createdAt: string;
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

export interface TemplateDefaultClause {
  id: number;
  clauseId: number;
  sortOrder: number;
  isDefault: boolean;
  category: string;
  variant: 'standard' | 'alternative' | 'fallback';
  titleEn: string;
  titleAr: string | null;
}

export interface TemplateDefaultClausesResult {
  templateId: number;
  data: TemplateDefaultClause[];
}

export const getTemplateDefaultClauses = (
  actorId: number,
  templateId: number,
): Promise<TemplateDefaultClausesResult> =>
  db.callFunction<TemplateDefaultClausesResult>(
    'fn_template_default_clauses',
    [actorId, templateId],
    { actorId },
  );

export interface CreateTemplateInput {
  nameEn: string;
  contractType: string;
  language?: 'en' | 'ar' | 'bilingual';
  nameAr?: string | null;
  descriptionEn?: string | null;
  descriptionAr?: string | null;
  bodyEn?: string | null;
  bodyAr?: string | null;
  regulatoryTags?: string[];
  placeholders?: TemplatePlaceholder[];
  regulatoryReference?: string | null;
}

export const createTemplate = (
  actorId: number,
  input: CreateTemplateInput,
): Promise<TemplateDetail> =>
  db.callFunction<TemplateDetail>(
    'fn_template_create',
    [
      actorId,
      input.nameEn,
      input.contractType,
      input.language ?? 'en',
      input.nameAr ?? null,
      input.descriptionEn ?? null,
      input.descriptionAr ?? null,
      input.bodyEn ?? null,
      input.bodyAr ?? null,
      input.regulatoryTags ?? [],
      JSON.stringify(input.placeholders ?? []),
      input.regulatoryReference ?? null,
    ],
    { actorId },
  );

export interface UpdateTemplateInput {
  nameEn?: string | null;
  nameAr?: string | null;
  descriptionEn?: string | null;
  descriptionAr?: string | null;
  bodyEn?: string | null;
  bodyAr?: string | null;
  language?: 'en' | 'ar' | 'bilingual' | null;
  contractType?: string | null;
  regulatoryTags?: string[] | null;
  placeholders?: TemplatePlaceholder[] | null;
  regulatoryReference?: string | null;
}

export const updateTemplate = (
  actorId: number,
  templateId: number,
  input: UpdateTemplateInput,
): Promise<TemplateDetail> =>
  db.callFunction<TemplateDetail>(
    'fn_template_update',
    [
      actorId,
      templateId,
      input.nameEn ?? null,
      input.nameAr ?? null,
      input.descriptionEn ?? null,
      input.descriptionAr ?? null,
      input.bodyEn ?? null,
      input.bodyAr ?? null,
      input.language ?? null,
      input.contractType ?? null,
      input.regulatoryTags ?? null,
      input.placeholders ? JSON.stringify(input.placeholders) : null,
      input.regulatoryReference ?? null,
    ],
    { actorId },
  );

export const deleteTemplate = (
  actorId: number,
  templateId: number,
): Promise<{ id: number; deleted: boolean }> =>
  db.callFunction<{ id: number; deleted: boolean }>(
    'fn_template_delete',
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

export interface CreateClauseInput {
  category: string;
  titleEn: string;
  bodyEn: string;
  variant?: 'standard' | 'alternative' | 'fallback';
  titleAr?: string | null;
  bodyAr?: string | null;
  legalCommentaryEn?: string | null;
  legalCommentaryAr?: string | null;
  regulatoryRefs?: string[];
}

export const createClause = (
  actorId: number,
  input: CreateClauseInput,
): Promise<ClauseDetail> =>
  db.callFunction<ClauseDetail>(
    'fn_clause_create',
    [
      actorId,
      input.category,
      input.titleEn,
      input.bodyEn,
      input.variant ?? 'standard',
      input.titleAr ?? null,
      input.bodyAr ?? null,
      input.legalCommentaryEn ?? null,
      input.legalCommentaryAr ?? null,
      input.regulatoryRefs ?? [],
    ],
    { actorId },
  );

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
  /** Last manual-flag event surfaced by fn_obligation_list (mig 500). */
  flaggedAt?: string | null;
  flaggedByName?: string | null;
  flaggedNote?: string | null;
}

export interface FlagObligationResult {
  eventId: number;
  roleCodes: string[];
  notifiedUserIds: number[];
  notificationCount: number;
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

export const flagObligation = (
  actorId: number,
  obligationId: number,
  note?: string | null,
): Promise<FlagObligationResult> =>
  db.callFunction<FlagObligationResult>(
    'fn_obligation_flag',
    [actorId, obligationId, note ?? null],
    { actorId },
  );

export interface CreateObligationInput {
  contractId: number;
  titleEn: string;
  obligationType: 'payment' | 'delivery' | 'reporting' | 'renewal' | 'compliance' | 'notice' | 'other';
  dueDate?: string | null;
  recurrence?: 'once' | 'monthly' | 'quarterly' | 'annually';
  responsibleParty?: 'our_party' | 'counterparty' | 'both';
  titleAr?: string | null;
  descriptionEn?: string | null;
  descriptionAr?: string | null;
  assigneeUserId?: number | null;
  status?: 'open' | 'in_progress' | 'completed' | 'overdue' | 'waived';
}

export const createObligation = (
  actorId: number,
  input: CreateObligationInput,
): Promise<ObligationListItem> =>
  db.callFunction<ObligationListItem>(
    'fn_obligation_create',
    [
      actorId,
      input.contractId,
      input.titleEn,
      input.obligationType,
      input.dueDate ?? null,
      input.recurrence ?? 'once',
      input.responsibleParty ?? 'our_party',
      input.titleAr ?? null,
      input.descriptionEn ?? null,
      input.descriptionAr ?? null,
      input.assigneeUserId ?? null,
      input.status ?? 'open',
    ],
    { actorId },
  );
