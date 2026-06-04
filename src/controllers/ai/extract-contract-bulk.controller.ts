/**
 * extract-contract-bulk.controller.ts — M1c S8 AI extraction STUB.
 *
 *   POST /api/v1/ai/extract-contract-bulk
 *
 * This is a CONTROLLER-ONLY endpoint. There is NO fn_ call, no DB write,
 * no audit row. Per HITL Gate 2 / HQ2 + AC-S8-07, M4 will replace the
 * controller body with a real OpenAI/Anthropic call WITHOUT changing:
 *   - the route
 *   - the auth middleware
 *   - the request DTO (ExtractContractBulkRequest)
 *   - the response DTO (ExtractContractBulkResponse)
 *
 * The DTO contract is FROZEN as of M1c ship.
 *
 * Sensitive logging (AC-S8-06):
 *   The request body field `extractedText` is treated as ai_prompt_payload
 *   per project.config.json sensitiveFields. Logger config in
 *   src/utils/logger.util.ts redacts paths matching '*.aiPromptPayload' /
 *   '*.ai_prompt_payload'. To make sure the redaction fires whether the
 *   payload is logged via req.body or any other path, the controller below
 *   NEVER passes req.body to a logger call — only its derived metadata
 *   (filename, fileSize, batchId, length).
 *
 * Rate limiting (AC-S8-05):
 *   Wired in the route (authedWriteRateLimiter). NOT applied here so the
 *   controller stays thin and unit-testable.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../../utils/errors.util';
import { extractContractData } from '../../services/ai/extract-contract-bulk.service';
import type { ExtractContractBulkInferred } from '../../schemas/import-batch.schemas';
import type { ExtractContractBulkResponse } from '../../types/import-batch.types';

/** Standard error-type label for log lines. */
const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

export const extractContractBulkController = {
  /**
   * POST /api/v1/ai/extract-contract-bulk → deterministic mock (no fn_).
   *
   * Validation (Zod, ExtractContractBulkSchema):
   *   - filename non-empty (AC-S8-03)
   *   - fileSize non-negative integer
   *   - extractedText >= 50 chars (AC-S8-03)
   *   - batchId positive bigint
   *
   * Response (AC-S8-04, AC-S8-07): see ExtractContractBulkResponse —
   * importConfidence calculated deterministically from extractedText.length;
   * other fields are M1a CreateContractDto-compatible optionals + the
   * M1c-specific extraction metadata (importWarnings,
   * detectedDuplicateContractNumber).
   */
  async extract(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    // Logger entry — explicitly project filename + fileSize + batchId only.
    // extractedText is NEVER logged (sensitive ai_prompt_payload).
    const body = req.body as ExtractContractBulkInferred;
    req.logger.info(
      {
        action: 'ai.extractContractBulk',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
        filename: body.filename,
        fileSize: body.fileSize,
        batchId: body.batchId,
        textLength: body.extractedText.length,
      },
      'Controller entry',
    );

    try {
      const result: ExtractContractBulkResponse = await extractContractData({
        filename: body.filename,
        fileSize: body.fileSize,
        extractedText: body.extractedText,
        batchId: body.batchId,
      });

      req.logger.info(
        {
          action: 'ai.extractContractBulk',
          userId: req.user?.id,
          batchId: body.batchId,
          duration: Date.now() - startTime,
          statusCode: 200,
          // Response is mock data — non-sensitive — but we still log only
          // metadata, not the full payload (forward-compat with the M4
          // replacement that will return real extracted body text).
          importConfidence: result.importConfidence,
          warningsCount: result.importWarnings?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'ai.extractContractBulk',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};
