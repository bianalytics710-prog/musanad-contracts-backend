/**
 * Vitest global setup. Loads .env.local so tests have DB + JWT config,
 * then redirects DB traffic to the isolated Neon `test` branch when
 * TEST_DATABASE_URL is set (recommended — keeps integration tests off the
 * dev branch). Falls back to DATABASE_URL if TEST_DATABASE_URL is empty.
 */
import 'dotenv/config';
import { config as loadDotenv } from 'dotenv';
import path from 'node:path';

// Layer .env.local on top of any existing env so the integration tests
// pick up the Neon DATABASE_URL and JWT secret without forcing the runner
// to symlink .env.
loadDotenv({ path: path.resolve(process.cwd(), '.env.local'), override: false });

// Swap to the dedicated test branch when TEST_DATABASE_URL is provided.
// Done BEFORE any DB module loads so env-validation + pool see the right URL.
if (process.env.TEST_DATABASE_URL && process.env.TEST_DATABASE_URL.trim() !== '') {
  process.env.DATABASE_URL = process.env.TEST_DATABASE_URL;
}

// Lower log noise during tests
if (!process.env.LOG_LEVEL) {
  process.env.LOG_LEVEL = 'warn';
}

// Mark this process as a test runner. The rate-limit middleware reads
// NODE_ENV and short-circuits to a no-op when this is 'test' — integration
// suites legitimately exceed the per-user write quota when exercising
// every story in one run.
if (!process.env.NODE_ENV || process.env.NODE_ENV === 'development') {
  process.env.NODE_ENV = 'test';
}
