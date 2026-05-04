/**
 * M3 — Cron expiry + S2-20 system actor sentinel coverage.
 *
 * Stories: S9 (fn_signature_invitation_expire_due), AC-S9-04 (system-actor sentinel),
 * AC-S9-05 (NULL coercion), AC-S9-09 (idempotent re-runs).
 *
 * Pattern: backdate invitation_expires_at via the BYPASSRLS pool, set
 * `app.current_user_id = '0'` (the SYSTEM_ACTOR_ID sentinel), invoke
 * fn_signature_invitation_expire_due, assert on resulting state.
 *
 * IMPORTANT: this is the M2-precedent "cron FK violation" probe — Testing Agent
 * caught a real cron-path defect in M2 that Codex would have caught. Be alert
 * for similar patterns in M3 (per the M3 prompt's expected-defects list).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { closeAdminPool, adminPool, adminQuery } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  seedApprovedContract,
  cleanupSignatureArtifacts,
  readInvitationRow,
  readContractStatus,
  countSignatureEvents,
  backdateInvitationExpiry,
  employerSigner,
} from '../helpers/m3-helpers';

const trackedContractIds: number[] = [];

beforeAll(async () => {
  await seedFixtureUsers();
});

afterAll(async () => {
  if (trackedContractIds.length > 0) {
    try {
      await cleanupSignatureArtifacts(trackedContractIds);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[M3-cron cleanup]', err);
    }
  }
  await closeAdminPool();
});

/**
 * Run fn_signature_invitation_expire_due as the SYSTEM_ACTOR sentinel
 * (app.current_user_id = '0'). Mirrors what the cron driver does in
 * src/services/signature-expiration.cron.service.ts.
 */
const runExpireDueAsSystem = async (
  batchSize: number,
): Promise<{ data: { expiredInvitations: number; contractsHalted: number } }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // S2-20 — explicit SYSTEM_ACTOR_ID sentinel.
    await client.query("SELECT set_config('app.current_user_id', '0', true)");
    const r = await client.query<{ result: { data: { expiredInvitations: number; contractsHalted: number } } }>(
      'SELECT fn_signature_invitation_expire_due($1::INTEGER) AS result',
      [batchSize],
    );
    await client.query('COMMIT');
    return r.rows[0]!.result;
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

describe('S9 — fn_signature_invitation_expire_due', () => {
  it('AC-S9-01 + AC-S9-02: cron expires backdated invitation; status → expired; emits expired event', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    const invId = sent.data.invitations[0]!.invitationId;
    // Backdate so it's already past expiry
    await backdateInvitationExpiry(invId, 24);

    const result = await runExpireDueAsSystem(100);
    expect(result.data.expiredInvitations).toBeGreaterThanOrEqual(1);

    const inv = await readInvitationRow(invId);
    expect(inv?.['status']).toBe('expired');
    expect(await countSignatureEvents(contractId, 'expired')).toBeGreaterThanOrEqual(1);
  });

  it('AC-S9-03: ALL required signers expired at current step → contract.status → expired', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await backdateInvitationExpiry(sent.data.invitations[0]!.invitationId, 24);
    await runExpireDueAsSystem(100);
    expect(await readContractStatus(contractId)).toBe('expired');
  });

  it('AC-S9-04 + AC-S9-05 (S2-20): cron emits event with actor_user_id IS NULL — no FK violation', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await backdateInvitationExpiry(sent.data.invitations[0]!.invitationId, 24);
    // Should NOT raise FK violation (the M2-precedent defect)
    const result = await runExpireDueAsSystem(100);
    expect(result.data.expiredInvitations).toBeGreaterThanOrEqual(1);

    // Verify contract_activity rows have actor_user_id NULL (not 0)
    const activity = await adminQuery<{ activity_type: string; actor_id: number | null }>(
      `SELECT activity_type, actor_id FROM contract_activity
        WHERE contract_id = $1 AND activity_type IN ('sent_for_signature', 'signature_invalidated', 'status_changed')
        ORDER BY id DESC LIMIT 5`,
      [contractId],
    );
    // Find any cron-emitted activity rows; they MUST have actor IS NULL.
    // Since cron doesn't directly emit those types, we check the signature_event
    // table for the actor on the expired event:
    const events = await adminQuery<{ event_type: string; actor_user_id: number | null }>(
      `SELECT event_type, actor_user_id FROM signature_event
        WHERE contract_id = $1 AND event_type = 'expired'`,
      [contractId],
    );
    expect(events.length).toBeGreaterThanOrEqual(1);
    expect(events[0]!.actor_user_id).toBeNull(); // S2-20 verification
    void activity; // referenced for context
  });

  it('AC-S9-09: idempotent re-runs — second invocation returns 0', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await backdateInvitationExpiry(sent.data.invitations[0]!.invitationId, 24);
    const r1 = await runExpireDueAsSystem(100);
    const r2 = await runExpireDueAsSystem(100);
    expect(r1.data.expiredInvitations).toBeGreaterThanOrEqual(1);
    expect(r2.data.expiredInvitations).toBe(0);
  });

  it('cron is no-op on already-signed invitations (no expiry on signed)', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number; invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await callFnAs(drafter.id, 'fn_signature_sign', [
      sent.data.invitations[0]!.invitationTokenPlaintext, 'typed', 'Done', null, null, null, null, null,
    ]);
    // Backdate the (now signed) invitation to test cron skips it
    await backdateInvitationExpiry(sent.data.invitations[0]!.invitationId, 24);
    const result = await runExpireDueAsSystem(100);
    // The signed invitation should NOT be expired
    const inv = await readInvitationRow(sent.data.invitations[0]!.invitationId);
    expect(inv?.['status']).toBe('signed');
    void result;
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S2-19 fn-to-fn signature verification (M3 migrations 032/033/034)
// ──────────────────────────────────────────────────────────────────────────

describe('S2-19 — fn_-extension byte-for-byte preserved signatures', () => {
  it('fn_contract_activity_create accepts both M2 + M3 activity types', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    // M2 types (already present in canonical 031): created, status_changed,
    // approval_decided, etc. M3 types: sent_for_signature etc.
    const m2Type = 'status_changed';
    const m3Type = 'sent_for_signature';
    await callFnAs(drafter.id, 'fn_contract_activity_create', [
      contractId, m2Type, drafter.id, null, null, null,
    ]);
    await callFnAs(drafter.id, 'fn_contract_activity_create', [
      contractId, m3Type, drafter.id, null, null, null,
    ]);
    const types = await adminQuery<{ activity_type: string }>(
      `SELECT activity_type FROM contract_activity WHERE contract_id = $1`,
      [contractId],
    );
    const set = new Set(types.map((r) => r.activity_type));
    expect(set.has(m2Type)).toBe(true);
    expect(set.has(m3Type)).toBe(true);
  });

  it('fn_audit_trigger redacts M3 sensitive fields (invitation_token_hash, signature_data)', async () => {
    // The redact list extension is verified by inspecting the function body
    // via pg_get_functiondef. The presence of the M3 names in v_redact_fields
    // confirms migration 034 took effect.
    const rows = await adminQuery<{ defs: string }>(
      `SELECT pg_get_functiondef(p.oid) AS defs
         FROM pg_proc p WHERE p.proname = 'fn_audit_trigger'
        LIMIT 1`,
    );
    const def = rows[0]!.defs;
    expect(def).toContain('invitation_token_hash');
    expect(def).toContain('session_token_hash');
    expect(def).toContain('signature_data');
    expect(def).toContain('signature_image_url');
  });

  it('fn_contract_status_update_internal accepts new M3 signature transitions', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    // Probe the transition approved → awaiting_signature_employer (legitimate M3 transition)
    await callFnAs(drafter.id, 'fn_contract_status_update_internal', [
      contractId, 'awaiting_signature_employer', drafter.id, 'm3 transition probe',
    ]);
    expect(await readContractStatus(contractId)).toBe('awaiting_signature_employer');
  });
});
