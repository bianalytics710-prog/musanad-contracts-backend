/**
 * Contract PDF renderer — M1b S4.
 *
 * Receives the JSONB output of fn_contract_export_pdf and produces an
 * application/pdf Buffer using headless Chromium (Puppeteer).
 *
 * Design:
 *   - Pure function in: ContractExportPdfResponse → out: Buffer.
 *   - HTML template inlined (no external assets) so Puppeteer can render
 *     without network / file-system dependencies.
 *   - body_en / body_ar are SENSITIVE — they reach the renderer here but
 *     pino is configured (logger.util.ts) to redact `*.bodyEn` / `*.bodyAr`
 *     so any incidental log line that references the JSONB object scrubs
 *     them out (AC-S4-08).
 *   - dir="rtl" applied for Arabic / bilingual rendering.
 *   - Browser process is shared across requests via puppeteer-pool.service
 *     (Codex BE-M1b-003 fix); per-request work is `withPage(fn)` →
 *     newPage → setContent → pdf → close-page. Concurrency capped by
 *     PUPPETEER_MAX_CONCURRENT (default 2) at the pool layer; the
 *     exportRateLimiter (30/min/user) remains in front for per-user fairness.
 *
 * Environment overrides:
 *   - PUPPETEER_EXECUTABLE_PATH — point at a system Chromium when the
 *     bundled binary cannot be installed (offline dev, alpine builds, etc.).
 *   - PUPPETEER_MAX_CONCURRENT — hard cap on concurrent page renders
 *     (default 2). See src/services/export/puppeteer-pool.service.ts.
 *
 * Container deps (Dockerfile must install): libnss3, libatk1.0-0,
 * libatk-bridge2.0-0, libxss1, libxrandr2, libasound2, libpangocairo-1.0-0,
 * libgtk-3-0, libgbm1, ca-certificates.
 */
import { withPage } from './puppeteer-pool.service';
import type {
  ContractExportPdfResponse,
  ContractLanguage,
  PaymentSchedule,
} from '../../types/payment-schedule.types';

const escapeHtml = (raw: string | null | undefined): string => {
  if (raw === null || raw === undefined) return '';
  return String(raw)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
};

const isRtl = (lang: ContractLanguage): boolean => lang === 'ar' || lang === 'bilingual';

const formatAmount = (n: number | null | undefined, currency: string): string => {
  if (n === null || n === undefined) return '—';
  const v = Number(n);
  if (!Number.isFinite(v)) return '—';
  return `${currency} ${v.toLocaleString('en-AE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};

const formatDate = (iso: string | null | undefined): string => {
  if (!iso) return '—';
  // fn_ returns ISO strings; show the YYYY-MM-DD portion (Asia/Dubai display
  // formatting is FE responsibility).
  return escapeHtml(iso.length >= 10 ? iso.slice(0, 10) : iso);
};

const renderPaymentRow = (row: PaymentSchedule, currency: string): string => `
  <tr>
    <td>${escapeHtml(row.milestoneLabelEn)}</td>
    <td>${escapeHtml(row.milestoneNameEn)}</td>
    <td>${formatAmount(row.amountAed, currency)}</td>
    <td>${formatDate(row.dueDate)}</td>
    <td>${escapeHtml(row.status)}</td>
    <td>${escapeHtml(row.invoiceRef)}</td>
  </tr>
`;

const renderTagList = (tags: ReadonlyArray<string>): string => {
  if (!Array.isArray(tags) || tags.length === 0) return '<em>—</em>';
  return tags.map((t) => `<span class="tag">${escapeHtml(t)}</span>`).join(' ');
};

/**
 * Build the HTML document. Tailwind-derived semantic styling inlined so
 * Puppeteer needs no external network access.
 */
const buildHtml = (data: ContractExportPdfResponse): string => {
  const { contract, tags, paymentSchedule, exportLanguage, generatedAt } = data;
  const dir = isRtl(exportLanguage) ? 'rtl' : 'ltr';
  const lang = exportLanguage === 'bilingual' ? 'en' : exportLanguage;

  const bodyEn = contract.bodyEn ?? '';
  const bodyAr = contract.bodyAr ?? '';

  const showEn = exportLanguage === 'en' || exportLanguage === 'bilingual';
  const showAr = exportLanguage === 'ar' || exportLanguage === 'bilingual';

  return `<!doctype html>
<html lang="${lang}" dir="${dir}">
<head>
  <meta charset="utf-8" />
  <title>${escapeHtml(contract.contractNumber)}</title>
  <style>
    @page { size: A4; margin: 18mm 16mm; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #1f2937; font-size: 11pt; }
    h1 { font-size: 18pt; margin: 0 0 4pt 0; }
    h2 { font-size: 13pt; margin: 16pt 0 6pt 0; border-bottom: 1px solid #d1d5db; padding-bottom: 3pt; }
    .meta { color: #4b5563; font-size: 9pt; }
    table.head { width: 100%; border-collapse: collapse; margin: 8pt 0; }
    table.head td { padding: 3pt 6pt; vertical-align: top; }
    table.head td.k { color: #6b7280; width: 32%; font-weight: 600; }
    table.payments { width: 100%; border-collapse: collapse; margin: 6pt 0 12pt 0; font-size: 10pt; }
    table.payments th, table.payments td { border: 1px solid #d1d5db; padding: 4pt 6pt; text-align: left; }
    table.payments th { background: #f3f4f6; }
    .tag { display: inline-block; background: #eef2ff; color: #4338ca; padding: 1pt 6pt; border-radius: 4pt; font-size: 9pt; margin-right: 4pt; }
    .body { white-space: pre-wrap; line-height: 1.55; }
    .body.ar { direction: rtl; text-align: right; }
    .footer { margin-top: 14pt; color: #6b7280; font-size: 8pt; border-top: 1px solid #e5e7eb; padding-top: 4pt; }
  </style>
</head>
<body>
  <h1>${escapeHtml(contract.titleEn)}</h1>
  ${contract.titleAr ? `<div class="meta" dir="rtl">${escapeHtml(contract.titleAr)}</div>` : ''}
  <div class="meta">${escapeHtml(contract.contractNumber)} · ${escapeHtml(contract.contractType)} · ${escapeHtml(contract.status)}</div>

  <h2>Contract Details</h2>
  <table class="head">
    <tr><td class="k">Language</td><td>${escapeHtml(contract.language)}</td></tr>
    <tr><td class="k">Value</td><td>${formatAmount(contract.valueAed, contract.currency)}</td></tr>
    <tr><td class="k">Start Date</td><td>${formatDate(contract.startDate)}</td></tr>
    <tr><td class="k">End Date</td><td>${formatDate(contract.endDate)}</td></tr>
    <tr><td class="k">Signed</td><td>${formatDate(contract.signedAt)}</td></tr>
    <tr><td class="k">Emirate</td><td>${escapeHtml(contract.emirate)}</td></tr>
    <tr><td class="k">Governing Law</td><td>${escapeHtml(contract.governingLaw)}</td></tr>
    <tr><td class="k">Jurisdiction Court</td><td>${escapeHtml(contract.jurisdictionCourt)}</td></tr>
    <tr><td class="k">Version</td><td>${contract.currentVersion}</td></tr>
    <tr><td class="k">Tags</td><td>${renderTagList(tags)}</td></tr>
  </table>

  <h2>Payment Schedule</h2>
  ${
    paymentSchedule.length === 0
      ? '<p><em>No milestones recorded.</em></p>'
      : `<table class="payments">
          <thead>
            <tr>
              <th>Milestone</th>
              <th>Description</th>
              <th>Amount</th>
              <th>Due</th>
              <th>Status</th>
              <th>Invoice Ref</th>
            </tr>
          </thead>
          <tbody>
            ${paymentSchedule.map((r) => renderPaymentRow(r, contract.currency)).join('')}
          </tbody>
        </table>`
  }

  ${showEn && bodyEn ? `<h2>Body (English)</h2><div class="body">${escapeHtml(bodyEn)}</div>` : ''}
  ${showAr && bodyAr ? `<h2>Body (Arabic)</h2><div class="body ar" dir="rtl">${escapeHtml(bodyAr)}</div>` : ''}

  <div class="footer">Generated ${escapeHtml(generatedAt)} · Musanad Contracts Hub</div>
</body>
</html>`;
};

/**
 * Render a contract PDF. Returns a Buffer of application/pdf bytes.
 *
 * Uses the shared puppeteer-pool: a singleton Browser process is launched
 * lazily on first call and reused. `withPage()` acquires the concurrency
 * semaphore (PUPPETEER_MAX_CONCURRENT, default 2), opens a page, and closes
 * the page (NOT the browser) on completion. The browser is closed only on
 * graceful shutdown via puppeteer-pool.closeBrowser() in server.ts.
 */
export const renderContractPdf = async (data: ContractExportPdfResponse): Promise<Buffer> => {
  const html = buildHtml(data);
  return withPage(async (page) => {
    await page.setContent(html, { waitUntil: 'networkidle0' });
    const pdf = await page.pdf({
      format: 'A4',
      printBackground: true,
      margin: { top: '18mm', bottom: '18mm', left: '16mm', right: '16mm' },
    });
    return Buffer.from(pdf);
  });
};
