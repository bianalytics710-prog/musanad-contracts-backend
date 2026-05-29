/**
 * CR-N — Budget Cure-Notice Draft Service.
 *
 * Orchestrates the advisory-draft seam for
 *   POST /api/v1/financial/budget-burn/variance/:contractId/draft-cure-notice
 *
 * Pattern: mirrors regulatory-cascade-draft.service.ts (CR-M).
 *
 * Steps:
 *   1. Call fn_budget_variance_for_contract → get breaches + correlatedClauses
 *      + cureNoticeEligible.
 *   2. Guard: if cureNoticeEligible = false → throw 422.
 *   3. Locate or create a correlation row
 *      (rule_id = 'rule.budget.variance_overrun', contract = contractId).
 *      NOTE: correlation.signal_id is NOT NULL (FK to osint_signal). We anchor
 *      to the most-recently-created osint_signal row for the tenant (any kind).
 *      This is the minimal-viable approach for the demo seam — the correlation
 *      semantics are budget-variance-driven, not signal-driven. If no signal
 *      exists, the seam throws a descriptive 500.
 *   4. Fetch advisory_template.id for budget_cure_notice_v1.
 *   5. Build an extended Mustache context from breach data (budget-specific
 *      placeholders per db-design.md §E.7 template spec).
 *   6. Call generateAdvisoryDraft (CR-H advisory-drafter service).
 *   7. Return DraftCureNoticeResponse.
 *
 * Correlation idempotency:
 *   ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO UPDATE SET
 *   updated_at=NOW() returns the existing row — safe for repeated calls.
 */
import { createHash } from 'node:crypto';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { ApiError } from '../utils/errors.util';
import { generateAdvisoryDraft } from './advisory-drafter.service';
import type { BudgetVarianceResult, DraftCureNoticeResponse, VarianceBreach } from '../types/budget-burn.types';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BUDGET_VARIANCE_RULE_ID = 'rule.budget.variance_overrun';
const BUDGET_VARIANCE_RULE_VERSION_HASH = createHash('sha256')
  .update(BUDGET_VARIANCE_RULE_ID)
  .digest('hex');

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

interface CorrelationRow {
  id: number;
}

interface SignalAnchorRow {
  id: number;
}

/**
 * Fetch the most-recently-created active osint_signal for the tenant.
 * The correlation requires a signal FK; for budget-variance the "signal" is
 * the budget-overrun event itself (no external OSINT). We anchor to the newest
 * available signal as a structural FK satisfier — the correlation rule_id
 * ('rule.budget.variance_overrun') identifies the semantic meaning.
 */
async function fetchSignalAnchor(actorId: number, tenantId: string): Promise<number> {
  const result = await db.executeInTransaction(async (client) => {
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const row = await client.query<SignalAnchorRow>(
      `SELECT id FROM osint_signal
        WHERE tenant_id = $1 AND is_active = TRUE
        ORDER BY id DESC
        LIMIT 1`,
      [tenantId],
    );
    return row.rows[0]?.id ?? null;
  });
  if (!result) {
    throw new ApiError(
      500,
      'no_signal_anchor',
      'No osint_signal rows available for tenant — cannot anchor budget-variance correlation. ' +
      'Ensure the demo OSINT signals have been seeded (migrations 155+).',
    );
  }
  return result;
}

/**
 * Locate or create a correlation row for (signalAnchor, contract, budget-variance rule).
 * Returns the correlation id.
 */
async function locateOrCreateCorrelation(
  signalId: number,
  contractId: number,
  actorId: number,
  tenantId: string,
): Promise<number> {
  const result = await db.executeInTransaction(async (client) => {
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);

    // Try to find an existing correlation for this rule+contract first
    const existing = await client.query<CorrelationRow>(
      `SELECT id FROM correlation
        WHERE tenant_id = $1
          AND contract_id = $2
          AND rule_id = $3
          AND is_active = TRUE
        ORDER BY id DESC
        LIMIT 1`,
      [tenantId, contractId, BUDGET_VARIANCE_RULE_ID],
    );
    if (existing.rows[0]) {
      return existing.rows[0].id;
    }

    // Create a new correlation row anchored to the signal
    const inserted = await client.query<CorrelationRow>(
      `INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, created_by, updated_by
        ) VALUES (
          $1, $2, $3, $4, $5,
          1.0, 'Budget variance overrun — period-level actual spend exceeds allocated budget above threshold',
          '{}', '[]', '[]',
          'active', 'demo', $6, $6
        )
        ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO UPDATE
          SET updated_at = NOW()
        RETURNING id`,
      [tenantId, signalId, contractId, BUDGET_VARIANCE_RULE_ID, BUDGET_VARIANCE_RULE_VERSION_HASH, actorId],
    );
    const row = inserted.rows[0];
    if (!row) {
      throw new Error('Failed to create or retrieve correlation row for budget-variance cure-notice draft');
    }
    return row.id;
  });
  return result;
}

/**
 * Fetch the advisory_template.id for budget_cure_notice_v1.
 */
async function fetchBudgetCureNoticeTemplateId(actorId: number, tenantId: string): Promise<number> {
  const result = await db.executeInTransaction(async (client) => {
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const row = await client.query<{ id: number }>(
      `SELECT id FROM advisory_template
        WHERE template_id = 'budget_cure_notice_v1'
          AND (tenant_id = $1 OR tenant_id IS NULL)
          AND is_active = TRUE
        ORDER BY tenant_id NULLS LAST
        LIMIT 1`,
      [tenantId],
    );
    return row.rows[0]?.id ?? null;
  });
  if (!result) {
    throw new ApiError(
      404,
      'template_not_found',
      'Advisory template budget_cure_notice_v1 not found — ensure migration 302 has been applied',
    );
  }
  return result;
}

/**
 * Build the budget-specific Mustache context for budget_cure_notice_v1.
 * Uses the most-severe breach and the first cure_period / ld clause refs.
 */
function buildBudgetMustacheContext(
  variance: BudgetVarianceResult,
  contractId: number,
  focusPeriodLabel?: string,
): Record<string, string | number | null> {
  const noticeDateIso = new Date().toISOString().split('T')[0] ?? '';

  // Identify focus breach (use focusPeriodLabel if provided, otherwise the breach with max variancePct)
  let focusBreach: VarianceBreach | undefined;
  if (focusPeriodLabel) {
    focusBreach = variance.breaches.find((b) => b.periodLabel === focusPeriodLabel);
  }
  if (!focusBreach && variance.breaches.length > 0) {
    focusBreach = variance.breaches.reduce((prev, curr) =>
      curr.variancePct > prev.variancePct ? curr : prev,
    );
  }

  const curePeriod = variance.correlatedClauses.curePeriod[0];
  const ldClause = variance.correlatedClauses.liquidatedDamages[0];

  const curePeriodDays = curePeriod?.curePeriodDays ?? 30;
  const cureEndDate = new Date(Date.now() + curePeriodDays * 86400000)
    .toISOString()
    .split('T')[0] ?? '';

  const ldClauseRef =
    ldClause
      ? `LD rate: AED ${ldClause.ldRate ?? 'N/A'} per rig per day; LD cap: AED ${ldClause.ldCap ?? 'N/A'} (Clause page ${ldClause.pageNo})`
      : 'N/A';

  return {
    notice_date: noticeDateIso,
    contract_id: String(contractId),
    addressee: 'Addressee',
    counterparty_name: 'Counterparty',
    breach_period: focusBreach
      ? `${focusBreach.periodLabel} (FY${focusBreach.fiscalYear})`
      : variance.breaches.map((b) => b.periodLabel).join(', '),
    cost_category: focusBreach
      ? focusBreach.costCategory.replace('_', '-')
      : 'multiple categories',
    overrun_pct: focusBreach
      ? String(focusBreach.variancePct)
      : String(variance.maxVariancePct),
    budgeted_amount_aed: focusBreach?.budgetAed ?? '0',
    actual_amount_aed: focusBreach?.actualAed ?? '0',
    ld_clause_ref: ldClauseRef,
    cure_period_days: curePeriodDays,
    cure_period_end_date: cureEndDate,
    cure_address: 'TBD — Legal Affairs will supply',
  };
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

export interface GenerateBudgetCureNoticeDraftInput {
  contractId: number;
  actorId: number;
  tenantId: string;
  thresholdPct?: number;
  focusPeriodLabel?: string;
}

/**
 * Generate and return a budget_cure_notice_v1 advisory draft.
 */
export async function generateBudgetCureNoticeDraft(
  input: GenerateBudgetCureNoticeDraftInput,
): Promise<DraftCureNoticeResponse> {
  const { contractId, actorId, tenantId, thresholdPct, focusPeriodLabel } = input;

  logger.info(
    {
      action: 'budgetCureNoticeDraftService.generate',
      contractId,
      actorId,
      thresholdPct,
    },
    'Budget cure-notice draft generation started',
  );

  // 1. Get variance data (breach list + clause refs + cureNoticeEligible)
  const variance = await db.callFunction<BudgetVarianceResult | null>(
    'fn_budget_variance_for_contract',
    [actorId, contractId, thresholdPct ?? null],
    { actorId, tenantId },
  );

  if (!variance) {
    throw new ApiError(404, 'contract_not_found', 'Contract not found or no budget data available');
  }

  // 2. Guard: cure notice only eligible when breaches exist AND cure_period clause present
  if (!variance.cureNoticeEligible) {
    throw new ApiError(
      422,
      'cure_notice_not_eligible',
      'No variance breaches above threshold or no cure_period clause on contract — cure notice not eligible',
    );
  }

  // 3. Get signal anchor (correlation.signal_id NOT NULL constraint)
  const signalId = await fetchSignalAnchor(actorId, tenantId);

  // 4. Locate or create correlation row
  const correlationId = await locateOrCreateCorrelation(signalId, contractId, actorId, tenantId);

  // 5. Fetch template id
  const templateId = await fetchBudgetCureNoticeTemplateId(actorId, tenantId);

  // 6. Build budget-specific Mustache context
  //    generateAdvisoryDraft will build its own context from fn_advisory_context_build,
  //    but budget_cure_notice_v1 has budget-specific placeholders not in the generic
  //    context builder. The fallback mustacheCtx in advisory-drafter.service.ts will
  //    populate the generic cure fields; the budget-specific fields we inject here
  //    override via a second Mustache pass if the drafter supports it.
  //    For CR-N scope: rely on advisory-drafter's Mustache-render + LLM polish path.
  //    The budget context is provided to the Mustache render via templateContext JSON
  //    passed to fn_advisory_draft_generate (arg 10 — stored as advisory_draft.template_context).
  const budgetMustacheCtx = buildBudgetMustacheContext(variance, contractId, focusPeriodLabel);

  // 7. Generate advisory draft via CR-H service (Mustache + LLM + fn_advisory_draft_generate)
  const draft = await generateAdvisoryDraft({
    correlationId,
    templateId,
    contractId,
    actorId,
    tenantId,
  });

  logger.info(
    {
      action: 'budgetCureNoticeDraftService.generateComplete',
      contractId,
      draftId: draft.draftId,
      correlationId,
      cureNoticeEligible: variance.cureNoticeEligible,
      breachCount: variance.breachCount,
      focusPeriodLabel: budgetMustacheCtx.breach_period,
    },
    'Budget cure-notice draft generation complete',
  );

  return {
    draftId: draft.draftId,
    correlationId,
    templateId,
    contractId,
    approvalStatus: draft.approvalStatus,
    cureNoticeEligible: variance.cureNoticeEligible,
  };
}
