/**
 * Unit tests — Zod schema branches in src/schemas/payment-schedule.schemas.ts.
 *
 * Covers M1b enum schemas, single-row create DTO, bulk replace DTO including
 * superRefine cross-row guards (duplicate label, paidAt/status mismatch),
 * list query schema, PDF query schema, XLSX query schema (incl. tags
 * preprocessor + maxRows clamping), and the audit-log helper input schema.
 *
 * Each test is annotated with the AC (or hardening rule) it covers where
 * applicable. These tests do NOT touch the DB — they exercise pure Zod
 * validation branches.
 */
import { describe, it, expect } from 'vitest';
import {
  PaymentScheduleStatusSchema,
  PaymentScheduleRecurrenceSchema,
  PaymentScheduleCreateSchema,
  PaymentScheduleBulkReplaceSchema,
  PaymentScheduleListQuerySchema,
  ContractExportPdfQuerySchema,
  ContractExportXlsxQuerySchema,
  AuditLogRecordInputSchema,
} from '../../src/schemas/payment-schedule.schemas';

describe('M1b — payment_schedule enum schemas', () => {
  it('PaymentScheduleStatusSchema accepts every 6-state value (AC-S2-06 / AC-S3-07)', () => {
    const all = ['pending', 'due', 'paid', 'overdue', 'waived', 'cancelled'];
    for (const v of all) expect(PaymentScheduleStatusSchema.parse(v)).toBe(v);
  });

  it('PaymentScheduleStatusSchema rejects unknown status with "Invalid status value" (AC-S3-07)', () => {
    const r = PaymentScheduleStatusSchema.safeParse('not-a-status');
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues[0]?.message).toBe('Invalid status value');
    }
  });

  it('PaymentScheduleRecurrenceSchema accepts every 4-value enum (AC-S3-08)', () => {
    const all = ['once', 'monthly', 'quarterly', 'annually'];
    for (const v of all) expect(PaymentScheduleRecurrenceSchema.parse(v)).toBe(v);
  });

  it('PaymentScheduleRecurrenceSchema rejects unknown with "Invalid recurrence value" (AC-S3-08)', () => {
    const r = PaymentScheduleRecurrenceSchema.safeParse('weekly');
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues[0]?.message).toBe('Invalid recurrence value');
    }
  });
});

describe('M1b — PaymentScheduleCreateSchema (single row)', () => {
  it('accepts a minimal valid row (only label + amount required)', () => {
    const r = PaymentScheduleCreateSchema.parse({
      milestoneLabelEn: 'Milestone 1',
      amountAed: 1000,
    });
    expect(r.milestoneLabelEn).toBe('Milestone 1');
    expect(r.amountAed).toBe(1000);
  });

  it('AC-S3-05: rejects missing milestoneLabelEn with "Milestone label is required"', () => {
    const r = PaymentScheduleCreateSchema.safeParse({ amountAed: 1000 });
    expect(r.success).toBe(false);
    if (!r.success) {
      const labelIssue = r.error.issues.find((i) => i.path.includes('milestoneLabelEn'));
      expect(labelIssue?.message).toBe('Milestone label is required');
    }
  });

  it('AC-S3-05: rejects empty milestoneLabelEn with "Milestone label is required"', () => {
    const r = PaymentScheduleCreateSchema.safeParse({
      milestoneLabelEn: '   ',
      amountAed: 1000,
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      const labelIssue = r.error.issues.find((i) => i.path.includes('milestoneLabelEn'));
      expect(labelIssue?.message).toBe('Milestone label is required');
    }
  });

  it('AC-S3-06: rejects negative amountAed with "Amount must be greater than or equal to zero"', () => {
    const r = PaymentScheduleCreateSchema.safeParse({
      milestoneLabelEn: 'Test',
      amountAed: -1,
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues[0]?.message).toBe('Amount must be greater than or equal to zero');
    }
  });

  it('AC-S3-07: rejects invalid status with "Invalid status value"', () => {
    const r = PaymentScheduleCreateSchema.safeParse({
      milestoneLabelEn: 'Test',
      amountAed: 100,
      status: 'unknown',
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message === 'Invalid status value')).toBe(true);
    }
  });

  it('AC-S3-08: rejects invalid recurrence with "Invalid recurrence value"', () => {
    const r = PaymentScheduleCreateSchema.safeParse({
      milestoneLabelEn: 'Test',
      amountAed: 100,
      recurrence: 'weekly',
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message === 'Invalid recurrence value')).toBe(true);
    }
  });
});

describe('M1b — PaymentScheduleBulkReplaceSchema (cross-row + bulk)', () => {
  it('AC-S3-04: rejects empty rows[] with "rows must be a non-empty array"', () => {
    const r = PaymentScheduleBulkReplaceSchema.safeParse({ rows: [] });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message === 'rows must be a non-empty array')).toBe(true);
    }
  });

  it('AC-S3-09: rejects > 100 rows with "Maximum 100 milestones per batch"', () => {
    const rows = Array.from({ length: 101 }, (_, i) => ({
      milestoneLabelEn: `M${i}`,
      amountAed: 1,
    }));
    const r = PaymentScheduleBulkReplaceSchema.safeParse({ rows });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message === 'Maximum 100 milestones per batch')).toBe(
        true,
      );
    }
  });

  it('superRefine: rejects duplicate milestoneLabelEn within batch (case-insensitive)', () => {
    const r = PaymentScheduleBulkReplaceSchema.safeParse({
      rows: [
        { milestoneLabelEn: 'Milestone-A', amountAed: 100 },
        { milestoneLabelEn: 'milestone-a', amountAed: 200 }, // dup, different case
      ],
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(
        r.error.issues.some((i) => i.message === 'Duplicate milestone label within batch'),
      ).toBe(true);
    }
  });

  it('superRefine: rejects paidAt without status=paid', () => {
    const r = PaymentScheduleBulkReplaceSchema.safeParse({
      rows: [
        {
          milestoneLabelEn: 'Test',
          amountAed: 100,
          paidAt: '2026-05-01',
          status: 'pending', // mismatch
        },
      ],
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(
        r.error.issues.some((i) => i.message === 'paidAt is only permitted when status is paid'),
      ).toBe(true);
    }
  });

  it('superRefine: paidAt with status=paid PASSES', () => {
    const r = PaymentScheduleBulkReplaceSchema.safeParse({
      rows: [
        {
          milestoneLabelEn: 'Test',
          amountAed: 100,
          paidAt: '2026-05-01',
          status: 'paid',
        },
      ],
    });
    expect(r.success).toBe(true);
  });

  it('happy path: 1..100 valid rows pass with replaceExisting optional', () => {
    const r = PaymentScheduleBulkReplaceSchema.parse({
      rows: [{ milestoneLabelEn: 'A', amountAed: 1 }],
    });
    expect(r.rows.length).toBe(1);
  });
});

describe('M1b — PaymentScheduleListQuerySchema', () => {
  it('accepts empty query', () => {
    const r = PaymentScheduleListQuerySchema.parse({});
    expect(r.status).toBeUndefined();
  });

  it('accepts a valid status filter (AC-S2-06)', () => {
    const r = PaymentScheduleListQuerySchema.parse({ status: 'paid' });
    expect(r.status).toBe('paid');
  });

  it('rejects invalid status (AC-S2-06)', () => {
    const r = PaymentScheduleListQuerySchema.safeParse({ status: 'banana' });
    expect(r.success).toBe(false);
  });
});

describe('M1b — ContractExportPdfQuerySchema', () => {
  it('AC-S4-05 default language is bilingual', () => {
    const r = ContractExportPdfQuerySchema.parse({});
    expect(r.language).toBe('bilingual');
    expect(r.includeAttachments).toBe(false);
  });

  it('AC-S4-05 accepts en|ar|bilingual', () => {
    expect(ContractExportPdfQuerySchema.parse({ language: 'en' }).language).toBe('en');
    expect(ContractExportPdfQuerySchema.parse({ language: 'ar' }).language).toBe('ar');
  });

  it('AC-S4-05 rejects bad language', () => {
    expect(ContractExportPdfQuerySchema.safeParse({ language: 'xx' }).success).toBe(false);
  });

  it('AC-S4-10 includeAttachments accepts boolean and string variants', () => {
    expect(ContractExportPdfQuerySchema.parse({ includeAttachments: true }).includeAttachments).toBe(
      true,
    );
    expect(
      ContractExportPdfQuerySchema.parse({ includeAttachments: 'true' }).includeAttachments,
    ).toBe(true);
    expect(
      ContractExportPdfQuerySchema.parse({ includeAttachments: 'false' }).includeAttachments,
    ).toBe(false);
  });
});

describe('M1b — ContractExportXlsxQuerySchema', () => {
  it('default maxRows is 10000 when omitted (AC-S5-05)', () => {
    const r = ContractExportXlsxQuerySchema.parse({});
    expect(r.maxRows).toBe(10000);
  });

  it('AC-S5-06: rejects maxRows <= 0', () => {
    const r = ContractExportXlsxQuerySchema.safeParse({ maxRows: -1 });
    expect(r.success).toBe(false);
  });

  it('AC-S5-06: rejects maxRows > 50000', () => {
    const r = ContractExportXlsxQuerySchema.safeParse({ maxRows: 50001 });
    expect(r.success).toBe(false);
  });

  it('coerces maxRows from string (query string parser yields strings)', () => {
    const r = ContractExportXlsxQuerySchema.parse({ maxRows: '5000' });
    expect(r.maxRows).toBe(5000);
  });

  it('tags preprocessor: comma-list string → array', () => {
    const r = ContractExportXlsxQuerySchema.parse({ tags: 'a,b,c' });
    expect(r.tags).toEqual(['a', 'b', 'c']);
  });

  it('tags preprocessor: single string → 1-element array', () => {
    const r = ContractExportXlsxQuerySchema.parse({ tags: 'only-one' });
    expect(r.tags).toEqual(['only-one']);
  });

  it('tags preprocessor: array passes through', () => {
    const r = ContractExportXlsxQuerySchema.parse({ tags: ['a', 'b'] });
    expect(r.tags).toEqual(['a', 'b']);
  });
});

describe('M1b — AuditLogRecordInputSchema', () => {
  it('accepts a valid INSERT payload', () => {
    const r = AuditLogRecordInputSchema.parse({
      tableName: 'contract',
      recordId: null,
      action: 'INSERT',
      newValues: { event: 'EXPORT', format: 'xlsx' },
      actorId: 1,
    });
    expect(r.action).toBe('INSERT');
  });

  it('rejects unknown action with "Invalid action value"', () => {
    const r = AuditLogRecordInputSchema.safeParse({
      tableName: 'contract',
      recordId: null,
      action: 'EXPORT', // not a valid action — must be INSERT|UPDATE|DELETE
      newValues: {},
    });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message === 'Invalid action value')).toBe(true);
    }
  });
});
