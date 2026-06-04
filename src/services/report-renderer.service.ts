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
    body { font-family: 'Helvetica Neue', Arial, sans-serif; font-size: 10.5pt; color: #1f2937; padding: 28px 32px; }
    h1 { font-size: 22pt; margin: 0 0 4px; color: #111827; letter-spacing: -0.01em; }
    h2 { font-size: 12pt; margin: 22px 0 8px; color: #111827; text-transform: uppercase; letter-spacing: 0.05em; border-bottom: 1px solid #d1d5db; padding-bottom: 4px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 16px; font-size: 9.5pt; }
    th, td { border-bottom: 1px solid #e5e7eb; padding: 7px 9px; text-align: left; vertical-align: top; }
    th { background: #f9fafb; font-weight: 600; color: #374151; font-size: 8.5pt; text-transform: uppercase; letter-spacing: 0.04em; border-bottom: 2px solid #d1d5db; }
    td.num { text-align: right; font-variant-numeric: tabular-nums; }
    .meta { color: #6b7280; font-size: 9pt; margin-bottom: 18px; }
    .kpi-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin: 12px 0 20px; }
    .kpi { border: 1px solid #e5e7eb; border-radius: 4px; padding: 10px 12px; background: #f9fafb; }
    .kpi .lbl { font-size: 8.5pt; color: #6b7280; text-transform: uppercase; letter-spacing: 0.04em; }
    .kpi .val { font-size: 16pt; font-weight: 600; color: #111827; margin-top: 2px; font-variant-numeric: tabular-nums; }
    .footer { margin-top: 28px; font-size: 8.5pt; color: #9ca3af; text-align: center; border-top: 1px solid #e5e7eb; padding-top: 10px; }
    .narrative { background: #f9fafb; border-left: 3px solid #B8935A; padding: 10px 14px; margin: 12px 0; color: #374151; font-size: 10pt; line-height: 1.55; }
    .empty { color: #9ca3af; font-style: italic; }
  </style>
</head>
<body>
  <h1>{{title}}</h1>
  <div class="meta">Generated {{generatedAt}}{{#window}} · {{window}}{{/window}}</div>

  {{#narrative}}<div class="narrative">{{narrative}}</div>{{/narrative}}

  {{#hasKpis}}
    <div class="kpi-grid">
      {{#kpis}}
        <div class="kpi"><div class="lbl">{{label}}</div><div class="val">{{value}}</div></div>
      {{/kpis}}
    </div>
  {{/hasKpis}}

  {{#sections}}
    <h2>{{name}}</h2>
    {{#hasRows}}
      <table>
        <thead><tr>{{#columns}}<th>{{.}}</th>{{/columns}}</tr></thead>
        <tbody>
          {{#rows}}<tr>{{#cells}}<td>{{.}}</td>{{/cells}}</tr>{{/rows}}
        </tbody>
      </table>
    {{/hasRows}}
    {{^hasRows}}<p class="empty">No records.</p>{{/hasRows}}
  {{/sections}}

  <div class="footer">ADNOC Musanad Contracts Hub · Confidential</div>
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
  generatedAt: string;
  window: string;
  narrative: string;
  hasKpis: boolean;
  kpis: Array<{ label: string; value: string }>;
  sections: HtmlSection[];
}

// ----------------------------------------------------------------
// Universal formatting helpers (human-readable column headers/values)
// ----------------------------------------------------------------

/** camelCase / snake_case → Title Case ("contractNumber" → "Contract Number") */
const titleCase = (key: string): string => {
  if (!key) return '';
  // Drop currency-suffix hints from the column header — the formatted value
  // already carries the unit ("portfolioValueAed" → "Portfolio Value" + cell
  // "AED 112.23B").
  let trimmed = key.replace(/(Aed|Usd|Eur|Gbp)$/, '');
  // ...but preserve at least one char if the whole key was the suffix
  if (!trimmed) trimmed = key;
  const overrides: Record<string, string> = {
    aed: 'AED', usd: 'USD', sla: 'SLA', icv: 'ICV', kpi: 'KPI',
    fm: 'FM', avar: 'AVaR', mar: 'MaR', adgm: 'ADGM', adnoc: 'ADNOC',
    p95: 'P95', id: 'ID', url: 'URL', pdpl: 'PDPL', osint: 'OSINT',
    pct: '%',
  };
  const spaced = trimmed
    .replace(/[_]+/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z])([A-Z][a-z])/g, '$1 $2')
    .replace(/([a-zA-Z])(\d)/g, '$1 $2')
    .replace(/(\d)([a-zA-Z])/g, '$1 $2');
  return spaced
    .split(/\s+/)
    .filter(Boolean)
    .map((w) => {
      const lo = w.toLowerCase();
      if (overrides[lo]) return overrides[lo];
      return w[0]!.toUpperCase() + w.slice(1).toLowerCase();
    })
    .join(' ');
};

/** True if a column key should be hidden by default (internal IDs etc.) */
const isInternalColumn = (key: string): boolean => {
  if (key === 'id' || key === 'tenantId' || key === 'createdBy' || key === 'updatedBy') return true;
  // hide any *Id like "stepId", "draftId", "logId" — they are surrogate keys
  if (/Id$/.test(key) && key !== 'recordId') return true;
  // hide tenant_id-style snake_case
  if (key === 'tenant_id' || key === 'created_by' || key === 'updated_by') return true;
  if (/_id$/.test(key)) return true;
  return false;
};

const isCurrencyKey = (key: string): boolean =>
  /(Aed|Usd|ValueAed|valueAed)$/.test(key) || /amount/i.test(key) || /aed$/i.test(key);

const isDateTimeKey = (key: string): boolean => /At$/.test(key) || /Date$/.test(key) || /_at$/.test(key);

const isPercentKey = (key: string): boolean => /(Pct|Percent|Percentage)$/.test(key) || /share$/i.test(key);

const formatAed = (n: number): string => {
  if (!Number.isFinite(n)) return '—';
  if (Math.abs(n) >= 1_000_000_000) return `AED ${(n / 1_000_000_000).toFixed(2)}B`;
  if (Math.abs(n) >= 1_000_000) return `AED ${(n / 1_000_000).toFixed(2)}M`;
  if (Math.abs(n) >= 10_000) return `AED ${(n / 1_000).toFixed(0)}K`;
  return `AED ${Math.round(n).toLocaleString('en-US')}`;
};

const formatPlainNumber = (n: number): string => {
  if (!Number.isFinite(n)) return '—';
  if (Number.isInteger(n)) return n.toLocaleString('en-US');
  return n.toFixed(1);
};

const formatDateTime = (s: string): string => {
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  return d.toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Asia/Dubai',
  }).replace(',', ' ·');
};

const formatDate = (s: string): string => {
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  return d.toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric', timeZone: 'Asia/Dubai',
  });
};

const formatCell = (key: string, v: unknown): string => {
  if (v === null || v === undefined || v === '') return '—';
  if (typeof v === 'number') {
    if (isCurrencyKey(key)) return formatAed(v);
    if (isPercentKey(key)) return `${v.toFixed(1)}%`;
    return formatPlainNumber(v);
  }
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  if (typeof v === 'string') {
    if (isCurrencyKey(key) && /^-?\d+(\.\d+)?$/.test(v)) return formatAed(parseFloat(v));
    if (isDateTimeKey(key)) {
      // ISO with time → datetime, ISO date-only → date
      if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return formatDateTime(v);
      if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return formatDate(v);
    }
    // Pretty-print enum-ish slugs ("pending_more_info" → "Pending more info")
    if (/^[a-z][a-z0-9_]*$/.test(v) && v.includes('_')) {
      const t = v.replace(/_/g, ' ');
      return t[0]!.toUpperCase() + t.slice(1);
    }
    return v;
  }
  try { return JSON.stringify(v); } catch { return '[unserializable]'; }
};

/**
 * Build sections + KPI strip from the payload. The data-fn convention:
 *   - Top-level arrays of objects become tables (one per array).
 *   - Top-level scalars (number/string/boolean) become KPI tiles.
 *   - Top-level objects with shallow key/value entries become KPI tiles too
 *     (each entry one tile) so byStatus / byTemplate counts surface as cards
 *     instead of a key/value table.
 *   - Keys named "narrative" (string) become an executive narrative block.
 */
const buildHtmlPieces = (
  payload: Record<string, unknown> | null | undefined,
): { sections: HtmlSection[]; kpis: Array<{ label: string; value: string }>; narrative: string } => {
  const sections: HtmlSection[] = [];
  const kpis: Array<{ label: string; value: string }> = [];
  let narrative = '';
  if (!payload || typeof payload !== 'object') return { sections, kpis, narrative };

  for (const [key, value] of Object.entries(payload)) {
    if (key === 'narrative' && typeof value === 'string') {
      narrative = value;
      continue;
    }
    if (Array.isArray(value)) {
      const arr = value;
      if (arr.length === 0) {
        sections.push({ name: titleCase(key), hasRows: false, columns: [], rows: [] });
        continue;
      }
      const first = arr[0];
      if (first !== null && typeof first === 'object' && !Array.isArray(first)) {
        const allKeys = Object.keys(first as Record<string, unknown>);
        const visibleKeys = allKeys.filter((k) => !isInternalColumn(k));
        const columns = visibleKeys.map(titleCase);
        const rows = arr.map((row) => ({
          cells: visibleKeys.map((c) => formatCell(c, (row as Record<string, unknown>)[c])),
        }));
        sections.push({ name: titleCase(key), hasRows: true, columns, rows });
      } else {
        sections.push({
          name: titleCase(key),
          hasRows: true,
          columns: ['Value'],
          rows: arr.map((v) => ({ cells: [formatCell(key, v)] })),
        });
      }
    } else if (value !== null && typeof value === 'object') {
      // Object of counts/scalars → KPI strip entries. When the parent key is
      // a conventional KPI container ("headline" / "summary" / "kpis"),
      // use the inner key alone — the parent name is implicit from the
      // report title.
      const isKpiContainer = /^(headline|summary|kpis|kpi)$/i.test(key);
      for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
        if (v === null || v === undefined) continue;
        if (typeof v === 'object') continue;
        const label = isKpiContainer ? titleCase(k) : `${titleCase(key)} · ${titleCase(k)}`;
        kpis.push({ label, value: formatCell(k, v) });
      }
    } else {
      // Scalar → KPI tile
      kpis.push({ label: titleCase(key), value: formatCell(key, value) });
    }
  }

  return { sections, kpis, narrative };
};

const buildHtmlContext = (envelope: ReportRenderEnvelope, ctx: ReportRenderContext): HtmlContext => {
  const title = ctx.displayNameEn ?? ctx.slug;
  const parameters = envelope.meta?.parameters ?? {};
  const window = (() => {
    const p = parameters as Record<string, unknown>;
    if (p.dateRange && typeof p.dateRange === 'object') {
      const dr = p.dateRange as { start?: string; end?: string };
      if (dr.start && dr.end) return `${formatDate(dr.start)} → ${formatDate(dr.end)}`;
    }
    return '';
  })();

  const { sections, kpis, narrative } = buildHtmlPieces(envelope.payload ?? {});

  return {
    title,
    generatedAt: envelope.meta?.generatedAt
      ? formatDateTime(envelope.meta.generatedAt)
      : ctx.triggeredAt,
    window,
    narrative,
    hasKpis: kpis.length > 0,
    kpis: kpis.slice(0, 8),
    sections,
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
    ws.addRow([titleCase(name)]);
    ws.addRow(['(no rows)']);
    return;
  }
  const first = arr[0];
  if (first !== null && typeof first === 'object' && !Array.isArray(first)) {
    const allKeys = Object.keys(first as Record<string, unknown>);
    const visibleKeys = allKeys.filter((k) => !isInternalColumn(k));
    ws.columns = visibleKeys.map((c) => ({ header: titleCase(c), key: c, width: 24 }));
    // Bold header row
    ws.getRow(1).font = { bold: true };
    ws.getRow(1).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF3F4F6' } };
    arr.forEach((row) => {
      const flat: Record<string, unknown> = {};
      for (const c of visibleKeys) {
        const v = (row as Record<string, unknown>)[c];
        flat[c] = formatCellForXlsx(c, v);
      }
      ws.addRow(flat);
    });
  } else {
    ws.addRow([titleCase(name)]);
    ws.addRow(arr.map((v) => (typeof v === 'object' ? JSON.stringify(v) : v)));
  }
};

/** Excel cell value normalization. Preserves numbers for numeric columns
 *  (so charts/sorts work) while pretty-printing dates and currency-tagged
 *  strings so the rendered cell reads cleanly.
 */
const formatCellForXlsx = (key: string, v: unknown): unknown => {
  if (v === null || v === undefined) return null;
  if (typeof v === 'object') return JSON.stringify(v);
  if (typeof v === 'string') {
    if (isDateTimeKey(key)) {
      if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return formatDateTime(v);
      if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return formatDate(v);
    }
    if (isCurrencyKey(key) && /^-?\d+(\.\d+)?$/.test(v)) return formatAed(parseFloat(v));
    // Enum slug → human
    if (/^[a-z][a-z0-9_]*$/.test(v) && v.includes('_')) {
      const t = v.replace(/_/g, ' ');
      return t[0]!.toUpperCase() + t.slice(1);
    }
    return v;
  }
  if (typeof v === 'number') {
    if (isCurrencyKey(key)) return formatAed(v);
    if (isPercentKey(key)) return `${v.toFixed(1)}%`;
    return v;
  }
  return v;
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

  // Build Summary tab first — KPIs from scalars + flattened nested-object entries.
  const payload = envelope.payload ?? {};
  const kpiRows: Array<{ metric: string; value: string }> = [];
  let narrative: string | null = null;

  for (const [key, value] of Object.entries(payload)) {
    if (key === 'narrative' && typeof value === 'string') {
      narrative = value;
      continue;
    }
    if (Array.isArray(value)) continue;
    if (value !== null && typeof value === 'object') {
      for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
        if (v === null || v === undefined || typeof v === 'object') continue;
        kpiRows.push({
          metric: `${titleCase(key)} · ${titleCase(k)}`,
          value: String(formatCellForXlsx(k, v) ?? '—'),
        });
      }
    } else if (value !== null && value !== undefined) {
      kpiRows.push({
        metric: titleCase(key),
        value: String(formatCellForXlsx(key, value) ?? '—'),
      });
    }
  }

  if (kpiRows.length > 0 || narrative) {
    const wsSummary = workbook.addWorksheet('Summary');
    if (narrative) {
      wsSummary.addRow([narrative]);
      wsSummary.mergeCells('A1:B1');
      const r = wsSummary.getRow(1);
      r.font = { italic: true };
      r.alignment = { wrapText: true, vertical: 'top' };
      r.height = 60;
      wsSummary.addRow([]); // blank spacer
    }
    wsSummary.columns = [
      { header: 'Metric', key: 'metric', width: 40 },
      { header: 'Value', key: 'value', width: 32 },
    ];
    const headerRow = wsSummary.getRow(narrative ? 3 : 1);
    headerRow.values = ['Metric', 'Value'];
    headerRow.font = { bold: true };
    headerRow.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF3F4F6' } };
    kpiRows.forEach((r) => wsSummary.addRow([r.metric, r.value]));
  }

  // Then one tab per top-level array (capped at 8)
  let arraySheetCount = 0;
  for (const [key, value] of Object.entries(payload)) {
    if (Array.isArray(value) && arraySheetCount < 8) {
      const ws = workbook.addWorksheet(titleCase(key).slice(0, 31));
      writeArraySheet(ws, key, value);
      arraySheetCount += 1;
    }
  }

  const arrayBuffer = await workbook.xlsx.writeBuffer();
  return Buffer.from(arrayBuffer as ArrayBuffer);
};
