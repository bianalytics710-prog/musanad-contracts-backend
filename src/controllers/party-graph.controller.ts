/**
 * M9 — Counterparty Graph (CR-B) controllers.
 *
 *   GET    /api/v1/parties/:id/relationships              → list edges
 *   POST   /api/v1/parties/:id/relationships              → create edge
 *   PATCH  /api/v1/parties/:id/relationships/:relId       → update edge
 *   DELETE /api/v1/parties/:id/relationships/:relId       → soft-delete edge
 *   GET    /api/v1/parties/:id/chain?direction=&maxDepth= → traverse chain
 *   GET    /api/v1/parties/:id/chain-summary?maxDepth=    → summary
 *   PATCH  /api/v1/parties/:id                            → editable subset
 *
 * (admin-only sanctions-match endpoint lives in admin/parties-sanctions-match.controller.ts)
 *
 * Permissions are gated inside the fn_ bodies (party.graph.read /
 * party.graph.manage / contract.edit). 42501 → 403 via translatePgError.
 *
 * Tenant GUC is set by db.callFunction({ tenantId }) using `req.tenantId`
 * resolved by rls.middleware.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import * as svc from '../services/party-graph.service';
import { getPartyIntelligence } from '../services/party-intelligence.service';
import type {
  CreateRelationshipInferred,
  PartyChainSummaryQueryInferred,
  PartyChainTraverseQueryInferred,
  PartyUpdateInferred,
  UpdateRelationshipInferred,
} from '../schemas/party-graph.schemas';
import type {
  CreateRelationshipPayload,
  PartyChainTraverseResponse,
  PartyUpdatePayload,
  UpdateRelationshipPayload,
} from '../types/party-graph.types';

const errorTypeOf = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const partyGraphController = {
  // ----------------------------------------------------------
  // GET /api/v1/parties/:id/intelligence?excludeContractId=&lang=
  // Counterparty drafting/review intelligence (metrics + short AI note).
  // ----------------------------------------------------------
  async intelligence(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      { action: 'partyGraph.intelligence', userId: req.user?.id, path: req.path },
      'Controller entry',
    );
    try {
      const partyId = Number((req.params as { id: number | string }).id);
      const excludeRaw = (req.query as { excludeContractId?: string }).excludeContractId;
      const excludeContractId =
        excludeRaw !== undefined && excludeRaw !== '' ? Number(excludeRaw) : null;
      const lang = (req.query as { lang?: string }).lang === 'ar' ? 'ar' : 'en';
      const result = await getPartyIntelligence({
        actorId: req.user!.id,
        partyId,
        excludeContractId,
        language: lang,
      });
      req.logger.info(
        {
          action: 'partyGraph.intelligence',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          hasSummary: result.summary !== null,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        { action: 'partyGraph.intelligence', userId: req.user?.id, errorType: errorTypeOf(err) },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // GET /api/v1/parties/:id/relationships
  // ----------------------------------------------------------
  async listRelationships(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.relationships.list',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      // Path params validated by validate(partyIdParamSchema, 'params').
      const partyId = Number((req.params as { id: number | string }).id);
      const result = await svc.listRelationships(req.user!.id, req.tenantId, partyId);
      req.logger.info(
        {
          action: 'partyGraph.relationships.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          incomingCount: result?.counts?.incoming ?? 0,
          outgoingCount: result?.counts?.outgoing ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.relationships.list',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // POST /api/v1/parties/:id/relationships
  // ----------------------------------------------------------
  async createRelationship(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.relationships.create',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const parentId = Number((req.params as { id: number | string }).id);
      // Body shape guaranteed by validate(createRelationshipSchema, 'body').
      const body = req.body as CreateRelationshipInferred;
      const payload: CreateRelationshipPayload = {
        childId: body.childId,
        relationshipType: body.relationshipType,
        ownershipPct: body.ownershipPct ?? null,
        effectiveFrom: body.effectiveFrom ?? null,
        effectiveTo: body.effectiveTo ?? null,
        ...(body.source !== undefined ? { source: body.source } : {}),
        ...(body.confidence !== undefined ? { confidence: body.confidence } : {}),
        ...(body.metadata !== undefined ? { metadata: body.metadata } : {}),
      };
      const result = await svc.createRelationship(
        req.user!.id,
        req.tenantId,
        parentId,
        payload,
      );
      req.logger.info(
        {
          action: 'partyGraph.relationships.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 201,
          relationshipId: result?.id,
        },
        'Controller exit',
      );
      res.status(201).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.relationships.create',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // PATCH /api/v1/parties/:id/relationships/:relId
  // ----------------------------------------------------------
  async updateRelationship(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.relationships.update',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const relId = Number((req.params as { relId: number | string }).relId);
      const body = req.body as UpdateRelationshipInferred;
      // AC-S2-04: parentId / childId silently ignored even if forwarded by the
      // FE — Zod schema doesn't accept them; this just enforces the contract
      // explicitly. The service signature also doesn't include them.
      const payload: UpdateRelationshipPayload = {
        ...(body.relationshipType !== undefined ? { relationshipType: body.relationshipType } : {}),
        ...(body.ownershipPct !== undefined ? { ownershipPct: body.ownershipPct } : {}),
        ...(body.effectiveFrom !== undefined ? { effectiveFrom: body.effectiveFrom } : {}),
        ...(body.effectiveTo !== undefined ? { effectiveTo: body.effectiveTo } : {}),
        ...(body.source !== undefined ? { source: body.source } : {}),
        ...(body.confidence !== undefined ? { confidence: body.confidence } : {}),
        ...(body.metadata !== undefined ? { metadata: body.metadata } : {}),
      };
      const result = await svc.updateRelationship(
        req.user!.id,
        req.tenantId,
        relId,
        payload,
      );
      req.logger.info(
        {
          action: 'partyGraph.relationships.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          relationshipId: relId,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.relationships.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // DELETE /api/v1/parties/:id/relationships/:relId
  // ----------------------------------------------------------
  async deleteRelationship(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.relationships.delete',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const relId = Number((req.params as { relId: number | string }).relId);
      const result = await svc.deleteRelationship(req.user!.id, req.tenantId, relId);
      req.logger.info(
        {
          action: 'partyGraph.relationships.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          relationshipId: relId,
          idempotent: Boolean(result?.idempotent),
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.relationships.delete',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // GET /api/v1/parties/:id/chain?direction=&maxDepth=
  // ----------------------------------------------------------
  async traverseChain(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.chain.traverse',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const partyId = Number((req.params as { id: number | string }).id);
      const q = req.query as unknown as PartyChainTraverseQueryInferred;
      const direction = q.direction ?? 'both';
      const maxDepth = q.maxDepth ?? 5;

      let result: PartyChainTraverseResponse;
      if (direction === 'up') {
        result = await svc.traverseChainUp(req.user!.id, req.tenantId, partyId, maxDepth);
      } else if (direction === 'down') {
        result = await svc.traverseChainDown(req.user!.id, req.tenantId, partyId, maxDepth);
      } else {
        result = await svc.traverseChainBoth(req.user!.id, req.tenantId, partyId, maxDepth);
      }

      req.logger.info(
        {
          action: 'partyGraph.chain.traverse',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          direction,
          maxDepth,
          chainTruncated: result.chainTruncated,
          depthReached: result.depthReached,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.chain.traverse',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // GET /api/v1/parties/:id/chain-summary?maxDepth=
  // ----------------------------------------------------------
  async chainSummary(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.chain.summary',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const partyId = Number((req.params as { id: number | string }).id);
      const q = req.query as unknown as PartyChainSummaryQueryInferred;
      const maxDepth = q.maxDepth ?? 5;
      const result = await svc.getChainSummary(req.user!.id, req.tenantId, partyId, maxDepth);
      req.logger.info(
        {
          action: 'partyGraph.chain.summary',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          maxDepth,
          chainTruncated: result?.chainTruncated,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.chain.summary',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorTypeOf(err),
        },
        'Controller error',
      );
      next(err);
    }
  },

  // ----------------------------------------------------------
  // PATCH /api/v1/parties/:id  (editable subset)
  // ----------------------------------------------------------
  async updateParty(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'partyGraph.party.update',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const partyId = Number((req.params as { id: number | string }).id);
      const body = req.body as PartyUpdateInferred;
      // Forward only the fields the caller actually provided. `parentId` /
      // `uboId` are special: `null` is a meaningful sentinel ("explicitly
      // unset"). The service-layer mapNullableIdToSentinel translates that
      // to the fn body's -1 marker.
      const payload: PartyUpdatePayload = {
        ...(body.nameEn !== undefined ? { nameEn: body.nameEn } : {}),
        ...(body.nameAr !== undefined ? { nameAr: body.nameAr } : {}),
        ...(body.emirate !== undefined ? { emirate: body.emirate } : {}),
        ...(body.freeZone !== undefined ? { freeZone: body.freeZone } : {}),
        ...(body.country !== undefined ? { country: body.country } : {}),
        ...(body.contactEmail !== undefined ? { contactEmail: body.contactEmail } : {}),
        ...(body.contactPhone !== undefined ? { contactPhone: body.contactPhone } : {}),
        ...(body.registeredAddress !== undefined ? { registeredAddress: body.registeredAddress } : {}),
        ...(body.notes !== undefined ? { notes: body.notes } : {}),
        ...(body.tradeLicenseNumber !== undefined ? { tradeLicenseNumber: body.tradeLicenseNumber } : {}),
        ...(body.tradeLicenseIssuer !== undefined ? { tradeLicenseIssuer: body.tradeLicenseIssuer } : {}),
        ...(body.parentId !== undefined ? { parentId: body.parentId } : {}),
        ...(body.uboId !== undefined ? { uboId: body.uboId } : {}),
        ...(body.aliases !== undefined ? { aliases: body.aliases } : {}),
        ...(body.esgScore !== undefined ? { esgScore: body.esgScore } : {}),
        ...(body.icvStatus !== undefined ? { icvStatus: body.icvStatus } : {}),
        ...(body.icvPct !== undefined ? { icvPct: body.icvPct } : {}),
        ...(body.icvLastChecked !== undefined ? { icvLastChecked: body.icvLastChecked } : {}),
        ...(body.metadata !== undefined ? { metadata: body.metadata } : {}),
      };
      const result = await svc.updateParty(req.user!.id, partyId, payload);
      req.logger.info(
        {
          action: 'partyGraph.party.update',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          partyId,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (err) {
      req.logger.error(
        {
          action: 'partyGraph.party.update',
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
