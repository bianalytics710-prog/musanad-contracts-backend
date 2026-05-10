/**
 * M9 — Admin Parties Sanctions-Match Controller (CR-B).
 *
 *   POST /api/v1/admin/parties/sanctions-match → fn_party_sanctions_match
 *
 * Permission gate: party.graph.manage (controller layer narrows to manage
 * to keep this admin-only — see api-contracts.json ep_party_sanctions_match).
 * The fn body itself gates on party.graph.read OR system caller; the
 * controller is the authoritative narrowing path.
 *
 * Per HITL Q-DA4 lock: this endpoint returns matches only — does NOT
 * update party.sanctions_status. CR-E rule engine writes the status via
 * a separate DEFINER carve-out (out of M9 scope).
 *
 * Per HITL Q-DA2 lock: similarityThreshold is optional in the body. When
 * omitted, fn body resolves: GUC `app.party_sanctions_match_threshold` →
 * fallback 0.7.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../../utils/errors.util';
import * as svc from '../../services/party-graph.service';
import type { PartySanctionsMatchInputInferred } from '../../schemas/party-graph.schemas';
import type { PartySanctionsMatchInput } from '../../types/party-graph.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const adminPartiesSanctionsMatchController = {
  async match(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.partiesSanctionsMatch.match',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
        // S2-16 / Pino redact note: signalEntities[].name MAY contain UBO
        // personal names. We log only the count, never the entity names.
        signalEntityCount: Array.isArray(req.body?.signalEntities)
          ? req.body.signalEntities.length
          : 0,
      },
      'Controller entry',
    );
    try {
      const body = req.body as PartySanctionsMatchInputInferred;
      const input: PartySanctionsMatchInput = {
        signalEntities: body.signalEntities,
        ...(body.similarityThreshold !== undefined
          ? { similarityThreshold: body.similarityThreshold }
          : {}),
      };
      const result = await svc.sanctionsMatch(req.user!.id, req.tenantId, input);
      req.logger.info(
        {
          action: 'admin.partiesSanctionsMatch.match',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          matchCount: result?.matches?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'admin.partiesSanctionsMatch.match',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },
};
