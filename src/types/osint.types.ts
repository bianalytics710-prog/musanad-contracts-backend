// ============================================================
// M7 — OSINT Source Framework + Adapter Protocol (CR-A)
// TypeScript Type Definitions
//
// Owned by: M7. Mirrors workspace types.ts (Agent 5 contract output).
// Imports: PaginationMeta from M0 type registry (api.types).
//
// Naming convention notes
//  - Entity / DTO / list / response interfaces use camelCase keys (matches
//    the JSONB shapes returned by every fn_ in db-design.md Sections 2/3).
//  - The SourceAdapter / RawSignal / NormalisedSignal interfaces use
//    snake_case keys verbatim from the CR-A brief Backend section. This is
//    intentional — adapters must implement the brief's exact contract for
//    protocol parity. AC-S4-01 requires byte-for-byte signature.
//
// Cross-tenant safety invariants (mirror db-design.md Section 6 RLS)
//  - Every list/detail response is auto-scoped by `app.current_tenant_id`
//    GUC at the DB layer; FE never passes tenantId in filters.
//  - SourceCredentialMetadata intentionally OMITS `credentialRef`
//    (AC-S3-04 invariant — credential_ref must NEVER appear in API
//    responses).
//  - OsintSignal.rawPayload IS exposed in API responses per design note
//    ("legal_counsel needs SDN entry text"); redacted only at log layer.
// ============================================================

import type { PaginationMeta } from './api.types';

// ============================================================
// 1. Status / Category String Unions
// ============================================================

export type SourceKind =
  | 'sanctions'
  | 'news'
  | 'weather'
  | 'commodity'
  | 'fx'
  | 'social'
  | 'regulatory'
  | 'internal';

export type SourceFormat = 'xml' | 'csv' | 'json' | 'rss' | 'api';

export type SignalKind =
  | 'geopolitical'
  | 'sanctions'
  | 'weather'
  | 'commodity'
  | 'fx'
  | 'logistics'
  | 'esg'
  | 'regulatory'
  | 'news'
  | 'internal';

export type Severity = 'informational' | 'low' | 'medium' | 'high' | 'critical';

export type HealthState = 'healthy' | 'degraded' | 'failing' | 'unauthorised';

export type CredentialKind = 'api_key' | 'oauth_token' | 'basic_auth' | 'none';

export type DataClassification = 'demo' | 'pilot' | 'production';

// ============================================================
// 2. Embedded JSONB Shapes
// ============================================================

export interface RateLimitConfig {
  callsPerMinute: number;
  burst: number;
  minIntervalMs: number;
  respectRetryAfter: boolean;
}

export interface GeoReference {
  isoCountry?: string;
  regionCode?: string;
  free?: string;
}

export interface EntityReference {
  entityType: string;
  name: string;
  identifier?: string;
  partyId?: number;
}

export interface SeverityMappingRule {
  programContains?: string;
  titleContains?: string;
  absChangePctGte?: number;
  pegDeviationPctGte?: number;
  default?: Severity;
  severity?: Severity;
}

export interface SeverityMapping {
  rules: SeverityMappingRule[];
}

export interface GeographyFilter {
  countryIn?: string[];
  themeIn?: string[];
  actorIn?: string[];
}

// ============================================================
// 3. Tenant
// ============================================================

export interface Tenant {
  id: string;
  slug: string;
  displayName: string;
  configPack: string;
}

// ============================================================
// 4. OsintSource
// ============================================================

export interface OsintSource {
  id: number;
  tenantId: string;
  sourceId: string;
  displayName: string;
  displayNameAr: string | null;
  kind: SourceKind;
  url: string | null;
  format: SourceFormat;
  refreshSeconds: number;
  sourceReliability: number;
  enabled: boolean;
  rateLimit: RateLimitConfig | null;
  severityMapping: SeverityMapping | null;
  geographyFilter: GeographyFilter | null;
  licensingNote: string | null;
  metadata: Record<string, unknown>;
  dataClassification: DataClassification;
  createdAt: string;
  updatedAt: string;
}

export interface OsintSourceDetail extends OsintSource {
  health: SourceHealthBadge | null;
  credential: SourceCredentialMetadata | null;
}

export interface OsintSourceListItem extends OsintSource {
  health: SourceHealthBadge | null;
}

export interface OsintSourceListResponse {
  data: OsintSourceListItem[];
  pagination: PaginationMeta;
}

export interface OsintSourceListFilter {
  kind?: SourceKind;
  state?: HealthState;
  search?: string;
}

export interface CreateOsintSourceDto {
  sourceId: string;
  displayName: string;
  displayNameAr?: string;
  kind: SourceKind;
  url?: string;
  format: SourceFormat;
  refreshSeconds: number;
  sourceReliability: number;
  enabled?: boolean;
  rateLimit?: RateLimitConfig;
  severityMapping?: SeverityMapping;
  geographyFilter?: GeographyFilter;
  licensingNote?: string;
  metadata?: Record<string, unknown>;
  dataClassification?: DataClassification;
}

export interface UpdateOsintSourceDto {
  displayName?: string;
  displayNameAr?: string;
  kind?: SourceKind;
  url?: string;
  format?: SourceFormat;
  refreshSeconds?: number;
  sourceReliability?: number;
  enabled?: boolean;
  rateLimit?: RateLimitConfig;
  severityMapping?: SeverityMapping;
  geographyFilter?: GeographyFilter;
  licensingNote?: string;
  metadata?: Record<string, unknown>;
  dataClassification?: DataClassification;
}

export interface DeleteOsintSourceResponse {
  id: number;
  deactivated: boolean;
  message: string;
}

export interface TestPullResponse {
  queued: boolean;
  sourceId: string;
  requestedAt: string;
}

// ============================================================
// 5. SourceCredential
// ============================================================

export interface SetCredentialDto {
  credentialKind: CredentialKind;
  /** Pattern: 'env:VARNAME' OR 'vault:path'. NEVER plain-text secret. */
  credentialRef: string;
}

export interface SetCredentialResponse {
  id: number;
  credentialKind: CredentialKind;
  lastRotatedAt: string;
}

export interface SourceCredentialMetadata {
  kind: CredentialKind;
  lastRotatedAt: string | null;
}

// ============================================================
// 6. OsintSignal
// ============================================================

export interface OsintSignal {
  id: number;
  tenantId: string;
  osintSourceId: number | null;
  sourceId: string;
  sourceReliability: number;
  fetchedAt: string;
  eventDate: string | null;
  kind: SignalKind;
  signalKindSubtype: string | null;
  title: string;
  summary: string | null;
  geographies: GeoReference[];
  affectedEntities: EntityReference[];
  severity: Severity;
  confidence: number;
  url: string | null;
  /** SENSITIVE — exposed in API response per design; redacted in logs + audit. */
  rawPayload: Record<string, unknown>;
  dedupHash: string;
  dataClassification: DataClassification;
  createdAt: string;
}

export interface OsintSignalListFilter {
  kind?: SignalKind;
  sourceId?: string;
  severityMin?: Severity;
  since?: string;
  geographyIntersects?: string;
  affectedEntityId?: string;
}

export interface OsintSignalListResponse {
  data: OsintSignal[];
  pagination: PaginationMeta;
}

// ============================================================
// 7. SourceHealth
// ============================================================

export interface SourceHealthBadge {
  state: HealthState;
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
  signals24h: number;
  lastErrorMessage: string | null;
  checkedAt: string;
}

export interface SourceHealthListItem {
  sourceId: string;
  displayName: string;
  kind: SourceKind;
  state: HealthState;
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
  signals24h: number;
  lastErrorMessage: string | null;
  checkedAt: string;
}

// ============================================================
// 8. SourceAdapter Protocol Contract (snake_case verbatim)
// ============================================================
//
// The brief specifies adapter contract using Python-style naming so
// cross-language reference implementations stay signature-compatible.
// AC-S4-01 requires byte-for-byte signature parity.
// ============================================================

export interface RawSignal {
  payload: Record<string, unknown>;
  fetched_at: Date;
}

export interface NormalisedSignal {
  source_id: string;
  source_reliability: number;
  fetched_at: Date;
  event_date?: Date;
  kind: SignalKind;
  title: string;
  summary?: string;
  geographies: GeoReference[];
  affected_entities: EntityReference[];
  severity: Severity;
  confidence: number;
  url?: string;
  raw_payload: Record<string, unknown>;
  /** SHA-256(source_id || '|' || isoformat(event_date OR fetched_at) || '|' || lower(trim(title))). */
  dedup_hash: string;
}

export interface AdapterHealthCheckResult {
  state: HealthState;
  /** Truncated to 500 chars by fn_source_health_record on persistence. */
  error?: string;
}

export interface SourceAdapter {
  source_id: string;
  source_reliability: number;
  refresh_seconds: number;
  rate_limit: RateLimitConfig | null;
  fetch(since: Date): AsyncIterator<RawSignal>;
  normalise(raw: RawSignal): NormalisedSignal;
  health_check(): Promise<AdapterHealthCheckResult>;
}

// ============================================================
// 9. Upsert (system-only — DEFINER fn_osint_signal_upsert)
// ============================================================

export interface OsintSignalUpsertPayload {
  sourceId: string;
  sourceReliability: number;
  fetchedAt: string;
  eventDate?: string;
  kind: SignalKind;
  signalKindSubtype?: string;
  title: string;
  summary?: string;
  geographies: GeoReference[];
  affectedEntities: EntityReference[];
  severity: Severity;
  confidence: number;
  url?: string;
  rawPayload: Record<string, unknown>;
  dedupHash: string;
  dataClassification?: DataClassification;
}

export interface OsintSignalUpsertResult {
  id: number;
  inserted: boolean;
  dedupHash: string;
}

export interface SourceHealthRecordResult {
  id: number;
  state: HealthState;
  checkedAt: string;
}

// ============================================================
// 10. pg_notify channel payload shapes
// ============================================================

export interface OsintSignalInsertedNotification {
  id: number;
  tenantId: string;
  sourceId: string;
  severity: Severity;
  kind: SignalKind;
}

export interface OsintTestPullNotification {
  osintSourceId: number;
  tenantId: string;
  sourceId: string;
  actorId: number;
  requestedAt: string;
}
