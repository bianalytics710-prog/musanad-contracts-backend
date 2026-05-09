/**
 * M7 — EU Consolidated Sanctions adapter (CR-A).
 *
 * URL: https://webgate.ec.europa.eu/fsd/fsf/public/files/xmlFullSanctionsList_1_1/content
 * Refresh: 86400 s (daily). Reliability: 1.0. Severity: high.
 */
import {
  XmlSanctionsBaseAdapter,
  firstMatchingArray,
  stringOrEmpty,
  type XmlSanctionsEntry,
} from './xml-sanctions-base.adapter';

const EU_URL =
  'https://webgate.ec.europa.eu/fsd/fsf/public/files/xmlFullSanctionsList_1_1/content';

export class EuConsolidatedAdapter extends XmlSanctionsBaseAdapter {
  constructor() {
    super({
      source_id: 'eu_consolidated',
      source_reliability: 1.0,
      refresh_seconds: 86400,
      url: EU_URL,
      rate_limit: {
        callsPerMinute: 1,
        burst: 1,
        minIntervalMs: 60_000,
        respectRetryAfter: true,
      },
      extractEntries: (parsed) => {
        const rows = firstMatchingArray(parsed, /sanctionEntity|sanctionsEntity|nameAlias/i);
        return rows.map((row): XmlSanctionsEntry => {
          const id = stringOrEmpty(row['logicalId'] ?? row['id'] ?? row['euReferenceNumber']);
          const name = stringOrEmpty(
            row['wholeName'] ?? row['name'] ?? row['title'] ?? row['nameAlias'] ?? '',
          );
          const program = stringOrEmpty(row['programme'] ?? row['regulation'] ?? '');
          return {
            uid: id || `eu-${name.slice(0, 32)}`,
            name: name || 'Unknown EU designation',
            programs: program ? [program] : [],
            remarks: stringOrEmpty(row['remark'] ?? row['note'] ?? '') || undefined,
          };
        });
      },
    });
  }

  protected override titlePrefix(): string {
    return 'EU sanctions';
  }
}
