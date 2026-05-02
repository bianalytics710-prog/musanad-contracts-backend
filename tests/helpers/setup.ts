/**
 * Vitest global setup. Loads .env.local so tests have DB + JWT config.
 *
 * Note: tests run against the Neon m0-foundation branch (no separate test
 * branch yet — see DB Impl handoff §10). Avoid destructive writes; the few
 * integration tests use idempotent reads + login flow only.
 */
import 'dotenv/config';
import { config as loadDotenv } from 'dotenv';
import path from 'node:path';

// Layer .env.local on top of any existing env so the integration tests
// pick up the Neon DATABASE_URL and JWT secret without forcing the runner
// to symlink .env.
loadDotenv({ path: path.resolve(process.cwd(), '.env.local'), override: false });

// Lower log noise during tests
if (!process.env.LOG_LEVEL) {
  process.env.LOG_LEVEL = 'warn';
}
