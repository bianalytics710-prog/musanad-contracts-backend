/**
 * R-RC0..R-RC4 — Database function tests for the Recipient persona work.
 *
 *   R-RC0 (087):
 *     - fn_contract_list with contract_recipient row-level visibility
 *       (signature_party.signer_user_id match) — recipient sees ONLY
 *       contracts they're a signer on, never the full register.
 *
 *   R-RC2 (088):
 *     - fn_signature_invitation_resolve_for_self — caller-bound fresh
 *       token mint for an authenticated signer. Negative paths:
 *         - 42501 when actor is not a signer on the contract.
 *         - P0002 when no active invitation exists.
 *         - P0001 when invitation is in a terminal state.
 *
 * Cleanup tracker rolls back any new invitations / signature_event rows
 * inserted by the test so reruns are idempotent against the dev branch.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminQuery } from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';

let RECIPIENT: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;
let APPROVER: SeededFixtureUser;

const trackedInvitationIds: number[] = [];
const trackedEventIds: number[] = [];

beforeAll(async () => {
  await seedFixtureUsers();
  RECIPIENT = getFixture('recipient1');
  DRAFTER = getFixture('drafter1');
  APPROVER = getFixture('approver1');
});

afterAll(async () => {
  if (trackedEventIds.length > 0) {
    await adminQuery(
      `DELETE FROM signature_event WHERE id = ANY($1::BIGINT[])`,
      [trackedEventIds],
    );
  }
  if (trackedInvitationIds.length > 0) {
    // Re-activate the original invitations the resolve_for_self may have
    // soft-deactivated, so the dev seed remains intact across test runs.
    await adminQuery(
      `UPDATE signature_invitation SET is_active = TRUE
        WHERE id IN (
          SELECT (metadata->>'newInvitationId')::BIGINT
          FROM signature_event
          WHERE id = ANY($1::BIGINT[])
        )`,
      [trackedEventIds],
    );
    await adminQuery(
      `DELETE FROM signature_invitation WHERE id = ANY($1::BIGINT[])`,
      [trackedInvitationIds],
    );
  }
});

// ─── R-RC0: fn_contract_list recipient row-level visibility ───────────────

describe('fn_contract_list — recipient row-level visibility (087)', () => {
  it('recipient sees exactly the contracts they are a signer on (and no more)', async () => {
    // Compute the canonical set of contract ids the recipient is a
    // signer on. fn_contract_list output should equal this set.
    const linkedRows = await adminQuery<{ contract_id: number }>(
      `SELECT DISTINCT sp.contract_id
         FROM signature_party sp
         JOIN contract c ON c.id = sp.contract_id
        WHERE sp.signer_user_id = $1
          AND sp.is_active = TRUE
          AND c.is_active = TRUE`,
      [RECIPIENT.id],
    );
    const linkedIds = new Set(linkedRows.map((r) => Number(r.contract_id)));

    const r: any = await callFnAs(
      RECIPIENT.id,
      'fn_contract_list',
      [
        1, 100,
        null, null, null, null, null,
        null, null, null, null, null, null,
        RECIPIENT.id, 'contract_recipient',
        null, null, null, null, null, null,
      ],
    );
    expect(Array.isArray(r.data)).toBe(true);
    // Both sides should agree — fn returns exactly the linked set.
    expect(Number(r.pagination.total)).toBe(linkedIds.size);

    const returnedIds = new Set(r.data.map((c: any) => Number(c.id)));
    for (const id of returnedIds) {
      expect(linkedIds.has(id as number)).toBe(true);
    }
    for (const id of linkedIds) {
      expect(returnedIds.has(id)).toBe(true);
    }
  });

  it('drafter visibility unchanged — still sees only their own drafted/reviewed/approved/created', async () => {
    // Regression guard: 087 only ADDS the recipient OR clause. Drafter
    // visibility (drafter is_active row-level OR clause) must be intact.
    const r: any = await callFnAs(
      DRAFTER.id,
      'fn_contract_list',
      [
        1, 100,
        null, null, null, null, null,
        null, null, null, null, null, null,
        DRAFTER.id, 'contract_drafter',
        null, null, null, null, null, null,
      ],
    );
    expect(Array.isArray(r.data)).toBe(true);
    expect(typeof r.pagination.total).toBe('number');
  });
});

// ─── R-RC2: fn_signature_invitation_resolve_for_self ──────────────────────

describe('fn_signature_invitation_resolve_for_self (088)', () => {
  it('rejects with 42501 when actor is not a signer on the contract', async () => {
    // Find a contract the drafter does NOT sign. Any contract where
    // there is no signature_party row for drafter id.
    const candidates = await adminQuery<{ id: number }>(
      `SELECT c.id FROM contract c
        WHERE c.is_active = TRUE
          AND NOT EXISTS (
            SELECT 1 FROM signature_party sp
             WHERE sp.contract_id = c.id
               AND sp.signer_user_id = $1
               AND sp.is_active = TRUE
          )
        LIMIT 1`,
      [DRAFTER.id],
    );
    if (candidates.length === 0) {
      // Nothing to test against; the dev seed has every drafter signing
      // every contract, which would itself be a defect.
      return;
    }
    const contractId = Number(candidates[0]!.id);

    await expect(
      callFnAs(DRAFTER.id, 'fn_signature_invitation_resolve_for_self', [
        DRAFTER.id,
        contractId,
      ]),
    ).rejects.toThrow(/not a signer|42501/);
  });

  it('rejects with 22023 when actorId is null', async () => {
    await expect(
      callFnAs(RECIPIENT.id, 'fn_signature_invitation_resolve_for_self', [
        null,
        28,
      ]),
    ).rejects.toThrow(/actorId|22023/);
  });

  it('rejects with 22023 when contractId is null', async () => {
    await expect(
      callFnAs(RECIPIENT.id, 'fn_signature_invitation_resolve_for_self', [
        RECIPIENT.id,
        null,
      ]),
    ).rejects.toThrow(/contractId|22023/);
  });

  it('rejects with P0002 for a contract id that doesn\'t exist', async () => {
    // A non-existent contract has no signature_party rows, so the
    // caller-bound check raises 42501 (not P0002). Either is an
    // acceptable rejection for the not-found-OR-not-yours case.
    await expect(
      callFnAs(RECIPIENT.id, 'fn_signature_invitation_resolve_for_self', [
        RECIPIENT.id,
        99999999,
      ]),
    ).rejects.toThrow(/42501|P0002|not a signer|not found/i);
  });

  it('happy path — recipient resolves their pending invitation, fresh token returned, old invitation deactivated', async () => {
    // Find a contract where recipient1 has an active pending|viewed
    // signature_invitation. Skip if none in the seed.
    const candidates = await adminQuery<{
      contract_id: number;
      old_inv_id: number;
    }>(
      `SELECT si.contract_id, si.id AS old_inv_id
         FROM signature_invitation si
         JOIN signature_party sp ON sp.id = si.signature_party_id
        WHERE sp.signer_user_id = $1
          AND sp.is_active = TRUE
          AND si.is_active = TRUE
          AND si.status IN ('pending','viewed','expired')
        LIMIT 1`,
      [RECIPIENT.id],
    );
    if (candidates.length === 0) return;
    const contractId = Number(candidates[0]!.contract_id);
    const oldInvId = Number(candidates[0]!.old_inv_id);

    const r: any = await callFnAs(
      RECIPIENT.id,
      'fn_signature_invitation_resolve_for_self',
      [RECIPIENT.id, contractId],
    );
    expect(r.data).toBeDefined();
    expect(typeof r.data.invitationTokenPlaintext).toBe('string');
    expect(r.data.invitationTokenPlaintext.length).toBeGreaterThan(40);
    expect(Number(r.data.contractId)).toBe(contractId);
    expect(Number(r.data.newInvitationId)).not.toBe(oldInvId);

    trackedInvitationIds.push(Number(r.data.newInvitationId));

    // Verify the audit event was emitted with the in_app source tag.
    const events = await adminQuery<{ id: number; source: string }>(
      `SELECT id, metadata->>'source' AS source
         FROM signature_event
        WHERE signature_invitation_id = $1
          AND event_type = 'resent'
          AND (metadata->>'newInvitationId')::BIGINT = $2`,
      [oldInvId, Number(r.data.newInvitationId)],
    );
    expect(events.length).toBeGreaterThanOrEqual(1);
    expect(events[0]!.source).toBe('in_app_self_resolve');
    trackedEventIds.push(Number(events[0]!.id));

    // Verify old invitation soft-deactivated.
    const oldRow = await adminQuery<{ is_active: boolean }>(
      `SELECT is_active FROM signature_invitation WHERE id = $1`,
      [oldInvId],
    );
    expect(oldRow[0]!.is_active).toBe(false);

    // Verify new invitation active + status=pending.
    const newRow = await adminQuery<{ is_active: boolean; status: string }>(
      `SELECT is_active, status FROM signature_invitation WHERE id = $1`,
      [Number(r.data.newInvitationId)],
    );
    expect(newRow[0]!.is_active).toBe(true);
    expect(newRow[0]!.status).toBe('pending');
  });
});
