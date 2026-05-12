/**
 * M11 — Extraction engine router.
 *
 * Given a file's mime-type (and optionally sample text), returns the
 * extraction engine to use for text extraction.
 *
 * Engine selection rules:
 *   1. DOCX → mammoth_docx (regardless of sample text)
 *   2. PDF → try digital_pdf first; if sample text is present and
 *      chars/page > threshold → digital_pdf
 *   3. PDF with insufficient text → tesseract (with gpt-4o Vision
 *      fallback for low-confidence pages inside the service)
 *   4. Images (jpeg/png/tiff/webp) → tesseract directly
 *   5. Unknown → tesseract as safe default
 *
 * The returned engine is the INITIAL engine. The service may switch
 * individual pages to gpt4o_vision if Tesseract confidence < threshold,
 * producing an overall engine of 'mixed'.
 */

import type { ExtractionEngine } from '../types/document-ingestion.types';

/**
 * DOCX mime types — canonical + legacy aliases.
 */
const DOCX_MIMES = new Set([
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/msword',
  'application/vnd.ms-word.document.macroEnabled.12',
]);

const PDF_MIMES = new Set([
  'application/pdf',
  'application/x-pdf',
  'application/acrobat',
]);

const IMAGE_MIMES = new Set([
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/tiff',
  'image/webp',
  'image/bmp',
  'image/gif',
]);

/**
 * Minimum chars per page to trust a digital PDF extraction.
 * Default is 200 per page (Q2 threshold; system_setting 'ocr.confidence_threshold').
 */
const DIGITAL_CHARS_PER_PAGE_MIN = 200;

/**
 * selectExtractionEngine — choose the initial extraction engine.
 *
 * @param fileMime - MIME type of the file
 * @param sampleText - optional: pre-extracted text sample (from pdf-parse first-pass).
 *                    When non-null, used to decide digital vs tesseract for PDFs.
 * @param threshold - chars per page minimum for digital PDF trust (default 200)
 * @param pageCount - estimated page count (default 1 if unknown)
 * @returns ExtractionEngine to use for the primary extraction pass
 */
export function selectExtractionEngine(
  fileMime: string,
  sampleText: string | null,
  threshold: number = DIGITAL_CHARS_PER_PAGE_MIN,
  pageCount: number = 1,
): ExtractionEngine {
  const mime = fileMime.toLowerCase().trim();

  // 1. DOCX path
  if (DOCX_MIMES.has(mime)) {
    return 'mammoth_docx';
  }

  // 2. Image path → tesseract directly
  if (IMAGE_MIMES.has(mime)) {
    return 'tesseract';
  }

  // 3. PDF path
  if (PDF_MIMES.has(mime)) {
    if (sampleText !== null) {
      // We already have a first-pass result from pdf-parse.
      const charsPerPage =
        pageCount > 0 ? sampleText.length / pageCount : sampleText.length;
      if (charsPerPage > threshold) {
        return 'digital_pdf';
      }
      // Not enough digital text → fall through to tesseract
      return 'tesseract';
    }
    // No sample text yet → caller should run pdf-parse first, then re-call.
    // Return tesseract as a conservative default — the service layer handles
    // the pdf-parse first-pass before calling this function.
    return 'tesseract';
  }

  // 4. Unknown mime — tesseract as safe default
  return 'tesseract';
}

/**
 * isPdfMime — convenience predicate used by the service layer to decide
 * whether to attempt pdf-parse first.
 */
export function isPdfMime(fileMime: string): boolean {
  return PDF_MIMES.has(fileMime.toLowerCase().trim());
}

/**
 * isDocxMime — convenience predicate.
 */
export function isDocxMime(fileMime: string): boolean {
  return DOCX_MIMES.has(fileMime.toLowerCase().trim());
}
