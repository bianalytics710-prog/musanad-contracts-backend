/**
 * M22 / CR-MIG-DRIVE — migration orchestrator.
 *
 * Responsibilities (Phase 1 = Google Drive only):
 *   1. triggerSync()  — create migration_batch row (queued) + return id.
 *   2. processBatch() — worker entry: discover Drive files, dedup, download,
 *                       ingest via M11, link contract back to record.
 *   3. rollback()     — DB fn delegate.
 *   4. purgeAll()     — DB fn delegate (preview / execute paths).
 *
 * Sensitive surface: never log file bodies, decrypted tokens, or contract
 * extracted text. All such data goes through Pino-redacted paths.
 */
import { createHash, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { db } from '../database/client';
import { pool } from '../database/config';
import { logger } from '../utils/logger.util';
import { InternalError } from '../utils/errors.util';
import { decryptToken, encryptToken } from './token-cipher.service';
import {
  listFiles,
  downloadFile,
  refreshAccessToken,
  type DriveFileMeta,
} from './google-drive.service';
import { extractDocument } from './document-ingestion.service';
import { getOpenAIClient } from './ai/_shared/openai-client';

const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const BUCKET = 'contract-attachments';
const MIGRATION_STAGING_PREFIX = 'migration-staging';

// ----------------------------------------------------------------
// Trigger sync — creates the batch row, returns id, doesn't block
// ----------------------------------------------------------------

export async function triggerSync(args: {
  connectionId: number;
  actorId: number;
  tenantId?: string;
}): Promise<number> {
  const tenantId = args.tenantId ?? ADNOC_TENANT_ID;
  const batchId = await db.callFunction<number>(
    'fn_migration_batch_create',
    [args.connectionId, args.actorId, 'manual'],
    { actorId: args.actorId, tenantId },
  );
  logger.info(
    { action: 'migration.triggerSync', batchId, connectionId: args.connectionId },
    'Migration batch queued',
  );
  return batchId;
}

// ----------------------------------------------------------------
// Worker — runs against a single batch
// ----------------------------------------------------------------

interface BatchContext {
  batchId: number;
  tenantId: string;
  connectionId: number;
  accessToken: string;
  refreshToken: string | null;
  expiresAt: Date;
  folderId: string;
  actorId: number | null;
  /** Per-batch party-name → party_id cache so we don't re-create the same
   *  party for every file imported in a sync run. */
  partyCache: Map<string, number>;
}

async function loadBatchContext(batchId: number, tenantId: string): Promise<BatchContext> {
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    const r = await client.query<{
      external_connection_id: string;
      triggered_by_user_id: string | null;
    }>(
      `SELECT external_connection_id, triggered_by_user_id
       FROM migration_batch WHERE id = $1 AND tenant_id = $2`,
      [batchId, tenantId],
    );
    if (r.rowCount === 0) {
      throw new InternalError(`migration_batch ${batchId} not found`);
    }
    const connId = Number(r.rows[0].external_connection_id);
    const tokenRow = await client.query<{ result: Record<string, unknown> }>(
      `SELECT fn_external_connection_get_tokens($1::bigint, $2::uuid) AS result`,
      [connId, tenantId],
    );
    const t = tokenRow.rows[0]?.result;
    if (!t) throw new InternalError(`Cannot load tokens for connection ${connId}`);
    const access = decryptToken(String(t.oauthAccessTokenEncrypted));
    const refresh = t.oauthRefreshTokenEncrypted
      ? decryptToken(String(t.oauthRefreshTokenEncrypted))
      : null;
    await client.query('COMMIT');
    return {
      batchId,
      tenantId,
      connectionId: connId,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: new Date(String(t.oauthExpiresAt)),
      folderId: String(t.sourceResourceId),
      actorId: r.rows[0].triggered_by_user_id ? Number(r.rows[0].triggered_by_user_id) : null,
      partyCache: new Map<string, number>(),
    };
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* ignore */ }
    throw err;
  } finally {
    client.release();
  }
}

async function ensureFreshToken(ctx: BatchContext): Promise<string> {
  if (ctx.expiresAt.getTime() > Date.now() + 60_000) return ctx.accessToken;
  if (!ctx.refreshToken) {
    throw new InternalError('Token expired and no refresh token available — reconnect required');
  }
  const refreshed = await refreshAccessToken(ctx.refreshToken);
  ctx.accessToken = refreshed.accessToken;
  ctx.expiresAt = refreshed.expiresAt;
  await db.callFunction<void>(
    'fn_external_connection_update_tokens',
    [ctx.connectionId, ctx.tenantId, encryptToken(refreshed.accessToken), refreshed.expiresAt],
    { actorId: ctx.actorId ?? undefined, tenantId: ctx.tenantId },
  );
  return ctx.accessToken;
}

function supabase() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new InternalError('Supabase not configured — M22 storage staging requires it');
  }
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function stageBufferToSupabase(args: {
  tenantId: string;
  buffer: Buffer;
  mime: string;
  originalName: string;
}): Promise<string> {
  const safeExt = args.originalName.split('.').pop()?.replace(/[^a-z0-9]/gi, '').slice(0, 6) || 'bin';
  const path = `${MIGRATION_STAGING_PREFIX}/${args.tenantId}/${randomUUID()}.${safeExt}`;
  const c = supabase();
  const { error } = await c.storage.from(BUCKET).upload(path, args.buffer, {
    contentType: args.mime,
    upsert: false,
  });
  if (error) throw new InternalError(`Supabase upload failed: ${error.message}`);
  return path;
}

interface ExtractedFields {
  titleEn: string | null;
  contractType: string | null;
  counterpartyName: string | null;
  valueAed: number | null;
  startDate: string | null;
  endDate: string | null;
  language: string;
}

/**
 * Light-weight structured-field extraction from the OCR text. Uses simple
 * regex/heuristics; sets confidence accordingly. A future iteration can
 * swap this for an LLM tool-call against the M11 extracted text.
 */
function heuristicExtractFields(text: string, sourceFileName: string): ExtractedFields {
  const titleFromFile = sourceFileName
    .replace(/\.[a-z0-9]{1,6}$/i, '')
    .replace(/[_-]+/g, ' ')
    .trim();
  const titleEn = titleFromFile.length > 0 ? titleFromFile.substring(0, 200) : null;

  const isArabic = /[؀-ۿ]/.test(text);
  const language = isArabic && /[a-zA-Z]/.test(text) ? 'bilingual' : isArabic ? 'ar' : 'en';

  // Counterparty: look for "between X and Y" pattern
  const partyMatch = text.match(/between\s+([A-Z][A-Za-z &.\-,]{2,80})\s+and\s+([A-Z][A-Za-z &.\-,]{2,80})/);
  const counterpartyName = partyMatch?.[2]?.replace(/[.,]$/, '').trim() ?? null;

  // Value: first AED-prefixed amount over 1000
  const valueMatch = text.match(/AED\s*([\d,]+(?:\.\d{1,2})?)/i);
  const valueRaw = valueMatch?.[1]?.replace(/,/g, '');
  const valueAed = valueRaw && Number(valueRaw) >= 1000 ? Number(valueRaw) : null;

  // Dates: ISO YYYY-MM-DD anywhere
  const dateMatches = Array.from(text.matchAll(/(\d{4}-\d{2}-\d{2})/g)).map((m) => m[1]);
  const startDate = dateMatches[0] ?? null;
  const endDate = dateMatches[1] ?? null;

  // Type: keywords. Must stay inside the contract.chk_contract_contract_type
  // enum: services / epc / gas_spa / concession / term_sale / spot_purchase /
  // vessel_charter / master_services / employment / consultancy / advisory /
  // nda / sow / supply. No 'lease' allowed — map to 'services'.
  const lower = text.toLowerCase();
  const contractType =
    lower.includes('master services') ? 'master_services' :
    lower.includes('non-disclosure') || lower.includes('nda') ? 'nda' :
    lower.includes('employment') ? 'employment' :
    lower.includes('consultancy') || lower.includes('consulting') ? 'consultancy' :
    lower.includes('statement of work') || lower.includes(' sow ') ? 'sow' :
    lower.includes(' epc ') || lower.includes('engineering procurement construction') ? 'epc' :
    lower.includes('gas sales') || lower.includes('gas spa') ? 'gas_spa' :
    lower.includes('concession') ? 'concession' :
    lower.includes('vessel') || lower.includes('charter party') ? 'vessel_charter' :
    lower.includes('supply') ? 'supply' :
    'services';

  return { titleEn, contractType, counterpartyName, valueAed, startDate, endDate, language };
}

/**
 * LLM-based structured-field extractor. Runs against the M11-extracted text
 * and asks gpt-4o-mini to return a typed JSON object. Falls back to NULL
 * fields on any error (caller defaults to heuristic). Bounded to first 12K
 * chars of body to stay inside a small prompt.
 */
async function llmExtractFields(args: {
  text: string;
  sourceFileName: string;
}): Promise<Partial<ExtractedFields> & { ourPartyName?: string | null }> {
  const client = getOpenAIClient();
  const slice = (args.text || '').substring(0, 12_000);
  const systemPrompt = [
    'You extract structured contract metadata from raw text.',
    'Output a JSON object with these keys (use null if unknown):',
    '  titleEn (short business title; max 200 chars)',
    '  contractType (one of: services|epc|gas_spa|concession|term_sale|spot_purchase|vessel_charter|master_services|employment|consultancy|advisory|nda|sow|supply)',
    '  ourPartyName (the ADNOC-side party / OqoodAI / our internal counterparty)',
    '  counterpartyName (the external counterparty)',
    '  valueAed (numeric value of the contract in AED; 0 if not stated)',
    '  startDate (YYYY-MM-DD; null if unknown)',
    '  endDate (YYYY-MM-DD; null if unknown)',
    '  governingLaw (one of: uae_federal|adgm|difc|english|new_york|singapore|null)',
    '  emirate (one of: abu_dhabi|dubai|sharjah|ajman|fujairah|ras_al_khaimah|umm_al_quwain|null)',
    'Return ONLY a JSON object — no prose.',
  ].join('\n');
  let parsed: Record<string, unknown> = {};
  try {
    const r = await client.chat.completions.create({
      model: process.env.OPENAI_MODEL_FAST || 'gpt-4o-mini',
      temperature: 0,
      max_tokens: 600,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: systemPrompt },
        {
          role: 'user',
          content: `Source filename: ${args.sourceFileName}\n\nContract text:\n\`\`\`\n${slice}\n\`\`\``,
        },
      ],
    });
    const content = r.choices[0]?.message?.content ?? '{}';
    parsed = JSON.parse(content);
  } catch (err) {
    logger.warn(
      { action: 'migration.llm.extractFailed', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'LLM field extraction failed — falling back to heuristic',
    );
    return {};
  }

  // Sanitise into the orchestrator's expected shape
  const allowedType = new Set([
    'services','epc','gas_spa','concession','term_sale','spot_purchase',
    'vessel_charter','master_services','employment','consultancy','advisory',
    'nda','sow','supply',
  ]);
  const isoDate = (v: unknown): string | null =>
    typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
  const num = (v: unknown): number | null => {
    if (typeof v === 'number' && Number.isFinite(v) && v >= 1000) return v;
    if (typeof v === 'string') {
      const n = Number(v.replace(/[,_\s]/g, ''));
      if (Number.isFinite(n) && n >= 1000) return n;
    }
    return null;
  };
  const str = (v: unknown, max = 200): string | null =>
    typeof v === 'string' && v.trim().length > 0 ? v.trim().substring(0, max) : null;

  const typeRaw = String(parsed['contractType'] ?? '').toLowerCase();
  return {
    titleEn: str(parsed['titleEn']),
    contractType: allowedType.has(typeRaw) ? typeRaw : null,
    counterpartyName: str(parsed['counterpartyName']),
    ourPartyName: str(parsed['ourPartyName']),
    valueAed: num(parsed['valueAed']),
    startDate: isoDate(parsed['startDate']),
    endDate: isoDate(parsed['endDate']),
  };
}

/**
 * Find or create a party by display name. Returns party id.
 * Caches lookups within a single batch run via the passed Map.
 */
async function findOrCreateParty(args: {
  name: string;
  actorId: number;
  tenantId: string;
  cache: Map<string, number>;
}): Promise<number | null> {
  const cleaned = args.name?.trim();
  if (!cleaned) return null;
  const cached = args.cache.get(cleaned.toLowerCase());
  if (cached) return cached;
  // 1. Try exact-name lookup
  const exact = await pool().query<{ id: string }>(
    `SELECT id FROM party WHERE lower(name_en) = lower($1) AND is_active = TRUE LIMIT 1`,
    [cleaned],
  );
  if ((exact.rowCount ?? 0) > 0) {
    const id = Number(exact.rows[0].id);
    args.cache.set(cleaned.toLowerCase(), id);
    return id;
  }
  // 2. Create via fn_party_create — minimal payload (corporate, name only)
  try {
    // fn_party_create returns JSONB (full party via fn_party_get_by_id), not a raw id.
    const created = await db.callFunction<{ id?: number | string } | null>(
      'fn_party_create',
      [
        args.actorId, 'company', cleaned, null, null, null, null, null,
        'United Arab Emirates', null, null, null, 'Created during M22 migration import',
      ],
      { actorId: args.actorId, tenantId: args.tenantId },
    );
    const numId = Number(created?.id);
    if (!Number.isFinite(numId)) return null;
    args.cache.set(cleaned.toLowerCase(), numId);
    return numId;
  } catch (err) {
    logger.warn(
      {
        action: 'migration.party.createFailed',
        name: cleaned.substring(0, 50),
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Party create failed — leaving unbound',
    );
    return null;
  }
}

/** Average confidence: heuristic — 90 for digital PDF, 70 for OCR, 60 if mostly empty. */
function avgConfidence(args: {
  textLen: number;
  pageCount: number;
  ocrUsed: boolean;
  ocrConfidenceAvg: number | null;
}): number {
  if (args.ocrUsed) {
    return args.ocrConfidenceAvg != null
      ? Math.round(Math.min(95, Math.max(40, args.ocrConfidenceAvg * 100)))
      : 70;
  }
  const charsPerPage = args.pageCount > 0 ? args.textLen / args.pageCount : 0;
  if (charsPerPage < 100) return 50;
  if (charsPerPage > 500) return 92;
  return 80;
}

async function getConfidenceThreshold(): Promise<number> {
  try {
    const r = await pool().query<{ value: { threshold?: number } }>(
      `SELECT value FROM system_setting WHERE key='migration.confidence_threshold' AND is_active = TRUE LIMIT 1`,
    );
    const t = r.rows[0]?.value?.threshold;
    return typeof t === 'number' ? t : 80;
  } catch {
    return 80;
  }
}

/**
 * Process a single batch end-to-end. Idempotent: re-running on a partially-
 * complete batch picks up where it left off (records in `discovered` state).
 */
export async function processBatch(args: {
  batchId: number;
  tenantId?: string;
}): Promise<{ imported: number; review: number; failed: number; skipped: number }> {
  const tenantId = args.tenantId ?? ADNOC_TENANT_ID;
  const ctx = await loadBatchContext(args.batchId, tenantId);

  let imported = 0, review = 0, failed = 0, skipped = 0;

  try {
    await db.callFunction<void>(
      'fn_migration_batch_set_status',
      [ctx.batchId, tenantId, 'in_progress'],
      { actorId: ctx.actorId ?? undefined, tenantId },
    );

    const accessToken = await ensureFreshToken(ctx);
    const driveFiles = await listFiles({ accessToken, folderId: ctx.folderId });
    logger.info(
      { action: 'migration.discovered', batchId: ctx.batchId, files: driveFiles.length },
      'Drive files discovered',
    );
    await db.callFunction<void>(
      'fn_migration_batch_update_counts',
      [ctx.batchId, tenantId, driveFiles.length, null, null, null, null],
      { actorId: ctx.actorId ?? undefined, tenantId },
    );

    // Phase A: register every file as a migration_record (idempotent upsert).
    // BIGINT round-trip — pg returns BIGINT as a string by default; coerce
    // to number so the !== recordId guard in processSingleFile compares
    // apples to apples with the JSONB-decoded duplicateOfRecordId.
    const recordMap = new Map<string, number>();
    for (const f of driveFiles) {
      const recId = await db.callFunction<number | string>(
        'fn_migration_record_create',
        [
          ctx.batchId, tenantId,
          f.id, f.name, f.mimeType, f.size, new Date(f.modifiedTime),
        ],
        { actorId: ctx.actorId ?? undefined, tenantId },
      );
      recordMap.set(f.id, Number(recId));
    }

    const threshold = await getConfidenceThreshold();

    // Phase B: per-file pipeline
    for (const f of driveFiles) {
      const recordId = recordMap.get(f.id);
      if (!recordId) continue;
      try {
        await processSingleFile({
          ctx, file: f, recordId, threshold,
          onImported: () => { imported += 1; },
          onReview:   () => { review += 1; },
          onFailed:   () => { failed += 1; },
          onSkipped:  () => { skipped += 1; },
        });
      } catch (err) {
        failed += 1;
        logger.error(
          {
            action: 'migration.file.failed',
            batchId: ctx.batchId, recordId,
            errorType: err instanceof Error ? err.name : 'UNKNOWN',
          },
          'Per-file pipeline failure',
        );
        await db.callFunction<void>(
          'fn_migration_record_update_status',
          [recordId, tenantId, 'failed', err instanceof Error ? err.message.slice(0, 500) : 'unknown'],
          { actorId: ctx.actorId ?? undefined, tenantId },
        );
      }
      // running tally so the FE progress poll shows movement
      await db.callFunction<void>(
        'fn_migration_batch_update_counts',
        [ctx.batchId, tenantId, null, imported, review, failed, skipped],
        { actorId: ctx.actorId ?? undefined, tenantId },
      );
    }

    // Final status
    const finalStatus = failed > 0 ? 'completed_with_errors' : 'completed';
    await db.callFunction<void>(
      'fn_migration_batch_set_status',
      [ctx.batchId, tenantId, finalStatus],
      { actorId: ctx.actorId ?? undefined, tenantId },
    );

    // Update connection last_synced_at
    await pool().query(
      `UPDATE external_connection SET last_synced_at = now() WHERE id = $1 AND tenant_id = $2`,
      [ctx.connectionId, tenantId],
    );

    logger.info(
      { action: 'migration.batch.done', batchId: ctx.batchId, imported, review, failed, skipped },
      'Migration batch complete',
    );
    return { imported, review, failed, skipped };
  } catch (err) {
    logger.error(
      {
        action: 'migration.batch.failed', batchId: ctx.batchId,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Migration batch fatal',
    );
    await db.callFunction<void>(
      'fn_migration_batch_set_status',
      [ctx.batchId, tenantId, 'failed'],
      { actorId: ctx.actorId ?? undefined, tenantId },
    );
    throw err;
  }
}

interface SingleFileArgs {
  ctx: BatchContext;
  file: DriveFileMeta;
  recordId: number;
  threshold: number;
  onImported: () => void;
  onReview: () => void;
  onFailed: () => void;
  onSkipped: () => void;
}

async function processSingleFile(args: SingleFileArgs): Promise<void> {
  const { ctx, file, recordId, threshold } = args;
  const tenantId = ctx.tenantId;
  const opts = { actorId: ctx.actorId ?? undefined, tenantId };

  // Level 1 dedup: source-file-ID
  const dupL1 = await db.callFunction<{ duplicateKind: string; duplicateOfRecordId: number | null }>(
    'fn_migration_record_check_duplicates',
    [ctx.connectionId, file.id, null],
    opts,
  );
  if (dupL1.duplicateKind === 'id_match' && Number(dupL1.duplicateOfRecordId) !== Number(recordId)) {
    await db.callFunction<void>(
      'fn_migration_record_mark_duplicate',
      [recordId, tenantId, 'skipped_duplicate_id', dupL1.duplicateOfRecordId],
      opts,
    );
    args.onSkipped();
    return;
  }

  // Phase: downloading
  await db.callFunction<void>(
    'fn_migration_record_update_status',
    [recordId, tenantId, 'downloading', null],
    opts,
  );
  const accessToken = await ensureFreshToken(ctx);
  const buf = await downloadFile({ accessToken, fileId: file.id });
  const sha256 = createHash('sha256').update(buf).digest('hex');
  await db.callFunction<void>(
    'fn_migration_record_set_sha256',
    [recordId, tenantId, sha256],
    opts,
  );

  // Level 2 dedup: SHA-256 content hash
  const dupL2 = await db.callFunction<{ duplicateKind: string; duplicateOfRecordId: number | null }>(
    'fn_migration_record_check_duplicates',
    [ctx.connectionId, file.id, sha256],
    opts,
  );
  if (dupL2.duplicateKind === 'hash_match' && Number(dupL2.duplicateOfRecordId) !== Number(recordId)) {
    await db.callFunction<void>(
      'fn_migration_record_mark_duplicate',
      [recordId, tenantId, 'skipped_duplicate_hash', dupL2.duplicateOfRecordId],
      opts,
    );
    args.onSkipped();
    return;
  }

  // Ingesting: stage to Supabase, create contract + contract_version,
  // call M11 extractDocument.
  await db.callFunction<void>(
    'fn_migration_record_update_status',
    [recordId, tenantId, 'ingesting', null],
    opts,
  );

  const storageUri = await stageBufferToSupabase({
    tenantId, buffer: buf, mime: file.mimeType, originalName: file.name,
  });

  // Create minimal contract + version rows.
  // data_classification = 'production' (contract + contract_version CHECK
  // constraints accept only 'demo' | 'pilot' | 'production').
  // contract_version has chk_contract_version_body_present requiring
  // body_en OR body_ar to be NOT NULL at INSERT. We seed body_en with
  // an explicit placeholder so the row is creatable; the post-extraction
  // UPDATE overwrites it with the OCR'd text.
  const created = await pool().query<{ contract_id: string; version_id: string }>(
    `WITH ins_c AS (
       INSERT INTO contract (
         contract_number, title_en, contract_type, language, status,
         created_by, updated_by, is_active, data_classification
       ) VALUES (
         'MIG-' || nextval('contract_id_seq')::text,
         $1, 'services', 'en', 'draft',
         $2, $2, TRUE, 'production'
       ) RETURNING id
     ),
     ins_v AS (
       INSERT INTO contract_version (
         contract_id, version_number, body_en, ingestion_status, is_active,
         data_classification, created_by, changed_by
       )
       SELECT id, 1, '[Migration: extraction in progress]', 'pending',
              TRUE, 'production', $2, $2 FROM ins_c
       RETURNING id, contract_id
     )
     SELECT contract_id::text, id::text AS version_id FROM ins_v`,
    [file.name.substring(0, 200), ctx.actorId ?? null],
  );
  const contractId = Number(created.rows[0].contract_id);
  const versionId = Number(created.rows[0].version_id);

  let extractedText = '';
  let pageCount = 0;
  let ocrUsed = false;
  let ocrConfAvg: number | null = null;
  try {
    const r = await extractDocument({
      contractVersionId: versionId,
      contractId,
      versionNumber: 1,
      fileUri: storageUri,
      fileMime: file.mimeType,
      actorUserId: ctx.actorId ?? 0,
      tenantId,
    });
    extractedText = r.extractedText;
    pageCount = r.pageCount;
    ocrUsed = r.ocrUsed;
    ocrConfAvg = r.ocrConfidenceAvg;
  } catch (err) {
    logger.warn(
      { action: 'migration.extract.failed', recordId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'extractDocument failed — record marked failed',
    );
    await db.callFunction<void>(
      'fn_migration_record_update_status',
      [recordId, tenantId, 'failed', err instanceof Error ? err.message.slice(0, 500) : 'unknown'],
      opts,
    );
    args.onFailed();
    return;
  }

  // 1) Persist body_en on the version. ingestion_status stays 'pending' for
  //    a moment so fn_contract_version_ingestion_complete can transition it.
  //    The body_en is the SOT for the Extracted-text view + clause extractor.
  await pool().query(
    `UPDATE contract_version
        SET body_en = $1,
            page_count = $2,
            ocr_used = $3,
            ocr_confidence_avg = $4
      WHERE id = $5`,
    [extractedText.substring(0, 200_000), pageCount, ocrUsed, ocrConfAvg, versionId],
  );

  // 2) Upload the EXTRACTED TEXT to Supabase so the FE Document tab can
  //    render the "Extracted text" view (it reads contract_version.extracted_text_uri).
  let extractedTextUri: string | null = null;
  try {
    const txtBuf = Buffer.from(extractedText, 'utf8');
    const txtPath = `migration-extracted/${tenantId}/${contractId}-v1-${randomUUID()}.txt`;
    const { error: uploadErr } = await supabase().storage
      .from(BUCKET)
      .upload(txtPath, txtBuf, { contentType: 'text/plain', upsert: false });
    if (!uploadErr) extractedTextUri = txtPath;
  } catch (err) {
    logger.warn(
      { action: 'migration.extractedTextUpload.failed', recordId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'extracted text upload skipped — extracted_text_uri will be NULL',
    );
  }

  // 3) Close out the contract_version via the canonical ingestion fn so
  //    the version transitions to status='complete' and the extracted_text_uri
  //    (when set) becomes queryable by the Document tab.
  try {
    await db.callFunction<void>(
      'fn_contract_version_ingestion_complete',
      [
        versionId, extractedTextUri, pageCount, ocrUsed, ocrConfAvg,
        ocrUsed ? 'tesseract' : 'digital_pdf',
      ],
      opts,
    );
  } catch (err) {
    logger.warn(
      { action: 'migration.ingestionComplete.failed', recordId, versionId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'fn_contract_version_ingestion_complete failed — version may stay pending',
    );
  }

  // 4) Register the ORIGINAL Drive file as an attachment so the FE
  //    Attachments tab + Original view of the Document tab resolve.
  try {
    await db.callFunction<unknown>(
      'fn_contract_attachment_create',
      [
        contractId,
        file.name.substring(0, 200),
        file.mimeType,
        file.size,
        storageUri,
        'Imported from Google Drive (migration batch ' + ctx.batchId + ')',
        ctx.actorId ?? 0,
      ],
      opts,
    );
  } catch (err) {
    logger.warn(
      { action: 'migration.attachmentCreate.failed', recordId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'contract_attachment row create failed — Original tab will be empty',
    );
  }

  // 5) LLM-powered structured-field extraction. Falls back to heuristic
  //    fields on error.
  let llmFields: Awaited<ReturnType<typeof llmExtractFields>> = {};
  try {
    llmFields = await llmExtractFields({ text: extractedText, sourceFileName: file.name });
  } catch (err) {
    logger.warn(
      { action: 'migration.llm.failed', recordId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'LLM structured-field extraction failed — using heuristic only',
    );
  }
  const heuristic = heuristicExtractFields(extractedText, file.name);
  const fields = {
    titleEn:        llmFields.titleEn        ?? heuristic.titleEn,
    contractType:   llmFields.contractType   ?? heuristic.contractType,
    counterpartyName: llmFields.counterpartyName ?? heuristic.counterpartyName,
    ourPartyName:   llmFields.ourPartyName   ?? null,
    valueAed:       llmFields.valueAed       ?? heuristic.valueAed,
    startDate:      llmFields.startDate      ?? heuristic.startDate,
    endDate:        llmFields.endDate        ?? heuristic.endDate,
    language:       heuristic.language,
  };

  // 6) Resolve party IDs (find-or-create), cached across the batch.
  const ourPartyId = fields.ourPartyName
    ? await findOrCreateParty({
        name: fields.ourPartyName,
        actorId: ctx.actorId ?? 0,
        tenantId, cache: ctx.partyCache,
      })
    : null;
  const counterpartyId = fields.counterpartyName
    ? await findOrCreateParty({
        name: fields.counterpartyName,
        actorId: ctx.actorId ?? 0,
        tenantId, cache: ctx.partyCache,
      })
    : null;

  // 7) Apply structured fields to the contract row. Direct UPDATE (not
  //    fn_contract_update) because the canonical update fn has its own
  //    permission gates that don't fit the worker context.
  // Mirror extracted text onto the contract row too. The contract detail page
  // gates the AI Insights panel on contract.body_en / body_ar (not on
  // contract_version.body_en) — without this mirror, AI Insights is hidden
  // for every migration-imported contract.
  const bodyEnForContract = fields.language === 'ar' ? null : extractedText.substring(0, 200_000);
  const bodyArForContract = fields.language === 'ar' ? extractedText.substring(0, 200_000) : null;

  await pool().query(
    `UPDATE contract
        SET title_en        = COALESCE($1, title_en),
            contract_type   = COALESCE($2, contract_type),
            language        = COALESCE($3, language),
            value_aed       = COALESCE($4, value_aed),
            start_date      = COALESCE($5::date, start_date),
            end_date        = COALESCE($6::date, end_date),
            our_party_id    = COALESCE($7, our_party_id),
            counterparty_id = COALESCE($8, counterparty_id),
            body_en         = COALESCE($10, body_en),
            body_ar         = COALESCE($11, body_ar)
      WHERE id = $9`,
    [
      fields.titleEn, fields.contractType, fields.language,
      fields.valueAed, fields.startDate, fields.endDate,
      ourPartyId, counterpartyId, contractId,
      bodyEnForContract, bodyArForContract,
    ],
  );

  const confidence = avgConfidence({
    textLen: extractedText.length, pageCount, ocrUsed, ocrConfidenceAvg: ocrConfAvg,
  });
  const fieldCount = [
    fields.titleEn, fields.counterpartyName, fields.ourPartyName,
    fields.valueAed, fields.startDate, fields.endDate, fields.contractType,
  ].filter((v) => v !== null && v !== undefined).length;

  // 8) Link contract back to record (and tag contract.migration_batch_id).
  await db.callFunction<void>(
    'fn_migration_record_link_contract',
    [recordId, tenantId, contractId, versionId, confidence, fieldCount, null],
    opts,
  );

  // 9) Logical-duplicate check (does not block).
  try {
    await db.callFunction<boolean>(
      'fn_migration_logical_duplicate_flag',
      [recordId, tenantId],
      opts,
    );
  } catch (err) {
    logger.warn(
      { action: 'migration.logicalDup.failed', recordId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'logical-dup flagging skipped',
    );
  }

  // 10) Queue clause extraction (CR-D pipeline). The clause-extraction
  //     worker picks up the marker on its next sweep.
  try {
    await db.callFunction<unknown>(
      'fn_clause_extraction_request',
      [versionId, ctx.actorId ?? 0],
      opts,
    );
  } catch (err) {
    logger.warn(
      { action: 'migration.clauseQueue.failed', recordId, versionId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'fn_clause_extraction_request failed — Clauses tab will stay empty',
    );
  }

  // 11) Compute initial risk score. Non-blocking — risk dashboards
  //     re-render on the next correlation event regardless.
  try {
    await db.callFunction<unknown>(
      'fn_risk_score_compute',
      [contractId, 'manual', ctx.actorId ?? 0],
      opts,
    );
  } catch (err) {
    logger.warn(
      { action: 'migration.riskCompute.failed', recordId, contractId, errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'fn_risk_score_compute failed — Risk tab will show defaults',
    );
  }

  // Final status: imported vs needs_review based on threshold
  const finalStatus = confidence >= threshold ? 'imported' : 'needs_review';
  await db.callFunction<void>(
    'fn_migration_record_update_status',
    [recordId, tenantId, finalStatus, null],
    opts,
  );
  if (finalStatus === 'imported') args.onImported(); else args.onReview();
}

// ----------------------------------------------------------------
// Rollback delegate
// ----------------------------------------------------------------

export async function rollback(args: {
  batchId: number;
  actorId: number;
  reason: string;
  tenantId?: string;
}): Promise<{ contractsRolledBack: number; batchId: number }> {
  return db.callFunction(
    'fn_migration_batch_rollback',
    [args.batchId, args.actorId, args.reason],
    { actorId: args.actorId, tenantId: args.tenantId ?? ADNOC_TENANT_ID },
  );
}

// ----------------------------------------------------------------
// Purge delegate (preview + execute)
// ----------------------------------------------------------------

export async function purgeAll(args: {
  actorId: number;
  dryRun: boolean;
  tenantId?: string;
}): Promise<unknown> {
  return db.callFunction(
    'fn_migration_purge_all',
    [args.dryRun],
    { actorId: args.actorId, tenantId: args.tenantId ?? ADNOC_TENANT_ID },
  );
}
