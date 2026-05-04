/**
 * M3 — Signer Q&A AI DB function tests.
 *
 * Stories: S11 (session_start), S12 (session_record_message GATE/COMMIT).
 * Special focus: AN-12 sliding-window soft-deactivate (5+ active sessions),
 * token-once invariant for sessionTokenPlaintext, NULL-safe session checks.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { closeAdminPool, adminQuery } from '../helpers/m1a-helpers';
import { getFixture, seedFixtureUsers } from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';
import {
  seedApprovedContract,
  cleanupSignatureArtifacts,
  readSessionRow,
  backdateSessionWindow,
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
      console.warn('[M3-signer-qa cleanup]', err);
    }
  }
  await closeAdminPool();
});

const provisionInvitation = async (drafterId: number) => {
  const { contractId } = await seedApprovedContract({ drafterId });
  trackedContractIds.push(contractId);
  await callFnAs(drafterId, 'fn_signature_party_create_bulk', [
    contractId,
    [employerSigner()],
    drafterId,
  ]);
  const sent = await callFnAs<{ data: { invitations: Array<{ invitationId: number; invitationTokenPlaintext: string }> } }>(
    drafterId,
    'fn_signature_send_for_signature',
    [contractId, drafterId],
  );
  return {
    contractId,
    invitationId: sent.data.invitations[0]!.invitationId,
    invitationToken: sent.data.invitations[0]!.invitationTokenPlaintext,
  };
};

describe('S11 — fn_signer_qa_session_start', () => {
  it('AC-S11-01: returns sessionTokenPlaintext ONCE + sessionId + rateLimit + language', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const result = await callFnAs<{ data: { sessionTokenPlaintext: string; sessionId: number; rateLimit: { maxMessagesPerHour: number; remaining: number }; language: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    expect(result.data.sessionTokenPlaintext).toMatch(/^[A-Za-z0-9_-]{32,}$/);
    expect(result.data.sessionId).toBeGreaterThan(0);
    expect(result.data.rateLimit.maxMessagesPerHour).toBe(20);
    expect(result.data.rateLimit.remaining).toBe(20);
    expect(['en', 'ar']).toContain(result.data.language);
  });

  it('AC-S11-02: raises generic invitation_invalid_or_expired on unknown invitation token (controller maps P0001 → 410)', async () => {
    await expect(
      callFnAs(1, 'fn_signer_qa_session_start', ['x'.repeat(43), 'en']),
    ).rejects.toThrow(/invitation_invalid_or_expired/);
  });

  it('AC-S11-04: token is hashed at rest (not the plaintext)', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const r = await callFnAs<{ data: { sessionTokenPlaintext: string; sessionId: number } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    const session = await readSessionRow(r.data.sessionId);
    expect(typeof session?.['session_token_hash']).toBe('string');
    expect((session?.['session_token_hash'] as string).length).toBe(64); // SHA-256 hex
    expect(session?.['session_token_hash']).not.toBe(r.data.sessionTokenPlaintext);
  });

  it('AC-S11-03 (AN-12 sliding window): 6th session soft-deactivates the oldest; 6th call succeeds with 200', async () => {
    const drafter = getFixture('drafter1');
    const { invitationId, invitationToken } = await provisionInvitation(drafter.id);

    const ids: number[] = [];
    for (let i = 0; i < 5; i++) {
      const r = await callFnAs<{ data: { sessionId: number } }>(
        drafter.id,
        'fn_signer_qa_session_start',
        [invitationToken, 'en'],
      );
      ids.push(r.data.sessionId);
    }
    // Verify all 5 active
    const activeBefore = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM signer_qa_session
        WHERE signature_invitation_id = $1 AND is_active = TRUE`,
      [invitationId],
    );
    expect(Number(activeBefore[0]!.count)).toBe(5);

    // 6th — should NOT throw 429; should soft-deactivate oldest.
    const r6 = await callFnAs<{ data: { sessionId: number } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    expect(r6.data.sessionId).toBeGreaterThan(0);

    // Total active should still be 5 (one was deactivated).
    const activeAfter = await adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count FROM signer_qa_session
        WHERE signature_invitation_id = $1 AND is_active = TRUE`,
      [invitationId],
    );
    expect(Number(activeAfter[0]!.count)).toBe(5);

    // Oldest (ids[0]) should now be inactive.
    const oldest = await readSessionRow(ids[0]!);
    expect(oldest?.['is_active']).toBe(false);
    // Newest (r6) should be active.
    const newest = await readSessionRow(r6.data.sessionId);
    expect(newest?.['is_active']).toBe(true);
  });

  it('AC-S11-05: language locked at session start; defaults to invitation.language', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const ar = await callFnAs<{ data: { sessionId: number; language: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'ar'],
    );
    expect(ar.data.language).toBe('ar');
    const row = await readSessionRow(ar.data.sessionId);
    expect(row?.['language']).toBe('ar');
  });
});

describe('S12 — fn_signer_qa_session_record_message (GATE/COMMIT)', () => {
  it('AC-S12-01: GATE call (tokensConsumed=0) reserves slot — returns OK', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const session = await callFnAs<{ data: { sessionTokenPlaintext: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    const r = await callFnAs<{ data: Record<string, unknown> }>(
      drafter.id,
      'fn_signer_qa_session_record_message',
      [session.data.sessionTokenPlaintext, 0, 'GATE'],
    );
    expect(r.data).toBeTruthy();
  });

  it('AC-S12-03: COMMIT call updates message_count + tokens_consumed', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const session = await callFnAs<{ data: { sessionId: number; sessionTokenPlaintext: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    await callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
      session.data.sessionTokenPlaintext, 0, 'GATE',
    ]);
    await callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
      session.data.sessionTokenPlaintext, 142, 'COMMIT',
    ]);
    const row = await readSessionRow(session.data.sessionId);
    expect(Number(row?.['message_count'])).toBeGreaterThanOrEqual(1);
    expect(Number(row?.['tokens_consumed'])).toBeGreaterThanOrEqual(142);
  });

  it('AC-S12-04 + AC-S12-05: 429 rate_limit_exceeded after 20 GATE calls in window', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const session = await callFnAs<{ data: { sessionTokenPlaintext: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    // 20 successful GATE calls (and matching COMMITs)
    for (let i = 0; i < 20; i++) {
      await callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
        session.data.sessionTokenPlaintext, 0, 'GATE',
      ]);
      await callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
        session.data.sessionTokenPlaintext, 1, 'COMMIT',
      ]);
    }
    // 21st GATE should hit rate_limit_exceeded
    await expect(
      callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
        session.data.sessionTokenPlaintext, 0, 'GATE',
      ]),
    ).rejects.toThrow(/rate_limit_exceeded/);
  });

  it('AC-S12-10: 410 session_invalid_or_expired on unknown session token', async () => {
    await expect(
      callFnAs(1, 'fn_signer_qa_session_record_message', [
        'x'.repeat(43), 0, 'GATE',
      ]),
    ).rejects.toThrow(/session_invalid_or_expired/);
  });

  it('window expiry: backdated window allows next GATE call without rate-limit', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const session = await callFnAs<{ data: { sessionId: number; sessionTokenPlaintext: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    // Run 20 messages
    for (let i = 0; i < 20; i++) {
      await callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
        session.data.sessionTokenPlaintext, 0, 'GATE',
      ]);
      await callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
        session.data.sessionTokenPlaintext, 1, 'COMMIT',
      ]);
    }
    // Backdate the window — fn should reset and allow another GATE.
    await backdateSessionWindow(session.data.sessionId, 2);
    // Should now succeed
    const r = await callFnAs<{ data: unknown }>(
      drafter.id,
      'fn_signer_qa_session_record_message',
      [session.data.sessionTokenPlaintext, 0, 'GATE'],
    );
    expect(r.data).toBeTruthy();
  });

  it('rejects invalid mode (22023)', async () => {
    const drafter = getFixture('drafter1');
    const { invitationToken } = await provisionInvitation(drafter.id);
    const session = await callFnAs<{ data: { sessionTokenPlaintext: string } }>(
      drafter.id,
      'fn_signer_qa_session_start',
      [invitationToken, 'en'],
    );
    await expect(
      callFnAs(drafter.id, 'fn_signer_qa_session_record_message', [
        session.data.sessionTokenPlaintext, 0, 'BOGUS_MODE',
      ]),
    ).rejects.toThrow(/mode|Invalid/i);
  });
});
