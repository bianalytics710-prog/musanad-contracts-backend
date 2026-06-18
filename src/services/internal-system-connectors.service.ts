/**
 * internal-system-connectors.service.ts
 *
 * The "adapter" half of a connector, expressed DECLARATIVELY. Each connector is
 * a `ConnectorSpec` whose records carry an explicit `fieldMappings` table —
 * "their data model → our data model". That mapping is the SINGLE SOURCE OF
 * TRUTH:
 *   • the PULL (`fetchConnectorRecords`) builds each landed record's snapshot +
 *     record-ref FROM the field mappings, and
 *   • the UI (`getConnectorMappings` → GET /admin/internal-systems/field-mappings)
 *     renders the very same table.
 * So what an integrator sees on the "Field mapping" view is exactly what drives
 * ingestion — not a separate diagram that can drift.
 *
 * In production the per-record sample values are replaced by a real vendor-API
 * fetch; the mapping rows (source field → our field + transform) are unchanged,
 * which is the point — the contract with their system is declared in one place.
 *
 * Each connector declares the contract's already-known finding (re-pulled every
 * run → dedupes against the mig-690 seed) plus one fresh finding, so the first
 * Sync reports "pulled 2 → created 1, deduped 1".
 */

type Severity = 'informational' | 'low' | 'medium' | 'high' | 'critical';

// ── Declarative mapping types ────────────────────────────────────────────────

/** Where a source field lands in our model, + how it is shown to integrators. */
export type FieldRole =
  | 'identity' // becomes osint_signal.source_record_ref (the record key)
  | 'snapshot' // preserved verbatim in source_record_snapshot.fields[]
  | 'derived' // computed by the connector (not a 1:1 source field)
  | 'routing'; // used to route into our model (e.g. which contract)

export interface ConnectorFieldMapping {
  /** Their data-model field (API field / column). */
  sourceField: string;
  /** Human label shown in the record + mapping view. */
  sourceLabel: string;
  /** Example value (the sample we pull in the demo). */
  sampleValue: string;
  /** Our data-model target (dotted path). */
  targetField: string;
  /** How the value is transformed on the way in. */
  transform: string;
  role: FieldRole;
}

/** One record type a connector emits → one of our internal signals. */
interface ConnectorRecordSpec {
  signalType: string;
  recordType: string;
  contractId: number;
  severity: Severity;
  summary: string;
  matchReason: string;
  ruleId: string;
  confidence: number;
  caseTitle: string;
  caseBody: string;
  assignedRole: string;
  slaHours: number;
  materialityAed?: number;
  tier: number;
  suppressedReason?: string;
  dedupeKey: string;
  /** their data model → our data model (drives the pull AND the view). */
  fieldMappings: ConnectorFieldMapping[];
}

interface ConnectorSpec {
  systemCode: string;
  systemName: string;
  systemKind: string;
  baseUrl: string;
  records: ConnectorRecordSpec[];
}

/** The normalised record shape consumed by fn_internal_system_sync_run. */
export interface ConnectorRecord {
  signalType: string;
  contractId: number;
  observedAt: string;
  severity: Severity;
  recordRef: string;
  recordUrl: string;
  title: string;
  summary: string;
  snapshot: {
    systemName: string;
    systemCode: string;
    systemKind: string;
    recordType: string;
    recordId: string;
    recordUrl: string;
    capturedAt: string;
    fields: Array<{ label: string; value: string }>;
  };
  matchReason: string;
  ruleId: string;
  confidence: number;
  caseType: string;
  casePriority: Severity;
  caseTitle: string;
  caseBody: string;
  assignedRole: string;
  slaHours: number;
  materialityAed?: number;
  tier: number;
  suppressedReason?: string;
  dedupeKey: string;
}

// ── Connector specs (the declared "their model → our model" contracts) ────────

const CONNECTOR_SPECS: ConnectorSpec[] = [
  {
    systemCode: 'sap_s4_finance',
    systemName: 'SAP S/4HANA Finance',
    systemKind: 'finance',
    baseUrl: 'https://s4hana-finance.adnoc.ae',
    records: [
      // (a) already-known budget overrun — re-pulled, dedupes against seed.
      {
        signalType: 'budget_overrun',
        recordType: 'Purchase Order / WBS element',
        contractId: 52,
        severity: 'high',
        summary: 'SAP S/4HANA Finance: committed cost has exceeded the approved budget by 8.5%.',
        matchReason:
          'Committed cost exceeds approved budget by 8.5% (SAP S/4HANA Finance PO 4500087231)',
        ruleId: 'rule.internal.budget_overrun',
        confidence: 0.92,
        caseTitle: 'Budget overrun — committed cost 8.5% over approved budget',
        caseBody:
          'SAP S/4HANA Finance reports committed cost of AED 4.579B against an approved budget of AED 4.220B.',
        assignedRole: 'finance_treasury',
        slaHours: 48,
        materialityAed: 358700000,
        tier: 2,
        dedupeKey: 'internal-demo-budget-overrun-52',
        fieldMappings: [
          { sourceField: 'EBELN', sourceLabel: 'PO number', sampleValue: 'PO 4500087231', targetField: 'osint_signal.source_record_ref', transform: 'verbatim', role: 'identity' },
          { sourceField: 'BAPI_BUDGET.APPROVED', sourceLabel: 'Approved budget', sampleValue: 'AED 4,220,000,000', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: 'BAPI_BUDGET.COMMITTED', sourceLabel: 'Committed to date', sampleValue: 'AED 4,578,700,000', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: '(derived)', sourceLabel: 'Variance', sampleValue: '+8.5% (AED 358,700,000)', targetField: 'source_record_snapshot.fields[]', transform: 'derived: committed − approved', role: 'snapshot' },
        ],
      },
      // (b) NEW finding this pull — an overdue AP invoice → fresh risk case.
      {
        signalType: 'payment_delay',
        recordType: 'AP invoice',
        contractId: 52,
        severity: 'high',
        summary:
          'SAP S/4HANA Finance: accounts-payable invoice INV-2026-0442 is 37 days past its due date and on payment block.',
        matchReason:
          'AP invoice INV-2026-0442 (AED 142.5M) is 37 days overdue and on payment block R (SAP S/4HANA Finance)',
        ruleId: 'rule.internal.payment_delay',
        confidence: 0.9,
        caseTitle: 'Payment delay — vendor invoice 37 days overdue',
        caseBody:
          'SAP S/4HANA Finance shows AP invoice INV-2026-0442 (AED 142.5M) to Hero Marine Services LLC is 37 days past its 2026-05-12 due date and held on payment block R. Late-payment penalty exposure under the contract. Confirm as a finance risk or dismiss as noise.',
        assignedRole: 'finance_treasury',
        slaHours: 48,
        materialityAed: 142500000,
        tier: 2,
        suppressedReason:
          'Single-source (SAP) — confidence below Finance auto-route floor; exec confirmation requested.',
        dedupeKey: 'internal-sync-sap_s4_finance-52-inv-2026-0442',
        fieldMappings: [
          { sourceField: 'BELNR', sourceLabel: 'Invoice #', sampleValue: 'INV-2026-0442', targetField: 'osint_signal.source_record_ref', transform: 'verbatim', role: 'identity' },
          { sourceField: 'WRBTR', sourceLabel: 'Invoice amount', sampleValue: 'AED 142,500,000', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: 'ZFBDT', sourceLabel: 'Due date', sampleValue: '2026-05-12', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: '(derived)', sourceLabel: 'Days overdue', sampleValue: '37 days', targetField: 'source_record_snapshot.fields[]', transform: 'derived: today − ZFBDT (net due)', role: 'snapshot' },
          { sourceField: 'LIFNR → NAME1', sourceLabel: 'Vendor', sampleValue: 'Hero Marine Services LLC', targetField: 'source_record_snapshot.fields[]', transform: 'vendor-master lookup', role: 'snapshot' },
          { sourceField: 'ZLSPR', sourceLabel: 'Payment block', sampleValue: 'R — invoice verification', targetField: 'source_record_snapshot.fields[]', transform: 'block-code → text', role: 'snapshot' },
        ],
      },
    ],
  },
  {
    systemCode: 'servicenow_itsm',
    systemName: 'ServiceNow ITSM',
    systemKind: 'itsm',
    baseUrl: 'https://adnoc.service-now.com',
    records: [
      // (a) already-known SLA breach — re-pulled, dedupes against seed.
      {
        signalType: 'sla_breach',
        recordType: 'Incident',
        contractId: 243,
        severity: 'medium',
        summary: 'ServiceNow ITSM: a P2 incident resolution exceeded the contractual SLA target.',
        matchReason:
          'Incident INC0048921 resolved in 19h 42m against an 8h P2 SLA target (ServiceNow ITSM)',
        ruleId: 'rule.internal.sla_breach',
        confidence: 0.83,
        caseTitle: 'SLA breach — P2 incident 11h 42m over target',
        caseBody: 'ServiceNow ITSM reports incident INC0048921 resolved 11h 42m beyond its 8h P2 SLA target.',
        assignedRole: 'operations',
        slaHours: 48,
        tier: 2,
        dedupeKey: 'internal-demo-sla-breach-243',
        fieldMappings: [
          { sourceField: 'number', sourceLabel: 'Incident #', sampleValue: 'INC0048921', targetField: 'osint_signal.source_record_ref', transform: 'verbatim', role: 'identity' },
          { sourceField: 'sla.target', sourceLabel: 'SLA target', sampleValue: 'Resolve within 8h (P2)', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: '(derived)', sourceLabel: 'Actual resolution', sampleValue: '19h 42m', targetField: 'source_record_snapshot.fields[]', transform: 'derived: closed_at − opened_at', role: 'snapshot' },
        ],
      },
      // (b) NEW finding this pull — a fresh P2 telemetry incident.
      {
        signalType: 'sla_breach',
        recordType: 'Incident',
        contractId: 243,
        severity: 'medium',
        summary:
          'ServiceNow ITSM: a P2 incident on the pipeline SCADA telemetry feed exceeded its contractual resolution SLA.',
        matchReason:
          'Incident INC0049310 resolved in 14h 18m against an 8h P2 SLA target — 6h 18m breach (ServiceNow ITSM)',
        ruleId: 'rule.internal.sla_breach',
        confidence: 0.81,
        caseTitle: 'SLA breach — SCADA telemetry incident 6h 18m over target',
        caseBody:
          'ServiceNow ITSM reports P2 incident INC0049310 on the pipeline SCADA telemetry feed resolved in 14h 18m against an 8h SLA target — a 6h 18m breach of the contracted availability terms. Confirm as an operations risk or dismiss as noise.',
        assignedRole: 'operations',
        slaHours: 48,
        tier: 2,
        suppressedReason: 'Recurring service — confirm material breach before paging Operations.',
        dedupeKey: 'internal-sync-servicenow_itsm-243-inc0049310',
        fieldMappings: [
          { sourceField: 'number', sourceLabel: 'Incident #', sampleValue: 'INC0049310', targetField: 'osint_signal.source_record_ref', transform: 'verbatim', role: 'identity' },
          { sourceField: 'sla.target', sourceLabel: 'SLA target', sampleValue: 'Resolve within 8h (P2)', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: '(derived)', sourceLabel: 'Actual resolution', sampleValue: '14h 18m', targetField: 'source_record_snapshot.fields[]', transform: 'derived: closed_at − opened_at', role: 'snapshot' },
          { sourceField: '(derived)', sourceLabel: 'Breach', sampleValue: '+6h 18m over target', targetField: 'source_record_snapshot.fields[]', transform: 'derived: actual − SLA target', role: 'snapshot' },
          { sourceField: 'cmdb_ci', sourceLabel: 'Service', sampleValue: 'Pipeline SCADA telemetry feed', targetField: 'source_record_snapshot.fields[]', transform: 'CI-name lookup', role: 'snapshot' },
        ],
      },
    ],
  },
  {
    systemCode: 'primavera_p6',
    systemName: 'Oracle Primavera P6',
    systemKind: 'scm',
    baseUrl: 'https://p6.adnoc.ae',
    records: [
      // (a) already-known slippage — re-pulled, dedupes against seed.
      {
        signalType: 'milestone_slippage',
        recordType: 'Schedule activity',
        contractId: 77,
        severity: 'high',
        summary: 'Oracle Primavera P6: a critical-path activity is forecast 21 days behind baseline.',
        matchReason:
          'Critical-path activity A1340 forecast 21 days behind baseline finish (Oracle Primavera P6)',
        ruleId: 'rule.internal.milestone_slippage',
        confidence: 0.88,
        caseTitle: 'Milestone slippage — critical-path activity 21 days behind baseline',
        caseBody: 'Oracle Primavera P6 shows critical-path activity A1340 forecast to finish 21 days after baseline.',
        assignedRole: 'operations',
        slaHours: 48,
        materialityAed: 95000000,
        tier: 2,
        dedupeKey: 'internal-demo-milestone-slippage-77',
        fieldMappings: [
          { sourceField: 'activity_id', sourceLabel: 'Activity ID', sampleValue: 'A1340 — Mechanical Completion', targetField: 'osint_signal.source_record_ref', transform: 'verbatim', role: 'identity' },
          { sourceField: '(derived)', sourceLabel: 'Days slipped', sampleValue: '21 days', targetField: 'source_record_snapshot.fields[]', transform: 'derived: forecast − baseline finish', role: 'snapshot' },
          { sourceField: 'critical_path_flag', sourceLabel: 'On critical path', sampleValue: 'Yes', targetField: 'source_record_snapshot.fields[]', transform: 'boolean → Yes/No', role: 'snapshot' },
        ],
      },
      // (b) NEW finding this pull — a fresh commissioning slip.
      {
        signalType: 'milestone_slippage',
        recordType: 'Schedule activity',
        contractId: 77,
        severity: 'high',
        summary: 'Oracle Primavera P6: commissioning activity A1455 is forecast 14 days behind its baseline finish.',
        matchReason:
          'Critical-path activity A1455 forecast 14 days behind baseline finish (Oracle Primavera P6)',
        ruleId: 'rule.internal.milestone_slippage',
        confidence: 0.86,
        caseTitle: 'Milestone slippage — pre-commissioning handover 14 days behind baseline',
        caseBody:
          'Oracle Primavera P6 shows critical-path activity A1455 (Pre-Commissioning Handover) forecast to finish 14 days after its 2026-06-30 baseline — compounding the earlier mechanical-completion slip and exposing the contract to liquidated damages. Confirm as an operations risk or dismiss as noise.',
        assignedRole: 'operations',
        slaHours: 48,
        materialityAed: 62000000,
        tier: 2,
        suppressedReason: 'Forecast (not actual) slippage — exec confirmation requested before paging Operations.',
        dedupeKey: 'internal-sync-primavera_p6-77-a1455',
        fieldMappings: [
          { sourceField: 'activity_id', sourceLabel: 'Activity ID', sampleValue: 'A1455 — Pre-Commissioning Handover', targetField: 'osint_signal.source_record_ref', transform: 'verbatim', role: 'identity' },
          { sourceField: 'baseline_finish', sourceLabel: 'Baseline finish', sampleValue: '2026-06-30', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: 'forecast_finish', sourceLabel: 'Forecast finish', sampleValue: '2026-07-14', targetField: 'source_record_snapshot.fields[]', transform: 'preserved verbatim', role: 'snapshot' },
          { sourceField: '(derived)', sourceLabel: 'Days slipped', sampleValue: '14 days', targetField: 'source_record_snapshot.fields[]', transform: 'derived: forecast − baseline finish', role: 'snapshot' },
          { sourceField: 'critical_path_flag', sourceLabel: 'On critical path', sampleValue: 'Yes', targetField: 'source_record_snapshot.fields[]', transform: 'boolean → Yes/No', role: 'snapshot' },
        ],
      },
    ],
  },
];

const SPEC_BY_CODE: Record<string, ConnectorSpec> = Object.fromEntries(
  CONNECTOR_SPECS.map((s) => [s.systemCode, s]),
);

// ── Pull: build landed records FROM the declared mappings ────────────────────

function buildRecord(
  spec: ConnectorSpec,
  rec: ConnectorRecordSpec,
  now: string,
): ConnectorRecord {
  const identity = rec.fieldMappings.find((m) => m.role === 'identity');
  const recordRef = identity?.sampleValue ?? rec.dedupeKey;
  const recordUrl = `${spec.baseUrl}/record/${encodeURIComponent(recordRef)}`;
  // The snapshot the customer sees is generated straight from the field map —
  // identity + preserved fields, in declared order.
  const fields = rec.fieldMappings
    .filter((m) => m.role === 'identity' || m.role === 'snapshot')
    .map((m) => ({ label: m.sourceLabel, value: m.sampleValue }));
  const title = `${rec.caseTitle}`;

  return {
    signalType: rec.signalType,
    contractId: rec.contractId,
    observedAt: now,
    severity: rec.severity,
    recordRef,
    recordUrl,
    title,
    summary: rec.summary,
    snapshot: {
      systemName: spec.systemName,
      systemCode: spec.systemCode,
      systemKind: spec.systemKind,
      recordType: rec.recordType,
      recordId: recordRef,
      recordUrl,
      capturedAt: now,
      fields,
    },
    matchReason: rec.matchReason,
    ruleId: rec.ruleId,
    confidence: rec.confidence,
    caseType: 'correlation_alert',
    casePriority: rec.severity,
    caseTitle: rec.caseTitle,
    caseBody: rec.caseBody,
    assignedRole: rec.assignedRole,
    slaHours: rec.slaHours,
    materialityAed: rec.materialityAed,
    tier: rec.tier,
    suppressedReason: rec.suppressedReason,
    dedupeKey: rec.dedupeKey,
  };
}

/** True when a system_code has an end-to-end adapter wired (Option A connector). */
export const hasConnectorAdapter = (systemCode: string): boolean =>
  Object.prototype.hasOwnProperty.call(SPEC_BY_CODE, systemCode);

/**
 * Run the adapter for a system_code and return the normalised records to land.
 * Returns null when the system has no adapter (registry-only connector).
 */
export const fetchConnectorRecords = (systemCode: string): ConnectorRecord[] | null => {
  const spec = SPEC_BY_CODE[systemCode];
  if (!spec) return null;
  const now = new Date().toISOString();
  return spec.records.map((rec) => buildRecord(spec, rec, now));
};

// ── Mapping view: expose the declared mappings to the UI ─────────────────────

export interface ConnectorMappingView {
  systemCode: string;
  systemName: string;
  systemKind: string;
  recordTypes: Array<{
    recordType: string;
    signalType: string;
    fieldMappings: ConnectorFieldMapping[];
    /** routing/derivation rows generated from the same scalars the pull uses. */
    derived: Array<{ sourceLabel: string; sampleValue: string; targetField: string; transform: string }>;
  }>;
}

/**
 * The declarative "their model → our model" contract for every wired connector.
 * Reads the SAME specs the pull uses, so the view can never drift from reality.
 */
export const getConnectorMappings = (): ConnectorMappingView[] =>
  CONNECTOR_SPECS.map((spec) => ({
    systemCode: spec.systemCode,
    systemName: spec.systemName,
    systemKind: spec.systemKind,
    recordTypes: spec.records.map((rec) => ({
      recordType: rec.recordType,
      signalType: rec.signalType,
      fieldMappings: rec.fieldMappings,
      derived: [
        { sourceLabel: 'Signal type', sampleValue: rec.signalType, targetField: 'osint_signal.signal_kind_subtype', transform: 'classified by connector rule' },
        { sourceLabel: 'Severity', sampleValue: rec.severity, targetField: 'osint_signal.severity_v2', transform: 'derived from thresholds' },
        { sourceLabel: 'Linked contract', sampleValue: `contract #${rec.contractId}`, targetField: 'correlation.contract_id', transform: 'matched by contract reference' },
      ],
    })),
  }));
