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
import { authenticate, authorise, authoriseAnyOf } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../middleware/rate-limit.middleware';
import { extractContractBulkController } from '../../controllers/ai/extract-contract-bulk.controller';
import { ExtractContractBulkSchema } from '../../schemas/import-batch.schemas';
import { chatOrchestratorController } from '../../controllers/ai/chat-orchestrator.controller';
import { chatMentionsController } from '../../controllers/ai/chat-mentions.controller';
import { contractInsightsController } from '../../controllers/ai/contract-insights.controller';
import { draftingAssistantController } from '../../controllers/ai/drafting-assistant.controller';
import { executiveAnomaliesController } from '../../controllers/ai/executive-anomalies.controller';
import { regulatoryImpactController } from '../../controllers/ai/regulatory-impact.controller';
import { regulatoryImpactSummaryController } from '../../controllers/ai/regulatory-impact-summary.controller';
import { versionDiffSummaryController } from '../../controllers/ai/version-diff-summary.controller';
import { impactSignalAiController } from '../../controllers/ai/impact-signal-ai.controller';
import { translateTitleController } from '../../controllers/ai/translate-title.controller';
import {
  aiContractInsightsRequestSchema,
  aiDraftingAssistantRequestSchema,
  aiExecutiveAnomaliesRequestSchema,
  aiRegulatoryImpactRequestSchema,
  aiRegulatoryImpactSummaryRequestSchema,
  aiVersionDiffSummaryRequestSchema,
  aiImpactSignalIdParamSchema,
  aiImpactSignalExplainRequestSchema,
  aiImpactSignalSuggestAmendmentRequestSchema,
  aiTranslateTitleRequestSchema,
} from '../../schemas/ai.schemas';
import { verifySignedPdfTokenMiddleware } from '../../middleware/signed-pdf-token.middleware';

const router = Router();

// ---------------------------------------------------------------
// PUBLIC routes (verify_jwt: false) — declared BEFORE the global
// authenticate gate so they bypass JWT validation.
//
// S5 — POST /api/v1/ai/regulatory-impact-summary
//   Signed-PDF-token (HMAC) at Express middleware. fn_'s remain
//   neondb_owner-only DEFINER (Q3 Option A).
// ---------------------------------------------------------------
router.post(
  '/regulatory-impact-summary',
  verifySignedPdfTokenMiddleware,
  validate(aiRegulatoryImpactSummaryRequestSchema, 'body'),
  regulatoryImpactSummaryController.invoke,
);

// Every other AI endpoint requires authentication.
router.use(authenticate);

// ---------------------------------------------------------------
// M1c S8 — POST /api/v1/ai/extract-contract-bulk (legacy stub kept).
// ---------------------------------------------------------------
router.post(
  '/extract-contract-bulk',
  authedWriteRateLimiter,
  authorise(['import.run']),
  validate(ExtractContractBulkSchema, 'body'),
  extractContractBulkController.extract,
);

// ---------------------------------------------------------------
// M4 / S1 — POST /api/v1/ai/contract-insights
//   Per api-contracts.json ep_ai_contract_insights:
//   - permissions: ai.invoke.contract  (controller checks contract scope via fn_contract_get_by_id)
// ---------------------------------------------------------------
router.post(
  '/contract-insights',
  authedWriteRateLimiter,
  authorise(['ai.invoke.contract']),
  validate(aiContractInsightsRequestSchema, 'body'),
  contractInsightsController.invoke,
);

// ---------------------------------------------------------------
// M4 / S2 — POST /api/v1/ai/drafting-assistant
//   - permissions: ai.invoke.contract AND (contract.draft OR contract.edit)
// ---------------------------------------------------------------
router.post(
  '/drafting-assistant',
  authedWriteRateLimiter,
  authorise(['ai.invoke.contract']),
  authoriseAnyOf(['contract.draft', 'contract.edit']),
  validate(aiDraftingAssistantRequestSchema, 'body'),
  draftingAssistantController.invoke,
);

// ---------------------------------------------------------------
// POST /api/v1/ai/translate-title — EN ↔ AR contract title translation.
// Used by Compose Step 2 to auto-fill the AR title on EN blur.
// Permission: contract.draft OR contract.edit (anyone who can author a
// contract can translate its title).
// ---------------------------------------------------------------
router.post(
  '/translate-title',
  authedWriteRateLimiter,
  authoriseAnyOf(['contract.draft', 'contract.edit']),
  validate(aiTranslateTitleRequestSchema, 'body'),
  translateTitleController.invoke,
);

// ---------------------------------------------------------------
// M4 / S3 — POST /api/v1/ai/executive-anomalies
// ---------------------------------------------------------------
router.post(
  '/executive-anomalies',
  authedWriteRateLimiter,
  authorise(['ai.invoke.executive']),
  validate(aiExecutiveAnomaliesRequestSchema, 'body'),
  executiveAnomaliesController.invoke,
);

// ---------------------------------------------------------------
// M4 / S4 — POST /api/v1/ai/regulatory-impact (SSE)
// ---------------------------------------------------------------
router.post(
  '/regulatory-impact',
  authedWriteRateLimiter,
  authorise(['ai.invoke.regulatory']),
  validate(aiRegulatoryImpactRequestSchema, 'body'),
  regulatoryImpactController.invoke,
);

// ---------------------------------------------------------------
// M4 / S6 — POST /api/v1/ai/version-diff-summary
//   Persists to contract_version.diff_summary via DEFINER carve-out fn_.
// ---------------------------------------------------------------
router.post(
  '/version-diff-summary',
  authedWriteRateLimiter,
  authorise(['ai.invoke.contract']),
  validate(aiVersionDiffSummaryRequestSchema, 'body'),
  versionDiffSummaryController.invoke,
);

// ---------------------------------------------------------------
// R-LC7-D1 — Impact Watch AI endpoints
//   POST /api/v1/ai/impact-signals/:id/explain
//   POST /api/v1/ai/impact-signals/:id/suggest-amendment
//
// E-rev-E-3 (2026-06-02): split permission gates.
//   - Explain (read-only narrative): accepts ai.invoke.regulatory.explain
//     OR ai.invoke.regulatory. Granted to every role that already sees
//     Impact Watch — executive, compliance_esg, operations, etc. (mig 486).
//   - Suggest amendment language (drafts contractual text): still gated to
//     ai.invoke.regulatory only — legal_counsel + platform_admin + Super Admin.
// ---------------------------------------------------------------
router.post(
  '/impact-signals/:id/explain',
  authedWriteRateLimiter,
  authoriseAnyOf(['ai.invoke.regulatory.explain', 'ai.invoke.regulatory']),
  validate(aiImpactSignalIdParamSchema, 'params'),
  validate(aiImpactSignalExplainRequestSchema, 'body'),
  impactSignalAiController.explain,
);

router.post(
  '/impact-signals/:id/suggest-amendment',
  authedWriteRateLimiter,
  authorise(['ai.invoke.regulatory']),
  validate(aiImpactSignalIdParamSchema, 'params'),
  validate(aiImpactSignalSuggestAmendmentRequestSchema, 'body'),
  impactSignalAiController.suggestAmendment,
);

// ---------------------------------------------------------------
// Chat Orchestrator (mig 633/634/635) — prompt-driven actions via
// the floating chatbot. All gated by ai.invoke.risk_assistant
// (existing module-wide gate). Per-action permissions are checked
// inside the orchestrator service + each handler.
// ---------------------------------------------------------------
router.post(
  '/chat/ask',
  rlsMiddleware,
  authedWriteRateLimiter,
  authorise(['ai.invoke.risk_assistant']),
  chatOrchestratorController.ask,
);
router.post(
  '/chat/execute',
  rlsMiddleware,
  authedWriteRateLimiter,
  authorise(['ai.invoke.risk_assistant']),
  chatOrchestratorController.execute,
);
router.post(
  '/chat/reject',
  rlsMiddleware,
  authedWriteRateLimiter,
  authorise(['ai.invoke.risk_assistant']),
  chatOrchestratorController.reject,
);

router.get(
  '/chat/mentions/users',
  rlsMiddleware,
  authorise(['ai.invoke.risk_assistant']),
  chatMentionsController.users,
);
router.get(
  '/chat/mentions/contracts',
  rlsMiddleware,
  authorise(['ai.invoke.risk_assistant']),
  chatMentionsController.contracts,
);
router.get(
  '/chat/mentions/parties',
  rlsMiddleware,
  authorise(['ai.invoke.risk_assistant']),
  chatMentionsController.parties,
);

export default router;
