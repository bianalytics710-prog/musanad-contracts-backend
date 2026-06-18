/**
 * internal-system-connectors.service.ts
 *
 * The "adapter" half of a connector. For the three end-to-end (Option A)
 * connectors — SAP S/4HANA Finance, ServiceNow ITSM, Oracle Primavera P6 — this
 * is where, in production, we would call the vendor's published API, page
 * through results, and map their fields onto our internal-signal model.
 *
 * For the pilot/demo the adapters return a small, DETERMINISTIC set of sample
 * records (sandbox data) so a "Sync now" produces realistic risk without a live
 * corporate-network connection. The mapping logic — record → our normalised
 * shape — is identical to what the real adapter would emit, so swapping the
 * sample fetch for a real HTTP call is the only production change.
 *
 * Each record is handed verbatim to fn_internal_system_sync_run (mig 706),
 * which lands it as osint_signal → correlation → risk_case. Records carry a
 * stable `dedupeKey` so re-running a sync is idempotent (re-pulled findings
 * report as `deduped`, not duplicated).
 *
 * Deliberately, each adapter re-pulls the contract's already-known finding
 * (matching a mig-690 seed dedupe_key, so it dedupes) AND surfaces one fresh
 * finding — so the first Sync shows "pulled 2 → created 1, deduped 1", which is
 * exactly how a real incremental pull behaves.
 */

/** Normalised record shape consumed by fn_internal_system_sync_run. */
export interface ConnectorRecord {
  signalType: string;
  contractId: number;
  observedAt: string;
  severity: 'informational' | 'low' | 'medium' | 'high' | 'critical';
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
  casePriority: 'low' | 'medium' | 'high' | 'critical';
  caseTitle: string;
  caseBody: string;
  assignedRole: string;
  slaHours: number;
  materialityAed?: number;
  tier: number;
  suppressedReason?: string;
  dedupeKey: string;
}

type Adapter = (now: string) => ConnectorRecord[];

// ── SAP S/4HANA Finance (Finance) — payment / budget signals on contract 52 ──
const sapS4Finance: Adapter = (now) => [
  // (a) already-known budget overrun — re-pulled each run, dedupes against seed.
  {
    signalType: 'invoice_dispute',
    contractId: 52,
    observedAt: now,
    severity: 'high',
    recordRef: 'PO 4500087231',
    recordUrl: 'https://s4hana-finance.adnoc.ae/record/PO-4500087231',
    title: 'Budget Overrun — Jack-Up Drilling Rigs committed cost +8.5%',
    summary: 'SAP S/4HANA Finance: committed cost has exceeded the approved budget by 8.5%.',
    snapshot: {
      systemName: 'SAP S/4HANA Finance', systemCode: 'sap_s4_finance', systemKind: 'finance',
      recordType: 'Purchase Order / WBS element', recordId: 'PO 4500087231',
      recordUrl: 'https://s4hana-finance.adnoc.ae/record/PO-4500087231', capturedAt: now,
      fields: [
        { label: 'Approved budget', value: 'AED 4,220,000,000' },
        { label: 'Committed to date', value: 'AED 4,578,700,000' },
        { label: 'Variance', value: '+8.5% (AED 358,700,000)' },
      ],
    },
    matchReason: 'Committed cost exceeds approved budget by 8.5% (SAP S/4HANA Finance PO 4500087231)',
    ruleId: 'rule.internal.budget_overrun', confidence: 0.92,
    caseType: 'correlation_alert', casePriority: 'high',
    caseTitle: 'Budget overrun — committed cost 8.5% over approved budget',
    caseBody: 'SAP S/4HANA Finance reports committed cost of AED 4.579B against an approved budget of AED 4.220B.',
    assignedRole: 'finance_treasury', slaHours: 48, materialityAed: 358700000, tier: 2,
    dedupeKey: 'internal-demo-budget-overrun-52',
  },
  // (b) NEW finding this pull — an overdue AP invoice → fresh risk case.
  {
    signalType: 'payment_delay',
    contractId: 52,
    observedAt: now,
    severity: 'high',
    recordRef: 'INV-2026-0442',
    recordUrl: 'https://s4hana-finance.adnoc.ae/record/INV-2026-0442',
    title: 'Payment Delay — Vendor invoice INV-2026-0442 overdue 37 days',
    summary: 'SAP S/4HANA Finance: accounts-payable invoice INV-2026-0442 is 37 days past its due date and on payment block.',
    snapshot: {
      systemName: 'SAP S/4HANA Finance', systemCode: 'sap_s4_finance', systemKind: 'finance',
      recordType: 'AP invoice', recordId: 'INV-2026-0442',
      recordUrl: 'https://s4hana-finance.adnoc.ae/record/INV-2026-0442', capturedAt: now,
      fields: [
        { label: 'Invoice #', value: 'INV-2026-0442' },
        { label: 'Invoice amount', value: 'AED 142,500,000' },
        { label: 'Due date', value: '2026-05-12' },
        { label: 'Days overdue', value: '37 days' },
        { label: 'Vendor', value: 'Hero Marine Services LLC' },
        { label: 'Payment block', value: 'R — invoice verification' },
      ],
    },
    matchReason: 'AP invoice INV-2026-0442 (AED 142.5M) is 37 days overdue and on payment block R (SAP S/4HANA Finance)',
    ruleId: 'rule.internal.payment_delay', confidence: 0.9,
    caseType: 'correlation_alert', casePriority: 'high',
    caseTitle: 'Payment delay — vendor invoice 37 days overdue',
    caseBody:
      'SAP S/4HANA Finance shows AP invoice INV-2026-0442 (AED 142.5M) to Hero Marine Services LLC is 37 days past its 2026-05-12 due date and held on payment block R. Late-payment penalty exposure under the contract. Confirm as a finance risk or dismiss as noise.',
    assignedRole: 'finance_treasury', slaHours: 48, materialityAed: 142500000, tier: 2,
    suppressedReason: 'Single-source (SAP) — confidence below Finance auto-route floor; exec confirmation requested.',
    dedupeKey: 'internal-sync-sap_s4_finance-52-inv-2026-0442',
  },
];

// ── ServiceNow ITSM — SLA-breach incidents on contract 243 ───────────────────
const serviceNowItsm: Adapter = (now) => [
  // (a) already-known SLA breach — re-pulled, dedupes against seed.
  {
    signalType: 'sla_breach',
    contractId: 243,
    observedAt: now,
    severity: 'medium',
    recordRef: 'INC0048921',
    recordUrl: 'https://adnoc.service-now.com/record/INC0048921',
    title: 'SLA Breach — Gas dispatch scheduling API incident +11h',
    summary: 'ServiceNow ITSM: a P2 incident resolution exceeded the contractual SLA target.',
    snapshot: {
      systemName: 'ServiceNow ITSM', systemCode: 'servicenow_itsm', systemKind: 'itsm',
      recordType: 'Incident', recordId: 'INC0048921',
      recordUrl: 'https://adnoc.service-now.com/record/INC0048921', capturedAt: now,
      fields: [
        { label: 'Incident #', value: 'INC0048921' },
        { label: 'SLA target', value: 'Resolve within 8h (P2)' },
        { label: 'Actual resolution', value: '19h 42m' },
      ],
    },
    matchReason: 'Incident INC0048921 resolved in 19h 42m against an 8h P2 SLA target (ServiceNow ITSM)',
    ruleId: 'rule.internal.sla_breach', confidence: 0.83,
    caseType: 'correlation_alert', casePriority: 'medium',
    caseTitle: 'SLA breach — P2 incident 11h 42m over target',
    caseBody: 'ServiceNow ITSM reports incident INC0048921 resolved 11h 42m beyond its 8h P2 SLA target.',
    assignedRole: 'operations', slaHours: 48, tier: 2,
    dedupeKey: 'internal-demo-sla-breach-243',
  },
  // (b) NEW finding this pull — a fresh P2 telemetry incident → fresh risk case.
  {
    signalType: 'sla_breach',
    contractId: 243,
    observedAt: now,
    severity: 'medium',
    recordRef: 'INC0049310',
    recordUrl: 'https://adnoc.service-now.com/record/INC0049310',
    title: 'SLA Breach — Pipeline SCADA telemetry incident +6h 18m',
    summary: 'ServiceNow ITSM: a P2 incident on the pipeline SCADA telemetry feed exceeded its contractual resolution SLA.',
    snapshot: {
      systemName: 'ServiceNow ITSM', systemCode: 'servicenow_itsm', systemKind: 'itsm',
      recordType: 'Incident', recordId: 'INC0049310',
      recordUrl: 'https://adnoc.service-now.com/record/INC0049310', capturedAt: now,
      fields: [
        { label: 'Incident #', value: 'INC0049310' },
        { label: 'SLA target', value: 'Resolve within 8h (P2)' },
        { label: 'Actual resolution', value: '14h 18m' },
        { label: 'Breach', value: '+6h 18m over target' },
        { label: 'Service', value: 'Pipeline SCADA telemetry feed' },
      ],
    },
    matchReason: 'Incident INC0049310 resolved in 14h 18m against an 8h P2 SLA target — 6h 18m breach (ServiceNow ITSM)',
    ruleId: 'rule.internal.sla_breach', confidence: 0.81,
    caseType: 'correlation_alert', casePriority: 'medium',
    caseTitle: 'SLA breach — SCADA telemetry incident 6h 18m over target',
    caseBody:
      'ServiceNow ITSM reports P2 incident INC0049310 on the pipeline SCADA telemetry feed resolved in 14h 18m against an 8h SLA target — a 6h 18m breach of the contracted availability terms. Confirm as an operations risk or dismiss as noise.',
    assignedRole: 'operations', slaHours: 48, tier: 2,
    suppressedReason: 'Recurring service — confirm material breach before paging Operations.',
    dedupeKey: 'internal-sync-servicenow_itsm-243-inc0049310',
  },
];

// ── Oracle Primavera P6 — schedule slippage on contract 77 ───────────────────
const primaveraP6: Adapter = (now) => [
  // (a) already-known slippage — re-pulled, dedupes against seed.
  {
    signalType: 'milestone_slippage',
    contractId: 77,
    observedAt: now,
    severity: 'high',
    recordRef: 'A1340',
    recordUrl: 'https://p6.adnoc.ae/record/A1340',
    title: 'Milestone Slippage — EPC Crude Stabilization critical activity +21d',
    summary: 'Oracle Primavera P6: a critical-path activity is forecast 21 days behind baseline.',
    snapshot: {
      systemName: 'Oracle Primavera P6', systemCode: 'primavera_p6', systemKind: 'scm',
      recordType: 'Schedule activity', recordId: 'A1340 — Mechanical Completion',
      recordUrl: 'https://p6.adnoc.ae/record/A1340', capturedAt: now,
      fields: [
        { label: 'Activity ID', value: 'A1340 — Mechanical Completion' },
        { label: 'Days slipped', value: '21 days' },
        { label: 'On critical path', value: 'Yes' },
      ],
    },
    matchReason: 'Critical-path activity A1340 forecast 21 days behind baseline finish (Oracle Primavera P6)',
    ruleId: 'rule.internal.milestone_slippage', confidence: 0.88,
    caseType: 'correlation_alert', casePriority: 'high',
    caseTitle: 'Milestone slippage — critical-path activity 21 days behind baseline',
    caseBody: 'Oracle Primavera P6 shows critical-path activity A1340 forecast to finish 21 days after baseline.',
    assignedRole: 'operations', slaHours: 48, materialityAed: 95000000, tier: 2,
    dedupeKey: 'internal-demo-milestone-slippage-77',
  },
  // (b) NEW finding this pull — a fresh commissioning slip → fresh risk case.
  {
    signalType: 'milestone_slippage',
    contractId: 77,
    observedAt: now,
    severity: 'high',
    recordRef: 'A1455',
    recordUrl: 'https://p6.adnoc.ae/record/A1455',
    title: 'Milestone Slippage — Commissioning activity A1455 +14d',
    summary: 'Oracle Primavera P6: commissioning activity A1455 is forecast 14 days behind its baseline finish.',
    snapshot: {
      systemName: 'Oracle Primavera P6', systemCode: 'primavera_p6', systemKind: 'scm',
      recordType: 'Schedule activity', recordId: 'A1455 — Pre-Commissioning Handover',
      recordUrl: 'https://p6.adnoc.ae/record/A1455', capturedAt: now,
      fields: [
        { label: 'Activity ID', value: 'A1455 — Pre-Commissioning Handover' },
        { label: 'Baseline finish', value: '2026-06-30' },
        { label: 'Forecast finish', value: '2026-07-14' },
        { label: 'Days slipped', value: '14 days' },
        { label: 'On critical path', value: 'Yes' },
      ],
    },
    matchReason: 'Critical-path activity A1455 forecast 14 days behind baseline finish (Oracle Primavera P6)',
    ruleId: 'rule.internal.milestone_slippage', confidence: 0.86,
    caseType: 'correlation_alert', casePriority: 'high',
    caseTitle: 'Milestone slippage — pre-commissioning handover 14 days behind baseline',
    caseBody:
      'Oracle Primavera P6 shows critical-path activity A1455 (Pre-Commissioning Handover) forecast to finish 14 days after its 2026-06-30 baseline — compounding the earlier mechanical-completion slip and exposing the contract to liquidated damages. Confirm as an operations risk or dismiss as noise.',
    assignedRole: 'operations', slaHours: 48, materialityAed: 62000000, tier: 2,
    suppressedReason: 'Forecast (not actual) slippage — exec confirmation requested before paging Operations.',
    dedupeKey: 'internal-sync-primavera_p6-77-a1455',
  },
];

const ADAPTERS: Record<string, Adapter> = {
  sap_s4_finance: sapS4Finance,
  servicenow_itsm: serviceNowItsm,
  primavera_p6: primaveraP6,
};

/** True when a system_code has an end-to-end adapter wired (Option A connector). */
export const hasConnectorAdapter = (systemCode: string): boolean =>
  Object.prototype.hasOwnProperty.call(ADAPTERS, systemCode);

/**
 * Run the adapter for a system_code and return the normalised records to land.
 * Returns null when the system has no adapter (registry-only connector).
 */
export const fetchConnectorRecords = (systemCode: string): ConnectorRecord[] | null => {
  const adapter = ADAPTERS[systemCode];
  if (!adapter) return null;
  return adapter(new Date().toISOString());
};
