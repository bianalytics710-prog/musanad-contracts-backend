/**
 * Unit tests — src/services/export/contract-pdf.service.ts (renderContractPdf).
 *
 * Puppeteer is mocked at module scope so these tests run in milliseconds and
 * do not require Chromium. We assert that:
 *   1. The HTML passed to page.setContent() contains the expected i18n /
 *      RTL markers and the contract head fields (escaped).
 *   2. The Buffer returned is exactly the bytes returned by page.pdf().
 *   3. page.close() is called even when page.pdf() throws.
 *   4. Codex BE-M1b-003: the shared puppeteer pool reuses ONE browser
 *      across many concurrent renders (browser.close NOT called per request)
 *      and the per-request work uses newPage / page.close.
 *
 * No Puppeteer process is spawned; coverage is for the data-prep + HTML
 * template branches only. The end-to-end render is exercised by the M1b
 * integration suite.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type {
  ContractExportPdfResponse,
} from '../../src/types/payment-schedule.types';

const fakePdfBytes = Buffer.from('%PDF-1.4 fake-content');
const setContentSpy = vi.fn(async (_html: string) => undefined);
const pdfSpy = vi.fn(async () => fakePdfBytes);
const pageCloseSpy = vi.fn(async () => undefined);
const newPageSpy = vi.fn(async () => ({
  setContent: setContentSpy,
  pdf: pdfSpy,
  close: pageCloseSpy,
}));
const closeSpy = vi.fn(async () => undefined);
const launchSpy = vi.fn(async () => ({
  newPage: newPageSpy,
  close: closeSpy,
  connected: true,
}));

vi.mock('puppeteer', () => ({
  default: { launch: launchSpy },
}));

const buildPdfData = (overrides: Partial<ContractExportPdfResponse> = {}): ContractExportPdfResponse => ({
  contract: {
    id: 1,
    contractNumber: 'CT-2026-000001',
    titleEn: 'Test <Contract> & "Doe"',
    titleAr: 'عقد اختبار',
    contractType: 'employment',
    language: 'bilingual',
    valueAed: 50000,
    currency: 'AED',
    startDate: '2026-01-01T00:00:00Z',
    endDate: '2026-12-31T00:00:00Z',
    signedAt: null,
    emirate: 'Dubai',
    governingLaw: 'uae_federal',
    jurisdictionCourt: null,
    status: 'draft',
    currentVersion: 1,
    draftedBy: null,
    reviewedBy: null,
    approvedBy: null,
    bodyEn: 'English body content',
    bodyAr: 'محتوى عربي',
    createdAt: '2026-01-01T00:00:00Z',
  },
  tags: ['tag1', 'tag-two'],
  paymentSchedule: [
    {
      id: 10,
      contractId: 1,
      milestoneLabelEn: 'M1',
      milestoneLabelAr: null,
      milestoneNameEn: 'Milestone 1',
      milestoneNameAr: null,
      amountAed: 5000,
      dueDate: '2026-02-01',
      paidAt: null,
      status: 'pending',
      recurrence: 'once',
      invoiceRef: null,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    },
  ],
  ourParty: null,
  counterparty: null,
  attachments: null,
  exportLanguage: 'bilingual',
  generatedAt: '2026-05-03T00:00:00Z',
  ...overrides,
});

describe('renderContractPdf', () => {
  beforeEach(async () => {
    delete process.env.PUPPETEER_EXECUTABLE_PATH;
    delete process.env.PUPPETEER_MAX_CONCURRENT;
    // Reset the singleton browser so each test sees a fresh launch. This
    // calls closeSpy on whatever browser the previous test launched —
    // clear mocks AFTER the reset so each test sees a zeroed counter.
    const pool = await import('../../src/services/export/puppeteer-pool.service');
    await pool.__testReset();
    vi.clearAllMocks();
    pdfSpy.mockResolvedValue(fakePdfBytes);
  });

  afterEach(() => {
    delete process.env.PUPPETEER_EXECUTABLE_PATH;
    delete process.env.PUPPETEER_MAX_CONCURRENT;
  });

  it('renders a PDF buffer and includes contract head fields in the HTML (HTML-escaped)', async () => {
    const { renderContractPdf } = await import('../../src/services/export/contract-pdf.service');
    const data = buildPdfData();
    const result = await renderContractPdf(data);

    expect(Buffer.isBuffer(result)).toBe(true);
    expect(result.equals(fakePdfBytes)).toBe(true);
    // Codex BE-M1b-003: shared pool — launch called once for the test's
    // first render, and page (not browser) is closed.
    expect(launchSpy).toHaveBeenCalledTimes(1);
    expect(newPageSpy).toHaveBeenCalledTimes(1);
    expect(setContentSpy).toHaveBeenCalledTimes(1);
    expect(pdfSpy).toHaveBeenCalledTimes(1);
    expect(pageCloseSpy).toHaveBeenCalledTimes(1);
    expect(closeSpy).toHaveBeenCalledTimes(0); // browser.close NOT called per request

    const html = setContentSpy.mock.calls[0]?.[0] ?? '';
    // Title HTML-escaped
    expect(html).toContain('Test &lt;Contract&gt; &amp; &quot;Doe&quot;');
    // Bilingual → dir="rtl"
    expect(html).toContain('dir="rtl"');
    // Tags rendered
    expect(html).toContain('tag1');
    expect(html).toContain('tag-two');
    // Payment row
    expect(html).toContain('Milestone 1');
    // Bodies present (English + Arabic) — bilingual mode
    expect(html).toContain('English body content');
    expect(html).toContain('محتوى عربي');
  });

  it('language=en omits the Arabic body section', async () => {
    const { renderContractPdf } = await import('../../src/services/export/contract-pdf.service');
    const data = buildPdfData({ exportLanguage: 'en' });
    await renderContractPdf(data);
    const html = setContentSpy.mock.calls[0]?.[0] ?? '';
    expect(html).toContain('English body content');
    expect(html).not.toContain('محتوى عربي');
    // dir="ltr" for english-only
    expect(html).toContain('dir="ltr"');
  });

  it('uses PUPPETEER_EXECUTABLE_PATH when set', async () => {
    process.env.PUPPETEER_EXECUTABLE_PATH = '/usr/bin/chromium';
    const { renderContractPdf } = await import('../../src/services/export/contract-pdf.service');
    await renderContractPdf(buildPdfData());
    const lastCall = launchSpy.mock.calls[launchSpy.mock.calls.length - 1] as unknown as
      | [{ executablePath?: string; args?: string[] }]
      | undefined;
    const opts = lastCall?.[0];
    expect(opts?.executablePath).toBe('/usr/bin/chromium');
    expect(opts?.args).toContain('--no-sandbox');
  });

  it('closes the page even when page.pdf() throws', async () => {
    pdfSpy.mockRejectedValueOnce(new Error('synthetic-render-failure'));
    const { renderContractPdf } = await import('../../src/services/export/contract-pdf.service');
    await expect(renderContractPdf(buildPdfData())).rejects.toThrow(/synthetic-render-failure/);
    // page.close() in finally — browser.close NOT called.
    expect(pageCloseSpy).toHaveBeenCalledTimes(1);
    expect(closeSpy).toHaveBeenCalledTimes(0);
  });

  // ---------------------------------------------------------------------------
  // Codex BE-M1b-003 regression — Puppeteer pool reuse
  // ---------------------------------------------------------------------------
  it('BE-M1b-003: reuses one browser across many concurrent renders', async () => {
    const { renderContractPdf } = await import('../../src/services/export/contract-pdf.service');
    const data = buildPdfData();
    const N = 10;
    const results = await Promise.all(
      Array.from({ length: N }, () => renderContractPdf(data)),
    );
    expect(results).toHaveLength(N);
    // Single browser launched, despite N concurrent renders.
    expect(launchSpy).toHaveBeenCalledTimes(1);
    // One page per render, each closed.
    expect(newPageSpy).toHaveBeenCalledTimes(N);
    expect(pageCloseSpy).toHaveBeenCalledTimes(N);
    // browser.close NEVER called from request path (only on shutdown).
    expect(closeSpy).toHaveBeenCalledTimes(0);
  });

  it('BE-M1b-003: closeBrowser() closes the shared browser exactly once', async () => {
    const { renderContractPdf } = await import('../../src/services/export/contract-pdf.service');
    const pool = await import('../../src/services/export/puppeteer-pool.service');
    await renderContractPdf(buildPdfData());
    expect(launchSpy).toHaveBeenCalledTimes(1);
    expect(closeSpy).toHaveBeenCalledTimes(0);
    await pool.closeBrowser();
    expect(closeSpy).toHaveBeenCalledTimes(1);
    // Idempotent — second call is a no-op.
    await pool.closeBrowser();
    expect(closeSpy).toHaveBeenCalledTimes(1);
  });
});
