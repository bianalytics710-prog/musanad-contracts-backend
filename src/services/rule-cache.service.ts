/**
 * M13 / CR-E — Rule Cache Service.
 *
 * In-memory rule cache indexed by SignalKind per Annex C.2.4.
 * Invalidates on PG NOTIFY 'correlation_rule_changed'.
 * Hot-reload < 5s per AC #3 (HITL Q1).
 *
 * Singleton per process. Worker registers the NOTIFY listener on startup.
 *
 * SENSITIVE: matchYaml / produceYaml in cached rules are not logged.
 */
import { Pool } from 'pg';
import { pool } from '../database/config';
import { db } from '../database/client';
import { logger } from '../utils/logger.util';

// ============================================================
// Types
// ============================================================

export interface CachedRule {
  id: number;
  ruleId: string;
  name: string;
  enabled: boolean;
  matchYaml: string;
  produceYaml: string;
  versionHash: string;
  meta: Record<string, unknown>;
  evaluationTimeoutSecondsOverride?: number;
}

// ============================================================
// Cache state
// ============================================================

/** All enabled rules, loaded from DB. Replaced atomically on invalidation. */
let _rules: CachedRule[] = [];
let _lastLoadedAt: Date | null = null;
let _isLoading = false;
let _notifyClient: import('pg').PoolClient | null = null;
let _notifyPool: Pool | null = null;

// ============================================================
// Load / invalidate
// ============================================================

/**
 * Load all enabled correlation rules from the DB into the in-memory cache.
 * Called on startup and on PG NOTIFY 'correlation_rule_changed'.
 */
async function loadRules(): Promise<void> {
  if (_isLoading) return; // prevent thundering-herd on simultaneous NOTIFY
  _isLoading = true;
  const startMs = Date.now();
  try {
    // Use fn_rule_list with a high limit to load all enabled rules
    const result = await db.callFunction<{ data: CachedRule[]; pagination: { total: number } }>(
      'fn_rule_list',
      [
        1,    // page
        1000, // limit — sufficient for all rules in one page
        true, // enabled = true only
        null, // scenario = null (all)
        null, // search = null (all)
      ],
    );

    const rules = result?.data ?? [];
    _rules = rules;
    _lastLoadedAt = new Date();

    logger.info(
      {
        action: 'ruleCache.loadRules',
        count: rules.length,
        durationMs: Date.now() - startMs,
      },
      'Rule cache reloaded',
    );
  } catch (err) {
    logger.error(
      {
        action: 'ruleCache.loadRules',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Failed to reload rule cache',
    );
  } finally {
    _isLoading = false;
  }
}

// ============================================================
// PG NOTIFY listener
// ============================================================

/**
 * Register a dedicated connection for PG NOTIFY 'correlation_rule_changed'.
 * Must be called once on worker startup.
 */
export async function startRuleCacheListener(): Promise<void> {
  if (_notifyClient) return; // already listening

  try {
    _notifyPool = pool();
    _notifyClient = await _notifyPool.connect();

    await _notifyClient.query("LISTEN correlation_rule_changed");

    _notifyClient.on('notification', async (msg) => {
      if (msg.channel === 'correlation_rule_changed') {
        logger.info({ action: 'ruleCache.notify', payload: msg.payload }, 'correlation_rule_changed received — invalidating cache');
        await loadRules();
      }
    });

    _notifyClient.on('error', (err) => {
      logger.error(
        { action: 'ruleCache.listenerError', errorMessage: err.message },
        'PG NOTIFY connection error — will reconnect on next startup',
      );
      _notifyClient = null;
    });

    logger.info({ action: 'ruleCache.startListener' }, 'PG NOTIFY listener registered for correlation_rule_changed');

    // Perform initial load
    await loadRules();
  } catch (err) {
    logger.error(
      {
        action: 'ruleCache.startListener',
        errorType: err instanceof Error ? err.name : 'UNKNOWN',
        errorMessage: err instanceof Error ? err.message : String(err),
      },
      'Failed to start rule cache listener',
    );
  }
}

/**
 * Stop the NOTIFY listener (called on graceful shutdown).
 */
export async function stopRuleCacheListener(): Promise<void> {
  if (_notifyClient) {
    try {
      await _notifyClient.query("UNLISTEN correlation_rule_changed");
      _notifyClient.release();
    } catch {
      // best effort
    }
    _notifyClient = null;
  }
}

// ============================================================
// Public accessors
// ============================================================

/**
 * Get all currently cached enabled rules.
 * Returns a snapshot — safe to iterate while the cache is refreshing.
 */
export function getCachedRules(): CachedRule[] {
  return _rules;
}

/**
 * Get cache metadata for observability.
 */
export function getRuleCacheStatus(): { count: number; lastLoadedAt: string | null } {
  return {
    count: _rules.length,
    lastLoadedAt: _lastLoadedAt?.toISOString() ?? null,
  };
}

/**
 * Force a cache reload (e.g., after a rule is created/updated via API).
 * Non-blocking — returns immediately, reload happens asynchronously.
 */
export function invalidateRuleCache(): void {
  void loadRules();
}
