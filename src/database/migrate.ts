/**
 * Migration runner.
 *
 * Reads `database/migrations/NNN_*.sql` files in lexicographic order and applies
 * any whose `version` (parsed from the leading `NNN_`) is not already in the
 * `schema_migrations` table.
 *
 * Statement-at-a-time execution
 * ─────────────────────────────
 * The runner SPLITS each .sql file into individual statements and executes them
 * one-by-one through a single held client. Multi-statement `client.query(sql)`
 * calls are unreliable for large DDL bodies (size limits + dollar-quoted block
 * handling vary across pg drivers and pgbouncer modes), and a failed statement
 * inside such a batch can be silently swallowed — leaving the DB in an
 * inconsistent state and the runner falsely reporting success.
 *
 * The splitter understands:
 *   - line comments `-- ...`
 *   - block comments `/* ... *​/`
 *   - single-quoted strings (with `''` escape)
 *   - dollar-quoted blocks `$$ ... $$` and `$tag$ ... $tag$`
 *
 * The runner manages its own transaction (BEGIN/COMMIT/ROLLBACK), so the
 * migration file's own `BEGIN;`/`COMMIT;` statements (if any) are skipped.
 * That means the file's transactional boundary is enforced by the runner,
 * not by the file. (Statements that cannot run inside a transaction — e.g.
 * `CREATE INDEX CONCURRENTLY` — are not yet supported; add a marker comment
 * and a non-transactional path when needed.)
 *
 * `--down` rolls back the MOST RECENT migration by extracting the
 * `-- ROLLBACK BEGIN` / `-- ROLLBACK END` block and applying it the same way.
 *
 * `--target=test` redirects to TEST_DATABASE_URL so migrations can be applied
 * to the dedicated Neon `test` branch independently of dev.
 *
 * Usage:
 *   npm run migrate              # apply pending up-migrations to dev (DATABASE_URL)
 *   npm run migrate:down         # roll back the most recent applied migration on dev
 *   npm run migrate:test         # apply pending up-migrations to test branch
 *   npm run migrate:test:down    # roll back the most recent migration on test branch
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

/**
 * Split a SQL string into individual statements, respecting comments, single
 * quotes, and dollar-quoted blocks. Returns trimmed, non-empty statements.
 * Strips standalone BEGIN / COMMIT / ROLLBACK lines (the runner manages those).
 */
const splitStatements = (sql: string): string[] => {
  const out: string[] = [];
  let buf = '';
  let i = 0;
  let inSingle = false;
  let inLineComment = false;
  let inBlockComment = false;
  let dollarTag: string | null = null; // e.g. "$$" or "$body$"

  const len = sql.length;
  while (i < len) {
    const ch = sql[i] ?? '';
    const next = sql[i + 1] ?? '';

    if (dollarTag) {
      buf += ch;
      if (sql.slice(i, i + dollarTag.length) === dollarTag) {
        // already added the first char above; add the rest of the closing tag
        buf += sql.slice(i + 1, i + dollarTag.length);
        i += dollarTag.length;
        dollarTag = null;
        continue;
      }
      i += 1;
      continue;
    }

    if (inLineComment) {
      buf += ch;
      if (ch === '\n') inLineComment = false;
      i += 1;
      continue;
    }

    if (inBlockComment) {
      buf += ch;
      if (ch === '*' && next === '/') {
        buf += next;
        i += 2;
        inBlockComment = false;
        continue;
      }
      i += 1;
      continue;
    }

    if (inSingle) {
      buf += ch;
      if (ch === "'") {
        if (next === "'") {
          buf += next;
          i += 2;
          continue;
        }
        inSingle = false;
      }
      i += 1;
      continue;
    }

    // Not inside any context — check for transitions
    if (ch === '-' && next === '-') {
      buf += ch + next;
      i += 2;
      inLineComment = true;
      continue;
    }
    if (ch === '/' && next === '*') {
      buf += ch + next;
      i += 2;
      inBlockComment = true;
      continue;
    }
    if (ch === "'") {
      buf += ch;
      i += 1;
      inSingle = true;
      continue;
    }
    if (ch === '$') {
      const m = sql.slice(i).match(/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/);
      if (m) {
        buf += m[0];
        i += m[0].length;
        dollarTag = m[0];
        continue;
      }
    }
    if (ch === ';') {
      const stmt = buf.trim();
      if (stmt.length > 0 && !isControlStatement(stmt)) out.push(stmt);
      buf = '';
      i += 1;
      continue;
    }

    buf += ch;
    i += 1;
  }

  const tail = buf.trim();
  if (tail.length > 0 && !isControlStatement(tail)) out.push(tail);
  return out;
};

/**
 * BEGIN / COMMIT / ROLLBACK are transaction control statements managed by the
 * runner itself — strip them out of the migration body. Returns true if the
 * given trimmed statement is one of these (after stripping comments).
 */
const isControlStatement = (stmt: string): boolean => {
  // Remove leading line/block comments to find the first SQL token
  let s = stmt;
  for (;;) {
    s = s.trimStart();
    if (s.startsWith('--')) {
      const eol = s.indexOf('\n');
      s = eol === -1 ? '' : s.slice(eol + 1);
      continue;
    }
    if (s.startsWith('/*')) {
      const end = s.indexOf('*/');
      s = end === -1 ? '' : s.slice(end + 2);
      continue;
    }
    break;
  }
  const firstWord = s.match(/^[A-Za-z]+/)?.[0]?.toUpperCase();
  return firstWord === 'BEGIN' || firstWord === 'COMMIT' || firstWord === 'ROLLBACK';
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

/**
 * Find the section markers `-- ROLLBACK BEGIN` and `-- ROLLBACK END` on their
 * OWN LINE (header comments often *reference* the marker text inline, e.g.
 * "See `-- ROLLBACK BEGIN` markers below.", which would mis-match a naive
 * indexOf). We require the marker to be the only non-whitespace content on
 * the line.
 */
const findMarker = (sql: string, marker: string): number => {
  const re = new RegExp(`(^|\\n)[ \\t]*${marker.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')}[ \\t]*(\\r?\\n|$)`);
  const m = sql.match(re);
  if (!m || m.index === undefined) return -1;
  return m.index + (m[1] === '\n' ? 1 : 0);
};

const extractRollbackSql = (sql: string): string | null => {
  const start = findMarker(sql, '-- ROLLBACK BEGIN');
  const end = findMarker(sql, '-- ROLLBACK END');
  if (start === -1 || end === -1 || end <= start) return null;
  return sql.slice(start + '-- ROLLBACK BEGIN'.length, end).trim();
};

/** Strip the rollback section so up-migrations only see their own DDL. */
const stripRollbackSection = (sql: string): string => {
  const idx = findMarker(sql, '-- ROLLBACK BEGIN');
  return idx === -1 ? sql : sql.slice(0, idx);
};

/**
 * Apply a SQL body (already free of the rollback section if applicable) by
 * splitting into statements and running each through a single held client
 * inside one transaction.
 */
const applySqlBody = async (sql: string, label: string): Promise<void> => {
  const statements = splitStatements(sql);
  if (statements.length === 0) {
    throw new Error(`migrate.${label}: no statements parsed from SQL body`);
  }

  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    for (let n = 0; n < statements.length; n++) {
      const stmt = statements[n] ?? '';
      try {
        await client.query(stmt);
      } catch (err) {
        const preview = stmt.replace(/\s+/g, ' ').slice(0, 120);
        logger.error(
          {
            action: `migrate.${label}.statement_failed`,
            statementIndex: n + 1,
            totalStatements: statements.length,
            preview,
          },
          err instanceof Error ? err.message : String(err),
        );
        try {
          await client.query('ROLLBACK');
        } catch {
          /* swallow */
        }
        throw err;
      }
    }
    await client.query('COMMIT');
    logger.info(
      { action: `migrate.${label}.applied`, statementsExecuted: statements.length },
      'SQL body applied',
    );
  } finally {
    client.release();
  }
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
    const sqlRaw = await fs.readFile(m.fullPath, 'utf8');
    const upSql = stripRollbackSection(sqlRaw);

    await applySqlBody(upSql, 'up');

    // Some migration files self-record into schema_migrations (skipped if
    // already present). Insert defensively in case the file omits the row.
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

  await applySqlBody(rollbackSql, 'down');
  await pool().query('DELETE FROM schema_migrations WHERE version = $1', [target.version]);

  logger.info(
    { action: 'migrate.rolled_back', version: target.version },
    'Rollback complete',
  );
};

const applyTargetOverride = (): void => {
  // --target=<name> redirects DB traffic. Only `test` is supported today.
  const targetArg = process.argv.find((a) => a.startsWith('--target='));
  if (!targetArg) return;
  const target = targetArg.split('=')[1];
  if (target === 'test') {
    const testUrl = process.env.TEST_DATABASE_URL;
    if (!testUrl || testUrl.trim() === '') {
      // eslint-disable-next-line no-console
      console.error('FATAL: --target=test requires TEST_DATABASE_URL to be set in .env.local');
      process.exit(1);
    }
    process.env.DATABASE_URL = testUrl;
  } else {
    // eslint-disable-next-line no-console
    console.error(`FATAL: Unknown --target=${target}. Valid targets: test`);
    process.exit(1);
  }
};

const main = async (): Promise<void> => {
  applyTargetOverride();
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
    const pgFields = (err as Record<string, unknown>) ?? {};
    logger.fatal(
      {
        action: 'migrate.fatal',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        code: pgFields.code,
        position: pgFields.position,
        internalPosition: pgFields.internalPosition,
        where: pgFields.where,
        routine: pgFields.routine,
      },
      err instanceof Error ? err.message : String(err),
    );
    closePool().finally(() => process.exit(1));
  });
