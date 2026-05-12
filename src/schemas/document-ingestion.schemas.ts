/**
 * M11 — Zod schemas for Document Ingestion endpoints.
 *
 * Covers:
 *   - POST /:id/versions/:vId/ingest  (path params only — no body)
 *   - GET  /:id/versions/:vId/extracted-text (path params only)
 *   - GET  /:id/versions/:vId/ingestion-status (path params only)
 *
 * Path params use z.coerce.number() because Express delivers them as strings.
 */

import { z } from 'zod';

/**
 * ContractVersionParamsSchema — shared path param validator for all
 * document-ingestion endpoints that take :id (contract) and :vId (version).
 */
export const ContractVersionParamsSchema = z.object({
  id: z.coerce.number().int().positive({ message: 'id must be a positive integer' }),
  vId: z.coerce.number().int().positive({ message: 'vId must be a positive integer' }),
});

export type ContractVersionParams = z.infer<typeof ContractVersionParamsSchema>;
