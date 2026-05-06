/**
 * R-LC7 — Impact Watch service. Thin DB-passthrough for fn_impact_signal_*.
 */
import { db } from '../database/client';

export interface ImpactSignalListItem {
  id: number;
  extId: string;
  category: 'regulatory' | 'commodity_prices' | 'supply_chain' | 'geopolitical' | 'market_financial';
  source: string;
  severity: string;
  titleEn: string;
  titleAr: string | null;
  descriptionEn: string | null;
  descriptionAr: string | null;
  affectedClauseCategories: string[];
  publishedDate: string;
  effectiveDate: string | null;
  complianceDeadline: string | null;
  impactedContractCount: number;
  createdAt: string;
}

export interface ImpactSignalDetail extends Omit<ImpactSignalListItem, 'impactedContractCount'> {
  impactedContracts: Array<{
    id: number;
    contractId: number;
    contractNumber: string;
    titleEn: string;
    impactScore: number;
    status: 'pending' | 'reviewed' | 'amended' | 'dismissed';
    reviewedAt: string | null;
  }>;
  updatedAt: string;
}

export interface ImpactSignalListResponse {
  data: ImpactSignalListItem[];
  pagination: { total: number; limit: number; offset: number };
}

export const listImpactSignals = (
  actorId: number,
  category?: string,
  severity?: string,
  search?: string,
  limit = 100,
  offset = 0,
): Promise<ImpactSignalListResponse> =>
  db.callFunction<ImpactSignalListResponse>(
    'fn_impact_signal_list',
    [actorId, category ?? null, severity ?? null, search ?? null, limit, offset],
    { actorId },
  );

export const getImpactSignal = (actorId: number, signalId: number): Promise<ImpactSignalDetail> =>
  db.callFunction<ImpactSignalDetail>('fn_impact_signal_get', [actorId, signalId], { actorId });

export const markImpactReviewed = (actorId: number, linkId: number): Promise<{ id: number; signalId: number; contractId: number; status: string }> =>
  db.callFunction('fn_impact_signal_mark_reviewed', [actorId, linkId], { actorId });

export const notifyDrafters = (actorId: number, signalId: number): Promise<{ signalId: number; notified: number }> =>
  db.callFunction('fn_impact_signal_notify_drafters', [actorId, signalId], { actorId });

export const bulkAmend = (actorId: number, signalId: number): Promise<{ signalId: number; amended: number }> =>
  db.callFunction('fn_impact_signal_bulk_amend', [actorId, signalId], { actorId });
