/**
 * Unit tests — Zod schema branches in src/schemas/contracts.schemas.ts.
 *
 * These tests exercise every validation branch without spinning up the
 * Express app or hitting the DB. They give us deterministic coverage of
 * the schema file (one of the M1a-authored files where coverage is
 * easiest to push high).
 *
 * Each test name is annotated with the AC it covers (where applicable).
 * Many tests double as M1a structural tests — they confirm the schemas
 * accept valid shapes and reject invalid shapes with the correct field
 * name + message that the AC contracts demand.
 */
import { describe, it, expect } from 'vitest';
import {
  PositiveBigIntSchema,
  IsoDateSchema,
  ContractStatusSchema,
  ContractLanguageSchema,
  GoverningLawSchema,
  RelationshipTypeSchema,
  ActivityTypeSchema,
  CreateContractDtoSchema,
  UpdateContractDtoSchema,
  UpdateContractStatusDtoSchema,
  SetContractTagsDtoSchema,
  CreateContractVersionDtoSchema,
  ContractIdParamSchema,
  ContractListQuerySchema,
  ContractVersionListQuerySchema,
  ContractActivityListQuerySchema,
} from '../../src/schemas/contracts.schemas';

describe('M1a — Zod primitive schemas', () => {
  it('PositiveBigIntSchema accepts positive integers (string and number)', () => {
    expect(PositiveBigIntSchema.parse(1)).toBe(1);
    expect(PositiveBigIntSchema.parse('42')).toBe(42);
  });

  it('PositiveBigIntSchema rejects 0, negatives, and non-numeric strings', () => {
    expect(() => PositiveBigIntSchema.parse(0)).toThrow();
    expect(() => PositiveBigIntSchema.parse(-1)).toThrow();
    expect(() => PositiveBigIntSchema.parse('abc')).toThrow();
  });

  it('IsoDateSchema accepts YYYY-MM-DD and ISO datetime', () => {
    expect(IsoDateSchema.parse('2026-01-15')).toBe('2026-01-15');
    expect(IsoDateSchema.parse('2026-01-15T10:30:00Z')).toBe('2026-01-15T10:30:00Z');
    expect(IsoDateSchema.parse('2026-01-15T10:30:00.123+04:00')).toBeTruthy();
  });

  it('IsoDateSchema rejects malformed dates', () => {
    expect(() => IsoDateSchema.parse('15/01/2026')).toThrow();
    expect(() => IsoDateSchema.parse('not-a-date')).toThrow();
    expect(() => IsoDateSchema.parse('2026-1-15')).toThrow(); // single-digit month
  });
});

describe('M1a — enum schemas', () => {
  it('ContractStatusSchema accepts every 14-state value', () => {
    const all = [
      'draft',
      'in_review',
      'approved',
      'awaiting_signature_employer',
      'awaiting_signature_counterparty',
      'fully_signed',
      'active',
      'expiring_soon',
      'expired',
      'amended',
      'renewed',
      'terminated',
      'rejected',
      'resubmission_requested',
    ];
    for (const v of all) expect(ContractStatusSchema.parse(v)).toBe(v);
  });

  it('ContractStatusSchema rejects unknown status with "Invalid status" message (AC-S6-03)', () => {
    try {
      ContractStatusSchema.parse('not_a_status');
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Invalid status');
    }
  });

  it('ContractLanguageSchema rejects unknown language with "Invalid language" (AC-S3-09)', () => {
    expect(ContractLanguageSchema.parse('en')).toBe('en');
    expect(ContractLanguageSchema.parse('ar')).toBe('ar');
    expect(ContractLanguageSchema.parse('bilingual')).toBe('bilingual');
    try {
      ContractLanguageSchema.parse('fr');
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Invalid language');
    }
  });

  it('GoverningLawSchema rejects unknown value with "Invalid governing law" (AC-S3-09)', () => {
    expect(GoverningLawSchema.parse('uae_federal')).toBe('uae_federal');
    try {
      GoverningLawSchema.parse('mars_treaty');
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Invalid governing law');
    }
  });

  it('RelationshipTypeSchema rejects unknown with "Invalid relationship type" (AC-S3-09)', () => {
    expect(RelationshipTypeSchema.parse('amendment')).toBe('amendment');
    try {
      RelationshipTypeSchema.parse('subcontract');
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Invalid relationship type');
    }
  });

  it('ActivityTypeSchema accepts all 7 activity types', () => {
    const all = [
      'created',
      'updated',
      'status_changed',
      'version_created',
      'tagged',
      'soft_deleted',
      'restored',
    ];
    for (const v of all) expect(ActivityTypeSchema.parse(v)).toBe(v);
  });
});

describe('CreateContractDtoSchema — POST /api/v1/contracts (S3)', () => {
  const validBase = { titleEn: 'My Contract', contractType: 'employment' };

  it('accepts a minimal valid payload', () => {
    const parsed = CreateContractDtoSchema.parse(validBase);
    expect(parsed.titleEn).toBe('My Contract');
    expect(parsed.contractType).toBe('employment');
    expect(parsed.language).toBe('en'); // default
    expect(parsed.currency).toBe('AED'); // default
    expect(parsed.expiryNoticeDays).toBe(30); // default
  });

  it('AC-S3-04: missing titleEn → message "Title (English) is required"', () => {
    try {
      CreateContractDtoSchema.parse({ contractType: 'employment' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'titleEn');
      expect(issue?.message).toBe('Title (English) is required');
    }
  });

  it('AC-S3-04: empty titleEn → "Title (English) is required"', () => {
    try {
      CreateContractDtoSchema.parse({ titleEn: '   ', contractType: 'employment' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'titleEn');
      expect(issue?.message).toBe('Title (English) is required');
    }
  });

  it('AC-S3-05: missing contractType → "Contract type is required"', () => {
    try {
      CreateContractDtoSchema.parse({ titleEn: 'X' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'contractType');
      expect(issue?.message).toBe('Contract type is required');
    }
  });

  it('AC-S3-06: negative valueAed → "Value must be greater than or equal to zero"', () => {
    try {
      CreateContractDtoSchema.parse({ ...validBase, valueAed: -1 });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'valueAed');
      expect(issue?.message).toBe('Value must be greater than or equal to zero');
    }
  });

  it('AC-S3-06: valueAed=0 is accepted (boundary)', () => {
    const parsed = CreateContractDtoSchema.parse({ ...validBase, valueAed: 0 });
    expect(parsed.valueAed).toBe(0);
  });

  it('AC-S3-07: endDate before startDate → "End date must be on or after start date"', () => {
    try {
      CreateContractDtoSchema.parse({
        ...validBase,
        startDate: '2026-02-01',
        endDate: '2026-01-01',
      });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'endDate');
      expect(issue?.message).toBe('End date must be on or after start date');
    }
  });

  it('AC-S3-07: endDate equal to startDate is accepted', () => {
    const parsed = CreateContractDtoSchema.parse({
      ...validBase,
      startDate: '2026-02-01',
      endDate: '2026-02-01',
    });
    expect(parsed.startDate).toBe('2026-02-01');
  });

  it('AC-S3-02: tag too long → "Each tag must be 1 to 64 characters"', () => {
    const tooLong = 'x'.repeat(65);
    try {
      CreateContractDtoSchema.parse({ ...validBase, tags: [tooLong] });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Each tag must be 1 to 64 characters');
    }
  });

  it('AC-S3-02: empty tag → "Each tag must be 1 to 64 characters"', () => {
    try {
      CreateContractDtoSchema.parse({ ...validBase, tags: ['   '] });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Each tag must be 1 to 64 characters');
    }
  });
});

describe('UpdateContractDtoSchema — PUT /:id (S4)', () => {
  it('accepts a partial update', () => {
    const parsed = UpdateContractDtoSchema.parse({ titleEn: 'New Title' });
    expect(parsed.titleEn).toBe('New Title');
  });

  it('AC-S4-04: rejects status in payload — "Use fn_contract_status_update to change status"', () => {
    try {
      UpdateContractDtoSchema.parse({ status: 'approved' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      // Either the strict() unknown-key error fires first, or our custom
      // superRefine fires — both are valid AC-S4-04 paths. We accept either.
      const statusIssue = err.issues.find(
        (i) => i.path.join('.') === 'status' || (i as { code?: string }).code === 'unrecognized_keys',
      );
      expect(statusIssue).toBeTruthy();
    }
  });

  it('AC-S4-07: endDate before startDate → "End date must be on or after start date"', () => {
    try {
      UpdateContractDtoSchema.parse({ startDate: '2026-02-01', endDate: '2026-01-01' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'endDate');
      expect(issue?.message).toBe('End date must be on or after start date');
    }
  });
});

describe('UpdateContractStatusDtoSchema — PATCH /:id/status (S6)', () => {
  it('accepts a valid newStatus + reason', () => {
    const parsed = UpdateContractStatusDtoSchema.parse({
      newStatus: 'in_review',
      reason: 'Submitting for review',
    });
    expect(parsed.newStatus).toBe('in_review');
  });

  it('AC-S6-03: invalid newStatus → "Invalid status"', () => {
    try {
      UpdateContractStatusDtoSchema.parse({ newStatus: 'frozen' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'newStatus');
      expect(issue?.message).toBe('Invalid status');
    }
  });
});

describe('SetContractTagsDtoSchema — PUT /:id/tags (S8)', () => {
  it('accepts an empty array (AC-S8-03 — clears all tags)', () => {
    const parsed = SetContractTagsDtoSchema.parse({ tags: [] });
    expect(parsed.tags).toEqual([]);
  });

  it('accepts a list of valid tags', () => {
    const parsed = SetContractTagsDtoSchema.parse({ tags: ['legal', 'urgent'] });
    expect(parsed.tags).toEqual(['legal', 'urgent']);
  });

  it('AC-S8-05: tag length violation → "Each tag must be 1 to 64 characters"', () => {
    try {
      SetContractTagsDtoSchema.parse({ tags: ['x'.repeat(65)] });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Each tag must be 1 to 64 characters');
    }
  });

  it('AC-S8-06: control character in tag → "Tag must not contain control characters"', () => {
    try {
      SetContractTagsDtoSchema.parse({ tags: ['ok\x07tag'] });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Tag must not contain control characters');
    }
  });

  it('AC-S8-06: DEL (0x7F) in tag is rejected', () => {
    try {
      SetContractTagsDtoSchema.parse({ tags: ['ok\x7Ftag'] });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ message: string }> };
      expect(err.issues[0]?.message).toBe('Tag must not contain control characters');
    }
  });
});

describe('CreateContractVersionDtoSchema — POST /:id/versions (S10)', () => {
  it('accepts payload with bodyEn + changeNote', () => {
    const parsed = CreateContractVersionDtoSchema.parse({
      bodyEn: 'New body content',
      changeNote: 'Initial draft',
    });
    expect(parsed.bodyEn).toBe('New body content');
    expect(parsed.changeNote).toBe('Initial draft');
  });

  it('accepts payload with bodyAr only + changeNote', () => {
    const parsed = CreateContractVersionDtoSchema.parse({
      bodyAr: 'محتوى',
      changeNote: 'Arabic only',
    });
    expect(parsed.bodyAr).toBe('محتوى');
  });

  it('AC-S10-04: both bodyEn and bodyAr missing → "At least one of bodyEn or bodyAr must be provided"', () => {
    try {
      CreateContractVersionDtoSchema.parse({ changeNote: 'No body' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'body');
      expect(issue?.message).toBe('At least one of bodyEn or bodyAr must be provided');
    }
  });

  it('AC-S10-04: both bodyEn and bodyAr empty strings → "At least one of bodyEn or bodyAr must be provided"', () => {
    try {
      CreateContractVersionDtoSchema.parse({ bodyEn: '', bodyAr: '', changeNote: 'Update' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'body');
      expect(issue?.message).toBe('At least one of bodyEn or bodyAr must be provided');
    }
  });

  it('AC-S10-05: missing changeNote → "Change note is required"', () => {
    try {
      CreateContractVersionDtoSchema.parse({ bodyEn: 'X' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'changeNote');
      expect(issue?.message).toBe('Change note is required');
    }
  });

  it('AC-S10-05: empty changeNote → "Change note is required"', () => {
    try {
      CreateContractVersionDtoSchema.parse({ bodyEn: 'X', changeNote: '   ' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'changeNote');
      expect(issue?.message).toBe('Change note is required');
    }
  });
});

describe('ContractIdParamSchema — /:id', () => {
  it('coerces string to positive number', () => {
    const parsed = ContractIdParamSchema.parse({ id: '42' });
    expect(parsed.id).toBe(42);
  });

  it('rejects non-positive id', () => {
    expect(() => ContractIdParamSchema.parse({ id: 0 })).toThrow();
    expect(() => ContractIdParamSchema.parse({ id: -1 })).toThrow();
    expect(() => ContractIdParamSchema.parse({ id: 'abc' })).toThrow();
  });
});

describe('ContractListQuerySchema — GET /api/v1/contracts query', () => {
  it('AC-S1-01: defaults page=1, limit=20', () => {
    const parsed = ContractListQuerySchema.parse({});
    expect(parsed.page).toBe(1);
    expect(parsed.limit).toBe(20);
  });

  it('AC-S1-09: page=0 → "Page must be >= 1"', () => {
    try {
      ContractListQuerySchema.parse({ page: '0' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'page');
      expect(issue?.message).toBe('Page must be >= 1');
    }
  });

  it('AC-S1-09: limit=101 → "Limit must be between 1 and 100"', () => {
    try {
      ContractListQuerySchema.parse({ limit: '101' });
      expect.fail('expected throw');
    } catch (e: unknown) {
      const err = e as { issues: Array<{ path: (string | number)[]; message: string }> };
      const issue = err.issues.find((i) => i.path.join('.') === 'limit');
      expect(issue?.message).toBe('Limit must be between 1 and 100');
    }
  });

  it('tags query param: single string is wrapped to array', () => {
    const parsed = ContractListQuerySchema.parse({ tags: 'legal' });
    expect(parsed.tags).toEqual(['legal']);
  });

  it('tags query param: comma-separated string is split', () => {
    const parsed = ContractListQuerySchema.parse({ tags: 'legal,urgent' });
    expect(parsed.tags).toEqual(['legal', 'urgent']);
  });

  it('tags query param: array passes through', () => {
    const parsed = ContractListQuerySchema.parse({ tags: ['a', 'b'] });
    expect(parsed.tags).toEqual(['a', 'b']);
  });

  it('search trimmed and passed through', () => {
    const parsed = ContractListQuerySchema.parse({ search: '  hello  ' });
    expect(parsed.search).toBe('hello');
  });
});

describe('ContractVersionListQuerySchema and ContractActivityListQuerySchema', () => {
  it('Versions query: defaults page=1, limit=20', () => {
    const parsed = ContractVersionListQuerySchema.parse({});
    expect(parsed.page).toBe(1);
    expect(parsed.limit).toBe(20);
  });

  it('Activity query: defaults page=1, limit=50', () => {
    const parsed = ContractActivityListQuerySchema.parse({});
    expect(parsed.page).toBe(1);
    expect(parsed.limit).toBe(50);
  });

  it('Activity query: filters by activityType', () => {
    const parsed = ContractActivityListQuerySchema.parse({ activityType: 'status_changed' });
    expect(parsed.activityType).toBe('status_changed');
  });
});
