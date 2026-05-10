/**
 * CR-C — Tenant list / get-by-id Zod schemas (S8).
 */
import { z } from 'zod';

export const tenantListQuerySchema = z
  .object({
    page: z.coerce.number().int().min(1).max(100000).optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    search: z.string().trim().min(1).max(200).optional(),
  })
  .strict();

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const tenantIdParamSchema = z.object({
  id: z
    .string()
    .trim()
    .regex(UUID_RE, 'id must be a valid UUID'),
});

export type TenantListQueryInferred = z.infer<typeof tenantListQuerySchema>;
export type TenantIdParamInferred = z.infer<typeof tenantIdParamSchema>;
