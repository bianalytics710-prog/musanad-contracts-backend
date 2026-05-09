/**
 * M7 — UN Security Council Consolidated sanctions adapter (CR-A).
 *
 * URL: https://scsanctions.un.org/resources/xml/en/consolidated.xml
 * Refresh: 86400 s (daily). Reliability: 1.0. Severity: high.
 */
import {
  XmlSanctionsBaseAdapter,
  firstMatchingArray,
  stringOrEmpty,
  type XmlSanctionsEntry,
} from './xml-sanctions-base.adapter';

const UN_URL = 'https://scsanctions.un.org/resources/xml/en/consolidated.xml';

export class UnSecurityCouncilAdapter extends XmlSanctionsBaseAdapter {
  constructor() {
    super({
      source_id: 'un_security_council',
      source_reliability: 1.0,
      refresh_seconds: 86400,
      url: UN_URL,
      rate_limit: {
        callsPerMinute: 1,
        burst: 1,
        minIntervalMs: 60_000,
        respectRetryAfter: true,
      },
      extractEntries: (parsed) => {
        const rows = firstMatchingArray(parsed, /INDIVIDUAL|ENTITY|individual|entity/);
        return rows.map((row): XmlSanctionsEntry => {
          const id = stringOrEmpty(row['DATAID'] ?? row['REFERENCE_NUMBER'] ?? row['id']);
          const firstName = stringOrEmpty(row['FIRST_NAME'] ?? row['firstName'] ?? '');
          const secondName = stringOrEmpty(row['SECOND_NAME'] ?? row['secondName'] ?? '');
          const entityName = stringOrEmpty(row['NAME'] ?? row['name'] ?? '');
          const composedName =
            entityName || `${firstName} ${secondName}`.trim() || 'Unknown UN designation';
          const program = stringOrEmpty(row['UN_LIST_TYPE'] ?? row['committee'] ?? '');
          return {
            uid: id || `un-${composedName.slice(0, 32)}`,
            name: composedName,
            programs: program ? [program] : [],
            remarks: stringOrEmpty(row['COMMENTS1'] ?? row['comments'] ?? '') || undefined,
          };
        });
      },
    });
  }

  protected override titlePrefix(): string {
    return 'UN sanctions';
  }
}
