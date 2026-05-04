/**
 * Shared helpers for M3 (Signatures + Signer Q&A AI) tests.
 *
 * Provides:
 *   - createApprovedContract — seed a draft, force-promote to 'approved' with
 *     an attached approval_chain in 'approved' status. Most M3 fn_'s require
 *     contract.status='approved' AND approval_chain.status='approved' as
 *     precondition (AC-S1-02 / AC-S1-03).
 *   - cleanupSignatureArtifacts — afterAll bulk delete of signature_event,
 *     signature_invitation, signature_party, signer_qa_session and the
 *     activity / chain rows attached to test contracts.
 *   - bypassDenyUpdateTrigger — temporarily disable the
 *     trg_signature_event_deny_update trigger for tests that need to mutate
 *     a signature_event (rare).
 *   - readInvitationRow / readPartyRow / readSessionRow — direct admin-pool
 *     reads for assertions that inspect persisted state.
 *   - countSignatureEvents — count signature_event rows by event_type.
 *
 * Reuses M1c fixture user pool + M2 callFnAs primitives.
 */
import { adminPool, adminQuery } from './m1a-helpers';

/**
 * Force-elevate a draft contract to status='approved' via the BYPASSRLS pool.
 *
 * Inserts an approval_chain stub with status='approved' so the AC-S1-03
 * precondition (no_approved_chain) is satisfied. This is acceptable for M3
 * tests because the M2 chain lifecycle is already covered by M2 suites; M3
 * only needs the approved-state shape.
 *
 * Returns { contractId, chainId }.
 */
export const seedApprovedContract = async (params: {
  drafterId: number;
  contractType?: string;
  language?: 'en' | 'ar' | 'bilingual';
  valueAed?: number;
  titleEn?: string;
}): Promise<{ contractId: number; chainId: number; contractNumber: string }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // Set GUC so fn_contract_create's audit columns are populated correctly.
    await client.query("SELECT set_config('app.current_user_id', $1, true)", [
      String(params.drafterId),
    ]);
    const created = await client.query<{ created: { id: number; contractNumber: string } }>(
      'SELECT fn_contract_create($1::JSONB, $2::BIGINT) AS created',
      [
        JSON.stringify({
          titleEn: params.titleEn ?? `M3-${Date.now()}-${Math.floor(Math.random() * 1e6)}`,
          contractType: params.contractType ?? 'employment',
          language: params.language ?? 'en',
          valueAed: params.valueAed ?? 25_000,
        }),
        params.drafterId,
      ],
    );
    const contractId = Number(created.rows[0]!.created.id);
    const contractNumber = created.rows[0]!.created.contractNumber;
    // Force contract.status='approved' (bypass M2 state machine).
    await client.query(
      `UPDATE contract SET status = 'approved', updated_at = CURRENT_TIMESTAMP WHERE id = $1`,
      [contractId],
    );
    // Insert an approved approval_chain stub. The M3 fn_'s only check
    // approval_chain.status='approved' & is_active=TRUE for the contract.
    const chain = await client.query<{ id: number | string }>(
      `INSERT INTO approval_chain
         (contract_id, matrix_snapshot, status, current_step_order,
          initiated_by, initiated_at, completed_at, created_by, updated_by, is_active)
         VALUES ($1, '[]'::jsonb, 'approved', 1, $2, CURRENT_TIMESTAMP,
                 CURRENT_TIMESTAMP, $2, $2, TRUE)
       RETURNING id`,
      [contractId, params.drafterId],
    );
    const chainId = Number(chain.rows[0]!.id);
    await client.query('COMMIT');
    return { contractId, chainId, contractNumber };
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Hard-delete signature artifacts for the supplied contract ids. Runs in a
 * single transaction. Safe with empty list.
 */
export const cleanupSignatureArtifacts = async (
  contractIds: number[],
): Promise<void> => {
  if (contractIds.length === 0) return;
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // signer_qa_session FK chain: signature_invitation. Delete sessions first.
    await client.query(
      `DELETE FROM signer_qa_session
        WHERE signature_invitation_id IN (
          SELECT inv.id FROM signature_invitation inv
          WHERE inv.contract_id = ANY($1::BIGINT[])
        )`,
      [contractIds],
    );
    // signature_event temporarily allow delete (deny-update trigger is
    // BEFORE UPDATE, not BEFORE DELETE — so DELETE works).
    await client.query(
      'DELETE FROM signature_event WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    await client.query(
      'DELETE FROM signature_invitation WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    await client.query(
      'DELETE FROM signature_party WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    // approval_chain rows seeded by helper.
    await client.query(
      `DELETE FROM approval_decision d
         USING approval_step s, approval_chain ch
        WHERE d.approval_step_id = s.id
          AND s.approval_chain_id = ch.id
          AND ch.contract_id = ANY($1::BIGINT[])`,
      [contractIds],
    );
    await client.query(
      `DELETE FROM approval_step s
         USING approval_chain ch
        WHERE s.approval_chain_id = ch.id
          AND ch.contract_id = ANY($1::BIGINT[])`,
      [contractIds],
    );
    await client.query(
      'DELETE FROM approval_chain WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    // contract_activity for these contracts.
    await client.query(
      'DELETE FROM contract_activity WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    // Then contracts themselves.
    await client.query(
      'DELETE FROM contract_version WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    await client.query(
      'DELETE FROM contract_tag WHERE contract_id = ANY($1::BIGINT[])',
      [contractIds],
    );
    await client.query(
      'DELETE FROM contract WHERE id = ANY($1::BIGINT[])',
      [contractIds],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Read a signature_invitation row by id. BYPASSRLS for assertions.
 */
export const readInvitationRow = async (
  invitationId: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, signature_party_id, contract_id, status,
            invitation_sent_at, first_viewed_at, last_viewed_at, view_count,
            invitation_token_hash, invitation_expires_at,
            ip_address, user_agent, language, is_active
       FROM signature_invitation
      WHERE id = $1`,
    [invitationId],
  );
  return rows[0] ?? null;
};

/**
 * Read a signature_party row by id. BYPASSRLS for assertions.
 */
export const readPartyRow = async (
  partyId: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, contract_id, signer_side, signer_user_id,
            signer_name_en, signer_name_ar, signer_email, signer_phone,
            signer_party_id, step_order, is_required, is_active
       FROM signature_party
      WHERE id = $1`,
    [partyId],
  );
  return rows[0] ?? null;
};

/**
 * Read a signer_qa_session row by id. BYPASSRLS for assertions.
 */
export const readSessionRow = async (
  sessionId: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, signature_invitation_id, language, session_token_hash,
            message_count, tokens_consumed, rate_limit_window_start,
            rate_limit_count, last_activity_at, is_active, created_at
       FROM signer_qa_session
      WHERE id = $1`,
    [sessionId],
  );
  return rows[0] ?? null;
};

/**
 * Count signature_event rows by event_type for a contract.
 */
export const countSignatureEvents = async (
  contractId: number,
  eventType: string,
): Promise<number> => {
  const rows = await adminQuery<{ count: string }>(
    `SELECT COUNT(*)::text AS count
       FROM signature_event
      WHERE contract_id = $1 AND event_type = $2`,
    [contractId, eventType],
  );
  return Number(rows[0]?.count ?? 0);
};

/**
 * Read all contract_activity activity_type values for a contract, ordered by
 * created_at ASC. Used for verifying the M3 lifecycle activity emissions.
 */
export const listSignatureActivityTypes = async (
  contractId: number,
): Promise<string[]> => {
  const rows = await adminQuery<{ activity_type: string }>(
    `SELECT activity_type
       FROM contract_activity
      WHERE contract_id = $1
      ORDER BY created_at ASC, id ASC`,
    [contractId],
  );
  return rows.map((r) => r.activity_type);
};

/**
 * Read contract.status by id. BYPASSRLS.
 */
export const readContractStatus = async (
  contractId: number,
): Promise<string | null> => {
  const rows = await adminQuery<{ status: string }>(
    'SELECT status FROM contract WHERE id = $1',
    [contractId],
  );
  return rows[0]?.status ?? null;
};

/**
 * Helper to backdate a signature_invitation.invitation_expires_at so the cron
 * fn_signature_invitation_expire_due will pick it up. Bypasses any update
 * triggers via the admin pool.
 */
export const backdateInvitationExpiry = async (
  invitationId: number,
  hoursAgo: number,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    // chk_signature_invitation_expires_after_sent enforces expires > sent.
    // Push BOTH backwards so the constraint stays satisfied while expires_at
    // lands in the past.
    await client.query(
      `UPDATE signature_invitation
          SET invitation_sent_at    = CURRENT_TIMESTAMP - make_interval(hours => $2 + 1),
              invitation_expires_at = CURRENT_TIMESTAMP - make_interval(hours => $2),
              updated_at = CURRENT_TIMESTAMP
        WHERE id = $1`,
      [invitationId, hoursAgo],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Helper to backdate a signer_qa_session.window_started_at so the per-session
 * rate-limit window has expired.
 */
export const backdateSessionWindow = async (
  sessionId: number,
  hoursAgo: number,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `UPDATE signer_qa_session
          SET rate_limit_window_start = CURRENT_TIMESTAMP - make_interval(hours => $2),
              rate_limit_count = 0
        WHERE id = $1`,
      [sessionId, hoursAgo],
    );
    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Build a canonical SignaturePartyInput object the way fn_signature_party_create_bulk
 * expects (camelCase JSONB keys mirrored from schemas.ts).
 */
export interface PartyInput {
  signerSide: 'employer' | 'counterparty' | 'witness';
  signerUserId?: number | null;
  signerNameEn: string;
  signerNameAr?: string | null;
  signerEmail?: string | null;
  signerPhone?: string | null;
  signerPartyId?: number | null;
  stepOrder: number;
  isRequired?: boolean;
}

export const employerSigner = (overrides: Partial<PartyInput> = {}): PartyInput => ({
  signerSide: 'employer',
  signerNameEn: 'Test Employer Signer',
  signerEmail: `employer-${Date.now()}-${Math.floor(Math.random() * 1e6)}@m3.test`,
  stepOrder: 1,
  isRequired: true,
  ...overrides,
});

export const counterpartySigner = (overrides: Partial<PartyInput> = {}): PartyInput => ({
  signerSide: 'counterparty',
  signerNameEn: 'Test Counterparty Signer',
  signerEmail: `cp-${Date.now()}-${Math.floor(Math.random() * 1e6)}@m3.test`,
  stepOrder: 2,
  isRequired: true,
  ...overrides,
});
