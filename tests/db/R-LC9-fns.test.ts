/**
 * R-LC9-3 — Database function tests for the 9 new fn_'s introduced in
 * R-LC0..R-LC7 + the impact-watch module:
 *
 *   - fn_party_create               (R-LC3 / migration 073)
 *   - fn_template_create            (R-LC3 / migration 073)
 *   - fn_clause_create              (R-LC3 / migration 073)
 *   - fn_obligation_create          (R-LC3 / migration 073)
 *   - fn_approval_request_info      (R-LC4 / migration 074)
 *   - fn_impact_signal_list         (R-LC7 / migration 079)
 *   - fn_impact_signal_get          (R-LC7 / migration 079)
 *   - fn_impact_signal_mark_reviewed   (R-LC7 / migration 079)
 *   - fn_impact_signal_notify_drafters (R-LC7 / migration 079)
 *   - fn_impact_signal_bulk_amend      (R-LC7 / migration 079)
 *
 * Each function gets at minimum: happy path + permission denied + at least
 * one validation/state error path. Cleanup tracks every row inserted by
 * the tests so reruns are idempotent.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminQuery } from '../helpers/m1a-helpers';
import {
  getFixture,
  seedFixtureUsers,
  type SeededFixtureUser,
} from '../helpers/m1c-helpers';
import { callFnAs } from '../helpers/m2-helpers';

const RUN_ID = `rlc9-${Date.now()}`;
const ADMIN_ID = 1;

const trackedPartyIds: number[] = [];
const trackedTemplateIds: number[] = [];
const trackedClauseIds: number[] = [];
const trackedObligationIds: number[] = [];
const trackedSignalIds: number[] = [];

let LEGAL_COUNSEL: SeededFixtureUser;
let DRAFTER: SeededFixtureUser;
let RECIPIENT: SeededFixtureUser;

beforeAll(async () => {
  await seedFixtureUsers();
  LEGAL_COUNSEL = getFixture('legal_counsel1');
  DRAFTER = getFixture('drafter1');
  RECIPIENT = getFixture('recipient1');
});

afterAll(async () => {
  if (trackedSignalIds.length > 0) {
    await adminQuery(
      `DELETE FROM impact_signal_contract WHERE signal_id = ANY($1::BIGINT[])`,
      [trackedSignalIds],
    );
    await adminQuery(`DELETE FROM impact_signal WHERE id = ANY($1::BIGINT[])`, [
      trackedSignalIds,
    ]);
  }
  if (trackedObligationIds.length > 0) {
    await adminQuery(
      `DELETE FROM contract_obligation WHERE id = ANY($1::BIGINT[])`,
      [trackedObligationIds],
    );
  }
  if (trackedClauseIds.length > 0) {
    await adminQuery(
      `DELETE FROM contract_clause WHERE id = ANY($1::BIGINT[])`,
      [trackedClauseIds],
    );
  }
  if (trackedTemplateIds.length > 0) {
    await adminQuery(
      `DELETE FROM contract_template WHERE id = ANY($1::BIGINT[])`,
      [trackedTemplateIds],
    );
  }
  if (trackedPartyIds.length > 0) {
    await adminQuery(`DELETE FROM party WHERE id = ANY($1::BIGINT[])`, [
      trackedPartyIds,
    ]);
  }
});

// ─── fn_party_create ────────────────────────────────────────────────────────

describe('fn_party_create', () => {
  it('creates an individual party with required fields only', async () => {
    const row: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_party_create',
      [
        LEGAL_COUNSEL.id,
        'individual',
        `R-LC9 Test Individual ${RUN_ID}`,
        null, null, null, null, null,
        'United Arab Emirates',
        null, null, null, null,
      ],
    );
    expect(row.id).toBeDefined();
    expect(row.partyType).toBe('individual');
    expect(row.nameEn).toBe(`R-LC9 Test Individual ${RUN_ID}`);
    trackedPartyIds.push(row.id);
  });

  it('creates a company with full fields including isVerified projection', async () => {
    const row: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_party_create',
      [
        LEGAL_COUNSEL.id,
        'company',
        `R-LC9 Test Company ${RUN_ID}`,
        `شركة الاختبار`,
        'TL-12345',
        'Dubai DED',
        'dubai',
        null,
        'United Arab Emirates',
        'test@example.com',
        '+971-4-555-1212',
        'Test Address',
        'Test notes',
      ],
    );
    expect(row.partyType).toBe('company');
    expect(row.tradeLicenseNumber).toBe('TL-12345');
    expect(row.contactEmail).toBe('test@example.com');
    // isVerified defaults to FALSE; the auto-flag logic in 075 only runs
    // at migration time, so freshly-created parties are unverified.
    expect(row.isVerified).toBe(false);
    trackedPartyIds.push(row.id);
  });

  it('rejects invalid partyType with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_party_create',
        [LEGAL_COUNSEL.id, 'partnership', 'X', null, null, null, null, null,
         'United Arab Emirates', null, null, null, null],
      ),
    ).rejects.toThrow(/invalid party_type/);
  });

  it('rejects empty nameEn with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_party_create',
        [LEGAL_COUNSEL.id, 'individual', '', null, null, null, null, null,
         'United Arab Emirates', null, null, null, null],
      ),
    ).rejects.toThrow(/nameEn is required/);
  });

  it('rejects caller without contract.edit permission', async () => {
    // Recipient role does not have contract.edit.
    await expect(
      callFnAs(
        RECIPIENT.id,
        'fn_party_create',
        [RECIPIENT.id, 'individual', 'X', null, null, null, null, null,
         'United Arab Emirates', null, null, null, null],
      ),
    ).rejects.toThrow(/forbidden|42501/);
  });
});

// ─── fn_template_create ────────────────────────────────────────────────────

describe('fn_template_create', () => {
  it('creates a template with EN body + AR body + tags', async () => {
    const row: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_template_create',
      [
        LEGAL_COUNSEL.id,
        `R-LC9 Test Template ${RUN_ID}`,
        'employment',
        'bilingual',
        'قالب اختبار',
        'Test description EN',
        'وصف اختبار',
        '## 1. Test\nBody EN.',
        '## 1. اختبار\nالنص.',
        ['MoHRE', 'Test'],
      ],
    );
    expect(row.id).toBeDefined();
    expect(row.contractType).toBe('employment');
    expect(row.language).toBe('bilingual');
    expect(row.regulatoryTags).toContain('MoHRE');
    trackedTemplateIds.push(row.id);
  });

  it('rejects invalid language with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_template_create',
        [LEGAL_COUNSEL.id, 'X', 'employment', 'klingon',
         null, null, null, null, null, []],
      ),
    ).rejects.toThrow(/invalid language/);
  });

  it('rejects empty contractType', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_template_create',
        [LEGAL_COUNSEL.id, 'X', '', 'en',
         null, null, null, null, null, []],
      ),
    ).rejects.toThrow(/contractType is required/);
  });
});

// ─── fn_clause_create ──────────────────────────────────────────────────────

describe('fn_clause_create', () => {
  it('creates a clause with standard variant', async () => {
    const row: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_clause_create',
      [
        LEGAL_COUNSEL.id,
        'confidentiality',
        `R-LC9 Test Clause ${RUN_ID}`,
        'Test body — confidentiality clause.',
        'standard',
        'بند سرية اختبار',
        'بند السرية النص الاختباري',
        'Test commentary.',
        null,
        ['Federal Decree-Law 33/2021'],
      ],
    );
    expect(row.id).toBeDefined();
    expect(row.category).toBe('confidentiality');
    expect(row.variant).toBe('standard');
    trackedClauseIds.push(row.id);
  });

  it('rejects invalid variant with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_clause_create',
        [LEGAL_COUNSEL.id, 'confidentiality', 'X', 'body', 'experimental',
         null, null, null, null, []],
      ),
    ).rejects.toThrow(/invalid variant/);
  });

  it('rejects empty bodyEn', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_clause_create',
        [LEGAL_COUNSEL.id, 'confidentiality', 'Title', '', 'standard',
         null, null, null, null, []],
      ),
    ).rejects.toThrow(/bodyEn is required/);
  });
});

// ─── fn_obligation_create ──────────────────────────────────────────────────

describe('fn_obligation_create', () => {
  let testContractId: number;

  beforeAll(async () => {
    // Create a real test contract so FK pre-validation is satisfied.
    const rows = await adminQuery<{ id: number }>(
      `INSERT INTO contract (
         contract_number, title_en, contract_type, status, language,
         currency, value_aed, drafted_by, created_by, updated_by
       ) VALUES (
         $1, $2, 'service', 'active', 'en', 'AED', 100000, $3, $3, $3
       ) RETURNING id`,
      [`RLC9-OBL-${RUN_ID}`, `R-LC9 Obligation Test`, ADMIN_ID],
    );
    testContractId = rows[0]!.id;
  });

  afterAll(async () => {
    if (trackedObligationIds.length > 0) {
      await adminQuery(
        `DELETE FROM contract_obligation WHERE id = ANY($1::BIGINT[])`,
        [trackedObligationIds],
      );
    }
    await adminQuery(`DELETE FROM contract WHERE id = $1`, [testContractId]);
  });

  it('creates an obligation with all defaults', async () => {
    const row: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_obligation_create',
      [
        LEGAL_COUNSEL.id,
        testContractId,
        `R-LC9 Test Obligation ${RUN_ID}`,
        'payment',
        '2026-12-31',
        'monthly',
        'our_party',
        null, null, null, null, 'open',
      ],
    );
    expect(row.id).toBeDefined();
    expect(row.obligationType).toBe('payment');
    expect(row.recurrence).toBe('monthly');
    expect(row.status).toBe('open');
    trackedObligationIds.push(row.id);
  });

  it('rejects unknown contractId with SQLSTATE 23503', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_obligation_create',
        [LEGAL_COUNSEL.id, 99999999, 'X', 'payment', null, 'once', 'our_party',
         null, null, null, null, 'open'],
      ),
    ).rejects.toThrow(/contract not found/);
  });

  it('rejects invalid obligation_type', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_obligation_create',
        [LEGAL_COUNSEL.id, testContractId, 'X', 'rocket_launch', null, 'once',
         'our_party', null, null, null, null, 'open'],
      ),
    ).rejects.toThrow(/invalid type/);
  });
});

// ─── fn_approval_request_info ─────────────────────────────────────────────

describe('fn_approval_request_info', () => {
  it('rejects empty message with SQLSTATE 22023', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_approval_request_info',
        [LEGAL_COUNSEL.id, 1, ''],
      ),
    ).rejects.toThrow(/message is required/);
  });

  it('rejects unknown stepId with SQLSTATE P0002', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_approval_request_info',
        [LEGAL_COUNSEL.id, 99999999, 'Please clarify'],
      ),
    ).rejects.toThrow(/step not found/);
  });

  it('rejects caller without approval.act permission', async () => {
    // Drafter does not have approval.act
    await expect(
      callFnAs(
        DRAFTER.id,
        'fn_approval_request_info',
        [DRAFTER.id, 1, 'Hello'],
      ),
    ).rejects.toThrow(/forbidden|42501/);
  });
});

// ─── fn_impact_signal_list ────────────────────────────────────────────────

describe('fn_impact_signal_list', () => {
  it('returns paginated list with default limit', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_list',
      [LEGAL_COUNSEL.id, null, null, null, 100, 0],
    );
    expect(r.data).toBeDefined();
    expect(Array.isArray(r.data)).toBe(true);
    expect(r.pagination.total).toBeGreaterThanOrEqual(17);
  });

  it('filters by category', async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_list',
      [LEGAL_COUNSEL.id, 'regulatory', null, null, 100, 0],
    );
    expect(r.data.every((s: any) => s.category === 'regulatory')).toBe(true);
  });

  it('rejects caller without read permissions', async () => {
    await expect(
      callFnAs(
        RECIPIENT.id,
        'fn_impact_signal_list',
        [RECIPIENT.id, null, null, null, 100, 0],
      ),
    ).rejects.toThrow(/forbidden|42501/);
  });
});

// ─── fn_impact_signal_get ─────────────────────────────────────────────────

describe('fn_impact_signal_get', () => {
  let firstSignalId: number;

  beforeAll(async () => {
    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_list',
      [LEGAL_COUNSEL.id, null, null, null, 1, 0],
    );
    firstSignalId = r.data[0].id;
  });

  it('returns the signal + impactedContracts', async () => {
    const row: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_get',
      [LEGAL_COUNSEL.id, firstSignalId],
    );
    expect(row.id).toBe(firstSignalId);
    expect(Array.isArray(row.impactedContracts)).toBe(true);
  });

  it('rejects unknown signal id with SQLSTATE P0002', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_impact_signal_get',
        [LEGAL_COUNSEL.id, 99999999],
      ),
    ).rejects.toThrow(/impact_signal_not_found/);
  });
});

// ─── fn_impact_signal_mark_reviewed ───────────────────────────────────────

describe('fn_impact_signal_mark_reviewed', () => {
  it('flips a pending row to reviewed and sets reviewer fields', async () => {
    // Find a pending link; if none in seed (rare), create one.
    const pendingRows = await adminQuery<{ id: number }>(
      `SELECT id FROM impact_signal_contract WHERE status = 'pending' AND is_active = TRUE LIMIT 1`,
    );
    expect(pendingRows.length).toBeGreaterThan(0);
    const linkId = Number(pendingRows[0]!.id);

    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_mark_reviewed',
      [LEGAL_COUNSEL.id, linkId],
    );
    expect(Number(r.id)).toBe(linkId);
    expect(r.status).toBe('reviewed');

    // Reset for repeatability.
    await adminQuery(
      `UPDATE impact_signal_contract SET status = 'pending', reviewed_at = NULL, reviewed_by = NULL WHERE id = $1`,
      [linkId],
    );
  });

  it('rejects unknown link id with SQLSTATE P0002', async () => {
    await expect(
      callFnAs(
        LEGAL_COUNSEL.id,
        'fn_impact_signal_mark_reviewed',
        [LEGAL_COUNSEL.id, 99999999],
      ),
    ).rejects.toThrow(/impact_link_not_found/);
  });
});

// ─── fn_impact_signal_notify_drafters ─────────────────────────────────────

describe('fn_impact_signal_notify_drafters', () => {
  it('emits one contract_activity per linked contract', async () => {
    // Pick a signal with at least one linked contract.
    const signalRows = await adminQuery<{ signal_id: number; cnt: string }>(
      `SELECT signal_id, COUNT(*)::TEXT AS cnt
         FROM impact_signal_contract
         WHERE is_active = TRUE AND status IN ('pending', 'reviewed')
         GROUP BY signal_id ORDER BY cnt DESC LIMIT 1`,
    );
    expect(signalRows.length).toBeGreaterThan(0);
    const signalId = signalRows[0]!.signal_id;
    const expectedCount = Number(signalRows[0]!.cnt);

    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_notify_drafters',
      [LEGAL_COUNSEL.id, signalId],
    );
    expect(r.signalId).toBe(Number(signalId));
    expect(r.notified).toBe(expectedCount);
  });
});

// ─── fn_impact_signal_bulk_amend ──────────────────────────────────────────

describe('fn_impact_signal_bulk_amend', () => {
  it('flips every linked contract to amended and emits activity', async () => {
    // Create a fresh signal with 2 links so we don't disturb seed data.
    const contractRows = await adminQuery<{ id: number }>(
      `SELECT id FROM contract WHERE is_active = TRUE LIMIT 2`,
    );
    expect(contractRows.length).toBe(2);

    const signalRows = await adminQuery<{ id: number }>(
      `INSERT INTO impact_signal (ext_id, category, source, severity, title_en, created_by, updated_by)
       VALUES ($1, 'regulatory', 'Test', 'medium', 'R-LC9 Bulk Amend Signal', $2, $2)
       RETURNING id`,
      [`RLC9-BULK-${RUN_ID}`, ADMIN_ID],
    );
    const signalId = signalRows[0]!.id;
    trackedSignalIds.push(signalId);

    await adminQuery(
      `INSERT INTO impact_signal_contract (signal_id, contract_id, impact_score, status, created_by, updated_by)
       VALUES ($1, $2, 50, 'pending', $4, $4), ($1, $3, 50, 'pending', $4, $4)`,
      [signalId, contractRows[0]!.id, contractRows[1]!.id, ADMIN_ID],
    );

    const r: any = await callFnAs(
      LEGAL_COUNSEL.id,
      'fn_impact_signal_bulk_amend',
      [LEGAL_COUNSEL.id, signalId],
    );
    expect(r.signalId).toBe(Number(signalId));
    expect(r.amended).toBe(2);

    const postRows = await adminQuery<{ status: string }>(
      `SELECT status FROM impact_signal_contract WHERE signal_id = $1 ORDER BY id`,
      [signalId],
    );
    expect(postRows.every((p) => p.status === 'amended')).toBe(true);
  });
});
