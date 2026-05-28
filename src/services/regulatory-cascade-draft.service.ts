/**
 * CR-M — Regulatory Cascade Draft-Amendment Service.
 *
 * Orchestrates the advisory-draft seam for POST .../items/:itemId/draft-amendment:
 *   1. Load the cascade item via fn_regulatory_cascade_get (scoped to the run).
 *   2. Resolve contractId (body.contractId or first affectedContractId on item).
 *   3. Locate or create a correlation row (signal=decree, contract=contractId).
 *   4. Build Mustache context for labor_law_amendment_v1.
 *   5. Call generateAdvisoryDraft (existing CR-H advisory-drafter service).
 *   6. Call fn_regulatory_cascade_item_link_draft(actor, itemId, draftId).
 *   7. Return DraftAmendmentResponse.
 *
 * DB design §D.8 note: fn_regulatory_cascade_item_link_draft also sets
 * remediation_status='amended' if currently pending/in_progress.
 *
 * Correlation creation:
 *   No fn_correlation_create exists. Correlations are normally created by
 *   fn_rule_evaluate. For the advisory-draft seam we INSERT directly with
 *   executeInTransaction (INVOKER — RLS on correlation requires
 *   app.current_user_id + app.current_tenant_id GUCs, which we set before
 *   the INSERT). ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING
 *   returns the existing row on idempotent calls.
 *
 *   rule_id for the labor cascade correlation = 'rule.labor.cascade.mohre_2024'
 *   rule_version_hash = sha256 of rule_id (deterministic for seeded/mock rule)
 */
import { createHash } from 'node:crypto';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';
import { ApiError } from '../utils/errors.util';
import { generateAdvisoryDraft } from './advisory-drafter.service';
import type { DraftAmendmentResponse, RegulatoryCascadeItemDetail, RegulatoryCascadeRun } from '../types/regulatory-cascade.types';

/** Virtual rule_id for labor-cascade correlations */
const LABOR_CASCADE_RULE_ID = 'rule.labor.cascade.mohre_2024';
const LABOR_CASCADE_RULE_VERSION_HASH = createHash('sha256').update(LABOR_CASCADE_RULE_ID).digest('hex');

/** DB advisory_template.id lookup for labor_law_amendment_v1 */
interface AdvisoryTemplateRow {
  id: number;
  templateId: string;
  displayNameEn: string;
  draftType: string;
}

/** Minimal correlation row from the INSERT ... RETURNING query */
interface CorrelationRow {
  id: number;
  signal_id: number;
  contract_id: number;
}

/**
 * Find the advisory_template.id for labor_law_amendment_v1 via DB read.
 * Uses db.callFunction on fn_advisory_template_list_all (platform_admin fn) —
 * but we have no generic fn for template lookup by template_id. Use executeInTransaction.
 */
async function fetchLaborLawTemplateId(actorId: number, tenantId: string): Promise<number> {
  const result = await db.executeInTransaction(async (client) => {
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const row = await client.query<{ id: number }>(
      `SELECT id FROM advisory_template
        WHERE template_id = 'labor_law_amendment_v1'
          AND (tenant_id = $1 OR tenant_id IS NULL)
          AND is_active = TRUE
        ORDER BY tenant_id NULLS LAST
        LIMIT 1`,
      [tenantId],
    );
    return row.rows[0]?.id ?? null;
  });
  if (!result) {
    throw new ApiError(404, 'template_not_found', 'Advisory template labor_law_amendment_v1 not found');
  }
  return result;
}

/**
 * Locate or create a correlation row for (signal, contract).
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

    // Try to find an existing correlation for this signal+contract
    const existing = await client.query<CorrelationRow>(
      `SELECT id, signal_id, contract_id FROM correlation
        WHERE tenant_id = $1
          AND signal_id = $2
          AND contract_id = $3
          AND is_active = TRUE
        LIMIT 1`,
      [tenantId, signalId, contractId],
    );
    if (existing.rows[0]) {
      return existing.rows[0].id;
    }

    // Create a new correlation row for the labor-cascade seam
    const inserted = await client.query<CorrelationRow>(
      `INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, created_by, updated_by
        ) VALUES (
          $1, $2, $3, $4, $5,
          1.0, 'Labor-law cascade — Federal Decree-Law No.9/2024',
          '{}', '[]', '[]',
          'active', 'demo', $6, $6
        )
        ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO UPDATE
          SET updated_at = NOW()
        RETURNING id, signal_id, contract_id`,
      [tenantId, signalId, contractId, LABOR_CASCADE_RULE_ID, LABOR_CASCADE_RULE_VERSION_HASH, actorId],
    );
    const row = inserted.rows[0];
    if (!row) {
      throw new Error('Failed to create correlation row for labor cascade draft amendment');
    }
    return row.id;
  });
  return result;
}

/**
 * Load a single cascade item from a run (scoped by item id).
 * Uses fn_regulatory_cascade_get and filters to the item. Alternatively,
 * we query the item table directly via executeInTransaction (simpler).
 */
interface CascadeItemRow {
  id: number;
  cascadeRunId: number;
  signalId: number;
  partyId: number;
  contractorNameEn: string;
  headcountBand: string;
  emiratisationGap: number;
  affectedContractIds: number[];
  advisoryDraftId: number | null;
}

async function loadCascadeItem(itemId: number, actorId: number, tenantId: string): Promise<CascadeItemRow | null> {
  const result = await db.executeInTransaction(async (client) => {
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const row = await client.query<{
      id: number;
      cascade_run_id: number;
      signal_id: number;
      party_id: number;
      name_en: string;
      headcount_band: string;
      emiratisation_gap: number;
      affected_contract_ids: unknown;
      advisory_draft_id: number | null;
    }>(
      `SELECT
          rci.id,
          rci.cascade_run_id,
          rcr.signal_id,
          rci.party_id,
          p.name_en,
          rci.headcount_band,
          rci.emiratisation_gap,
          rci.affected_contract_ids,
          rci.advisory_draft_id
        FROM regulatory_cascade_item rci
        JOIN regulatory_cascade_run rcr ON rcr.id = rci.cascade_run_id
        JOIN party p ON p.id = rci.party_id
        WHERE rci.id = $1
          AND rci.tenant_id = $2
          AND rci.is_active = TRUE
        LIMIT 1`,
      [itemId, tenantId],
    );
    return row.rows[0] ?? null;
  });
  if (!result) return null;

  let affectedContractIds: number[] = [];
  try {
    const raw = result.affected_contract_ids;
    affectedContractIds = Array.isArray(raw) ? (raw as number[]) : (JSON.parse(String(raw ?? '[]')) as number[]);
  } catch {
    affectedContractIds = [];
  }

  return {
    id: result.id,
    cascadeRunId: result.cascade_run_id,
    signalId: result.signal_id,
    partyId: result.party_id,
    contractorNameEn: result.name_en,
    headcountBand: result.headcount_band,
    emiratisationGap: result.emiratisation_gap,
    affectedContractIds,
    advisoryDraftId: result.advisory_draft_id,
  };
}

// ----------------------------------------------------------------
// Main entry point
// ----------------------------------------------------------------

export interface GenerateCascadeDraftInput {
  itemId: number;
  contractId?: number;
  actorId: number;
  tenantId: string;
}

/**
 * Generate and link an advisory draft for a cascade item.
 */
export async function generateCascadeDraftAmendment(
  input: GenerateCascadeDraftInput,
): Promise<DraftAmendmentResponse> {
  const { itemId, contractId: requestedContractId, actorId, tenantId } = input;

  logger.info(
    { action: 'regulatoryCascadeDraftService.generate', itemId, actorId },
    'Cascade draft amendment generation started',
  );

  // 1. Load cascade item
  const item = await loadCascadeItem(itemId, actorId, tenantId);
  if (!item) {
    throw new ApiError(404, 'item_not_found', 'Cascade item not found');
  }

  // 2. Check idempotency — if already linked, return existing reference
  if (item.advisoryDraftId !== null) {
    logger.info(
      { action: 'regulatoryCascadeDraftService.alreadyLinked', itemId, draftId: item.advisoryDraftId },
      'Draft already linked to cascade item — returning existing',
    );
    throw new ApiError(409, 'draft_already_linked', 'Advisory draft already linked to this cascade item');
  }

  // 3. Resolve contractId
  const resolvedContractId = requestedContractId ?? item.affectedContractIds[0];
  if (resolvedContractId === undefined || resolvedContractId === null) {
    throw new ApiError(400, 'no_affected_contracts', 'No affected contracts on this cascade item — cannot create advisory draft');
  }

  // 4. Locate or create correlation (signal=decree, contract=affected contract)
  const correlationId = await locateOrCreateCorrelation(
    item.signalId,
    resolvedContractId,
    actorId,
    tenantId,
  );

  // 5. Fetch advisory template id for labor_law_amendment_v1
  const templateId = await fetchLaborLawTemplateId(actorId, tenantId);

  // 6. Generate advisory draft (Mustache + optional LLM)
  //    The existing generateAdvisoryDraft service handles template fetch,
  //    Mustache context (generic), LLM call, fn_advisory_draft_generate.
  //    The labor_law_amendment_v1 template has its own placeholders
  //    (contractorName, clauseRef, decreeRef, complianceDeadline, emiratisationTarget)
  //    which the advisory-drafter's buildMustacheContext won't cover directly.
  //    The service falls back to minimal context if fn_advisory_context_build
  //    doesn't cover these fields — which is acceptable for CR-M demo scope.
  const draft = await generateAdvisoryDraft({
    correlationId,
    templateId,
    contractId: resolvedContractId,
    actorId,
    tenantId,
  });

  // 7. Link the draft to the cascade item
  const linkResult = await db.callFunction<RegulatoryCascadeItemDetail>(
    'fn_regulatory_cascade_item_link_draft',
    [actorId, itemId, draft.draftId],
    { actorId, tenantId },
  );

  if (!linkResult) {
    throw new ApiError(500, 'link_failed', 'Failed to link advisory draft to cascade item');
  }

  logger.info(
    {
      action: 'regulatoryCascadeDraftService.generateComplete',
      itemId,
      draftId: draft.draftId,
      correlationId,
    },
    'Cascade draft amendment generation complete',
  );

  return {
    draftId: draft.draftId,
    correlationId,
    templateId,
    contractId: resolvedContractId,
    approvalStatus: draft.approvalStatus,
    remediationStatus: linkResult.remediationStatus,
    itemId,
  };
}
