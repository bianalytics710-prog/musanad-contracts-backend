// ============================================================
// R-LC9-2 — Zod schemas for the Impact Watch endpoints (R-LC7).
// ============================================================
import { z } from 'zod';
import { PositiveBigIntSchema } from './contracts.schemas';

export const ImpactCategorySchema = z.enum(
  ['regulatory', 'commodity_prices', 'supply_chain', 'geopolitical', 'market_financial'],
  { errorMap: () => ({ message: 'invalid category' }) },
);

export const ImpactSignalListQuerySchema = z.object({
  category: ImpactCategorySchema.optional(),
  severity: z.string().trim().max(40).optional(),
  q: z.string().trim().max(200).optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
  offset: z.coerce.number().int().min(0).optional(),
});
export type ImpactSignalListQueryInferred = z.infer<typeof ImpactSignalListQuerySchema>;

export const ImpactSignalIdParamSchema = z.object({
  id: PositiveBigIntSchema,
});
export type ImpactSignalIdParamInferred = z.infer<typeof ImpactSignalIdParamSchema>;

export const ImpactSignalLinkIdParamSchema = z.object({
  linkId: PositiveBigIntSchema,
});
export type ImpactSignalLinkIdParamInferred = z.infer<typeof ImpactSignalLinkIdParamSchema>;
