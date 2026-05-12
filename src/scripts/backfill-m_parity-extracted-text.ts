/**
 * M11 (CR-D0) — M_parity extracted-text backfill script.
 *
 * OPEN-DECISION-M sub-option (b): SQL-side prep (migration 139) marks
 * the 35 M_parity contract_version rows with extraction_engine='digital_pdf',
 * ingestion_status='pending'. This script does the TS-side work:
 *
 *   For each row where extraction_engine='digital_pdf'
 *                      AND ingestion_status='pending'
 *                      AND extracted_text_uri IS NULL:
 *
 *   1. Concat body_en + '\n\n---\n\n' + body_ar (skip null sides).
 *   2. Upload to Supabase Storage at <tenantId>/<contractId>/v<n>/<uuid>.txt
 *   3. Call fn_contract_version_ingestion_complete with the new URI.
 *
 * Run via:
 *   cd musanad-contracts-backend
 *   tsx -r dotenv/config ./src/scripts/backfill-m_parity-extracted-text.ts
 *
 * NOTE: This script uses the DATABASE_URL (not TEST_DATABASE_URL) by default.
 * Set DATABASE_URL=<test-branch-url> to run against the test branch.
 */

import dotenv from 'dotenv';
import path from 'node:path';

dotenv.config({ path: path.resolve(process.cwd(), '.env.local') });
dotenv.config();

import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import pg from 'pg';

const BUCKET = 'contract-attachments';
const ADNOC_TENANT_ID = '00000000-0000-0000-0000-000000000001';
const SYSTEM_ACTOR_ID = 1;
const BATCH_SIZE = 10;

interface BackfillRow {
  id: number;
  contract_id: number;
  version_number: number;
  body_en: string | null;
  body_ar: string | null;
  tenant_id: string | null;
}

function getStorageClient() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set');
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function uploadText(args: {
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
    contentType: 'text/plain; charset=utf-8',
    upsert: false,
  });

  if (error) {
    throw new Error(`Storage upload failed: ${error.message}`);
  }

  return storagePath;
}

async function main() {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl) {
    throw new Error('DATABASE_URL must be set');
  }

  const pool = new pg.Pool({ connectionString: dbUrl });

  // Query pending M_parity rows
  const query = `
    SELECT cv.id,
           cv.contract_id,
           cv.version_number,
           cv.body_en,
           cv.body_ar,
           c.tenant_id
      FROM contract_version cv
      JOIN contract c ON c.id = cv.contract_id
     WHERE cv.extraction_engine = 'digital_pdf'
       AND cv.ingestion_status  = 'pending'
       AND cv.extracted_text_uri IS NULL
     ORDER BY cv.id ASC
  `;

  const result = await pool.query<BackfillRow>(query);
  const rows = result.rows;

  console.log(`Found ${rows.length} M_parity rows to backfill`);

  let processed = 0;
  let skipped = 0;
  let failed = 0;

  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batch = rows.slice(i, i + BATCH_SIZE);
    for (const row of batch) {
      try {
        // Build extracted text from body columns
        const parts: string[] = [];
        if (row.body_en?.trim()) parts.push(row.body_en.trim());
        if (row.body_ar?.trim()) {
          if (parts.length > 0) parts.push('\n\n---\n\n');
          parts.push(row.body_ar.trim());
        }

        if (parts.length === 0) {
          console.log(`  SKIP  cv.id=${row.id} — both body_en and body_ar are empty`);
          skipped++;
          continue;
        }

        const text = parts.join('');
        const tenantId = row.tenant_id ?? ADNOC_TENANT_ID;

        // Upload to Storage
        const storagePath = await uploadText({
          text,
          tenantId,
          contractId: row.contract_id,
          versionNumber: row.version_number,
        });

        // Call fn_contract_version_ingestion_complete
        const client = await pool.connect();
        try {
          await client.query('BEGIN');
          await client.query("SELECT set_config('app.current_user_id', $1, true)", [String(SYSTEM_ACTOR_ID)]);
          await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
          await client.query(
            `SELECT fn_contract_version_ingestion_complete($1, $2, $3, $4, $5, $6)`,
            [
              row.id,          // p_contract_version_id
              storagePath,     // p_extracted_text_uri
              1,               // p_page_count (M_parity body = 1 logical page)
              false,           // p_ocr_used
              null,            // p_ocr_confidence_avg
              'digital_pdf',   // p_extraction_engine
            ],
          );
          await client.query('COMMIT');
        } catch (err) {
          await client.query('ROLLBACK');
          throw err;
        } finally {
          client.release();
        }

        console.log(`  OK    cv.id=${row.id} → ${storagePath}`);
        processed++;
      } catch (err) {
        console.error(`  FAIL  cv.id=${row.id}: ${err instanceof Error ? err.message : String(err)}`);
        failed++;
      }
    }
    // Brief pause between batches to avoid rate-limiting Storage
    if (i + BATCH_SIZE < rows.length) {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }

  await pool.end();

  console.log('\n--- Backfill summary ---');
  console.log(`  Total rows found : ${rows.length}`);
  console.log(`  Processed        : ${processed}`);
  console.log(`  Skipped (empty)  : ${skipped}`);
  console.log(`  Failed           : ${failed}`);
}

main().catch((err) => {
  console.error('Backfill script failed:', err);
  process.exit(1);
});
