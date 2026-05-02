/**
 * Database client — the ONLY way controllers touch the DB.
 *
 *   - callFunction<T>(fnName, args, opts) → SELECT fn_name($1, $2, ...) and
 *     return parsed JSONB.
 *   - executeInTransaction(fn) → BEGIN/COMMIT wrapper around a callback.
 *   - healthCheck() → SELECT 1 (boolean).
 *
 * RLS context (DB Impl handoff §3): every authenticated request must
 * `SET LOCAL app.current_user_id = <jwt.sub>` in the same transaction
 * before any fn_ call, otherwise RLS policies deny. This module exposes
 * the option to set the GUC inline; the rls.middleware does NOT pre-set
 * the GUC at the connection level (pooled connections leak state).
 *
 * Postgres errors are translated to ApiError before returning. Raw
 * SQLSTATE codes are mapped where useful (23505 unique violation → 409,
 * 23503 FK violation → 422). All other PG errors become 500 InternalError;
 * the raw message is logged but never surfaced to the API consumer.
 */
import type { PoolClient, QueryResult } from 'pg';
import { pool } from './config';
import { logger } from '../utils/logger.util';
import {
  ApiError,
  ConflictError,
  InternalError,
  LockedError,
  NotFoundError,
  UnprocessableEntityError,
  ValidationError,
} from '../utils/errors.util';

// Postgres error shape (subset we care about).
interface PgError extends Error {
  code?: string;
  detail?: string;
  schema?: string;
  table?: string;
  constraint?: string;
}

const isPgError = (e: unknown): e is PgError =>
  e instanceof Error && typeof (e as PgError).code === 'string';

/**
 * Translate fn_ exceptions (RAISE EXCEPTION 'fn_name: message') to ApiError.
 * The DB Implementation Agent established that fn_ functions raise messages
 * with semantic prefixes we can pattern-match on.
 */
const translatePgError = (err: unknown, fnName: string): ApiError => {
  const message = err instanceof Error ? err.message : String(err);
  const lower = message.toLowerCase();

  // SQLSTATE-driven mappings
  if (isPgError(err)) {
    switch (err.code) {
      case '23505': // unique_violation
        return new ConflictError(`${fnName}: duplicate key`);
      case '23503': // foreign_key_violation
        return new UnprocessableEntityError(`${fnName}: foreign key violation`);
      case '23502': // not_null_violation
        return new ValidationError(`${fnName}: required field missing`);
      case '22P02': // invalid_text_representation
        return new ValidationError(`${fnName}: invalid value type`);
      case '42883': // undefined_function
        return new InternalError(`${fnName}: function not deployed`);
      default:
        // fall through to text matching
        break;
    }
  }

  // Text-matching for fn_ RAISE EXCEPTION semantic prefixes
  if (lower.includes('email already in use')) {
    return new ConflictError('Email already in use');
  }
  if (lower.includes('not found') || lower.includes('not found or inactive')) {
    return new NotFoundError(message.replace(/^[a-z_]+:\s*/, ''));
  }
  if (lower.includes('cannot deactivate your own account')) {
    return new ValidationError('Cannot deactivate your own account');
  }
  if (lower.includes('locked')) {
    return new LockedError('Account locked');
  }
  if (lower.includes('role not found') || lower.includes('role not found or inactive')) {
    return new UnprocessableEntityError('Role not found or inactive');
  }
  if (lower.includes('is required') || lower.includes('must be')) {
    return new ValidationError(message.replace(/^[a-z_]+:\s*/, ''));
  }

  // Default — never expose raw text
  return new InternalError('Database operation failed');
};

export interface CallFunctionOptions {
  /**
   * The user id used to set `app.current_user_id` GUC for RLS.
   * Anonymous endpoints (login, refresh, health) pass undefined.
   */
  actorId?: number;
}

/**
 * Run `SELECT fn_name($1, $2, ...) AS result` and return parsed JSONB.
 *
 * `args` is positional — order MUST match the fn_ function signature.
 * For functions taking a JSONB payload (e.g. fn_user_create(p_data, p_actor_id)),
 * pass an object as one of the array elements; pg will JSONify it.
 *
 * Always runs inside a transaction so SET LOCAL works.
 */
export const callFunction = async <T = unknown>(
  fnName: string,
  args: ReadonlyArray<unknown>,
  opts: CallFunctionOptions = {},
): Promise<T> => {
  // Hard-prevent SQL injection via fn name (callers should use literals).
  if (!/^[a-z_][a-z0-9_]*$/i.test(fnName)) {
    throw new InternalError(`Invalid function name: ${fnName}`);
  }

  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  const sql = `SELECT ${fnName}(${placeholders}) AS result`;

  // Pre-serialise plain objects to JSONB. pg.Pool serialises JS objects
  // via JSON.stringify by default — we make this explicit so we control
  // the wire shape.
  const boundArgs = args.map((v) => {
    if (v === undefined) return null;
    if (v === null) return null;
    if (typeof v === 'object' && !Array.isArray(v) && !(v instanceof Date)) {
      return JSON.stringify(v);
    }
    return v;
  });

  const client = await pool().connect();
  try {
    await client.query('BEGIN');

    if (opts.actorId !== undefined && Number.isFinite(opts.actorId)) {
      // SET LOCAL with set_config so we can pass a parameter (avoids string
      // concatenation). third arg `is_local` = true matches `SET LOCAL`.
      await client.query("SELECT set_config('app.current_user_id', $1, true)", [
        String(opts.actorId),
      ]);
    }

    const result: QueryResult<{ result: T }> = await client.query(sql, boundArgs);

    await client.query('COMMIT');

    return result.rows[0]?.result as T;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow rollback error */
    }
    // Log raw error internally — never expose to caller
    logger.error(
      {
        action: 'db.callFunction',
        fnName,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        // err.message may contain raw PG text — log it but the API
        // response (via translatePgError) returns a sanitised message.
        message: err instanceof Error ? err.message : String(err),
      },
      'fn_ call failed',
    );
    throw translatePgError(err, fnName);
  } finally {
    client.release();
  }
};

/**
 * Run a callback inside a BEGIN/COMMIT block with an attached client.
 * Caller is responsible for any SET LOCAL needed before fn_ calls.
 */
export const executeInTransaction = async <T>(
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> => {
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Connectivity probe for /api/health. Returns true on success.
 * Does NOT throw — callers branch on the boolean.
 */
export const healthCheck = async (): Promise<boolean> => {
  try {
    const res = await pool().query('SELECT 1 AS ok');
    return res.rows[0]?.ok === 1;
  } catch (err) {
    logger.error(
      { action: 'db.healthCheck', errorType: err instanceof Error ? err.name : 'UNKNOWN' },
      'Health check failed',
    );
    return false;
  }
};

/** Bundle for ergonomic imports: `import { db } from '@/database/client'`. */
export const db = {
  callFunction,
  executeInTransaction,
  healthCheck,
} as const;
