/**
 * M7 — UK HMT Consolidated sanctions adapter (CR-A).
 *
 * URL: https://ofsistorage.blob.core.windows.net/publishlive/2022format/ConList.xml
 * Refresh: 86400 s (daily). Reliability: 1.0. Severity: high.
 */
import {
  XmlSanctionsBaseAdapter,
  firstMatchingArray,
  stringOrEmpty,
  type XmlSanctionsEntry,
} from './xml-sanctions-base.adapter';

const UK_URL =
  'https://ofsistorage.blob.core.windows.net/publishlive/2022format/ConList.xml';

export class UkHmtAdapter extends XmlSanctionsBaseAdapter {
  constructor() {
    super({
      source_id: 'uk_hmt',
      source_reliability: 1.0,
      refresh_seconds: 86400,
      url: UK_URL,
      rate_limit: {
        callsPerMinute: 1,
        burst: 1,
        minIntervalMs: 60_000,
        respectRetryAfter: true,
      },
      extractEntries: (parsed) => {
        const rows = firstMatchingArray(parsed, /Designation|FinancialSanctionsTarget/i);
        return rows.map((row): XmlSanctionsEntry => {
          const id = stringOrEmpty(row['GroupID'] ?? row['id'] ?? row['UniqueID']);
          const name = stringOrEmpty(
            row['Name6'] ?? row['Name1'] ?? row['Name'] ?? row['DesignatedName'] ?? '',
          );
          const regime = stringOrEmpty(row['RegimeName'] ?? row['Regime'] ?? '');
          return {
            uid: id || `uk-${name.slice(0, 32)}`,
            name: name || 'Unknown UK designation',
            programs: regime ? [regime] : [],
            remarks: stringOrEmpty(row['OtherInformation'] ?? '') || undefined,
          };
        });
      },
    });
  }

  protected override titlePrefix(): string {
    return 'UK HMT sanctions';
  }
}
