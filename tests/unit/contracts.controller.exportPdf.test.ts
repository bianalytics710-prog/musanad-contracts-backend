/**
 * Unit tests — Codex BE-M1b-007 negative regression for `exportPdf` controller.
 *
 * BE-M1b-007 (LOW gap, PDF parallel): If `renderContractPdf` throws,
 * `fn_contract_activity_create` (activity_type='exported') must NEVER be
 * invoked. The round-1 fix (BE-M1b-004) reordered render-before-activity;
 * this test locks the ordering so a future regression that puts the
 * activity emission before the render fails loudly.
 *
 * Mirrors `contracts.controller.exportXlsx.test.ts` BE-M1b-007 — same
 * pattern, different export route.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Request, Response, NextFunction } from 'express';

const callFunctionSpy: ReturnType<
  typeof vi.fn<(fnName: string, args: unknown[], opts?: unknown) => Promise<unknown>>
> = vi.fn(async () => ({}));
const checkActiveRowExistsSpy: ReturnType<
  typeof vi.fn<(table: string, id: number) => Promise<boolean>>
> = vi.fn(async () => true);
vi.mock('../../src/database/client', () => ({
  db: {
    callFunction: callFunctionSpy,
    checkActiveRowExists: checkActiveRowExistsSpy,
  },
}));

const renderContractPdfSpy = vi.fn(async (_data: unknown) => Buffer.from(''));
vi.mock('../../src/services/export/contract-pdf.service', () => ({
  renderContractPdf: renderContractPdfSpy,
}));

// XLSX renderer stub so the controller import does not pull in exceljs at
// load time when only the PDF path is exercised.
const renderContractXlsxSpy = vi.fn(async (_data: unknown) => Buffer.from(''));
vi.mock('../../src/services/export/contract-xlsx.service', () => ({
  renderContractXlsx: renderContractXlsxSpy,
}));

const loggerStub = {
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
};

const buildReq = (): Request =>
  ({
    method: 'GET',
    path: '/api/v1/contracts/1/export.pdf',
    query: { language: 'bilingual' },
    params: { id: 1 },
    body: {},
    user: {
      id: 1,
      role: 'super_admin',
      permissions: ['contract.read.all', 'contract.export'],
    },
    logger: loggerStub,
  }) as unknown as Request;

const buildRes = (): Response => {
  const res = {
    status: vi.fn().mockReturnThis(),
    send: vi.fn(),
    json: vi.fn(),
    setHeader: vi.fn(),
  } as unknown as Response;
  return res;
};

const fakePdfDataPayload = {
  contract: {
    id: 1,
    contractNumber: 'CT-2026-000001',
    titleEn: 'Test',
    titleAr: null,
    contractType: 'employment',
    language: 'bilingual',
    valueAed: 0,
    currency: 'AED',
    startDate: null,
    endDate: null,
    signedAt: null,
    emirate: null,
    governingLaw: null,
    jurisdictionCourt: null,
    status: 'draft',
    currentVersion: 1,
    draftedBy: null,
    reviewedBy: null,
    approvedBy: null,
    bodyEn: null,
    bodyAr: null,
    createdAt: '2026-01-01T00:00:00Z',
  },
  tags: [],
  paymentSchedule: [],
  ourParty: null,
  counterparty: null,
  attachments: null,
  exportLanguage: 'bilingual',
  generatedAt: '2026-05-03T00:00:00Z',
};

describe('contractsController.exportPdf — BE-M1b-007 (render failure must NOT emit activity)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renderContractPdf throws → fn_contract_activity_create is NOT called for "exported" activity', async () => {
    callFunctionSpy.mockImplementation(async (fnName: string) => {
      if (fnName === 'fn_contract_export_pdf') return fakePdfDataPayload;
      throw new Error(`Unexpected fn call in render-throw path: ${fnName}`);
    });
    renderContractPdfSpy.mockRejectedValueOnce(new Error('synthetic-pdf-failure'));

    const { contractsController } = await import('../../src/controllers/contracts.controller');
    const req = buildReq();
    const res = buildRes();
    const next = vi.fn() as unknown as NextFunction;

    await contractsController.exportPdf(req, res, next);

    // Assert: renderer was attempted exactly once
    expect(renderContractPdfSpy).toHaveBeenCalledTimes(1);

    // Assert: NO 'exported' contract_activity row was emitted
    const activityCalls = callFunctionSpy.mock.calls.filter(
      (call) => call[0] === 'fn_contract_activity_create',
    );
    expect(activityCalls).toHaveLength(0);

    // Assert: error forwarded to next
    expect(next).toHaveBeenCalledTimes(1);
    const forwarded = (next as unknown as ReturnType<typeof vi.fn>).mock.calls[0]?.[0] as Error;
    expect(forwarded.message).toMatch(/synthetic-pdf-failure/);

    // Assert: response was never sent
    expect((res.send as unknown as ReturnType<typeof vi.fn>)).not.toHaveBeenCalled();
  });

  it('happy path remains intact (regression sanity): renderer + activity both fire and 200 is sent', async () => {
    callFunctionSpy.mockImplementation(async (fnName: string) => {
      if (fnName === 'fn_contract_export_pdf') return fakePdfDataPayload;
      if (fnName === 'fn_contract_activity_create') return { id: 99 };
      throw new Error(`Unexpected fn call: ${fnName}`);
    });
    renderContractPdfSpy.mockResolvedValueOnce(Buffer.from('%PDF-1.4 fake'));

    const { contractsController } = await import('../../src/controllers/contracts.controller');
    const req = buildReq();
    const res = buildRes();
    const next = vi.fn() as unknown as NextFunction;

    await contractsController.exportPdf(req, res, next);

    expect(renderContractPdfSpy).toHaveBeenCalledTimes(1);
    const activityCalls = callFunctionSpy.mock.calls.filter(
      (call) => call[0] === 'fn_contract_activity_create',
    );
    expect(activityCalls).toHaveLength(1);
    expect((res.status as unknown as ReturnType<typeof vi.fn>)).toHaveBeenCalledWith(200);
    expect((res.send as unknown as ReturnType<typeof vi.fn>)).toHaveBeenCalledTimes(1);
    expect(next).not.toHaveBeenCalled();
  });
});
