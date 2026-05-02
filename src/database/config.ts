/**
 * pg Pool configuration. Reads from DATABASE_URL (Neon serverless pooler URL).
 *
 * The Neon pooler endpoint is already in the URL, e.g.
 *   postgresql://...@ep-still-violet-aj0h962i-pooler.c-3.us-east-2.aws.neon.tech/neondb
 * Pool sizing per DATABASE_POOL_MAX (default 20).
 *
 * TLS (CRX-5):
 *   The connection string already mandates sslmode=require + channel_binding=require.
 *   We pass ssl: { rejectUnauthorized: true } so the pg driver validates the
 *   server certificate against the system CA bundle. Neon presents a valid
 *   chain; previous `rejectUnauthorized: false` allowed silent MITM and is
 *   now removed.
 *   For a local Postgres (non-Neon) DSN over plaintext loopback, ssl is
 *   disabled; the heuristic below detects DATABASE_URL targeting localhost.
 */
import { Pool } from 'pg';
import type { PoolConfig } from 'pg';
import { env } from '../utils/env-validation.util';
import { logger } from '../utils/logger.util';

let _pool: Pool | null = null;

const isLocalhostDsn = (dsn: string): boolean =>
  /(@|host=|@\[)(localhost|127\.0\.0\.1|::1)([:\/?]|$)/i.test(dsn);

/**
 * Build the pg Pool. Lazy so env() is available.
 */
const buildPool = (): Pool => {
  const e = env();
  const isLocal = e.NODE_ENV === 'development' && isLocalhostDsn(e.DATABASE_URL);
  const config: PoolConfig = {
    connectionString: e.DATABASE_URL,
    max: e.DATABASE_POOL_MAX,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    application_name: e.SERVICE_NAME,
    // CRX-5 fix: enforce TLS cert validation. Disable SSL only for explicit
    // localhost DSNs in development. Production / Neon / any non-local DSN
    // gets full cert verification.
    ssl: isLocal ? false : { rejectUnauthorized: true },
  };

  const pool = new Pool(config);

  pool.on('error', (err) => {
    logger.error(
      { action: 'pg.pool_error', errorType: err.name, message: err.message },
      'Unexpected pg pool error',
    );
  });

  return pool;
};

export const pool = (): Pool => {
  if (!_pool) _pool = buildPool();
  return _pool;
};

/** For graceful shutdown. */
export const closePool = async (): Promise<void> => {
  if (_pool) {
    await _pool.end();
    _pool = null;
  }
};
