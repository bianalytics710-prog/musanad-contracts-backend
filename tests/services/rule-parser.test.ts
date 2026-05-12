/**
 * M13 / CR-E — rule-parser.service.ts unit tests.
 *
 * Tests the YAML parser + Annex C.3 grammar validator used by:
 *   - fn_rule_create / fn_rule_update (via BE controller → parser)
 *   - All 7 shipped worked rules' YAML must parse cleanly
 *
 * No DB connection required — pure TypeScript unit tests.
 *
 * KEY SCHEMA:
 *   matchYaml top-level keys: signal | contract | joins | anyOf | not
 *   produceYaml uses camelCase: confidenceBase, matchReasonTemplate
 *   alert.priority is the only enum-validated field
 */
import { describe, it, expect } from 'vitest';
import { parseRuleYaml } from '../../src/services/rule-parser.service';

// ─────────────────────────────────────────────────────────────────────────────
// Valid YAML fixtures using actual Annex C schema (signal/contract sub-blocks,
// camelCase keys in produce block)
// ─────────────────────────────────────────────────────────────────────────────

const SANCTIONS_MATCH = `
signal:
  kind: sanctions
  severityMin: medium
  sourceIdIn:
    - ofac_sdn
    - eu_consolidated
`.trim();

const SANCTIONS_PRODUCE = `
correlation:
  confidenceBase: 0.95
  matchReasonTemplate: "Sanctions designation by {{signal.sourceId}} affects counterparty {{contract.counterparty.name}}"
  category: sanctions_risk
`.trim();

const BRENT_MATCH = `
signal:
  kind: commodity_index
  sourceIdIn:
    - brent_crude
contract:
  hasClause:
    clauseType: price_review
`.trim();

const BRENT_PRODUCE = `
correlation:
  confidenceBase: 0.88
  matchReasonTemplate: "Brent crossed threshold; price review trigger applies to {{contract.title}}"
  category: pricing_risk
`.trim();

const RENEWAL_MATCH = `
signal:
  kind: calendar_timer
contract:
  renewalWithinDays: 90
  hasClause:
    clauseType: term_and_renewal
`.trim();

const RENEWAL_PRODUCE = `
correlation:
  confidenceBase: 0.75
  matchReasonTemplate: "Contract expires in {{contract.renewalWithinDays}} days"
  category: contract_lifecycle
`.trim();

const HORMUZ_MATCH = `
signal:
  kind: geopolitical
  geographyIntersects:
    - persian_gulf
    - strait_of_hormuz
  severityMin: high
`.trim();

const HORMUZ_PRODUCE = `
correlation:
  confidenceBase: 0.82
  matchReasonTemplate: "Geopolitical disruption affects contract"
  category: logistics_risk
`.trim();

const EPC_MATCH = `
signal:
  kind: internal
  rawField:
    path: signal_type
    equals: milestone_slippage
contract:
  hasClause:
    clauseType: sla_performance
`.trim();

const EPC_PRODUCE = `
correlation:
  confidenceBase: 0.85
  matchReasonTemplate: "EPC milestone slippage pattern detected"
  category: performance_risk
`.trim();

const SANCTIONS_CHAIN_MATCH = `
signal:
  kind: sanctions
  sourceIdIn:
    - ofac_sdn
joins:
  entityMatch:
    contractField: counterparty.id
    signalField: affectedEntities[*].id
`.trim();

const SANCTIONS_CHAIN_PRODUCE = `
correlation:
  confidenceBase: 0.90
  matchReasonTemplate: "Sanctions chain reaches counterparty {{contract.counterparty.name}}"
  category: sanctions_risk
`.trim();

const INVALID_MATCH_YAML = `
kind: [unclosed
`.trim();

const MISSING_CORRELATION_PRODUCE = `
alert:
  title: something
  priority: high
`.trim();

const INVALID_CONFIDENCE_PRODUCE = `
correlation:
  confidenceBase: 1.5
  matchReasonTemplate: "test"
`.trim();

const INVALID_ALERT_PRIORITY_PRODUCE = `
correlation:
  confidenceBase: 0.80
  matchReasonTemplate: "test"
alert:
  priority: VERY_HIGH
`.trim();

// ─────────────────────────────────────────────────────────────────────────────
// Positive cases — each worked rule's YAML parses cleanly
// ─────────────────────────────────────────────────────────────────────────────

describe('rule-parser — positive cases', () => {
  it('AC-S12-04: sanctions rule YAML parses cleanly', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, SANCTIONS_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.matchBlock).toBeDefined();
    expect(result.produceBlock).toBeDefined();
  });

  it('AC-S12-04: matchBlock contains the signal sub-object', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, SANCTIONS_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.matchBlock).toHaveProperty('signal');
    const signal = result.matchBlock!['signal'] as Record<string, unknown>;
    expect(signal['kind']).toBe('sanctions');
  });

  it('AC-S12-04: produceBlock contains confidenceBase + matchReasonTemplate', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, SANCTIONS_PRODUCE);
    expect(result.valid).toBe(true);
    const corr = result.produceBlock!['correlation'] as Record<string, unknown>;
    expect(corr['confidenceBase']).toBe(0.95);
    expect(typeof corr['matchReasonTemplate']).toBe('string');
  });

  it('AC-S17-02: brent price review rule YAML parses cleanly', () => {
    const result = parseRuleYaml(BRENT_MATCH, BRENT_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('AC-S19-02: renewal lookahead rule YAML parses cleanly', () => {
    const result = parseRuleYaml(RENEWAL_MATCH, RENEWAL_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('AC-S16-02: Hormuz geopolitical rule parses cleanly', () => {
    const result = parseRuleYaml(HORMUZ_MATCH, HORMUZ_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('AC-S18-02: EPC SLA rule with rawField + hasClause parses cleanly', () => {
    const result = parseRuleYaml(EPC_MATCH, EPC_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('AC-S15-02: sanctions chain rule with joins.entityMatch parses cleanly', () => {
    const result = parseRuleYaml(SANCTIONS_CHAIN_MATCH, SANCTIONS_CHAIN_PRODUCE);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('AC-S12-04: anyOf combinator parses cleanly', () => {
    const match = `
anyOf:
  - signal:
      kind: sanctions
  - signal:
      kind: geopolitical
      severityMin: high
`.trim();
    const produce = `
correlation:
  confidenceBase: 0.80
  matchReasonTemplate: "Multi-risk signal detected"
`.trim();
    const result = parseRuleYaml(match, produce);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('AC-S12-04: not combinator parses cleanly', () => {
    const match = `
signal:
  kind: sanctions
not:
  signal:
    sourceIdIn:
      - low_confidence_source
`.trim();
    const produce = `
correlation:
  confidenceBase: 0.78
  matchReasonTemplate: "High-confidence sanctions signal"
`.trim();
    const result = parseRuleYaml(match, produce);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Negative cases — parser must reject invalid YAML with errors
// ─────────────────────────────────────────────────────────────────────────────

describe('rule-parser — negative cases', () => {
  it('AC-S12-04: malformed YAML in matchYaml returns valid=false with line error', () => {
    const result = parseRuleYaml(INVALID_MATCH_YAML, SANCTIONS_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
    // Should include a line number hint
    const lineErrors = result.errors.filter((e) => e.line !== null);
    expect(lineErrors.length).toBeGreaterThan(0);
  });

  it('AC-S12-04: malformed YAML in produceYaml returns valid=false', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, 'correlation: [unclosed');
    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it('AC-S12-04: missing correlation key in produceYaml returns valid=false', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, MISSING_CORRELATION_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.message.toLowerCase().includes('correlation'))).toBe(true);
  });

  it('AC-S12-04: confidenceBase > 1.0 returns valid=false', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, INVALID_CONFIDENCE_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.message.toLowerCase().includes('confidence'))).toBe(true);
  });

  it('AC-S12-04: invalid alert.priority enum returns valid=false', () => {
    const result = parseRuleYaml(SANCTIONS_MATCH, INVALID_ALERT_PRIORITY_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.message.toLowerCase().includes('priority'))).toBe(true);
  });

  it('AC-S12-04: empty matchYaml string returns valid=false', () => {
    const result = parseRuleYaml('', SANCTIONS_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it('AC-S12-04: YAML array (not object) as matchYaml returns valid=false', () => {
    const result = parseRuleYaml('- item1\n- item2', SANCTIONS_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.message.includes('mapping'))).toBe(true);
  });

  it('AC-S12-04: unknown top-level key in matchYaml returns valid=false', () => {
    // "kind" is not a valid top-level match key — must be under signal:
    const result = parseRuleYaml('kind: sanctions\nseverityMin: medium', SANCTIONS_PRODUCE);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.message.toLowerCase().includes("unknown"))).toBe(true);
  });
});
