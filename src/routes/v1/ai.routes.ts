/**
 * /api/v1/ai/* routes — NEW namespace introduced by M1c (per collision-report
 * MD-4 + api-contracts.json _aiNamespaceConvention). M4 will inherit these
 * conventions and append its real-AI endpoints to this file.
 *
 * Conventions (frozen at M1c ship — Q3-OI-E):
 *   - Auth required on every /api/v1/ai/* endpoint (M0 JWT). No anonymous AI.
 *   - Permission gate at the BE middleware (controller-only stubs in M1c —
 *     M4 will add fn_-backed routes that also enforce permissions inside
 *     the fn_).
 *   - authedWriteRateLimiter applied to every AI route (AI calls are
 *     expensive; throttle at the BE — AC-S8-05).
 *   - pino-redact treats request payloads with text destined for an AI
 *     provider as 'ai_prompt_payload' per project.config.json
 *     sensitiveFields. The shared pino redact list in
 *     src/utils/logger.util.ts already covers '*.extractedText'.
 *   - Request + response DTOs are FROZEN at module ship time. M4 must NOT
 *     change the DTO when it replaces the controller body — only the
 *     implementation (AC-S8-07).
 *
 * Route ordering: keep literal-path routes BEFORE any :id-prefixed routes
 * (Express matches in declaration order — same convention as M1a/M1b).
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import { extractContractBulkController } from '../../controllers/ai/extract-contract-bulk.controller';
import { ExtractContractBulkSchema } from '../../schemas/import-batch.schemas';

const router = Router();

// Every AI endpoint requires authentication.
router.use(authenticate);

// ---------------------------------------------------------------
// POST /api/v1/ai/extract-contract-bulk — M1c S8 STUB (no fn_).
//   AC-S8-02: requires import.run permission
//   AC-S8-05: rate-limited (authedWriteRateLimiter)
//   AC-S8-06: extractedText is treated as ai_prompt_payload (pino-redacted
//             via logger.util.ts SENSITIVE_PATHS '*.extractedText').
//   AC-S8-07: M4 replaces the controller body without changing route /
//             auth / DTOs. Frozen contract.
// ---------------------------------------------------------------
router.post(
  '/extract-contract-bulk',
  authedWriteRateLimiter,
  authorise(['import.run']),
  validate(ExtractContractBulkSchema, 'body'),
  extractContractBulkController.extract,
);

export default router;
