/**
 * Unit tests — Codex BE-M1b-007 negative regression for `exportXlsx` controller.
 *
 * BE-M1b-007 (LOW gap): If `renderContractXlsx` throws mid-stream, the
 * controller's catch block must run and `fn_audit_log_record` must NEVER be
 * invoked. The round-1 fix reordered render-before-audit; this test locks the
 * ordering so a future regression that swaps the order again fails loudly.
 *
 * Why a unit test (not integration): exercising the renderer-throw branch
 * against the real renderer would require corrupting the input shape —
 * fragile and noisy. We mock both `db.callFunction` (to feed synthetic
 * fn_contract_export_xlsx output) and `renderContractXlsx` (to throw on
 * demand) and observe the controller's external effects via the `db`
 * spy and the captured `next` callback.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Request, Response, NextFunction } from 'express';

// Mock dependencies BEFORE importing the controller. Both modules are
// imported eagerly by the controller — vi.mock hoists above imports.
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

const renderContractXlsxSpy = vi.fn(async (_data: unknown) => Buffer.from(''));
vi.mock('../../src/services/export/contract-xlsx.service', () => ({
  renderContractXlsx: renderContractXlsxSpy,
}));

// Stub the PDF service so loading the controller does not pull in the
// puppeteer pool (which spins up a real Browser at import-evaluate time
// when a test inadvertently triggers a render path).
const renderContractPdfSpy = vi.fn(async (_data: unknown) => Buffer.from(''));
vi.mock('../../src/services/export/contract-pdf.service', () => ({
  renderContractPdf: renderContractPdfSpy,
}));

// Minimal logger contract — `Controller entry/exit` lines are advisory.
const loggerStub = {
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
};

const buildReq = (): Request =>
  ({
    method: 'GET',
    path: '/api/v1/contracts/export.xlsx',
    query: { maxRows: 100 },
    params: {},
    body: {},
    user: {
      id: 1,
      role: 'super_admin',
      permissions: ['contract.read.all', 'contract.export'],
    },
    logger: loggerStub,
  }) as unknown as Request;

const buildRes = (): {
  res: Response;
  status: ReturnType<typeof vi.fn>;
  send: ReturnType<typeof vi.fn>;
  setHeader: ReturnType<typeof vi.fn>;
  json: ReturnType<typeof vi.fn>;
} => {
  const status = vi.fn();
  const send = vi.fn();
  const json = vi.fn();
  const setHeader = vi.fn();
  const res = {
    status: vi.fn().mockReturnThis(),
    send,
    json,
    setHeader,
  } as unknown as Response;
  // Wire status to chain
  (res.status as unknown as ReturnType<typeof vi.fn>).mockImplementation(
    (_code: number) => res,
  );
  return { res, status: res.status as unknown as ReturnType<typeof vi.fn>, send, json, setHeader };
};

describe('contractsController.exportXlsx — BE-M1b-007 (render failure must NOT emit audit)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renderContractXlsx throws → fn_audit_log_record is NOT called and error is forwarded to next()', async () => {
    // Arrange: callFunction returns a valid fn_contract_export_xlsx payload
    // so the controller reaches the renderer call, then renderContractXlsx
    // throws. The audit emission must be skipped.
    callFunctionSpy.mockImplementation(async (fnName: string) => {
      if (fnName === 'fn_contract_export_xlsx') {
        return {
          rows: [],
          totalRows: 0,
          truncated: false,
          filterApplied: {},
          generatedAt: '2026-05-03T00:00:00Z',
        };
      }
      // Any other fn_ call (e.g. fn_audit_log_record) is the regression.
      throw new Error(`Unexpected fn call in render-throw path: ${fnName}`);
    });
    renderContractXlsxSpy.mockRejectedValueOnce(new Error('synthetic-renderer-failure'));

    const { contractsController } = await import('../../src/controllers/contracts.controller');
    const req = buildReq();
    const { res } = buildRes();
    const next = vi.fn() as unknown as NextFunction;

    await contractsController.exportXlsx(req, res, next);

    // Assert: renderer was attempted exactly once
    expect(renderContractXlsxSpy).toHaveBeenCalledTimes(1);

    // Assert: fn_audit_log_record was NEVER invoked
    const auditCalls = callFunctionSpy.mock.calls.filter(
      (call) => call[0] === 'fn_audit_log_record',
    );
    expect(auditCalls).toHaveLength(0);

    // Assert: error forwarded to next
    expect(next).toHaveBeenCalledTimes(1);
    const forwarded = (next as unknown as ReturnType<typeof vi.fn>).mock.calls[0]?.[0] as Error;
    expect(forwarded).toBeInstanceOf(Error);
    expect(forwarded.message).toMatch(/synthetic-renderer-failure/);

    // Assert: response was never sent
    expect((res.send as unknown as ReturnType<typeof vi.fn>)).not.toHaveBeenCalled();
  });

  it('happy path remains intact (regression sanity): renderer + audit both fire and 200 is sent', async () => {
    // Sanity: ensures the BE-M1b-007 negative test isn't masking a broader
    // breakage. If this test fails, it is NOT BE-M1b-007 — it is a wider
    // regression in the controller.
    callFunctionSpy.mockImplementation(async (fnName: string) => {
      if (fnName === 'fn_contract_export_xlsx') {
        return {
          rows: [],
          totalRows: 0,
          truncated: false,
          filterApplied: {},
          generatedAt: '2026-05-03T00:00:00Z',
        };
      }
      if (fnName === 'fn_audit_log_record') {
        return { id: 42 };
      }
      throw new Error(`Unexpected fn call: ${fnName}`);
    });
    renderContractXlsxSpy.mockResolvedValueOnce(Buffer.from('PK\x03\x04 fake-xlsx'));

    const { contractsController } = await import('../../src/controllers/contracts.controller');
    const req = buildReq();
    const { res } = buildRes();
    const next = vi.fn() as unknown as NextFunction;

    await contractsController.exportXlsx(req, res, next);

    expect(renderContractXlsxSpy).toHaveBeenCalledTimes(1);
    const auditCalls = callFunctionSpy.mock.calls.filter(
      (call) => call[0] === 'fn_audit_log_record',
    );
    expect(auditCalls).toHaveLength(1);
    expect((res.status as unknown as ReturnType<typeof vi.fn>)).toHaveBeenCalledWith(200);
    expect((res.send as unknown as ReturnType<typeof vi.fn>)).toHaveBeenCalledTimes(1);
    expect(next).not.toHaveBeenCalled();
  });
});
