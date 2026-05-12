/**
 * M13 / CR-E — Rule Parser Service.
 *
 * Parses and validates Correlation Rule YAML bodies (matchYaml, produceYaml)
 * against the Annex C.3 grammar.
 *
 * SENSITIVE: matchYaml / produceYaml may contain literal counterparty names
 * and source IDs. Never logged — Pino redact paths cover these fields.
 */
import * as yaml from 'js-yaml';
import { logger } from '../utils/logger.util';

// ============================================================
// Error type
// ============================================================

export interface RuleParseError {
  message: string;
  /** 1-based line number where the error was detected; null if not parseable. */
  line: number | null;
}

export interface RuleParseResult {
  valid: boolean;
  matchBlock?: Record<string, unknown>;
  produceBlock?: Record<string, unknown>;
  errors: RuleParseError[];
}

// ============================================================
// Top-level parser
// ============================================================

/**
 * Parse and validate a match+produce YAML pair.
 *
 * Returns { valid: true, matchBlock, produceBlock, errors: [] } on success.
 * Returns { valid: false, errors: [...] } on failure.
 *
 * SENSITIVE: inputs not logged.
 */
export function parseRuleYaml(matchYaml: string, produceYaml: string): RuleParseResult {
  const errors: RuleParseError[] = [];

  // --- Parse matchYaml ---
  let matchBlock: Record<string, unknown> | null = null;
  try {
    const parsed = yaml.load(matchYaml);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      errors.push({ message: 'matchYaml must be a YAML mapping (object)', line: null });
    } else {
      matchBlock = parsed as Record<string, unknown>;
      const matchErrors = validateMatchBlock(matchBlock);
      errors.push(...matchErrors);
    }
  } catch (err) {
    const yamlErr = err as yaml.YAMLException;
    errors.push({
      message: `matchYaml parse error: ${yamlErr.reason ?? yamlErr.message}`,
      line: yamlErr.mark?.line != null ? yamlErr.mark.line + 1 : null,
    });
  }

  // --- Parse produceYaml ---
  let produceBlock: Record<string, unknown> | null = null;
  try {
    const parsed = yaml.load(produceYaml);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      errors.push({ message: 'produceYaml must be a YAML mapping (object)', line: null });
    } else {
      produceBlock = parsed as Record<string, unknown>;
      const produceErrors = validateProduceBlock(produceBlock);
      errors.push(...produceErrors);
    }
  } catch (err) {
    const yamlErr = err as yaml.YAMLException;
    errors.push({
      message: `produceYaml parse error: ${yamlErr.reason ?? yamlErr.message}`,
      line: yamlErr.mark?.line != null ? yamlErr.mark.line + 1 : null,
    });
  }

  if (errors.length > 0) {
    logger.debug({ action: 'ruleParser.parseRuleYaml', errorCount: errors.length }, 'Rule YAML validation failed');
    return { valid: false, errors };
  }

  return {
    valid: true,
    matchBlock: matchBlock ?? {},
    produceBlock: produceBlock ?? {},
    errors: [],
  };
}

// ============================================================
// Match block validation (Annex C.3)
// ============================================================

const VALID_MATCH_TOP_KEYS = new Set(['signal', 'contract', 'joins', 'anyOf', 'not']);

function validateMatchBlock(block: Record<string, unknown>): RuleParseError[] {
  const errors: RuleParseError[] = [];

  for (const key of Object.keys(block)) {
    if (!VALID_MATCH_TOP_KEYS.has(key)) {
      errors.push({
        message: `matchYaml: unknown top-level key '${key}'. Allowed: ${[...VALID_MATCH_TOP_KEYS].join(', ')}`,
        line: null,
      });
    }
  }

  if (Object.keys(block).length === 0) {
    errors.push({ message: 'matchYaml: match block must have at least one predicate', line: null });
  }

  return errors;
}

// ============================================================
// Produce block validation (Annex C.5)
// ============================================================

const VALID_PRODUCE_TOP_KEYS = new Set(['correlation', 'alert', 'advisory']);
const VALID_ALERT_PRIORITIES = new Set(['low', 'medium', 'high', 'critical']);

function validateProduceBlock(block: Record<string, unknown>): RuleParseError[] {
  const errors: RuleParseError[] = [];

  for (const key of Object.keys(block)) {
    if (!VALID_PRODUCE_TOP_KEYS.has(key)) {
      errors.push({
        message: `produceYaml: unknown top-level key '${key}'. Allowed: ${[...VALID_PRODUCE_TOP_KEYS].join(', ')}`,
        line: null,
      });
    }
  }

  // correlation sub-block is mandatory
  const correlation = block['correlation'];
  if (!correlation) {
    errors.push({ message: "produceYaml: 'correlation' sub-block is required", line: null });
  } else if (typeof correlation === 'object' && !Array.isArray(correlation)) {
    const corrObj = correlation as Record<string, unknown>;
    if (
      typeof corrObj['confidenceBase'] !== 'number' ||
      (corrObj['confidenceBase'] as number) < 0 ||
      (corrObj['confidenceBase'] as number) > 1
    ) {
      errors.push({
        message: "produceYaml: correlation.confidenceBase must be a number between 0 and 1",
        line: null,
      });
    }
    if (typeof corrObj['matchReasonTemplate'] !== 'string') {
      errors.push({
        message: "produceYaml: correlation.matchReasonTemplate must be a string",
        line: null,
      });
    }
  }

  // alert sub-block validation (optional)
  const alert = block['alert'];
  if (alert && typeof alert === 'object' && !Array.isArray(alert)) {
    const alertObj = alert as Record<string, unknown>;
    if (alertObj['priority'] && !VALID_ALERT_PRIORITIES.has(String(alertObj['priority']))) {
      errors.push({
        message: `produceYaml: alert.priority must be one of: ${[...VALID_ALERT_PRIORITIES].join(', ')}`,
        line: null,
      });
    }
    if (alertObj['assignedRoles'] !== undefined && !Array.isArray(alertObj['assignedRoles'])) {
      errors.push({
        message: 'produceYaml: alert.assignedRoles must be an array',
        line: null,
      });
    }
  }

  return errors;
}
