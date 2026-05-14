/**
 * CR-J — Demo Seed Loader Service.
 *
 * Coordinates contracts + counterparties + clauses + obligations + signals +
 * correlations + scores + advisory drafts for each scenario. Reads seed packs
 * from seeds/adnoc-pack/scenarios/<scenario_id>/ (v1 minimal fixtures).
 *
 * Called by fn_demo_reset (which handles the DB-side purge + reload), but also
 * available for direct seeding in E2E harness and health-check verification.
 *
 * NOTE: The primary seed path for demo reset runs INSIDE fn_demo_reset via
 * fn_demo_seed_load_* family functions. This service provides a BE-side
 * coordination layer for external fixture injection and scenario readiness
 * verification — it does NOT duplicate what fn_demo_reset does in the DB.
 */
import { readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { logger } from '../utils/logger.util';

const SCENARIOS_DIR = resolve(process.cwd(), 'seeds/adnoc-pack/scenarios');

export interface ScenarioSeedManifest {
  scenarioId: string;
  description: string;
  /** Minimal fixture v1 note — full seed handled by fn_demo_seed_load_* */
  fixturesNote: string;
}

/** Read the scenario manifest if present; returns null if directory empty. */
export const loadScenarioManifest = async (
  scenarioId: string,
): Promise<ScenarioSeedManifest | null> => {
  const manifestPath = join(SCENARIOS_DIR, scenarioId, 'manifest.json');
  try {
    const raw = await readFile(manifestPath, 'utf8');
    return JSON.parse(raw) as ScenarioSeedManifest;
  } catch {
    // No manifest file — scenario uses DB-side seed functions entirely
    return null;
  }
};

/** List scenario IDs that have seed directories on disk. */
export const listSeededScenarios = async (): Promise<string[]> => {
  try {
    const { readdir } = await import('node:fs/promises');
    const entries = await readdir(SCENARIOS_DIR, { withFileTypes: true });
    return entries
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch {
    return [];
  }
};

/**
 * Verify that the scenario directory structure exists for a given scenarioId.
 * Returns true even when directory is empty — empty dir = v1 minimal, DB-side
 * seed handles the actual data injection.
 */
export const scenarioDirectoryExists = async (
  scenarioId: string,
): Promise<boolean> => {
  try {
    const { stat } = await import('node:fs/promises');
    const dirPath = join(SCENARIOS_DIR, scenarioId);
    const stats = await stat(dirPath);
    return stats.isDirectory();
  } catch {
    return false;
  }
};

/**
 * Ensure scenario seed directories exist for all 8 known CR-I scenario IDs.
 * Creates empty directories on first run. Called during app startup in dev mode.
 *
 * IMPORTANT: Actual data seeding is handled by fn_demo_seed_load_* family
 * inside the DB fn_demo_reset transaction. These directories are scaffolding
 * for future fixture file injection.
 */
export const ensureScenarioDirectories = async (): Promise<void> => {
  const knownScenarios = [
    'cyclone',
    'sanctions_shock',
    'oil_price_spike',
    'force_majeure_port',
    'regulatory_change',
    'counterparty_default',
    'esg_concern',
    'supply_chain_disruption',
  ];
  const { mkdir } = await import('node:fs/promises');
  for (const id of knownScenarios) {
    try {
      const dirPath = join(SCENARIOS_DIR, id);
      await mkdir(dirPath, { recursive: true });
    } catch {
      // Already exists or permission error — non-fatal
    }
  }
  logger.debug(
    { action: 'demo.seed.ensureDirectories', scenarioCount: knownScenarios.length },
    'Scenario seed directories ensured',
  );
};
