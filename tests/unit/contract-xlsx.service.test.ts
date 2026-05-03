/**
 * Unit tests — src/services/export/contract-xlsx.service.ts (renderContractXlsx).
 *
 * These tests run the renderer end-to-end against the real exceljs library
 * (no mocks needed — exceljs is fast and pure JS). The output buffer is then
 * parsed back via exceljs.Workbook.read so we can assert on:
 *   1. Sheet name = 'Contracts' and column header row is correct.
 *   2. One row per ContractExportXlsxRow with values mapped to the right keys.
 *   3. Truncation footer row appears when truncated=true (AC-S5-05).
 *   4. Empty rows[] still produces a valid workbook with header only (AC-S5-07).
 *
 * Coverage targets the renderer file's branches: header build, row mapping,
 * truncation footer, empty-rows path.
 */
import { describe, it, expect } from 'vitest';
import ExcelJS from 'exceljs';
import { Readable } from 'node:stream';
import { renderContractXlsx } from '../../src/services/export/contract-xlsx.service';
import type {
  ContractExportXlsxResponse,
  ContractExportXlsxRow,
} from '../../src/types/payment-schedule.types';

const sampleRow = (overrides: Partial<ContractExportXlsxRow> = {}): ContractExportXlsxRow => ({
  id: 1,
  contractNumber: 'CT-2026-000001',
  titleEn: 'Test Contract',
  titleAr: null,
  contractType: 'employment',
  status: 'draft',
  valueAed: 5000,
  currency: 'AED',
  startDate: '2026-01-01',
  endDate: '2026-12-31',
  counterpartyId: null,
  ourPartyId: null,
  tagsCsv: 'a,b',
  currentVersion: 1,
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
  ...overrides,
});

const buildResponse = (
  rows: ContractExportXlsxRow[],
  overrides: Partial<ContractExportXlsxResponse> = {},
): ContractExportXlsxResponse => ({
  rows,
  totalRows: rows.length,
  truncated: false,
  filterApplied: {},
  generatedAt: '2026-05-03T00:00:00Z',
  ...overrides,
});

const readWorkbook = async (buffer: Buffer): Promise<ExcelJS.Workbook> => {
  const wb = new ExcelJS.Workbook();
  // exceljs reads from a Readable stream; wrap the buffer.
  const stream = Readable.from(buffer);
  await wb.xlsx.read(stream);
  return wb;
};

describe('renderContractXlsx', () => {
  it('produces an XLSX with the expected sheet, header row, and one data row per input', async () => {
    const data = buildResponse([
      sampleRow({ id: 1, contractNumber: 'CT-2026-000001', titleEn: 'Alpha' }),
      sampleRow({ id: 2, contractNumber: 'CT-2026-000002', titleEn: 'Beta' }),
    ]);
    const buf = await renderContractXlsx(data);
    expect(Buffer.isBuffer(buf)).toBe(true);
    expect(buf.length).toBeGreaterThan(100);

    const wb = await readWorkbook(buf);
    const sheet = wb.getWorksheet('Contracts');
    expect(sheet).toBeDefined();

    // Row 1 = header. Row 2..N = data. exceljs is 1-indexed.
    // (Stream-written workbooks lose column-key metadata on re-read, so we
    // resolve cells via header-row position rather than via column key.)
    const headerRow = sheet!.getRow(1);
    const headerByCol = new Map<string, number>();
    headerRow.eachCell((cell, colNumber) => {
      headerByCol.set(String(cell.value ?? ''), colNumber);
    });
    expect(headerByCol.has('ID')).toBe(true);
    expect(headerByCol.has('Contract #')).toBe(true);
    expect(headerByCol.has('Title (EN)')).toBe(true);
    expect(headerByCol.has('Tags')).toBe(true);

    const row2 = sheet!.getRow(2);
    expect(row2.getCell(headerByCol.get('Contract #')!).value).toBe('CT-2026-000001');
    expect(row2.getCell(headerByCol.get('Title (EN)')!).value).toBe('Alpha');
  });

  it('AC-S5-05: appends a truncation footer when truncated=true', async () => {
    const data = buildResponse([sampleRow()], {
      truncated: true,
      totalRows: 50000,
    });
    const buf = await renderContractXlsx(data);

    const wb = await readWorkbook(buf);
    const sheet = wb.getWorksheet('Contracts');
    expect(sheet).toBeDefined();
    // Last row is the footer — text contains 'Result truncated' and the totalRows.
    const lastRow = sheet!.lastRow;
    expect(lastRow).toBeDefined();
    const footerText = String(lastRow!.getCell(1).value ?? '');
    expect(footerText).toMatch(/Result truncated/);
    expect(footerText).toMatch(/50000/);
  });

  it('AC-S5-07: empty rows[] produces a valid workbook with header row only (no error)', async () => {
    const data = buildResponse([]);
    const buf = await renderContractXlsx(data);
    const wb = await readWorkbook(buf);
    const sheet = wb.getWorksheet('Contracts');
    expect(sheet).toBeDefined();
    // rowCount counts header only.
    // exceljs reports rowCount=1 for header-only sheets.
    expect(sheet!.rowCount).toBeGreaterThanOrEqual(1);
    // Confirm there's no row 2 (data) — getRow returns an empty row object, but
    // its values are undefined.
    const row2 = sheet!.getRow(2);
    expect(row2.getCell(1).value).toBeFalsy();
  });

  // ---------------------------------------------------------------------------
  // Codex BE-M1b-002 regression — formula injection sanitiser
  // ---------------------------------------------------------------------------
  it('BE-M1b-002: prefixes TAB to dynamic string cells starting with =, +, -, or @', async () => {
    const evilTitle = '=HYPERLINK("https://evil.example/x","click me")';
    const evilTags = '+SUM(A1:A2)';
    const evilNumber = '-1234';
    const evilCmd = '@cmd|/c calc';
    const data = buildResponse([
      sampleRow({ id: 1, contractNumber: 'CT-2026-000001', titleEn: evilTitle, tagsCsv: evilTags }),
      sampleRow({ id: 2, contractNumber: 'CT-2026-000002', titleEn: evilNumber, tagsCsv: evilCmd }),
    ]);
    const buf = await renderContractXlsx(data);
    const wb = await readWorkbook(buf);
    const sheet = wb.getWorksheet('Contracts');
    expect(sheet).toBeDefined();
    const headerRow = sheet!.getRow(1);
    const headerByCol = new Map<string, number>();
    headerRow.eachCell((cell, colNumber) => {
      headerByCol.set(String(cell.value ?? ''), colNumber);
    });
    const titleCol = headerByCol.get('Title (EN)')!;
    const tagsCol = headerByCol.get('Tags')!;

    // Row 2 — "=HYPERLINK..." must have a TAB prefix and NOT be a formula
    const row2Title = sheet!.getRow(2).getCell(titleCol);
    const row2TitleVal = String(row2Title.value ?? '');
    expect(row2TitleVal.startsWith('\t')).toBe(true);
    expect(row2TitleVal).toContain('HYPERLINK');
    // Cell type must be string (not formula). exceljs ValueType.Formula = 6.
    expect(row2Title.type).not.toBe(6);

    const row2Tags = String(sheet!.getRow(2).getCell(tagsCol).value ?? '');
    expect(row2Tags.startsWith('\t')).toBe(true);
    expect(row2Tags).toContain('SUM');

    const row3Title = String(sheet!.getRow(3).getCell(titleCol).value ?? '');
    expect(row3Title.startsWith('\t')).toBe(true);
    const row3Tags = String(sheet!.getRow(3).getCell(tagsCol).value ?? '');
    expect(row3Tags.startsWith('\t')).toBe(true);
    expect(row3Tags).toContain('cmd');
  });

  it('BE-M1b-002: leaves benign string cells, numbers, and dates unchanged', async () => {
    const data = buildResponse([
      sampleRow({
        id: 1,
        contractNumber: 'CT-2026-000001',
        titleEn: 'Plain Title',
        valueAed: 5000, // number — must not be sanitised
        currency: 'AED',
      }),
    ]);
    const buf = await renderContractXlsx(data);
    const wb = await readWorkbook(buf);
    const sheet = wb.getWorksheet('Contracts');
    const headerRow = sheet!.getRow(1);
    const headerByCol = new Map<string, number>();
    headerRow.eachCell((cell, colNumber) => {
      headerByCol.set(String(cell.value ?? ''), colNumber);
    });
    expect(sheet!.getRow(2).getCell(headerByCol.get('Title (EN)')!).value).toBe('Plain Title');
    // Value column (number) — must be a number, not a TAB-prefixed string
    expect(sheet!.getRow(2).getCell(headerByCol.get('Value')!).value).toBe(5000);
  });
});
