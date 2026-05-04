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
  ForbiddenError,
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
 *
 * Two raise-message formats are supported:
 *
 *   1. Legacy M0 format:        'fn_X: <message>'
 *      e.g. 'fn_user_create: Email already in use'
 *
 *   2. M1a structured format:   'fn_X: <field>:<message>'
 *      e.g. 'fn_contract_create: titleEn:Title (English) is required'
 *           'fn_contract_get_by_id: id:Contract not found'
 *           'fn_contract_delete: children:Cannot delete contract with active child contracts'
 *
 * The structured format carries the field name as the first colon-delimited
 * token after the fn_ prefix. We map the field prefix to the appropriate
 * HTTP status:
 *   - id, contractId         → 404 NOT_FOUND
 *   - children               → 409 CONFLICT
 *   - contractNumber, versionNumber → 409 CONFLICT
 *   - any other field        → 400 VALIDATION_ERROR with { details: { field } }
 *
 * Raw SQLSTATE / table names are NEVER surfaced to the API consumer
 * (CLAUDE.md §8). `42501` (RLS denial) maps to 403 FORBIDDEN.
 */
const STRUCTURED_RAISE_RE = /^(fn_[a-z0-9_]+):\s*([a-zA-Z][a-zA-Z0-9_]*):\s*(.+)$/;

// M1c: '404:Import batch not found' → 404. The fn_import_batch_update raise
// uses the literal field name '404' which the structured-raise regex matches.
// (Token must start with a-z A-Z but the regex actually allows leading
// digits via [a-zA-Z][a-zA-Z0-9_]* — leading digit fails. Use a separate
// 404-prefix check below.)
const NOT_FOUND_FIELD_PREFIXES = new Set(['id', 'contractId']);

// M1c: 'status:Invalid status transition' is a 409 (illegal lifecycle
// transition — e.g. completed → in_progress). Generic 'status:' field on
// other fn_'s would 400, but for M1c the only 'status:' raise is the
// transition error. We pattern-match on the message for safety.
const CONFLICT_FIELD_PREFIXES = new Set(['children', 'contractNumber', 'versionNumber']);

// M1c: 'permission:Forbidden' raised by fn_import_batch_create /
// fn_import_batch_update as defense in depth (the BE permission middleware
// blocks 403 cases upstream, so this raise should not normally fire — but
// it is mapped here to keep the layered enforcement honest).
const FORBIDDEN_FIELD_PREFIXES = new Set(['permission']);

// M1c: '404:<msg>' literal-prefix raised by fn_import_batch_update to flag
// the not-found case (token '404' has a leading digit so the structured-
// raise regex above does not match — handled separately below).
const HTTP_404_LITERAL_PREFIX_RE = /^fn_[a-z0-9_]+:\s*404:\s*(.+)$/;

const translatePgError = (err: unknown, fnName: string): ApiError => {
  const message = err instanceof Error ? err.message : String(err);
  const lower = message.toLowerCase();

  // SQLSTATE-driven mappings
  if (isPgError(err)) {
    switch (err.code) {
      case '42501': // insufficient_privilege — RLS denial
        return new ForbiddenError('Forbidden');
      case '23505': // unique_violation
        return new ConflictError(`${fnName}: duplicate key`);
      case '23503': // foreign_key_violation
        // M1c AC-S9-04: contract.import_batch_id FK to import_batch(id).
        // INSERT into contract with a non-existent import_batch_id raises
        // 23503; surface as 400 with a field-scoped envelope so the FE
        // bulk-import flow gets a clear message instead of the generic
        // 422. We pattern-match on the constraint name to scope the
        // friendlier message — other 23503s remain 422.
        if (err.constraint === 'fk_contract_import_batch_id') {
          return new ValidationError('Referenced import batch not found', {
            importBatchId: 'Referenced import batch not found',
          });
        }
        return new UnprocessableEntityError(`${fnName}: foreign key violation`);
      case '23502': // not_null_violation
        return new ValidationError(`${fnName}: required field missing`);
      case '23514': // check_violation — Codex BE-M1b-005
        // The Zod schemas allow combinations the DB rejects via CHECK
        // (e.g., paid_at set when status != 'paid' on payment_schedule;
        // M1c chk_import_batch_counter_sum / chk_import_batch_completed_at_status).
        // Surface as a 400 so the client knows it is a request-shape
        // problem, not a server fault. We deliberately do NOT echo
        // err.constraint — it leaks raw constraint names — but keep the
        // message generic.
        return new ValidationError('Data violates database constraint', { check: 'invalid' });
      case '22P02': // invalid_text_representation
        return new ValidationError(`${fnName}: invalid value type`);
      case '42883': // undefined_function
        return new InternalError(`${fnName}: function not deployed`);
      default:
        // fall through to text matching
        break;
    }
  }

  // M1c: '404:<msg>' literal-prefix raise (e.g. fn_import_batch_update for
  // missing batch). The structured-raise regex requires a leading letter on
  // the field token, so '404' is matched separately here.
  const firstLine = message.split('\n')[0]?.trim() ?? message;
  const literal404 = HTTP_404_LITERAL_PREFIX_RE.exec(firstLine);
  if (literal404) {
    const msg = literal404[1]?.trim() ?? 'Not found';
    return new NotFoundError(msg);
  }

  // Structured format: 'fn_X: <field>:<message>'
  // We match the first line because pg may append CONTEXT/HINT lines.
  const structuredMatch = STRUCTURED_RAISE_RE.exec(firstLine);
  if (structuredMatch) {
    const field = structuredMatch[2] ?? '';
    const msg = structuredMatch[3]?.trim() ?? '';
    if (NOT_FOUND_FIELD_PREFIXES.has(field)) {
      return new NotFoundError(msg, { [field]: msg });
    }
    if (FORBIDDEN_FIELD_PREFIXES.has(field)) {
      // M1c: defense-in-depth fn_ permission raise. BE middleware blocks
      // 403 cases upstream so this rarely fires — surface as 403 anyway.
      return new ForbiddenError(msg);
    }
    // M1c AC-S2-02: 'status:Invalid status transition' is the only 'status'
    // field raise from fn_import_batch_update — it's a CONFLICT, not a
    // validation failure. We scope this strictly to the transition message
    // so other future 'status:' raises fall through to 400 VALIDATION_ERROR.
    if (field === 'status' && /invalid status transition/i.test(msg)) {
      return new ConflictError(msg, { [field]: msg });
    }
    if (CONFLICT_FIELD_PREFIXES.has(field)) {
      return new ConflictError(msg, { [field]: msg });
    }
    // Default for any other field name → 400 VALIDATION_ERROR
    return new ValidationError(msg, { [field]: msg });
  }

  // Legacy M0 text-matching for fn_ RAISE EXCEPTION semantic prefixes
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

  // Pre-serialise plain objects (and arrays of objects) to JSONB. pg.Pool
  // serialises JS objects via JSON.stringify by default — we make this
  // explicit so we control the wire shape. Arrays of primitives (string[],
  // number[]) are passed through so pg can bind them as Postgres array
  // literals (e.g. TEXT[] for fn_contract_set_tags).
  const boundArgs = args.map((v) => {
    if (v === undefined) return null;
    if (v === null) return null;
    if (v instanceof Date) return v;
    if (Array.isArray(v)) {
      // Empty arrays are ambiguous; treat as Postgres array (caller can
      // wrap in JSON.stringify for JSONB). Arrays containing objects must
      // be JSONB — pg will not auto-stringify those.
      const containsObject = v.some(
        (el) => el !== null && typeof el === 'object' && !(el instanceof Date),
      );
      if (containsObject) {
        return JSON.stringify(v);
      }
      return v;
    }
    if (typeof v === 'object') {
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
 * Existence check that BYPASSES RLS. Used for the AC-S2-03 403-vs-404
 * distinction in M1a contracts: fn_contract_get_by_id returns NULL both
 * when the row truly doesn't exist AND when RLS hides it from the caller.
 * To produce the correct status, the controller calls this helper to
 * determine whether the row physically exists (with is_active = true).
 *
 * Mechanism: SET LOCAL row_security = off inside a transaction. This
 * requires the connection role to be the table owner OR have BYPASSRLS
 * (Neon's `neondb_owner` role is the owner of all application tables).
 * Falls back gracefully — if SET LOCAL is denied, returns false rather
 * than throwing, so the caller can still produce a 404.
 *
 * Safety: query is parameterised; table name is a literal in this module
 * (not user-supplied). Pool client is released after every call.
 */
export const checkActiveRowExists = async (table: 'contract', id: number): Promise<boolean> => {
  if (!Number.isFinite(id) || id <= 0) return false;
  // Hardcoded allowlist — never accept user input here.
  if (table !== 'contract') return false;
  const client = await pool().connect();
  try {
    await client.query('BEGIN');
    try {
      await client.query('SET LOCAL row_security = off');
    } catch {
      // If we cannot bypass RLS, fall back to the regular path (returns
      // false because no current_user_id is set). The controller will
      // produce a 404 — same as before this helper existed.
      await client.query('ROLLBACK');
      return false;
    }
    const result = await client.query<{ exists: boolean }>(
      'SELECT EXISTS(SELECT 1 FROM contract WHERE id = $1 AND is_active = TRUE) AS exists',
      [id],
    );
    await client.query('COMMIT');
    return result.rows[0]?.exists === true;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    logger.error(
      {
        action: 'db.checkActiveRowExists',
        table,
        id,
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
      },
      'Existence check failed',
    );
    return false;
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
  checkActiveRowExists,
  healthCheck,
} as const;
