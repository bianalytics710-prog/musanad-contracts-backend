/**
 * M3 — Signature ceremony DB function tests.
 *
 * Stories covered: S1 (party_create_bulk), S2 (send_for_signature),
 * S3 (get_by_invitation_token), S4 (sign), S5 (decline), S6 (list_for_contract),
 * S7 (resend), S8 (cancel), S10 (activity-type whitelist), S14 (activity list).
 *
 * Pattern: drive each fn_ via the BYPASSRLS admin pool with `app.current_user_id`
 * set to the appropriate fixture user. Mirrors M2 test conventions.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { closeAdminPool, adminQuery } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  seedApprovedContract,
  cleanupSignatureArtifacts,
  readInvitationRow,
  readPartyRow,
  countSignatureEvents,
  listSignatureActivityTypes,
  readContractStatus,
  employerSigner,
  counterpartySigner,
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
      console.warn('[M3-signature-ceremony cleanup]', err);
    }
  }
  await closeAdminPool();
});

// ──────────────────────────────────────────────────────────────────────────
// S1 — fn_signature_party_create_bulk
// ──────────────────────────────────────────────────────────────────────────

describe('S1 — fn_signature_party_create_bulk', () => {
  it('AC-S1-01: drafter creates 2 signers; createdCount=2, skippedCount=0', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);

    const result = await callFnAs<{ data: { signatureParties: unknown[]; createdCount: number; skippedCount: number } }>(
      drafter.id,
      'fn_signature_party_create_bulk',
      [
        contractId,
        [employerSigner(), counterpartySigner()],
        drafter.id,
      ],
    );
    expect(result.data.createdCount).toBe(2);
    expect(result.data.skippedCount).toBe(0);
    expect(result.data.signatureParties.length).toBe(2);
  });

  it('AC-S1-02: 409 precondition_failed when contract.status != approved', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    // Force contract back to draft
    await adminQuery(`UPDATE contract SET status = 'draft' WHERE id = $1`, [contractId]);
    await expect(
      callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
        contractId,
        [employerSigner()],
        drafter.id,
      ]),
    ).rejects.toThrow(/precondition_failed:contract_status_not_approved|contract_status_not_approved/);
  });

  it('AC-S1-04: 22023 when no employer is_required signer (counterparty only)', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);

    await expect(
      callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
        contractId,
        [counterpartySigner({ stepOrder: 1 })],
        drafter.id,
      ]),
    ).rejects.toThrow(/employer/i);
  });

  it('AC-S1-05: 22023 missing signer_name_en raises a validation error', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);

    await expect(
      callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
        contractId,
        [{ ...employerSigner(), signerNameEn: '' }],
        drafter.id,
      ]),
    ).rejects.toThrow();
  });

  it('AC-S1-06: P0002 contract_not_found on bogus contract id', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
        9_999_999_999,
        [employerSigner()],
        drafter.id,
      ]),
    ).rejects.toThrow(/Contract not found|contract_not_found/);
  });

  it('AC-S1-07: 42501 forbidden when actor lacks signature.send (recipient)', async () => {
    const drafter = getFixture('drafter1');
    const recipient = getFixture('recipient1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await expect(
      callFnAs(recipient.id, 'fn_signature_party_create_bulk', [
        contractId,
        [employerSigner()],
        recipient.id,
      ]),
    ).rejects.toThrow(/permission|signature\.send|forbidden/i);
  });

  it('AC-S1-08: idempotency — re-submitting same signer is skipped (createdCount=0, skippedCount=1)', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    const initial = employerSigner({ signerEmail: 'idempotent@m3.test' });

    const r1 = await callFnAs<{ data: { createdCount: number; skippedCount: number } }>(
      drafter.id,
      'fn_signature_party_create_bulk',
      [contractId, [initial, counterpartySigner()], drafter.id],
    );
    expect(r1.data.createdCount).toBe(2);

    // Re-submit the same employer (counterparty differs by random email so still creates)
    const r2 = await callFnAs<{ data: { createdCount: number; skippedCount: number } }>(
      drafter.id,
      'fn_signature_party_create_bulk',
      [contractId, [initial], drafter.id],
    );
    expect(r2.data.createdCount).toBe(0);
    expect(r2.data.skippedCount).toBe(1);
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S2 — fn_signature_send_for_signature + token-once invariant
// ──────────────────────────────────────────────────────────────────────────

describe('S2 — fn_signature_send_for_signature', () => {
  it('AC-S2-01 + AC-S2-06 + AC-S2-07: status transitions to awaiting_signature_employer; plaintext token returned ONCE; expiry = sent_at + 14d', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);

    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner(), counterpartySigner()],
      drafter.id,
    ]);

    const sent = await callFnAs<{ data: { contractId: number; newStatus: string; invitations: Array<{ invitationId: number; invitationTokenPlaintext: string; expiresAt: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    expect(sent.data.newStatus).toBe('awaiting_signature_employer');
    expect(sent.data.invitations.length).toBe(1); // step_order=1 only (employer)
    expect(sent.data.invitations[0]!.invitationTokenPlaintext).toMatch(/^[A-Za-z0-9_-]{32,}$/);
    expect(sent.data.invitations[0]!.expiresAt).toBeTruthy();

    // Verify plaintext is NOT stored — only the hash.
    const inv = await readInvitationRow(sent.data.invitations[0]!.invitationId);
    expect(inv).not.toBeNull();
    expect(inv?.['invitation_token_hash']).toBeTruthy();
    expect(JSON.stringify(inv)).not.toContain(sent.data.invitations[0]!.invitationTokenPlaintext);

    // Expiry should be ~14 days in future.
    const expiresAt = new Date(sent.data.invitations[0]!.expiresAt).getTime();
    const now = Date.now();
    const diffDays = (expiresAt - now) / (1000 * 60 * 60 * 24);
    expect(diffDays).toBeGreaterThan(13.9);
    expect(diffDays).toBeLessThan(14.1);
  });

  it('AC-S2-04: 409 invalid_status_for_send when status != approved', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await adminQuery(`UPDATE contract SET status = 'draft' WHERE id = $1`, [contractId]);
    await expect(
      callFnAs(drafter.id, 'fn_signature_send_for_signature', [contractId, drafter.id]),
    ).rejects.toThrow(/invalid_status_for_send|precondition_failed/);
  });

  it('AC-S2-05: 409 no_signature_parties when none configured', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await expect(
      callFnAs(drafter.id, 'fn_signature_send_for_signature', [contractId, drafter.id]),
    ).rejects.toThrow(/no_signature_parties|precondition_failed/);
  });

  it('AC-S2-08: 42501 forbidden when actor lacks signature.send (recipient)', async () => {
    const drafter = getFixture('drafter1');
    const recipient = getFixture('recipient1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    await expect(
      callFnAs(recipient.id, 'fn_signature_send_for_signature', [contractId, recipient.id]),
    ).rejects.toThrow(/permission|signature\.send|forbidden/i);
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S3 — fn_signature_get_by_invitation_token (PUBLIC)
// ──────────────────────────────────────────────────────────────────────────

describe('S3 — fn_signature_get_by_invitation_token', () => {
  it('AC-S3-01 + AC-S3-05 + AC-S3-07: returns contract excerpt + masked email + language', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner({ signerEmail: 'jane.doe@example.com' })],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    const token = sent.data.invitations[0]!.invitationTokenPlaintext;

    const view = await callFnAs<{ data: { invitation: Record<string, unknown>; signer: Record<string, unknown>; contract: Record<string, unknown>; availableMethods: unknown[] } }>(
      drafter.id, // actor irrelevant for SECURITY DEFINER, but admin pool is OK
      'fn_signature_get_by_invitation_token',
      [token],
    );
    expect(view.data.signer).toBeTruthy();
    // Email must be masked (j***@example.com or similar)
    const email = view.data.signer['email'];
    expect(typeof email).toBe('string');
    expect(email).toMatch(/\*+/); // contains mask
    // Phone must NOT be returned.
    expect(view.data.signer['phone']).toBeUndefined();
    expect(view.data.invitation['language']).toMatch(/en|ar/);
    expect(Array.isArray(view.data.availableMethods)).toBe(true);
  });

  it('AC-S3-02: first call sets first_viewed_at + view_count=1; emits "viewed" event ONCE per session', async () => {
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
    const inv = sent.data.invitations[0]!;
    // First view
    await callFnAs(drafter.id, 'fn_signature_get_by_invitation_token', [inv.invitationTokenPlaintext]);
    const after1 = await readInvitationRow(inv.invitationId);
    expect(after1?.['first_viewed_at']).not.toBeNull();
    expect(Number(after1?.['view_count'])).toBe(1);
    // Second view increments count but does NOT add another viewed event.
    await callFnAs(drafter.id, 'fn_signature_get_by_invitation_token', [inv.invitationTokenPlaintext]);
    const after2 = await readInvitationRow(inv.invitationId);
    expect(Number(after2?.['view_count'])).toBe(2);
    const viewedEvents = await countSignatureEvents(contractId, 'viewed');
    expect(viewedEvents).toBe(1);
  });

  it('AC-S3-04: returns NULL on unknown token (controller maps to 410 generic)', async () => {
    const result = await callFnAs<unknown>(
      1,
      'fn_signature_get_by_invitation_token',
      ['x'.repeat(43)],
    );
    expect(result).toBeNull();
  });

  it('AC-S3-06: token is hashed before lookup (SHA-256, never plaintext compare)', async () => {
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
    const token = sent.data.invitations[0]!.invitationTokenPlaintext;
    const inv = await readInvitationRow(sent.data.invitations[0]!.invitationId);
    // Hash should be 64-char hex (SHA-256).
    expect(typeof inv?.['invitation_token_hash']).toBe('string');
    expect((inv?.['invitation_token_hash'] as string).length).toBe(64);
    expect(inv?.['invitation_token_hash']).not.toBe(token);
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S4 — fn_signature_sign
// ──────────────────────────────────────────────────────────────────────────

describe('S4 — fn_signature_sign', () => {
  /**
   * Helper — set up an approved contract with employer + counterparty signers,
   * send for signature, return both invitation tokens (employer issued, cp not yet).
   */
  const setupForSign = async (drafterId: number) => {
    const { contractId } = await seedApprovedContract({ drafterId });
    trackedContractIds.push(contractId);
    await callFnAs(drafterId, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner(), counterpartySigner()],
      drafterId,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number; invitationTokenPlaintext: string }> } }>(
      drafterId,
      'fn_signature_send_for_signature',
      [contractId, drafterId],
    );
    return { contractId, employerToken: sent.data.invitations[0]!.invitationTokenPlaintext, employerInvitationId: sent.data.invitations[0]!.invitationId };
  };

  it('AC-S4-01: typed method records signed event + sets invitation.status=signed', async () => {
    const drafter = getFixture('drafter1');
    const { contractId, employerToken, employerInvitationId } = await setupForSign(drafter.id);
    const result = await callFnAs<{ data: { invitationId: number; status: string; signedAt: string; stepCompleted: boolean; contractNewStatus: string | null } }>(
      drafter.id,
      'fn_signature_sign',
      [employerToken, 'typed', 'John Doe Signature', null, null, '127.0.0.1', 'TestAgent', null],
    );
    expect(result.data.status).toBe('signed');
    expect(result.data.signedAt).toBeTruthy();
    const inv = await readInvitationRow(employerInvitationId);
    expect(inv?.['status']).toBe('signed');
    const signedEvents = await countSignatureEvents(contractId, 'signed');
    expect(signedEvents).toBe(1);
  });

  it('AC-S4-02: uae_pass requires uae_pass_verification_level (raises 22023 when missing)', async () => {
    const drafter = getFixture('drafter1');
    const { employerToken } = await setupForSign(drafter.id);
    await expect(
      callFnAs(drafter.id, 'fn_signature_sign', [
        employerToken, 'uae_pass', null, null, null, null, null, null,
      ]),
    ).rejects.toThrow(/uae_pass|level/i);
  });

  it('AC-S4-03: drawn requires signature_image_url + signature_data', async () => {
    const drafter = getFixture('drafter1');
    const { employerToken } = await setupForSign(drafter.id);
    await expect(
      callFnAs(drafter.id, 'fn_signature_sign', [
        employerToken, 'drawn', 'data', null, null, null, null, null,
      ]),
    ).rejects.toThrow(/signature_image|missing/i);
  });

  it('AC-S4-04: ds_otp requires metadata.otpReceipt', async () => {
    const drafter = getFixture('drafter1');
    const { employerToken } = await setupForSign(drafter.id);
    await expect(
      callFnAs(drafter.id, 'fn_signature_sign', [
        employerToken, 'ds_otp', null, null, null, null, null, JSON.stringify({}),
      ]),
    ).rejects.toThrow(/otp/i);
  });

  it('AC-S4-05: 410 generic invitation_invalid_or_expired on unknown token', async () => {
    await expect(
      callFnAs(1, 'fn_signature_sign', [
        'x'.repeat(43), 'typed', 'foo', null, null, null, null, null,
      ]),
    ).rejects.toThrow(/invitation_invalid_or_expired/);
  });

  it('AC-S4-06: employer signs (last required at step 1) → contract.status awaiting_signature_counterparty', async () => {
    const drafter = getFixture('drafter1');
    const { contractId, employerToken } = await setupForSign(drafter.id);
    const result = await callFnAs<{ data: { stepCompleted: boolean; contractNewStatus: string | null } }>(
      drafter.id,
      'fn_signature_sign',
      [employerToken, 'typed', 'Done', null, null, null, null, null],
    );
    expect(result.data.stepCompleted).toBe(true);
    expect(result.data.contractNewStatus).toBe('awaiting_signature_counterparty');
    const status = await readContractStatus(contractId);
    expect(status).toBe('awaiting_signature_counterparty');
  });

  it('AC-S4-09: idempotency — second sign returns 409 already_signed', async () => {
    const drafter = getFixture('drafter1');
    const { employerToken } = await setupForSign(drafter.id);
    await callFnAs(drafter.id, 'fn_signature_sign', [
      employerToken, 'typed', 'Done', null, null, null, null, null,
    ]);
    await expect(
      callFnAs(drafter.id, 'fn_signature_sign', [
        employerToken, 'typed', 'Done2', null, null, null, null, null,
      ]),
    ).rejects.toThrow(/already_signed/);
  });

  it('AC-S4-10: signature_data + signature_image_url NEVER returned in response', async () => {
    const drafter = getFixture('drafter1');
    const { employerToken } = await setupForSign(drafter.id);
    const result = await callFnAs<{ data: Record<string, unknown> }>(
      drafter.id,
      'fn_signature_sign',
      [employerToken, 'typed', 'My Signature Text', null, null, null, null, null],
    );
    const flat = JSON.stringify(result.data);
    expect(flat).not.toContain('My Signature Text');
    expect(result.data['signatureData']).toBeUndefined();
    expect(result.data['signatureImageUrl']).toBeUndefined();
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S5 — fn_signature_decline
// ──────────────────────────────────────────────────────────────────────────

describe('S5 — fn_signature_decline', () => {
  it('AC-S5-01: decline records event + sets status=declined; required-signer triggers contract → rejected', async () => {
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
    const token = sent.data.invitations[0]!.invitationTokenPlaintext;

    const result = await callFnAs<{ data: { status: string; contractNewStatus: string | null } }>(
      drafter.id,
      'fn_signature_decline',
      [token, 'I do not agree with the terms', null, null],
    );
    expect(result.data.status).toBe('declined');
    expect(result.data.contractNewStatus).toBe('rejected');
    expect(await readContractStatus(contractId)).toBe('rejected');
    expect(await countSignatureEvents(contractId, 'declined')).toBe(1);
  });

  it('AC-S5-02: 22023 reason_too_short < 5 chars', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await expect(
      callFnAs(drafter.id, 'fn_signature_decline', [
        sent.data.invitations[0]!.invitationTokenPlaintext, 'no', null, null,
      ]),
    ).rejects.toThrow(/reason_too_short|short/i);
  });

  it('AC-S5-04: 410 generic on unknown token', async () => {
    await expect(
      callFnAs(1, 'fn_signature_decline', [
        'x'.repeat(43), 'Reason for decline here', null, null,
      ]),
    ).rejects.toThrow(/invitation_invalid_or_expired/);
  });

  it('AC-S5-07: 409 already_decided when re-declining', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    const token = sent.data.invitations[0]!.invitationTokenPlaintext;
    await callFnAs(drafter.id, 'fn_signature_decline', [token, 'Reason 12345', null, null]);
    await expect(
      callFnAs(drafter.id, 'fn_signature_decline', [token, 'Reason 67890', null, null]),
    ).rejects.toThrow(/already_decided/);
  });

  it('AC-S5-08 / S2-20: external-signer decline records signature_event.actor_user_id IS NULL', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await callFnAs(drafter.id, 'fn_signature_decline', [
      sent.data.invitations[0]!.invitationTokenPlaintext, 'Decline reason', null, null,
    ]);
    // signature_event row for external signer must have actor_user_id IS NULL.
    const events = await adminQuery<{ actor_user_id: number | null }>(
      `SELECT actor_user_id FROM signature_event WHERE contract_id = $1 AND event_type = 'declined'`,
      [contractId],
    );
    expect(events.length).toBe(1);
    expect(events[0]!.actor_user_id).toBeNull();
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S6 — fn_signature_list_for_contract
// ──────────────────────────────────────────────────────────────────────────

describe('S6 — fn_signature_list_for_contract', () => {
  it('AC-S6-01 + AC-S6-02: returns signers + stepProgress; currentInvitationId populated on active invitation', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner(), counterpartySigner()],
      drafter.id,
    ]);
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    const empInvitationId = sent.data.invitations[0]!.invitationId;
    const list = await callFnAs<{ data: { signers: Array<Record<string, unknown>>; stepProgress: Array<Record<string, unknown>> } }>(
      drafter.id,
      'fn_signature_list_for_contract',
      [contractId, drafter.id, 'platform_admin'],
    );
    expect(list.data.signers.length).toBe(2);
    // Step 1 (employer) gets the invitation; step 2 doesn't yet.
    const emp = list.data.signers.find((s) => s['stepOrder'] === 1)!;
    expect(emp['currentInvitationId']).toBe(empInvitationId);
    const cp = list.data.signers.find((s) => s['stepOrder'] === 2)!;
    expect(cp['currentInvitationId']).toBeNull();

    // step_progress aggregates
    expect(list.data.stepProgress.length).toBe(2);
    const step1Progress = list.data.stepProgress.find((p) => p['stepOrder'] === 1)!;
    expect(Number(step1Progress['totalRequired'])).toBe(1);
    expect(Number(step1Progress['pendingCount'])).toBe(1);
  });

  it('AC-S6-04: signer_email masked for non-privileged roles, full for legal_counsel', async () => {
    const drafter = getFixture('drafter1');
    const legal = getFixture('legal_counsel1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner({ signerEmail: 'visible@m3.test' })],
      drafter.id,
    ]);
    // contract_drafter sees masked
    const draft = await callFnAs<{ data: { signers: Array<{ signerEmail: string }> } }>(
      drafter.id,
      'fn_signature_list_for_contract',
      [contractId, drafter.id, 'contract_drafter'],
    );
    const draftEmail = draft.data.signers[0]!.signerEmail;
    expect(draftEmail).toMatch(/\*+/); // masked

    // legal_counsel sees full
    const lc = await callFnAs<{ data: { signers: Array<{ signerEmail: string }> } }>(
      legal.id,
      'fn_signature_list_for_contract',
      [contractId, legal.id, 'legal_counsel'],
    );
    expect(lc.data.signers[0]!.signerEmail).toBe('visible@m3.test');
  });

  it('AC-S6-07: signers sorted by stepOrder ASC, created_at ASC', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [
        counterpartySigner({ stepOrder: 2, signerEmail: 'cp1@m3.test' }),
        counterpartySigner({ stepOrder: 2, signerEmail: 'cp2@m3.test' }),
        employerSigner({ stepOrder: 1, signerEmail: 'emp@m3.test' }),
      ],
      drafter.id,
    ]);
    const list = await callFnAs<{ data: { signers: Array<{ stepOrder: number }> } }>(
      drafter.id,
      'fn_signature_list_for_contract',
      [contractId, drafter.id, 'platform_admin'],
    );
    const orders = list.data.signers.map((s) => s.stepOrder);
    // Ascending order
    expect(orders).toEqual([...orders].sort((a, b) => a - b));
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S7 — fn_signature_invitation_resend
// ──────────────────────────────────────────────────────────────────────────

describe('S7 — fn_signature_invitation_resend', () => {
  it('AC-S7-01 + AC-S7-02: resend creates fresh invitation, deactivates old, returns plaintext token ONCE; old invitation has resent event', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    const partiesResult = await callFnAs<{ data: { signatureParties: Array<{ id: number }> } }>(
      drafter.id,
      'fn_signature_party_create_bulk',
      [contractId, [employerSigner()], drafter.id],
    );
    const partyId = partiesResult.data.signatureParties[0]!.id;
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    const oldInvId = sent.data.invitations[0]!.invitationId;

    const resent = await callFnAs<{ data: { newInvitationId: number; invitationTokenPlaintext: string; expiresAt: string } }>(
      drafter.id,
      'fn_signature_invitation_resend',
      [partyId, drafter.id, 'manual nudge'],
    );
    expect(resent.data.newInvitationId).not.toBe(oldInvId);
    expect(resent.data.invitationTokenPlaintext).toMatch(/^[A-Za-z0-9_-]{32,}$/);
    // Old should be is_active=FALSE
    const oldInv = await readInvitationRow(oldInvId);
    expect(oldInv?.['is_active']).toBe(false);
    const resentEvents = await countSignatureEvents(contractId, 'resent');
    expect(resentEvents).toBeGreaterThanOrEqual(1);
  });

  it('AC-S7-03: 409 invalid_invitation_status_for_resend on signed', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    const partiesResult = await callFnAs<{ data: { signatureParties: Array<{ id: number }> } }>(
      drafter.id,
      'fn_signature_party_create_bulk',
      [contractId, [employerSigner()], drafter.id],
    );
    const partyId = partiesResult.data.signatureParties[0]!.id;
    const sent = await callFnAs<{ data: { invitations: Array<{ invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await callFnAs(drafter.id, 'fn_signature_sign', [
      sent.data.invitations[0]!.invitationTokenPlaintext, 'typed', 'Signed', null, null, null, null, null,
    ]);
    await expect(
      callFnAs(drafter.id, 'fn_signature_invitation_resend', [partyId, drafter.id, null]),
    ).rejects.toThrow(/invalid_invitation_status_for_resend|status_for_resend/);
  });

  it('AC-S7-04: 42501 forbidden when actor lacks signature.send', async () => {
    const drafter = getFixture('drafter1');
    const recipient = getFixture('recipient1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    const partiesResult = await callFnAs<{ data: { signatureParties: Array<{ id: number }> } }>(
      drafter.id,
      'fn_signature_party_create_bulk',
      [contractId, [employerSigner()], drafter.id],
    );
    const partyId = partiesResult.data.signatureParties[0]!.id;
    await callFnAs(drafter.id, 'fn_signature_send_for_signature', [contractId, drafter.id]);
    await expect(
      callFnAs(recipient.id, 'fn_signature_invitation_resend', [partyId, recipient.id, null]),
    ).rejects.toThrow(/permission|forbidden/i);
  });

  it('AC-S7-05: P0002 signature_party_not_found on bogus party id', async () => {
    const drafter = getFixture('drafter1');
    await expect(
      callFnAs(drafter.id, 'fn_signature_invitation_resend', [9_999_999_999, drafter.id, null]),
    ).rejects.toThrow(/Signature party not found|signature_party_not_found/);
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S8 — fn_signature_invitation_cancel + privilege escalation guard
// ──────────────────────────────────────────────────────────────────────────

describe('S8 — fn_signature_invitation_cancel', () => {
  it('AC-S8-01 + AC-S8-02: cancel sets status=cancelled + rolls contract back to approved (last active at step)', async () => {
    const drafter = getFixture('drafter1');
    const legal = getFixture('legal_counsel1');
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
    expect(await readContractStatus(contractId)).toBe('awaiting_signature_employer');

    const result = await callFnAs<{ data: { status: string; contractRolledBack: boolean } }>(
      legal.id,
      'fn_signature_invitation_cancel',
      [invId, legal.id, 'Internal review pending'],
    );
    expect(result.data.status).toBe('cancelled');
    expect(result.data.contractRolledBack).toBe(true);
    expect(await readContractStatus(contractId)).toBe('approved');
    expect(await countSignatureEvents(contractId, 'cancelled')).toBe(1);
  });

  it('AC-S8-03 — PRIVILEGE GUARD: contract_drafter cannot cancel (must be legal/admin)', async () => {
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
    await expect(
      callFnAs(drafter.id, 'fn_signature_invitation_cancel', [invId, drafter.id, 'Cancel reason']),
    ).rejects.toThrow(/permission|signature\.cancel|forbidden/i);
  });

  it('AC-S8-05: 409 invalid_invitation_status_for_cancel when status=signed', async () => {
    const drafter = getFixture('drafter1');
    const legal = getFixture('legal_counsel1');
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
    const invId = sent.data.invitations[0]!.invitationId;
    await callFnAs(drafter.id, 'fn_signature_sign', [
      sent.data.invitations[0]!.invitationTokenPlaintext, 'typed', 'Signed', null, null, null, null, null,
    ]);
    await expect(
      callFnAs(legal.id, 'fn_signature_invitation_cancel', [invId, legal.id, 'Cancel after sign']),
    ).rejects.toThrow(/invalid_invitation_status_for_cancel/);
  });

  it('AC-S8-06: 22023 missing_reason — empty reason rejected', async () => {
    const drafter = getFixture('drafter1');
    const legal = getFixture('legal_counsel1');
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
    await expect(
      callFnAs(legal.id, 'fn_signature_invitation_cancel', [
        sent.data.invitations[0]!.invitationId, legal.id, '   ',
      ]),
    ).rejects.toThrow(/missing_reason|reason/i);
  });
});

// ──────────────────────────────────────────────────────────────────────────
// S10 — activity_type whitelist
// ──────────────────────────────────────────────────────────────────────────

describe('S10 — fn_contract_activity_create whitelist extension (M3 migration 032)', () => {
  it('AC-S10-01 + AC-S10-02: M3 activity types accepted (sent_for_signature, signer_signed, fully_executed)', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    // Probe via direct call — fn_contract_activity_create signature is
    // (p_contract_id, p_activity_type, p_actor_user_id, ...)
    const m3Types = ['sent_for_signature', 'signer_viewed', 'signer_signed', 'signer_declined', 'fully_executed', 'signature_invalidated'];
    for (const at of m3Types) {
      // Should NOT throw — fn_contract_activity_create has 6 params:
      // (p_contract_id, p_activity_type, p_actor_id, p_description_en, p_description_ar, p_metadata)
      await callFnAs(drafter.id, 'fn_contract_activity_create', [
        contractId, at, drafter.id, null, null, null,
      ]);
    }
    const types = await listSignatureActivityTypes(contractId);
    for (const at of m3Types) expect(types).toContain(at);
  });

  it('AC-S10-02: rejects an unknown activity_type (defensive whitelist)', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await expect(
      callFnAs(drafter.id, 'fn_contract_activity_create', [
        contractId, 'totally_invalid_activity', drafter.id, null, null, null,
      ]),
    ).rejects.toThrow();
  });

  it('AC-S10-03: contract_activity emits sent_for_signature + signer_signed activity rows after happy-path step 1', async () => {
    const drafter = getFixture('drafter1');
    const { contractId } = await seedApprovedContract({ drafterId: drafter.id });
    trackedContractIds.push(contractId);
    await callFnAs(drafter.id, 'fn_signature_party_create_bulk', [
      contractId,
      [employerSigner(), counterpartySigner()],
      drafter.id,
    ]);
    const sent1 = await callFnAs<{ data: { invitations: Array<{ invitationTokenPlaintext: string }> } }>(
      drafter.id,
      'fn_signature_send_for_signature',
      [contractId, drafter.id],
    );
    await callFnAs(drafter.id, 'fn_signature_sign', [
      sent1.data.invitations[0]!.invitationTokenPlaintext, 'typed', 'Emp signed', null, null, null, null, null,
    ]);
    const types = await listSignatureActivityTypes(contractId);
    expect(types).toContain('sent_for_signature');
    expect(types).toContain('signer_signed');
  });
});
