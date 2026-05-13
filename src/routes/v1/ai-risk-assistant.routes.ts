/**
 * /api/v1/ai/risk-assistant/* — M15 (CR-G) AI Risk Assistant SSE endpoint.
 *
 * Appended to the existing aiRouter (src/routes/v1/ai.routes.ts) via
 * src/routes/v1/index.ts mount at /ai (same prefix).
 *
 * Endpoint:
 *   POST /api/v1/ai/risk-assistant/ask
 *
 * Auth posture:
 *   - Requires JWT (authenticate middleware — inherited from aiRouter global)
 *   - Permission gate: ai.invoke.risk_assistant (route-level, before SSE opens)
 *   - Rate limit: riskAssistantRateLimiter (30/min/user) — stricter than
 *     authedWriteRateLimiter (60/min) because per-call ACL resolution + pgvector
 *     search + streaming GPT-4o call make this the most expensive endpoint.
 *   - Body validation via riskAssistantAskSchema is done in the controller
 *     before SSE headers open (Zod errors → 400 JSON, not SSE).
 *
 * SSE:
 *   - Content-Type: text/event-stream; charset=utf-8
 *   - Cache-Control: no-cache, no-transform
 *   - Connection: keep-alive
 *   - X-Accel-Buffering: no
 *
 * Non-streaming fallback:
 *   ?stream=false → { answer: string, citations: RiskAssistantCitation[] }
 *
 * Sensitive fields (Pino-redacted):
 *   - req.body.query
 *   - req.body.filters
 *   - SSE response chunks (never in INFO-level logs)
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { riskAssistantRateLimiter } from '../../middleware/rate-limit.middleware';
import { riskAssistantController } from '../../controllers/ai/risk-assistant.controller';

const aiRiskAssistantRouter = Router();

// Inherit authenticate from aiRouter global — no duplicate here.
// Explicit authenticate for standalone mount safety (index.ts mounts this
// AFTER aiRouter.use(authenticate), but this router can be tested independently).
aiRiskAssistantRouter.use(authenticate);

// ------------------------------------------------------------
// POST /api/v1/ai/risk-assistant/ask
// ------------------------------------------------------------
// Permission pre-gate: ai.invoke.risk_assistant — applied BEFORE SSE opens
// so 403 is returned as JSON, not as an SSE error event.
aiRiskAssistantRouter.post(
  '/risk-assistant/ask',
  riskAssistantRateLimiter,
  authorise(['ai.invoke.risk_assistant']),
  riskAssistantController.ask,
);

export default aiRiskAssistantRouter;
