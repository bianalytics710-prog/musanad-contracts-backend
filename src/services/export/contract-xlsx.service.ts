/**
 * Contract XLSX renderer — M1b S5.
 *
 * Receives the JSONB output of fn_contract_export_xlsx and produces an
 * application/vnd.openxmlformats-officedocument.spreadsheetml.sheet Buffer
 * via exceljs WorkbookWriter (memory-bounded streaming pattern).
 *
 * Column layout matches ContractExportXlsxRow plus a Tags CSV column. When
 * the result was truncated by max_rows, an extra footer row is appended
 * ('Result truncated …') AND the controller emits an X-Export-Truncated:true
 * response header (AC-S5-05).
 *
 * body_en / body_ar are EXPLICITLY EXCLUDED — fn_contract_export_xlsx does
 * not return them and we do not synthesise them here (AC-S5-02).
 *
 * Empty filter result → header row only; not an error (AC-S5-07).
 */
import ExcelJS from 'exceljs';
import { PassThrough } from 'node:stream';
import type {
  ContractExportXlsxResponse,
  ContractExportXlsxRow,
} from '../../types/payment-schedule.types';

/**
 * Codex BE-M1b-002 — XLSX formula-injection mitigation.
 *
 * Excel auto-evaluates any cell whose first non-whitespace character is one
 * of `=`, `+`, `-`, or `@` as a formula. A contract title like
 * `=HYPERLINK("https://evil.example/x","click me")` would render as a
 * clickable malicious link in every recipient's spreadsheet.
 *
 * Mitigation: prefix the value with TAB (`\t`). Excel still displays the
 * cell visually identically (the leading whitespace is invisible) but does
 * not interpret the cell as a formula. Numbers, Dates, booleans, and
 * `null`/`undefined` are passed through unchanged so legitimate numeric
 * cells remain numeric (sortable, formattable). Static column headers are
 * not user-controlled and are not routed through this helper.
 */
const FORMULA_PREFIX_RE = /^[=+\-@]/;
export const sanitizeCellValue = (value: unknown): unknown => {
  if (typeof value !== 'string') return value;
  // Trim only for the prefix check — the original (untrimmed) value is what
  // we sanitise so a leading-space-then-`=` is also caught.
  const trimmed = value.replace(/^\s+/, '');
  if (FORMULA_PREFIX_RE.test(trimmed)) return `\t${value}`;
  return value;
};

const COLUMNS: Array<{ header: string; key: keyof ContractExportXlsxRow; width: number }> = [
  { header: 'ID', key: 'id', width: 8 },
  { header: 'Contract #', key: 'contractNumber', width: 20 },
  { header: 'Title (EN)', key: 'titleEn', width: 36 },
  { header: 'Title (AR)', key: 'titleAr', width: 36 },
  { header: 'Type', key: 'contractType', width: 16 },
  { header: 'Status', key: 'status', width: 18 },
  { header: 'Value', key: 'valueAed', width: 14 },
  { header: 'Currency', key: 'currency', width: 10 },
  { header: 'Start Date', key: 'startDate', width: 12 },
  { header: 'End Date', key: 'endDate', width: 12 },
  { header: 'Counterparty ID', key: 'counterpartyId', width: 14 },
  { header: 'Our Party ID', key: 'ourPartyId', width: 14 },
  { header: 'Tags', key: 'tagsCsv', width: 28 },
  { header: 'Version', key: 'currentVersion', width: 9 },
  { header: 'Created At', key: 'createdAt', width: 22 },
  { header: 'Updated At', key: 'updatedAt', width: 22 },
];

const projectRow = (row: ContractExportXlsxRow): Record<string, unknown> => {
  const out: Record<string, unknown> = {};
  for (const col of COLUMNS) {
    const v = row[col.key];
    if (v === null || v === undefined) {
      out[col.key] = '';
      continue;
    }
    // Codex BE-M1b-002: sanitise dynamic string cells against formula
    // injection. Non-strings (numbers, dates) flow through unchanged.
    out[col.key] = sanitizeCellValue(v);
  }
  return out;
};

/**
 * Render a contracts XLSX export. Returns a Buffer of XLSX bytes.
 *
 * Uses exceljs WorkbookWriter with a PassThrough sink so we never hold the
 * whole workbook in memory at once — the writer flushes per row. We collect
 * the stream into a single Buffer at the end for the simplest controller
 * contract; if very large exports become a perf issue, swap to streaming
 * the PassThrough directly into res.
 */
export const renderContractXlsx = async (data: ContractExportXlsxResponse): Promise<Buffer> => {
  const sink = new PassThrough();
  const chunks: Buffer[] = [];
  sink.on('data', (chunk: Buffer | string) => {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  });
  const finished = new Promise<void>((resolve, reject) => {
    sink.on('end', () => resolve());
    sink.on('error', (e) => reject(e));
  });

  const workbook = new ExcelJS.stream.xlsx.WorkbookWriter({
    stream: sink,
    useStyles: true,
    useSharedStrings: true,
  });

  workbook.creator = 'Musanad Contracts Hub';
  workbook.created = new Date();

  const sheet = workbook.addWorksheet('Contracts', {
    views: [{ state: 'frozen', ySplit: 1 }],
  });

  // Header
  sheet.columns = COLUMNS.map((c) => ({ header: c.header, key: c.key, width: c.width }));
  sheet.getRow(1).font = { bold: true };
  sheet.getRow(1).commit();

  // Data rows — streamed
  for (const row of data.rows) {
    sheet.addRow(projectRow(row)).commit();
  }

  // Truncation footer (AC-S5-05)
  if (data.truncated) {
    const footer = sheet.addRow({});
    footer.getCell(1).value =
      `Result truncated at ${data.totalRows} rows. Refine your filters to see the full set.`;
    footer.font = { italic: true, color: { argb: 'FF6B7280' } };
    footer.commit();
  }

  sheet.commit();
  await workbook.commit();

  await finished;
  return Buffer.concat(chunks);
};
