/**
 * Unit-3 — persona action service helpers (R-OPS / R-FT / R-CES).
 *
 * Wraps fn_audit_log_record_v2 for each action code defined in migration 192.
 * Controllers are thin (Route → Controller → service → db.callFunction → response).
 * No business logic lives here — only the DB calls and the idempotency check.
 *
 * fn_audit_log_record_v2(actor_id BIGINT, table_name TEXT, record_id BIGINT,
 *                        action TEXT, new_values JSONB) RETURNS JSONB
 *   Returns: { id, prevHash, thisHash }
 *
 * Action codes (migration 192 audit_log_action_code catalog):
 *   ops_event_acknowledged, ops_remedy_linked, ops_escalation_requested
 *   price_review_initiated, payment_hold_recommended, hedge_review_initiated
 *   sanctions_flag_raised, supplier_audit_initiated,
 *   hold_recommended, termination_recommended, icv_certificate_uploaded
 *
 * Idempotency for ops_event_acknowledged:
 *   Raw SQL check (no fn_ for this path) counts audit_log rows matching
 *   (action, record_id, changed_by) within the last 24h via executeInTransaction.
 */

import { db } from '../database/client';
import { ConflictError } from '../utils/errors.util';
import { ADNOC_TENANT_ID } from '../middleware/rls.middleware';

/** Return type of fn_audit_log_record_v2 */
interface AuditLogRecordResult {
  id: number;
  prevHash: string;
  thisHash: string;
}

/**
 * Central helper — calls fn_audit_log_record_v2 with the correct 6-param signature
 * as defined in migration 128 (crc_audit_chain_extend):
 *   fn_audit_log_record_v2(p_table_name TEXT, p_record_id BIGINT, p_action TEXT,
 *                          p_old_values JSONB, p_new_values JSONB, p_changed_by BIGINT)
 *
 * IMPORTANT: fn_audit_log_record_v2 enforces p_action IN ('INSERT','UPDATE','DELETE').
 * Persona action codes (ops_event_acknowledged etc.) are NOT valid p_action values.
 * Convention: use p_action='INSERT' (creating a new semantic event record) and embed
 * the semantic action code in p_new_values as { actionCode: '...', ...payload }.
 * This keeps the hash chain intact and the actionCode survives in new_values for
 * any consumer that queries audit_log.new_values->>'actionCode'.
 *
 * The actor is passed as p_changed_by (last param). The GUC app.current_user_id
 * must also be set (via actorId in callFunction opts) for SECURITY DEFINER.
 */
async function writeAuditLog(
  actorId: number,
  tableName: string,
  recordId: number,
  actionCode: string,
  payload: Record<string, unknown>,
  tenantId?: string,
): Promise<AuditLogRecordResult> {
  // Embed the semantic action code inside new_values so it survives in the
  // audit_log record. p_action='INSERT' satisfies the fn_ CHECK constraint.
  const newValues = { actionCode, ...payload };
  const result = await db.callFunction<AuditLogRecordResult>(
    'fn_audit_log_record_v2',
    [tableName, recordId, 'INSERT', null, newValues, actorId],
    { actorId, tenantId: tenantId ?? ADNOC_TENANT_ID },
  );
  return result;
}

/**
 * Idempotency check: has the actor already acknowledged this correlation
 * in the last 24 hours?
 *
 * Uses db.executeInTransaction with a raw parameterised SQL query against
 * audit_log. No fn_ exists for this check (fn_audit_log_record_v2 writes
 * but does not expose a read path). Raw SQL is acceptable here per the
 * "report don't fix" protocol — the alternative would be a new migration
 * to add fn_audit_log_check_recent_action, but the idempotency check is
 * BE-only logic that doesn't need DB-side enforcement.
 *
 * Returns true if a duplicate acknowledgement exists in the last 24h.
 */
async function alreadyAcknowledged(
  actorId: number,
  correlationId: number,
  tenantId: string,
): Promise<boolean> {
  const count = await db.executeInTransaction(async (client) => {
    // Set GUCs so RLS is satisfied even on the raw query
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(actorId)]);
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const result = await client.query<{ cnt: string }>(
      `SELECT COUNT(*)::text AS cnt
         FROM audit_log
        WHERE table_name  = 'correlation'
          AND record_id   = $1
          AND changed_by  = $2
          AND action      = 'INSERT'
          AND (new_values->>'actionCode') = 'ops_event_acknowledged'
          AND changed_at  >= NOW() - INTERVAL '24 hours'`,
      [correlationId, actorId],
    );
    return parseInt(result.rows[0]?.cnt ?? '0', 10);
  });
  return count > 0;
}

// ---------------------------------------------------------------------------
// Operations action set
// ---------------------------------------------------------------------------

export const personaActionsService = {
  /**
   * ops_event_acknowledged — idempotency guarded (409 if duplicate within 24h).
   */
  async acknowledgeOpsEvent(
    actorId: number,
    correlationId: number,
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ correlationId: string; acknowledgedAt: string }> {
    const tid = tenantId ?? ADNOC_TENANT_ID;

    // Idempotency check — return 409 if already acknowledged in last 24h
    const duplicate = await alreadyAcknowledged(actorId, correlationId, tid);
    if (duplicate) {
      throw new ConflictError('already-acknowledged');
    }

    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'correlation',
      correlationId,
      'ops_event_acknowledged',
      { note: note ?? null, acknowledgedBy: actorId },
      tid,
    );

    return { correlationId: String(correlationId), acknowledgedAt: now };
  },

  /**
   * ops_remedy_linked — links a correlation event to a contract/clause remedy.
   */
  async linkRemedyToOpsEvent(
    actorId: number,
    correlationId: number,
    contractId: string,
    clauseId: string | undefined,
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ correlationId: string; contractId: string; linkedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'correlation',
      correlationId,
      'ops_remedy_linked',
      { contractId, clauseId: clauseId ?? null, note: note ?? null },
      tenantId,
    );
    return { correlationId: String(correlationId), contractId, linkedAt: now };
  },

  /**
   * ops_escalation_requested — escalates an ops event to a target role.
   */
  async escalateOpsEvent(
    actorId: number,
    correlationId: number,
    toRole: 'procurement' | 'legal' | 'executive',
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ correlationId: string; escalatedTo: string; escalatedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'correlation',
      correlationId,
      'ops_escalation_requested',
      { toRole, note: note ?? null },
      tenantId,
    );
    return { correlationId: String(correlationId), escalatedTo: toRole, escalatedAt: now };
  },

  // ---------------------------------------------------------------------------
  // Finance & Treasury action set
  // ---------------------------------------------------------------------------

  /**
   * price_review_initiated — triggers a price-review clause on a contract.
   */
  async initiatePriceReview(
    actorId: number,
    contractId: number,
    correlationId: string,
    reason: 'index_crossed' | 'escalation' | 'manual',
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ contractId: string; correlationId: string; initiatedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'price_review_initiated',
      { correlationId, reason, note: note ?? null },
      tenantId,
    );
    return { contractId: String(contractId), correlationId, initiatedAt: now };
  },

  /**
   * payment_hold_recommended — recommends a payment hold on a contract.
   */
  async recommendPaymentHold(
    actorId: number,
    contractId: number,
    invoiceRef: string | undefined,
    amountAed: number | undefined,
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ contractId: string; recommendedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'payment_hold_recommended',
      { invoiceRef: invoiceRef ?? null, amountAed: amountAed ?? null, note: note ?? null },
      tenantId,
    );
    return { contractId: String(contractId), recommendedAt: now };
  },

  /**
   * hedge_review_initiated — initiates a hedge review for a contract.
   */
  async initiateHedgeReview(
    actorId: number,
    contractId: number,
    pair: string | undefined,
    exposureAed: number | undefined,
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ contractId: string; initiatedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'hedge_review_initiated',
      { pair: pair ?? null, exposureAed: exposureAed ?? null, note: note ?? null },
      tenantId,
    );
    return { contractId: String(contractId), initiatedAt: now };
  },

  // ---------------------------------------------------------------------------
  // Compliance & ESG action set
  // ---------------------------------------------------------------------------

  /**
   * sanctions_flag_raised — raises a compliance flag on a contract.
   * Returns the audit_log id as a synthetic flagId handle.
   */
  async raiseComplianceFlag(
    actorId: number,
    contractId: number,
    flagKind: 'sanctions' | 'esg' | 'audit_rights' | 'other',
    severity: 'low' | 'medium' | 'high' | 'critical',
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ contractId: string; flagId: string; raisedAt: string }> {
    const now = new Date().toISOString();
    const auditRow = await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'sanctions_flag_raised',
      { flagKind, severity, note: note ?? null },
      tenantId,
    );
    return {
      contractId: String(contractId),
      flagId: String(auditRow.id),
      raisedAt: now,
    };
  },

  /**
   * supplier_audit_initiated — initiates a supplier audit on a contract.
   */
  async initiateSupplierAudit(
    actorId: number,
    contractId: number,
    scope: 'financial' | 'operational' | 'esg' | 'sanctions' | 'full',
    targetDate: string | undefined,
    note: string | undefined,
    tenantId?: string,
  ): Promise<{ contractId: string; initiatedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'supplier_audit_initiated',
      { scope, targetDate: targetDate ?? null, note: note ?? null },
      tenantId,
    );
    return { contractId: String(contractId), initiatedAt: now };
  },

  /**
   * hold_recommended — recommends a contract hold.
   */
  async recommendHold(
    actorId: number,
    contractId: number,
    reason: string,
    proposedHoldUntil: string | undefined,
    tenantId?: string,
  ): Promise<{ contractId: string; recommendedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'hold_recommended',
      { reason, proposedHoldUntil: proposedHoldUntil ?? null },
      tenantId,
    );
    return { contractId: String(contractId), recommendedAt: now };
  },

  /**
   * termination_recommended — recommends contract termination.
   */
  async recommendTermination(
    actorId: number,
    contractId: number,
    reason: string,
    grounds: string,
    tenantId?: string,
  ): Promise<{ contractId: string; recommendedAt: string }> {
    const now = new Date().toISOString();
    await writeAuditLog(
      actorId,
      'contract',
      contractId,
      'termination_recommended',
      { reason, grounds },
      tenantId,
    );
    return { contractId: String(contractId), recommendedAt: now };
  },

  /**
   * icv_certificate_uploaded — writes audit log for ICV cert upload.
   * The attachment row is already created by the controller before this call.
   */
  async logIcvCertificateUpload(
    actorId: number,
    contractId: number,
    attachmentId: number,
    filename: string,
    validUntil: string | undefined,
    tenantId?: string,
  ): Promise<void> {
    await writeAuditLog(
      actorId,
      'contract_attachment',
      attachmentId,
      'icv_certificate_uploaded',
      { contractId, filename, validUntil: validUntil ?? null, kind: 'icv_certificate' },
      tenantId,
    );
  },
};
