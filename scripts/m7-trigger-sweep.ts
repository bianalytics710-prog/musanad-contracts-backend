/**
 * One-off — manually trigger source-fetch sweep + log results.
 * Used to verify M7 (CR-A) adapters live without waiting for cron tick.
 *
 * Run:  npx tsx -r dotenv/config scripts/m7-trigger-sweep.ts dotenv_config_path=.env.local
 */
import { validateEnv } from '../src/utils/env-validation.util';
validateEnv();
import { runSourceFetchSweep } from '../src/workers/source-fetch.worker';
import { pool } from '../src/database/config';

async function main(): Promise<void> {
  console.log('starting sweep at', new Date().toISOString());
  // First raw-query the same SELECT to surface the actual SQL error if any
  try {
    const r = await pool().query(
      `SELECT s.id, s.tenant_id, s.source_id, s.url, s.source_reliability,
              s.refresh_seconds, s.rate_limit, s.metadata, s.geography_filter,
              s.severity_mapping,
              c.credential_ref
         FROM osint_source s
         LEFT JOIN source_credential c
           ON c.osint_source_id = s.id
          AND c.tenant_id = s.tenant_id
          AND c.is_active = TRUE
        WHERE s.enabled = TRUE
          AND s.is_active = TRUE
        ORDER BY s.id ASC
        LIMIT 100`,
    );
    console.log('raw query OK — rows:', r.rows.length);
  } catch (e: unknown) {
    console.error('raw query FAILED:', (e as Error).message);
  }
  const stats = await runSourceFetchSweep();
  console.log('sweep done:', JSON.stringify(stats));
  await pool().end();
}

main().catch((err: unknown) => {
  console.error('sweep failed:', err);
  process.exit(1);
});
