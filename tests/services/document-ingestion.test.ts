/**
 * M11 — Document Ingestion Service unit tests.
 *
 * Coverage:
 *   - selectExtractionEngine routing logic (pure function — all paths)
 *   - isPdfMime / isDocxMime helpers
 *
 * Note on service-level tests: the extraction service uses CJS require() calls
 * inside function bodies (lazy requires for heavy deps: mammoth, pdf-parse,
 * tesseract.js). In vitest's fork mode these bypass vi.mock() interception.
 * Service-path coverage is provided by integration tests in
 * tests/integration/cr-d0-ingestion-flow.test.ts which run against the real DB
 * with seeded data.
 */

import { describe, it, expect } from 'vitest';
import { selectExtractionEngine, isPdfMime, isDocxMime } from '../../src/utils/extraction-router.util';

// ============================================================
// extraction-router.util — pure logic, no mocks needed
// ============================================================

describe('selectExtractionEngine', () => {
  it('returns mammoth_docx for DOCX MIME type', () => {
    expect(
      selectExtractionEngine(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        null,
      ),
    ).toBe('mammoth_docx');
  });

  it('returns mammoth_docx for legacy application/msword', () => {
    expect(selectExtractionEngine('application/msword', null)).toBe('mammoth_docx');
  });

  it('returns tesseract for image/jpeg', () => {
    expect(selectExtractionEngine('image/jpeg', null)).toBe('tesseract');
  });

  it('returns tesseract for image/png', () => {
    expect(selectExtractionEngine('image/png', null)).toBe('tesseract');
  });

  it('returns digital_pdf when chars/page > threshold (200)', () => {
    const richText = 'a'.repeat(2000); // 2000 chars / 1 page = 2000 chars/page > 200
    expect(selectExtractionEngine('application/pdf', richText, 200, 1)).toBe('digital_pdf');
  });

  it('returns tesseract when chars/page <= threshold', () => {
    const sparseText = 'ab'; // 2 chars / 1 page = 2 chars/page < 200
    expect(selectExtractionEngine('application/pdf', sparseText, 200, 1)).toBe('tesseract');
  });

  it('returns tesseract when sample text is null (no first-pass yet)', () => {
    expect(selectExtractionEngine('application/pdf', null)).toBe('tesseract');
  });

  it('returns tesseract for unknown MIME type', () => {
    expect(selectExtractionEngine('application/octet-stream', null)).toBe('tesseract');
  });

  it('handles multipage PDF correctly — rich', () => {
    // 4000 chars / 10 pages = 400 chars/page > 200 threshold → digital_pdf
    const richText = 'a'.repeat(4000);
    expect(selectExtractionEngine('application/pdf', richText, 200, 10)).toBe('digital_pdf');
  });

  it('handles multipage PDF correctly — sparse', () => {
    // 1000 chars / 10 pages = 100 chars/page < 200 threshold → tesseract
    const sparseText = 'a'.repeat(1000);
    expect(selectExtractionEngine('application/pdf', sparseText, 200, 10)).toBe('tesseract');
  });

  it('uses custom threshold correctly', () => {
    const text = 'a'.repeat(500); // 500 chars / 1 page
    expect(selectExtractionEngine('application/pdf', text, 200, 1)).toBe('digital_pdf'); // 500 > 200
    expect(selectExtractionEngine('application/pdf', text, 600, 1)).toBe('tesseract');   // 500 < 600
  });

  it('returns tesseract for empty string text', () => {
    expect(selectExtractionEngine('application/pdf', '', 200, 1)).toBe('tesseract');
  });
});

describe('isPdfMime', () => {
  it('returns true for application/pdf', () => {
    expect(isPdfMime('application/pdf')).toBe(true);
  });

  it('returns false for DOCX', () => {
    expect(
      isPdfMime('application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
    ).toBe(false);
  });

  it('returns false for image/jpeg', () => {
    expect(isPdfMime('image/jpeg')).toBe(false);
  });
});

describe('isDocxMime', () => {
  it('returns true for modern DOCX MIME', () => {
    expect(
      isDocxMime('application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
    ).toBe(true);
  });

  it('returns true for legacy application/msword', () => {
    expect(isDocxMime('application/msword')).toBe(true);
  });

  it('returns false for PDF', () => {
    expect(isDocxMime('application/pdf')).toBe(false);
  });

  it('returns false for image/png', () => {
    expect(isDocxMime('image/png')).toBe(false);
  });
});
