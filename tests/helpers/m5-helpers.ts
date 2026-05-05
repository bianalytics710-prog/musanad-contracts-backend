/**
 * Shared helpers for M5 (Regulatory Radar) integration + DB function tests.
 *
 * Provides direct (BYPASSRLS) seed/cleanup primitives for the five M5 entities:
 *   - regulator (lookup; seed-extended in case test needs an extra row)
 *   - regulation (master library; new fixture rows created per test suite)
 *   - regulatory_update (radar feed)
 *   - impact_category (taxonomy; canonical 8 already seeded by 052 — helper for ad-hoc rows)
 *   - regulatory_impact (G1-reconstituted; bulk-detect output rows)
 *
 * Also exposes:
 *   - cleanupRegulatoryArtifacts — afterAll bulk hard-delete keyed on the
 *     regulation/regulatoryUpdate/contract ids touched in a suite. Cleans
 *     contract_activity rows of M5 type (regulatory_impact_detected /
 *     regulatory_impact_resolved) so cross-test residue does not pollute
 *     fn_contract_activity_create whitelist or activity-count assertions.
 *   - readRegulationById / readRegulatoryUpdateById / readRegulatoryImpactById
 *     for assertions.
 *   - countContractActivitiesOfType (M5 specialisation of m2-helpers
 *     countContractActivities — kept here so the import surface is local).
 *
 * Reuses M1c fixture user pool (drafter1, recipient1, approver1, approver2,
 * executive1, legal_counsel1) via m1c-helpers + m2-helpers callFnAs primitive.
 *
 * Tag prefix: every helper-emitted row carries an 'm5test:' substring in a
 * deterministic field (reference_code / title_en) so the broad cleanup helper
 * can hard-delete deterministically without nuking sibling-suite data.
 */
import { adminPool, adminQuery } from './m1a-helpers';

// ---------------------------------------------------------------------------
// Identification
// ---------------------------------------------------------------------------
export const M5_TEST_TAG_PREFIX = 'm5test:' as const;

export const tagFor = (suite: string): string =>
  `${M5_TEST_TAG_PREFIX}${suite}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;

// ---------------------------------------------------------------------------
// regulator seed (extends 048's 9-row baseline only when a test needs an
// extra synthetic regulator. Most tests just look up existing rows.)
// ---------------------------------------------------------------------------
export interface SeedRegulatorInput {
  code: string;
  nameEn: string;
  nameAr?: string;
  jurisdiction?: string;
  displayOrder?: number;
}

export const seedRegulator = async (input: SeedRegulatorInput): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO regulator
         (code, name_en, name_ar, jurisdiction, display_order, is_seed,
          created_by, updated_by, is_active)
       VALUES ($1, $2, $3, $4, $5, FALSE, 1, 1, TRUE)
       ON CONFLICT (code) DO UPDATE SET
         name_en       = EXCLUDED.name_en,
         name_ar       = EXCLUDED.name_ar,
         jurisdiction  = EXCLUDED.jurisdiction,
         display_order = EXCLUDED.display_order,
         is_active     = TRUE,
         updated_by    = 1
       RETURNING id`,
      [
        input.code,
        input.nameEn,
        input.nameAr ?? input.nameEn,
        input.jurisdiction ?? 'uae_federal',
        input.displayOrder ?? 999,
      ],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

/**
 * Look up an existing seeded regulator by code (e.g. 'MoHRE', 'FTA'). Throws
 * if not found — the 9 rows are seeded by migration 048.
 */
export const getRegulatorIdByCode = async (code: string): Promise<number> => {
  const rows = await adminQuery<{ id: number | string }>(
    `SELECT id FROM regulator WHERE code = $1 AND is_active = TRUE`,
    [code],
  );
  if (rows.length === 0) {
    throw new Error(`Regulator with code '${code}' not seeded (migration 048?)`);
  }
  return Number(rows[0]!.id);
};

// ---------------------------------------------------------------------------
// regulation seed
// ---------------------------------------------------------------------------
export interface SeedRegulationInput {
  referenceCode: string;
  titleEn: string;
  titleAr?: string;
  issuerId: number;
  regulationType?: string;
  jurisdiction?: string | null;
  effectiveDate?: string | null; // ISO YYYY-MM-DD
  status?: 'active' | 'superseded' | 'repealed' | 'draft';
  tags?: string[];
  actorUserId: number;
}

/**
 * Direct INSERT of a regulation row (bypasses fn_regulation_create perm gate).
 * Returns the inserted id.
 */
export const seedRegulation = async (input: SeedRegulationInput): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO regulation
         (reference_code, title_en, title_ar, issuer_id, regulation_type,
          jurisdiction, effective_date, status, tags,
          created_by, updated_by, is_active)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10, TRUE)
       RETURNING id`,
      [
        input.referenceCode,
        input.titleEn,
        input.titleAr ?? null,
        input.issuerId,
        input.regulationType ?? 'circular',
        input.jurisdiction ?? 'uae_federal',
        input.effectiveDate ?? null,
        input.status ?? 'active',
        input.tags ?? [],
        input.actorUserId,
      ],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

// ---------------------------------------------------------------------------
// regulatory_update seed
// ---------------------------------------------------------------------------
export interface SeedRegulatoryUpdateInput {
  regulatorId: number;
  titleEn: string;
  titleAr?: string;
  publishedDate: string; // ISO YYYY-MM-DD
  effectiveDate?: string | null;
  complianceDeadline?: string | null;
  severity?: 'low' | 'medium' | 'high' | 'critical';
  categoryId?: number | null;
  affectedClauseCategories?: string[];
  actorUserId: number;
}

export const seedRegulatoryUpdate = async (
  input: SeedRegulatoryUpdateInput,
): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO regulatory_update
         (regulator_id, title_en, title_ar, published_date, effective_date,
          compliance_deadline, severity, category_id, affected_clause_categories,
          created_by, updated_by, is_active)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10, TRUE)
       RETURNING id`,
      [
        input.regulatorId,
        input.titleEn,
        input.titleAr ?? null,
        input.publishedDate,
        input.effectiveDate ?? null,
        input.complianceDeadline ?? null,
        input.severity ?? 'medium',
        input.categoryId ?? null,
        input.affectedClauseCategories ?? [],
        input.actorUserId,
      ],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

// ---------------------------------------------------------------------------
// regulatory_impact seed (direct, bypassing the bulk fn — used for tests
// that need a pre-existing row to exercise resolve / list / cascade-delete
// behaviour without going through the full bulk-detect stack)
// ---------------------------------------------------------------------------
export interface SeedRegulatoryImpactInput {
  contractId: number;
  regulationId: number;
  regulatoryUpdateId?: number | null; // NULL ⇒ structural impact (AC-S10-02)
  impactScore?: number | null;
  impactNoteEn?: string | null;
  impactNoteAr?: string | null;
  impactSummaryEn?: string | null;
  impactSummaryAr?: string | null;
  resolved?: boolean;
  resolutionAction?: 'amended' | 'waived' | 'out_of_scope' | 'pending' | null;
  resolutionNote?: string | null;
  actorUserId: number;
}

export const seedRegulatoryImpact = async (
  input: SeedRegulatoryImpactInput,
): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO regulatory_impact
         (contract_id, regulation_id, regulatory_update_id,
          impact_score, impact_note_en, impact_note_ar,
          impact_summary_en, impact_summary_ar,
          detected_at, resolved, resolution_action, resolution_note,
          is_seed, created_by, updated_by, is_active)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8,
               CURRENT_TIMESTAMP, $9, $10, $11,
               FALSE, $12, $12, TRUE)
       RETURNING id`,
      [
        input.contractId,
        input.regulationId,
        input.regulatoryUpdateId ?? null,
        input.impactScore ?? null,
        input.impactNoteEn ?? null,
        input.impactNoteAr ?? null,
        input.impactSummaryEn ?? null,
        input.impactSummaryAr ?? null,
        input.resolved ?? false,
        input.resolutionAction ?? null,
        input.resolutionNote ?? null,
        input.actorUserId,
      ],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

// ---------------------------------------------------------------------------
// impact_category seed (in addition to the canonical 8 from migration 052)
// ---------------------------------------------------------------------------
export interface SeedImpactCategoryInput {
  key: string;
  nameEn: string;
  nameAr: string;
  active?: boolean;
  displayOrder?: number;
  severityScale?: string[];
  actorUserId: number;
}

export const seedImpactCategory = async (
  input: SeedImpactCategoryInput,
): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const r = await client.query<{ id: number | string }>(
      `INSERT INTO impact_category
         (key, name_en, name_ar, active, display_order, severity_scale,
          created_by, updated_by, is_active)
       VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $7, TRUE)
       ON CONFLICT (key) DO UPDATE SET
         name_en       = EXCLUDED.name_en,
         name_ar       = EXCLUDED.name_ar,
         active        = EXCLUDED.active,
         display_order = EXCLUDED.display_order,
         severity_scale = EXCLUDED.severity_scale,
         is_active     = TRUE,
         updated_by    = $7
       RETURNING id`,
      [
        input.key,
        input.nameEn,
        input.nameAr,
        input.active ?? true,
        input.displayOrder ?? 100,
        JSON.stringify(input.severityScale ?? ['low', 'medium', 'high', 'critical']),
        input.actorUserId,
      ],
    );
    await client.query('COMMIT');
    return Number(r.rows[0]!.id);
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};

export const getImpactCategoryIdByKey = async (key: string): Promise<number | null> => {
  const rows = await adminQuery<{ id: number | string }>(
    `SELECT id FROM impact_category WHERE key = $1 AND is_active = TRUE`,
    [key],
  );
  return rows.length === 0 ? null : Number(rows[0]!.id);
};

// ---------------------------------------------------------------------------
// Reads — helper-level row inspection for assertions
// ---------------------------------------------------------------------------
export const readRegulationById = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, reference_code, title_en, title_ar, issuer_id,
            regulation_type, jurisdiction, effective_date, status,
            superseded_by_id, tags, source_url, summary_en, summary_ar,
            created_at, updated_at, created_by, updated_by, is_active
       FROM regulation WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};

export const readRegulatoryUpdateById = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, regulator_id, title_en, title_ar, published_date,
            effective_date, compliance_deadline, severity, category_id,
            affected_clause_categories,
            created_at, updated_at, created_by, updated_by, is_active
       FROM regulatory_update WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};

export const readRegulatoryImpactById = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, contract_id, regulation_id, regulatory_update_id,
            impact_score, impact_note_en, impact_note_ar,
            impact_summary_en, impact_summary_ar,
            detected_at, resolved, resolution_action, resolution_note,
            created_at, updated_at, created_by, updated_by, is_active
       FROM regulatory_impact WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};

/**
 * M5 specialisation of countContractActivities (m2-helpers). Counts rows where
 * activity_type is one of the M5 newcomers — useful for asserting Q9 EMIT
 * fired exactly once per AC.
 */
export const countM5ContractActivity = async (
  contractId: number,
  activityType: 'regulatory_impact_detected' | 'regulatory_impact_resolved',
): Promise<number> => {
  const rows = await adminQuery<{ count: string }>(
    `SELECT COUNT(*)::text AS count
       FROM contract_activity
      WHERE contract_id = $1 AND activity_type = $2`,
    [contractId, activityType],
  );
  return Number(rows[0]?.count ?? 0);
};

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
/**
 * Hard-delete M5 artefacts created during a test run. Order matters because
 * regulatory_impact has FK to both regulation and regulatory_update, and the
 * bulk-detect path emits contract_activity rows of M5 type that must be
 * cleared so subsequent runs don't see stale activity counts.
 *
 * Pass any combination of: ids of inserted regulatory_impact / regulatory_update /
 * regulation rows + contract ids whose contract_activity should be sanitised.
 */
export const cleanupRegulatoryArtifacts = async (params: {
  regulatoryImpactIds?: number[];
  regulatoryUpdateIds?: number[];
  regulationIds?: number[];
  impactCategoryKeys?: string[];
  regulatorCodes?: string[];
  /** Contract ids whose M5-type contract_activity rows should be deleted. */
  contractIds?: number[];
}): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');

    if (params.contractIds && params.contractIds.length > 0) {
      await client.query(
        `DELETE FROM contract_activity
           WHERE contract_id = ANY($1::BIGINT[])
             AND activity_type IN
               ('regulatory_impact_detected','regulatory_impact_resolved')`,
        [params.contractIds],
      );
      // Also nuke regulatory_impact rows attached to these contracts (any FK
      // to regulation/regulatory_update we drop after).
      await client.query(
        `DELETE FROM regulatory_impact WHERE contract_id = ANY($1::BIGINT[])`,
        [params.contractIds],
      );
    }
    if (params.regulatoryImpactIds && params.regulatoryImpactIds.length > 0) {
      await client.query(
        `DELETE FROM regulatory_impact WHERE id = ANY($1::BIGINT[])`,
        [params.regulatoryImpactIds],
      );
    }
    if (params.regulatoryUpdateIds && params.regulatoryUpdateIds.length > 0) {
      // Cascade-clean any impact rows still referencing the update.
      await client.query(
        `DELETE FROM regulatory_impact WHERE regulatory_update_id = ANY($1::BIGINT[])`,
        [params.regulatoryUpdateIds],
      );
      await client.query(
        `DELETE FROM regulatory_update WHERE id = ANY($1::BIGINT[])`,
        [params.regulatoryUpdateIds],
      );
    }
    if (params.regulationIds && params.regulationIds.length > 0) {
      // Clear any FK-self superseded_by_id references inside the same set
      // before deletion so we don't fight RESTRICT semantics.
      await client.query(
        `UPDATE regulation SET superseded_by_id = NULL
           WHERE superseded_by_id = ANY($1::BIGINT[])`,
        [params.regulationIds],
      );
      await client.query(
        `DELETE FROM regulatory_impact WHERE regulation_id = ANY($1::BIGINT[])`,
        [params.regulationIds],
      );
      await client.query(
        `DELETE FROM regulation WHERE id = ANY($1::BIGINT[])`,
        [params.regulationIds],
      );
    }
    if (params.impactCategoryKeys && params.impactCategoryKeys.length > 0) {
      await client.query(
        `DELETE FROM impact_category WHERE key = ANY($1::TEXT[]) AND is_seed = FALSE`,
        [params.impactCategoryKeys],
      );
    }
    if (params.regulatorCodes && params.regulatorCodes.length > 0) {
      await client.query(
        `DELETE FROM regulator WHERE code = ANY($1::TEXT[]) AND is_seed = FALSE`,
        [params.regulatorCodes],
      );
    }

    await client.query('COMMIT');
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* swallow */
    }
    throw err;
  } finally {
    client.release();
  }
};
