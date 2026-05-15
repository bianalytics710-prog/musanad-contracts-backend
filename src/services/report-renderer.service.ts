/**
 * M20 / CR-L — Report Renderer Service.
 *
 * Converts a fn_report_data_<slug> envelope (payload + meta) into:
 *   - application/pdf  via Puppeteer (shared browser pool)
 *   - .xlsx            via exceljs (streaming workbook)
 *
 * Both renderers consume the universal ReportDataResponse<TPayload> envelope:
 *   {
 *     payload: <slug-specific JSONB>,
 *     meta: {
 *       tenantId, generatedAt, sourceTraceability, parameters
 *     }
 *   }
 *
 * PDF templates are simple Mustache-rendered HTML. We deliberately keep the
 * template engine universal across slugs: a generic top-of-page header
 * (title + window) + a single tabular section + a Sources sheet/section
 * driven by `meta.sourceTraceability`. This satisfies AC#8 (source
 * traceability) for all 24 slugs without per-slug branching.
 *
 * Excel workbook layout:
 *   Sheet 1 — Payload (rows derived from the payload via flattenForTable)
 *   Sheet 2 — Sources (one row per source table in meta.sourceTraceability)
 *   Sheet 3 — Run Metadata (tenantId, generatedAt, parameters JSON dump)
 *
 * Concurrency: PDF rendering goes through puppeteer-pool.withPage() so the
 * report worker's p-limit(2) is preserved.
 *
 * SECURITY: every string interpolated into HTML is Mustache-escaped (default).
 * Never disable escape for user-supplied data.
 */
import Mustache from 'mustache';
import ExcelJS from 'exceljs';
import { withPage } from './export/puppeteer-pool.service';

// ----------------------------------------------------------------
// Types
// ----------------------------------------------------------------

export interface ReportRenderEnvelope {
  payload: Record<string, unknown> | null | undefined;
  meta?: {
    tenantId?: string;
    generatedAt?: string;
    sourceTraceability?: Array<{ tableName: string; recordIds: number[]; count: number }>;
    parameters?: Record<string, unknown>;
  };
}

export interface ReportRenderContext {
  /** Template slug — used for the page title. */
  slug: string;
  /** Optional human-readable display name (template.display_name_en). */
  displayNameEn?: string | null;
  /** ISO timestamp of when the run was triggered. */
  triggeredAt: string;
}

// ----------------------------------------------------------------
// PDF rendering — Mustache HTML → Puppeteer
// ----------------------------------------------------------------

/**
 * Minimal default Mustache template. Branches happen at the rendering
 * helper layer (`buildHtmlContext` flattens payload into rows). Per-slug
 * customisation is a follow-up; for v1.2 we ship the universal layout.
 */
const PDF_TEMPLATE = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>{{title}}</title>
  <style>
    body { font-family: 'Helvetica Neue', Arial, sans-serif; font-size: 11pt; color: #1a1a1a; padding: 24px; }
    h1 { font-size: 20pt; margin: 0 0 4px; }
    h2 { font-size: 14pt; margin: 16px 0 8px; border-bottom: 1px solid #ccc; padding-bottom: 4px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 12px; }
    th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
    th { background: #f5f5f5; font-weight: 600; }
    .meta { color: #666; font-size: 9pt; margin-bottom: 16px; }
    .footer { margin-top: 24px; font-size: 9pt; color: #888; text-align: center; }
    pre { background: #f9f9f9; padding: 8px; font-size: 9pt; overflow-x: auto; white-space: pre-wrap; }
  </style>
</head>
<body>
  <h1>{{title}}</h1>
  <div class="meta">
    Tenant: {{tenantId}} · Generated: {{generatedAt}}{{#window}} · Window: {{window}}{{/window}}
  </div>

  {{#sections}}
    <h2>{{name}}</h2>
    {{#hasRows}}
      <table>
        <thead><tr>{{#columns}}<th>{{.}}</th>{{/columns}}</tr></thead>
        <tbody>
          {{#rows}}
            <tr>{{#cells}}<td>{{.}}</td>{{/cells}}</tr>
          {{/rows}}
        </tbody>
      </table>
    {{/hasRows}}
    {{^hasRows}}<p><em>No data.</em></p>{{/hasRows}}
  {{/sections}}

  <h2>Sources</h2>
  {{#hasSources}}
    <table>
      <thead><tr><th>Source Table</th><th>Records</th><th>Count</th></tr></thead>
      <tbody>
        {{#sources}}
          <tr><td>{{tableName}}</td><td>{{recordIds}}</td><td>{{count}}</td></tr>
        {{/sources}}
      </tbody>
    </table>
  {{/hasSources}}
  {{^hasSources}}<p><em>No source traceability recorded.</em></p>{{/hasSources}}

  <div class="footer">{{slug}} · ADNOC Contracts Hub</div>
</body>
</html>`;

interface HtmlSection {
  name: string;
  hasRows: boolean;
  columns: string[];
  rows: Array<{ cells: string[] }>;
}

interface HtmlContext {
  title: string;
  tenantId: string;
  generatedAt: string;
  window: string;
  slug: string;
  sections: HtmlSection[];
  hasSources: boolean;
  sources: Array<{ tableName: string; recordIds: string; count: number }>;
}

const stringify = (v: unknown): string => {
  if (v === null || v === undefined) return '—';
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  // Stable JSON for nested objects/arrays — keep PDF readable
  try {
    return JSON.stringify(v);
  } catch {
    return '[unserializable]';
  }
};

/**
 * Flatten a payload object into HtmlSection[] sections. Each top-level
 * array-of-objects field becomes a section with column headers derived
 * from the first row's keys. Top-level scalar/object fields are coerced
 * into a single key-value table named "Summary".
 */
const buildHtmlSections = (payload: Record<string, unknown> | null | undefined): HtmlSection[] => {
  if (!payload || typeof payload !== 'object') return [];

  const sections: HtmlSection[] = [];
  const summaryEntries: Array<{ key: string; value: string }> = [];

  for (const [key, value] of Object.entries(payload)) {
    if (Array.isArray(value)) {
      const arr = value;
      if (arr.length === 0) {
        sections.push({ name: key, hasRows: false, columns: [], rows: [] });
        continue;
      }
      const first = arr[0];
      if (first !== null && typeof first === 'object' && !Array.isArray(first)) {
        const columns = Object.keys(first as Record<string, unknown>);
        const rows = arr.map((row) => ({
          cells: columns.map((c) => stringify((row as Record<string, unknown>)[c])),
        }));
        sections.push({ name: key, hasRows: true, columns, rows });
      } else {
        sections.push({
          name: key,
          hasRows: true,
          columns: ['value'],
          rows: arr.map((v) => ({ cells: [stringify(v)] })),
        });
      }
    } else if (value !== null && typeof value === 'object') {
      // Single-row table from object entries
      const entries = Object.entries(value as Record<string, unknown>);
      sections.push({
        name: key,
        hasRows: entries.length > 0,
        columns: ['key', 'value'],
        rows: entries.map(([k, v]) => ({ cells: [k, stringify(v)] })),
      });
    } else {
      summaryEntries.push({ key, value: stringify(value) });
    }
  }

  if (summaryEntries.length > 0) {
    sections.unshift({
      name: 'Summary',
      hasRows: true,
      columns: ['key', 'value'],
      rows: summaryEntries.map((e) => ({ cells: [e.key, e.value] })),
    });
  }

  return sections;
};

const buildHtmlContext = (envelope: ReportRenderEnvelope, ctx: ReportRenderContext): HtmlContext => {
  const title = ctx.displayNameEn ?? ctx.slug;
  const parameters = envelope.meta?.parameters ?? {};
  const window = (() => {
    const p = parameters as Record<string, unknown>;
    if (p.dateRange && typeof p.dateRange === 'object') {
      const dr = p.dateRange as { start?: string; end?: string };
      if (dr.start && dr.end) return `${dr.start} → ${dr.end}`;
    }
    return '';
  })();

  const sources = (envelope.meta?.sourceTraceability ?? []).map((s) => ({
    tableName: s.tableName,
    recordIds: Array.isArray(s.recordIds) ? s.recordIds.slice(0, 25).join(', ') : '',
    count: s.count ?? 0,
  }));

  return {
    title,
    tenantId: envelope.meta?.tenantId ?? '—',
    generatedAt: envelope.meta?.generatedAt ?? ctx.triggeredAt,
    window,
    slug: ctx.slug,
    sections: buildHtmlSections(envelope.payload ?? {}),
    hasSources: sources.length > 0,
    sources,
  };
};

/**
 * Render a report envelope to a PDF Buffer via Puppeteer.
 * Concurrency is bounded by puppeteer-pool.withPage().
 */
export const renderReportPdf = async (
  envelope: ReportRenderEnvelope,
  ctx: ReportRenderContext,
): Promise<Buffer> => {
  const context = buildHtmlContext(envelope, ctx);
  // Mustache.escape is HTML-escape by default; never disable for user data.
  const html = Mustache.render(PDF_TEMPLATE, context);
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

// ----------------------------------------------------------------
// XLSX rendering — exceljs streaming workbook
// ----------------------------------------------------------------

const writeArraySheet = (
  ws: ExcelJS.Worksheet,
  name: string,
  arr: ReadonlyArray<unknown>,
): void => {
  if (arr.length === 0) {
    ws.addRow([name]);
    ws.addRow(['(no rows)']);
    return;
  }
  const first = arr[0];
  if (first !== null && typeof first === 'object' && !Array.isArray(first)) {
    const columns = Object.keys(first as Record<string, unknown>);
    ws.columns = columns.map((c) => ({ header: c, key: c, width: 24 }));
    arr.forEach((row) => {
      const flat: Record<string, unknown> = {};
      for (const c of columns) {
        const v = (row as Record<string, unknown>)[c];
        flat[c] =
          v === null || v === undefined
            ? null
            : typeof v === 'object'
              ? JSON.stringify(v)
              : v;
      }
      ws.addRow(flat);
    });
  } else {
    ws.addRow([name]);
    arr.forEach((v) => ws.addRow([typeof v === 'object' ? JSON.stringify(v) : v]));
  }
};

/**
 * Render a report envelope to an XLSX Buffer via exceljs.
 */
export const renderReportXlsx = async (
  envelope: ReportRenderEnvelope,
  ctx: ReportRenderContext,
): Promise<Buffer> => {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = 'ADNOC Contracts Hub';
  workbook.created = new Date();

  // Sheet 1 — Payload. Each top-level array becomes its own sheet (capped
  // at 8 to avoid runaway tabs); scalars + objects go into "Summary".
  const payload = envelope.payload ?? {};
  const summaryRows: Array<{ key: string; value: unknown }> = [];
  let arraySheetCount = 0;

  for (const [key, value] of Object.entries(payload)) {
    if (Array.isArray(value) && arraySheetCount < 8) {
      const ws = workbook.addWorksheet(key.slice(0, 31)); // 31-char Excel sheet-name limit
      writeArraySheet(ws, key, value);
      arraySheetCount += 1;
    } else if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
        summaryRows.push({ key: `${key}.${k}`, value: v });
      }
    } else {
      summaryRows.push({ key, value });
    }
  }

  if (summaryRows.length > 0) {
    const ws = workbook.addWorksheet('Summary');
    ws.columns = [
      { header: 'Key', key: 'key', width: 36 },
      { header: 'Value', key: 'value', width: 60 },
    ];
    summaryRows.forEach((r) => {
      ws.addRow({
        key: r.key,
        value:
          r.value === null || r.value === undefined
            ? null
            : typeof r.value === 'object'
              ? JSON.stringify(r.value)
              : r.value,
      });
    });
  }

  // Sheet — Sources (always)
  const wsSources = workbook.addWorksheet('Sources');
  wsSources.columns = [
    { header: 'Source Table', key: 'tableName', width: 36 },
    { header: 'Record IDs (first 50)', key: 'recordIds', width: 60 },
    { header: 'Count', key: 'count', width: 12 },
  ];
  (envelope.meta?.sourceTraceability ?? []).forEach((s) =>
    wsSources.addRow({
      tableName: s.tableName,
      recordIds: Array.isArray(s.recordIds) ? s.recordIds.slice(0, 50).join(', ') : '',
      count: s.count ?? 0,
    }),
  );

  // Sheet — Run Metadata (always)
  const wsMeta = workbook.addWorksheet('Run Metadata');
  wsMeta.columns = [
    { header: 'Key', key: 'key', width: 28 },
    { header: 'Value', key: 'value', width: 80 },
  ];
  wsMeta.addRow({ key: 'slug', value: ctx.slug });
  wsMeta.addRow({ key: 'displayNameEn', value: ctx.displayNameEn ?? '' });
  wsMeta.addRow({ key: 'tenantId', value: envelope.meta?.tenantId ?? '' });
  wsMeta.addRow({ key: 'generatedAt', value: envelope.meta?.generatedAt ?? '' });
  wsMeta.addRow({ key: 'triggeredAt', value: ctx.triggeredAt });
  wsMeta.addRow({
    key: 'parameters',
    value: JSON.stringify(envelope.meta?.parameters ?? {}),
  });

  const arrayBuffer = await workbook.xlsx.writeBuffer();
  return Buffer.from(arrayBuffer as ArrayBuffer);
};
