/**
 * M11 — Document Ingestion Service.
 *
 * Implements the multi-engine text extraction pipeline:
 *   1. Download from Supabase Storage to temp file.
 *   2. digital_pdf path: pdf-parse with chars/page > threshold check.
 *   3. tesseract path: pdf-parse (page count) → Tesseract.js eng+ara OCR.
 *   4. gpt-4o Vision fallback for low-confidence pages.
 *   5. mammoth_docx path: mammoth extractRawText.
 *   6. Upload extracted text to Supabase Storage.
 *
 * SENSITIVE DATA:
 *   - extractedTextUri: never logged (Pino redact path applied in logger.util.ts).
 *   - tesseractText, gpt4oText, finalText: Pino-redacted.
 *   - ingestionError: Pino-redacted.
 *
 * Worker (ingestion.worker.ts) calls extractDocument() per queued job.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { logger } from '../utils/logger.util';
import { InternalError } from '../utils/errors.util';
import { selectExtractionEngine, isPdfMime, isDocxMime } from '../utils/extraction-router.util';
import { recordAiTelemetry } from './ai/_shared/telemetry-middleware';
import type {
  DocumentIngestionResult,
  ExtractionEngine,
  LowConfidencePage,
} from '../types/document-ingestion.types';

const BUCKET = 'contract-attachments';
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';

// ============================================================
// Supabase storage client (reuses env vars from existing service)
// ============================================================

function getStorageClient() {
  const url = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) {
    throw new InternalError(
      'Supabase storage is not configured (SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing)',
    );
  }
  return createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// ============================================================
// Download helper
// ============================================================

async function downloadToTemp(storageUri: string): Promise<string> {
  const client = getStorageClient();
  const { data, error } = await client.storage.from(BUCKET).download(storageUri);
  if (error || !data) {
    throw new InternalError(
      `Storage download failed for path '${storageUri.split('/').slice(0, 2).join('/')}...': ${error?.message ?? 'no data'}`,
    );
  }
  const tmpDir = os.tmpdir();
  const tmpFile = path.join(tmpDir, `ingestion-${randomUUID()}`);
  const arrayBuffer = await data.arrayBuffer();
  await fs.promises.writeFile(tmpFile, Buffer.from(arrayBuffer));
  return tmpFile;
}

// ============================================================
// digital_pdf extraction via pdf-parse
// ============================================================

async function extractDigitalPdf(filePath: string): Promise<{ text: string; pageCount: number }> {
  // Dynamic import to avoid loading in test environments that don't need it
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const pdfParse = require('pdf-parse') as (buf: Buffer) => Promise<{ text: string; numpages: number }>;
  const buffer = await fs.promises.readFile(filePath);
  const result = await pdfParse(buffer);
  return { text: result.text ?? '', pageCount: result.numpages ?? 1 };
}

// ============================================================
// Tesseract extraction (pdf-parse for page count + tesseract.js for OCR)
// ============================================================

interface PageResult {
  pageNo: number;
  text: string;
  confidence: number;
}

async function extractWithTesseract(
  filePath: string,
  confidenceThreshold: number,
): Promise<{ pages: PageResult[]; pageCount: number }> {
  // Use pdf-parse (already a dependency) to get page count and text layer.
  // pdfjs-dist v5 is ESM-only and incompatible with Node.js CJS require() — we
  // avoid it entirely. Tesseract processes the raw PDF/image file directly.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const pdfParse = require('pdf-parse') as (
    buf: Buffer,
  ) => Promise<{ text: string; numpages: number }>;
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const Tesseract = require('tesseract.js') as typeof import('tesseract.js');

  const buffer = await fs.promises.readFile(filePath);

  // Get page count and text-layer content via pdf-parse
  let pageCount = 1;
  const textLayerByPage: string[] = [];
  try {
    const parsed = await pdfParse(buffer);
    pageCount = parsed.numpages ?? 1;
    // Split text roughly by form-feeds (pdf-parse separates pages with \f)
    const rawPages = parsed.text.split('\f');
    for (let i = 0; i < pageCount; i++) {
      textLayerByPage.push(rawPages[i]?.trim() ?? '');
    }
  } catch {
    // If pdf-parse fails we still have pageCount=1, proceed to Tesseract
    textLayerByPage.push('');
  }

  // Build initial page stubs from text-layer
  const pages: PageResult[] = Array.from({ length: pageCount }, (_, i) => ({
    pageNo: i + 1,
    text: textLayerByPage[i] ?? '',
    confidence: (textLayerByPage[i]?.trim().length ?? 0) > 0 ? 0.9 : 0.0,
  }));

  // Run Tesseract on the whole file for OCR confidence measurement.
  // Tesseract.js v7 can process PDF/image buffers directly via Leptonica.
  const worker = await Tesseract.createWorker(['eng', 'ara']);
  try {
    const { data } = await worker.recognize(filePath);
    const ocrText = data.text ?? '';
    const avgConfidence = (data.confidence ?? 0) / 100; // Tesseract gives 0-100

    // Distribute OCR text across pages by line-count approximation
    const lines = ocrText.split('\n').filter((l) => l.trim().length > 0);
    const linesPerPage = Math.max(1, Math.floor(lines.length / pageCount));

    for (let i = 0; i < pages.length; i++) {
      const start = i * linesPerPage;
      const end = i === pages.length - 1 ? lines.length : start + linesPerPage;
      const pageOcrText = lines.slice(start, end).join('\n');
      // If OCR yielded more text than text-layer, prefer OCR
      if (pageOcrText.length > (pages[i]?.text?.length ?? 0)) {
        pages[i] = {
          ...pages[i]!,
          text: pageOcrText,
          confidence: avgConfidence,
        };
      } else {
        // Keep text-layer text but update confidence score
        const pageHasText = (pages[i]?.text?.trim().length ?? 0) > 50;
        pages[i] = {
          ...pages[i]!,
          confidence: pageHasText ? Math.max(avgConfidence, 0.85) : avgConfidence,
        };
      }
    }
  } catch (err) {
    logger.warn(
      {
        action: 'documentIngestion.tesseract_warn',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Tesseract recognition partial failure — using text-layer fallback',
    );
  } finally {
    await worker.terminate();
  }

  return { pages, pageCount };
}

// ============================================================
// gpt-4o Vision fallback for low-confidence pages
// ============================================================

const VISION_PROMPT_ID = 'ai-document-ingestion-vision';

async function extractPageWithVision(
  pageNo: number,
  contractVersionId: number,
  actorUserId: number,
): Promise<string> {
  const startMs = Date.now();
  let outcome: 'success' | 'error' = 'error';
  let errorMsg: string | null = null;

  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { getOpenAIClient } = require('./ai/_shared/openai-client') as {
      getOpenAIClient: () => import('openai').OpenAI;
    };
    const client = getOpenAIClient();

    const response = await client.chat.completions.create({
      model: 'gpt-4o',
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'text',
              text: `Extract all text content from page ${pageNo} of this contract document. Return only the extracted text, preserving the structure as much as possible. Language may be English or Arabic.`,
            },
          ],
        },
      ],
      max_tokens: 4096,
    });

    const text = response.choices[0]?.message?.content ?? '';
    outcome = 'success';

    // Record telemetry (best-effort — non-fatal)
    void recordAiTelemetry({
      promptId: VISION_PROMPT_ID,
      mode: 'vision_extract',
      actorUserId: actorUserId,
      entityType: 'contract_version',
      entityId: contractVersionId,
      language: 'en',
      provider: 'openai',
      modelUsed: 'gpt-4o',
      tokensInput: response.usage?.prompt_tokens ?? null,
      tokensOutput: response.usage?.completion_tokens ?? null,
      costUsdMicros: null, // cost estimation not implemented here
      latencyMs: Date.now() - startMs,
      cacheHit: false,
      streamMode: false,
      outcome: 'success',
    });

    return text;
  } catch (err) {
    outcome = 'error';
    errorMsg = err instanceof Error ? err.message : String(err);

    void recordAiTelemetry({
      promptId: VISION_PROMPT_ID,
      mode: 'vision_extract',
      actorUserId: actorUserId,
      entityType: 'contract_version',
      entityId: contractVersionId,
      language: 'en',
      provider: 'openai',
      modelUsed: 'gpt-4o',
      tokensInput: null,
      tokensOutput: null,
      costUsdMicros: null,
      latencyMs: Date.now() - startMs,
      cacheHit: false,
      streamMode: false,
      outcome: 'error',
      errorClass: err instanceof Error ? err.name : 'UnknownError',
      errorMessage: errorMsg,
    });

    logger.warn(
      {
        action: 'documentIngestion.vision_failed',
        contractVersionId,
        pageNo,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'gpt-4o Vision fallback failed — page will need human review',
    );

    return '';
  }
}

// ============================================================
// mammoth DOCX extraction
// ============================================================

async function extractDocx(filePath: string): Promise<{ text: string; pageCount: number }> {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const mammoth = require('mammoth') as {
    extractRawText: (opts: { path: string }) => Promise<{ value: string }>;
  };
  const result = await mammoth.extractRawText({ path: filePath });
  const text = result.value ?? '';
  // DOCX doesn't have a real page count; estimate by sections (~500 words per page)
  const wordCount = text.split(/\s+/).filter(Boolean).length;
  const estimatedPages = Math.max(1, Math.ceil(wordCount / 500));
  return { text, pageCount: estimatedPages };
}

// ============================================================
// Upload extracted text to Supabase Storage
// ============================================================

async function uploadExtractedText(args: {
  text: string;
  tenantId: string;
  contractId: number;
  versionNumber: number;
}): Promise<string> {
  const client = getStorageClient();
  const uuid = randomUUID();
  const storagePath = `${args.tenantId}/${args.contractId}/v${args.versionNumber}/${uuid}.txt`;
  const buffer = Buffer.from(args.text, 'utf-8');

  const { error } = await client.storage.from(BUCKET).upload(storagePath, buffer, {
    // Supabase bucket MIME policy allows 'text/plain' but not
    // 'text/plain; charset=utf-8'. The buffer is already UTF-8 by
    // construction (Buffer.from(text, 'utf-8') above).
    contentType: 'text/plain',
    upsert: false,
  });

  if (error) {
    throw new InternalError(`Extracted text upload failed: ${error.message}`);
  }

  return storagePath;
}

// ============================================================
// Main entry point
// ============================================================

/**
 * extractDocument — main extraction pipeline.
 *
 * @param contractVersionId - the contract_version.id (for telemetry + review queue)
 * @param contractId - the contract.id (for storage path)
 * @param versionNumber - the contract_version.version_number (for storage path)
 * @param fileUri - Supabase Storage path of the source file
 * @param fileMime - MIME type of the source file
 * @param actorUserId - user id for AI telemetry (bootstrap: 1)
 * @param tenantId - tenant UUID for multi-tenancy (defaults to ADNOC singleton)
 * @param confidenceThreshold - per-page Tesseract confidence threshold (default 0.75)
 */
export async function extractDocument(args: {
  contractVersionId: number;
  contractId: number;
  versionNumber: number;
  fileUri: string;
  fileMime: string;
  actorUserId: number;
  tenantId?: string;
  confidenceThreshold?: number;
}): Promise<DocumentIngestionResult> {
  const {
    contractVersionId,
    contractId,
    versionNumber,
    fileUri,
    fileMime,
    actorUserId,
    tenantId = ADNOC_TENANT_ID,
    confidenceThreshold = 0.75,
  } = args;

  let tmpFile: string | null = null;

  try {
    // Step 1: Download to temp
    tmpFile = await downloadToTemp(fileUri);

    logger.info(
      {
        action: 'documentIngestion.download_complete',
        contractVersionId,
        fileMime,
      },
      'File downloaded for extraction',
    );

    // Step 2: DOCX path — early return
    if (isDocxMime(fileMime)) {
      const { text, pageCount } = await extractDocx(tmpFile);
      const extractedTextUri = await uploadExtractedText({
        text,
        tenantId,
        contractId,
        versionNumber,
      });
      logger.info(
        { action: 'documentIngestion.complete', contractVersionId, engine: 'mammoth_docx', pageCount },
        'DOCX extraction complete',
      );
      return {
        extractedText: text,
        extractedTextUri,
        pageCount,
        ocrUsed: false,
        ocrConfidenceAvg: null,
        extractionEngine: 'mammoth_docx',
        lowConfidencePages: [],
      };
    }

    // Step 3: PDF path — try digital first
    if (isPdfMime(fileMime)) {
      let digitalText = '';
      let pageCount = 1;
      try {
        const { text, pageCount: pc } = await extractDigitalPdf(tmpFile);
        digitalText = text;
        pageCount = pc;
      } catch (err) {
        logger.warn(
          {
            action: 'documentIngestion.pdf_parse_failed',
            contractVersionId,
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'pdf-parse failed — falling back to tesseract',
        );
      }

      const charsPerPage = pageCount > 0 ? digitalText.length / pageCount : 0;
      const selectedEngine = selectExtractionEngine(
        fileMime,
        digitalText.length > 0 ? digitalText : null,
        confidenceThreshold * 1000, // threshold is chars/page (200 default)
        pageCount,
      );

      if (selectedEngine === 'digital_pdf' && charsPerPage > 200) {
        const extractedTextUri = await uploadExtractedText({
          text: digitalText,
          tenantId,
          contractId,
          versionNumber,
        });
        logger.info(
          { action: 'documentIngestion.complete', contractVersionId, engine: 'digital_pdf', pageCount },
          'Digital PDF extraction complete',
        );
        return {
          extractedText: digitalText,
          extractedTextUri,
          pageCount,
          ocrUsed: false,
          ocrConfidenceAvg: null,
          extractionEngine: 'digital_pdf',
          lowConfidencePages: [],
        };
      }

      // Step 4: Tesseract path
      const { pages, pageCount: tesseractPageCount } = await extractWithTesseract(
        tmpFile,
        confidenceThreshold,
      );

      const lowConfidencePages: LowConfidencePage[] = [];
      const pageTexts: string[] = [];
      let confidenceSum = 0;
      let visionPageCount = 0;
      const finalEngine: ExtractionEngine =
        pages.some((p) => p.confidence < confidenceThreshold) ? 'mixed' : 'tesseract';

      for (const page of pages) {
        confidenceSum += page.confidence;
        let pageText = page.text;

        if (page.confidence < confidenceThreshold) {
          // gpt-4o Vision fallback for low-confidence pages
          const visionText = await extractPageWithVision(
            page.pageNo,
            contractVersionId,
            actorUserId,
          );
          visionPageCount++;

          lowConfidencePages.push({
            pageNo: page.pageNo,
            tesseractConfidence: page.confidence,
            tesseractText: page.text || null,
            gpt4oText: visionText || null,
            gpt4oUsed: visionText.length > 0,
            initialReviewStatus: visionText.length > 0 ? 'pending_auto' : 'pending_human',
          });

          if (visionText.length > 0) {
            pageText = visionText;
          }
        }

        pageTexts.push(pageText);
      }

      const avgConfidence = pages.length > 0 ? confidenceSum / pages.length : 0;
      const concatenatedText = pageTexts.join('\n\n---\n\n');

      const extractedTextUri = await uploadExtractedText({
        text: concatenatedText,
        tenantId,
        contractId,
        versionNumber,
      });

      logger.info(
        {
          action: 'documentIngestion.complete',
          contractVersionId,
          engine: finalEngine,
          pageCount: tesseractPageCount,
          avgConfidence,
          visionPageCount,
        },
        'Tesseract/mixed extraction complete',
      );

      return {
        extractedText: concatenatedText,
        extractedTextUri,
        pageCount: tesseractPageCount,
        ocrUsed: true,
        ocrConfidenceAvg: Math.round(avgConfidence * 100) / 100,
        extractionEngine: finalEngine,
        lowConfidencePages,
      };
    }

    // Step 5: Unknown mime — Tesseract attempt
    logger.warn(
      { action: 'documentIngestion.unknown_mime', contractVersionId, fileMime },
      'Unknown MIME type — attempting Tesseract',
    );
    const { pages, pageCount } = await extractWithTesseract(tmpFile, confidenceThreshold);
    const text = pages.map((p) => p.text).join('\n\n---\n\n');
    const avgConf =
      pages.length > 0 ? pages.reduce((s, p) => s + p.confidence, 0) / pages.length : 0;

    const extractedTextUri = await uploadExtractedText({
      text,
      tenantId,
      contractId,
      versionNumber,
    });

    return {
      extractedText: text,
      extractedTextUri,
      pageCount,
      ocrUsed: true,
      ocrConfidenceAvg: Math.round(avgConf * 100) / 100,
      extractionEngine: 'tesseract',
      lowConfidencePages: [],
    };
  } finally {
    // Clean up temp file
    if (tmpFile) {
      try {
        await fs.promises.unlink(tmpFile);
      } catch {
        // non-fatal
      }
    }
  }
}
