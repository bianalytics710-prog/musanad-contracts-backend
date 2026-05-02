/**
 * Migration runner.
 *
 * Reads all `database/migrations/NNN_*.sql` files in lexicographic order
 * and applies any whose `version` (parsed from the leading `NNN_`) is not
 * already in the `schema_migrations` table.
 *
 * Each .sql file is the entire migration including its own BEGIN/COMMIT.
 * The runner does NOT wrap in another transaction — the file controls
 * transactional boundaries (this matters for things like CONCURRENTLY
 * indexes that cannot run inside a transaction).
 *
 * `--down` (or `migrate:down` script) rolls back the MOST RECENT migration
 * by extracting the `-- ROLLBACK BEGIN` / `-- ROLLBACK END` block from the
 * matching .sql file and executing it. To prevent accidents, only one
 * down-migration is run per invocation.
 *
 * Usage:
 *   npm run migrate            # apply pending up-migrations
 *   npm run migrate:down       # roll back the most recent applied migration
 */
import dotenv from 'dotenv';
import fs from 'node:fs/promises';
import path from 'node:path';
const _envFile = process.env.NODE_ENV === 'production' ? '.env' : '.env.local';
dotenv.config({ path: path.resolve(process.cwd(), _envFile), override: false });
dotenv.config({ override: false }); // fallback to default .env if present
import { validateEnv } from '../utils/env-validation.util';
import { logger } from '../utils/logger.util';
import { pool, closePool } from './config';

interface MigrationFile {
  version: number;
  description: string;
  filename: string;
  fullPath: string;
}

const MIGRATIONS_DIR = path.resolve(process.cwd(), 'database/migrations');

const parseFilename = (filename: string): MigrationFile | null => {
  const match = filename.match(/^(\d+)_(.+)\.sql$/);
  if (!match) return null;
  const [, versionStr, description] = match;
  return {
    version: parseInt(versionStr ?? '0', 10),
    description: description ?? '',
    filename,
    fullPath: path.join(MIGRATIONS_DIR, filename),
  };
};

const readMigrationFiles = async (): Promise<MigrationFile[]> => {
  let entries: string[];
  try {
    entries = await fs.readdir(MIGRATIONS_DIR);
  } catch (err) {
    logger.error({ action: 'migrate.read_dir', dir: MIGRATIONS_DIR }, 'Cannot read migrations dir');
    throw err;
  }
  return entries
    .map(parseFilename)
    .filter((m): m is MigrationFile => m !== null)
    .sort((a, b) => a.version - b.version);
};

const ensureSchemaMigrationsTable = async (): Promise<void> => {
  await pool().query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version     INTEGER     PRIMARY KEY,
      description TEXT        NOT NULL,
      applied_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
    )
  `);
};

const getAppliedVersions = async (): Promise<number[]> => {
  const res = await pool().query<{ version: number }>(
    'SELECT version FROM schema_migrations ORDER BY version ASC',
  );
  return res.rows.map((r) => r.version);
};

const extractRollbackSql = (sql: string): string | null => {
  const start = sql.indexOf('-- ROLLBACK BEGIN');
  const end = sql.indexOf('-- ROLLBACK END');
  if (start === -1 || end === -1 || end <= start) return null;
  return sql.slice(start + '-- ROLLBACK BEGIN'.length, end).trim();
};

const runUp = async (): Promise<void> => {
  await ensureSchemaMigrationsTable();
  const all = await readMigrationFiles();
  const applied = new Set(await getAppliedVersions());

  const pending = all.filter((m) => !applied.has(m.version));
  if (pending.length === 0) {
    logger.info({ action: 'migrate.up' }, 'No pending migrations');
    return;
  }

  for (const m of pending) {
    logger.info(
      { action: 'migrate.apply', version: m.version, description: m.description },
      'Applying migration',
    );
    const sql = await fs.readFile(m.fullPath, 'utf8');
    // The .sql file is expected to handle its own BEGIN/COMMIT and to insert
    // its own row into schema_migrations as the final statement before COMMIT.
    // For files that don't, we insert here as a fallback.
    await pool().query(sql);

    const check = await pool().query<{ exists: boolean }>(
      'SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1) AS exists',
      [m.version],
    );
    if (!check.rows[0]?.exists) {
      await pool().query(
        'INSERT INTO schema_migrations (version, description) VALUES ($1, $2)',
        [m.version, m.description],
      );
    }

    logger.info(
      { action: 'migrate.applied', version: m.version },
      'Migration applied',
    );
  }
};

const runDown = async (): Promise<void> => {
  await ensureSchemaMigrationsTable();
  const applied = await getAppliedVersions();
  if (applied.length === 0) {
    logger.warn({ action: 'migrate.down' }, 'No migrations to roll back');
    return;
  }

  const lastVersion = applied[applied.length - 1];
  if (lastVersion === undefined) return;

  const all = await readMigrationFiles();
  const target = all.find((m) => m.version === lastVersion);
  if (!target) {
    throw new Error(
      `migrate.down: schema_migrations records version ${lastVersion} but no .sql file matches`,
    );
  }

  logger.warn(
    { action: 'migrate.down', version: target.version, description: target.description },
    'Rolling back migration — DESTRUCTIVE',
  );

  const sql = await fs.readFile(target.fullPath, 'utf8');
  const rollbackSql = extractRollbackSql(sql);
  if (!rollbackSql) {
    throw new Error(
      `migrate.down: file ${target.filename} has no -- ROLLBACK BEGIN/END block`,
    );
  }

  await pool().query('BEGIN');
  try {
    await pool().query(rollbackSql);
    await pool().query('DELETE FROM schema_migrations WHERE version = $1', [target.version]);
    await pool().query('COMMIT');
    logger.info(
      { action: 'migrate.rolled_back', version: target.version },
      'Rollback complete',
    );
  } catch (err) {
    await pool().query('ROLLBACK');
    throw err;
  }
};

const main = async (): Promise<void> => {
  validateEnv();
  const cmd = process.argv[2] ?? 'up';
  if (cmd === 'up') {
    await runUp();
  } else if (cmd === 'down') {
    await runDown();
  } else {
    // eslint-disable-next-line no-console
    console.error(`Unknown migrate command: ${cmd}. Use 'up' or 'down'.`);
    process.exit(1);
  }
};

main()
  .then(() => closePool())
  .then(() => process.exit(0))
  .catch((err) => {
    logger.fatal(
      { action: 'migrate.fatal', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      err instanceof Error ? err.message : String(err),
    );
    closePool().finally(() => process.exit(1));
  });
