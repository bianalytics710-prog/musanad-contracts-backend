/**
 * Shared helpers for M6 (Dashboards & Reporting) integration + DB function
 * tests. M6 is read-only — these helpers focus on:
 *
 *   - getRoleByName        — lookup role.id for grant/revoke flows
 *   - grantPermissionToRole / revokePermissionFromRole — toggle permission
 *     codes for fixture roles inside a single test (used to verify the
 *     ai.observability.read gate on S7's aiCostUsdWindow + S11 entrypoint
 *     and the audit.read gate on S4's auditSummary)
 *   - countPublicExecuteGrants — S2-21 mandatory check (assert PUBLIC EXECUTE
 *     count is exactly 5 in the test branch)
 *   - hasSchemaMigrationsAdminPolicy — ARCH-NEW-3 option (c) verification
 *   - getMaxSchemaMigrationVersion — admin SELECT against schema_migrations
 *   - seedSignatureInvitationForUser — minimal signature_invitation row keyed
 *     by signer_email so fn_dashboard_recipient pendingSignatures5 has data
 *   - seedSignatureEventForUser — signature_event row with actor_user_id for
 *     fn_dashboard_recipient signedByMeWindow
 *   - seedAiInsightForExecutiveAnomaly — minimal ai_insight cache row so
 *     fn_dashboard_executive_anomalies_history has results
 *   - cleanupDashboardArtifacts — cumulative afterAll cleanup keyed on the
 *     ids inserted by these helpers (signature_invitation / signature_event /
 *     ai_insight). Uses BYPASSRLS pool.
 *
 * Reuses M1c fixture user pool (drafter1, recipient1, approver1, approver2,
 * executive1, legal_counsel1) via m1c-helpers.
 *
 * Tag prefix: 'm6test:' — kept in title fields so a broader cleanup can run
 * if a suite crashes mid-flight.
 */
import { adminPool, adminQuery } from './m1a-helpers';

// ---------------------------------------------------------------------------
// Identification
// ---------------------------------------------------------------------------
export const M6_TEST_TAG_PREFIX = 'm6test:' as const;

export const tagFor = (suite: string): string =>
  `${M6_TEST_TAG_PREFIX}${suite}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;

// ---------------------------------------------------------------------------
// Role helpers
// ---------------------------------------------------------------------------
export const getRoleIdByName = async (roleName: string): Promise<number> => {
  const rows = await adminQuery<{ id: number | string }>(
    `SELECT id FROM role WHERE name = $1 AND is_active = TRUE`,
    [roleName],
  );
  if (rows.length === 0) {
    throw new Error(`Role '${roleName}' not seeded`);
  }
  return Number(rows[0]!.id);
};

// ---------------------------------------------------------------------------
// Permission grant/revoke (used to flip 'ai.observability.read' / 'audit.read'
// for fixture roles inside a single test case)
// ---------------------------------------------------------------------------
export const grantPermissionToRole = async (
  roleId: number,
  permissionCode: string,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `INSERT INTO role_permission (role_id, permission_id, is_active, created_by)
         SELECT $1, p.id, TRUE, 1 FROM permission p WHERE p.code = $2
       ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE`,
      [roleId, permissionCode],
    );
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

export const revokePermissionFromRole = async (
  roleId: number,
  permissionCode: string,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    await client.query(
      `UPDATE role_permission rp
          SET is_active = FALSE
        FROM permission p
        WHERE rp.permission_id = p.id
          AND p.code = $2
          AND rp.role_id = $1`,
      [roleId, permissionCode],
    );
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

/**
 * Read whether a role currently holds a permission code (ignoring is_active=FALSE
 * row history).
 */
export const roleHasPermission = async (
  roleId: number,
  permissionCode: string,
): Promise<boolean> => {
  const rows = await adminQuery<{ ok: boolean }>(
    `SELECT TRUE AS ok
       FROM role_permission rp
       JOIN permission p ON p.id = rp.permission_id
      WHERE rp.role_id = $1 AND p.code = $2 AND rp.is_active = TRUE`,
    [roleId, permissionCode],
  );
  return rows.length > 0;
};

// ---------------------------------------------------------------------------
// S2-21 — PUBLIC EXECUTE grant count
// ---------------------------------------------------------------------------
/**
 * Returns the count of fn_-prefixed user-defined functions that have an
 * EXECUTE grant to PUBLIC. Per Q1 lock, this should be exactly 5
 * (M3 token-bearer family). M6 introduces ZERO new PUBLIC EXECUTE grants.
 */
export const countPublicExecuteGrantsOnFnFunctions = async (): Promise<number> => {
  const rows = await adminQuery<{ count: string }>(
    `SELECT COUNT(DISTINCT p.proname)::text AS count
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       JOIN aclexplode(p.proacl) acl ON TRUE
      WHERE n.nspname = 'public'
        AND p.proname LIKE 'fn\\_%'
        AND acl.privilege_type = 'EXECUTE'
        AND acl.grantee = 0`,
  );
  return Number(rows[0]?.count ?? 0);
};

/** Names of fn_'s with PUBLIC EXECUTE — for diagnostic logging on assertion failure. */
export const listPublicExecuteFnFunctions = async (): Promise<string[]> => {
  const rows = await adminQuery<{ name: string }>(
    `SELECT DISTINCT p.proname AS name
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       JOIN aclexplode(p.proacl) acl ON TRUE
      WHERE n.nspname = 'public'
        AND p.proname LIKE 'fn\\_%'
        AND acl.privilege_type = 'EXECUTE'
        AND acl.grantee = 0
      ORDER BY p.proname`,
  );
  return rows.map((r) => r.name);
};

// ---------------------------------------------------------------------------
// ARCH-NEW-3 option (c) — schema_migrations admin SELECT policy
// ---------------------------------------------------------------------------
export const hasSchemaMigrationsAdminPolicy = async (): Promise<boolean> => {
  const rows = await adminQuery<{ ok: boolean }>(
    `SELECT TRUE AS ok
       FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'schema_migrations'
        AND policyname = 'schema_migrations_select_admin'`,
  );
  return rows.length > 0;
};

// ---------------------------------------------------------------------------
// signature_invitation seed for fn_dashboard_recipient pendingSignatures5
// ---------------------------------------------------------------------------
export interface SeedSignatureInvitationInput {
  contractId: number;
  signerEmail: string;
  signerNameEn?: string | null;
  status?: 'pending' | 'sent' | 'declined' | 'signed' | 'expired';
  invitationSentAt?: Date | null;
  invitationExpiresAt?: Date | null;
  actorUserId: number;
  /** stepOrder for signature_party — defaults to 1. */
  stepOrder?: number;
}

/**
 * Direct INSERT of a signature_party + signature_invitation pair via BYPASSRLS
 * pool. Returns { partyId, invitationId }.
 *
 * - signature_party gets signer_email so fn_dashboard_recipient's email-match
 *   join hits.
 * - signature_invitation rows reference the party by signature_party_id and
 *   carry status / invitation_sent_at / invitation_expires_at columns.
 *
 * Required columns we must populate:
 *   signature_party: contract_id, signer_side, signer_name_en, step_order
 *   signature_invitation: signature_party_id, contract_id,
 *                         invitation_token_hash, invitation_expires_at
 */
export const seedSignatureInvitation = async (
  input: SeedSignatureInvitationInput,
): Promise<{ partyId: number; invitationId: number }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');

    const partyRes = await client.query<{ id: number | string }>(
      `INSERT INTO signature_party
         (contract_id, signer_side, signer_email, signer_name_en, step_order,
          is_active, created_by, updated_by)
       VALUES ($1, 'counterparty', $2, $3, $4, TRUE, $5, $5)
       RETURNING id`,
      [
        input.contractId,
        input.signerEmail.toLowerCase(),
        input.signerNameEn ?? input.signerEmail.split('@')[0] ?? 'Test',
        input.stepOrder ?? 1,
        input.actorUserId,
      ],
    );
    const partyId = Number(partyRes.rows[0]!.id);

    const expires =
      input.invitationExpiresAt ??
      new Date(Date.now() + 30 * 24 * 60 * 60 * 1000); // +30 days
    const tokenHash = `m6test_${partyId}_${Date.now()}_${Math.floor(Math.random() * 1e9)}`;

    const invRes = await client.query<{ id: number | string }>(
      `INSERT INTO signature_invitation
         (signature_party_id, contract_id, invitation_token_hash, status,
          invitation_sent_at, invitation_expires_at, language,
          is_active, created_by, updated_by)
       VALUES ($1, $2, $3, $4, $5, $6, 'en', TRUE, $7, $7)
       RETURNING id`,
      [
        partyId,
        input.contractId,
        tokenHash,
        input.status ?? 'pending',
        input.invitationSentAt ?? new Date(),
        expires,
        input.actorUserId,
      ],
    );
    const invitationId = Number(invRes.rows[0]!.id);

    await client.query('COMMIT');
    return { partyId, invitationId };
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
// signature_event seed for fn_dashboard_recipient signedByMeWindow
// ---------------------------------------------------------------------------
export interface SeedSignatureEventInput {
  signatureInvitationId: number;
  actorUserId: number;
  /** event_type — fn_dashboard_recipient counts 'signed'. */
  eventType?: 'sent' | 'opened' | 'signed' | 'declined' | 'expired';
  /** Override created_at for window tests (defaults to NOW). */
  createdAtOverride?: Date | null;
}

export const seedSignatureEvent = async (
  input: SeedSignatureEventInput,
): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');

    // Resolve contract_id from the invitation row (NOT NULL on signature_event).
    const invR = await client.query<{ contract_id: number | string }>(
      `SELECT contract_id FROM signature_invitation WHERE id = $1`,
      [input.signatureInvitationId],
    );
    if (invR.rows.length === 0) {
      throw new Error(
        `seedSignatureEvent: signature_invitation ${input.signatureInvitationId} not found`,
      );
    }
    const contractId = Number(invR.rows[0]!.contract_id);

    // chk_signature_event_signed_has_method requires signature_method NOT NULL
    // when event_type='signed'. Use 'typed' from the seeded enum (M3 035 line
    // 559: uae_pass / ds_otp / drawn / typed).
    const evtType = input.eventType ?? 'signed';
    const sigMethod = evtType === 'signed' ? 'typed' : null;
    const declineReason =
      evtType === 'declined' ? 'Test decline reason >= 5 chars' : null;

    const sql = input.createdAtOverride
      ? `INSERT INTO signature_event
           (signature_invitation_id, contract_id, actor_user_id, event_type,
            signature_method, decline_reason, created_at, is_active)
         VALUES ($1, $2, $3, $4, $5, $6, $7, TRUE)
         RETURNING id`
      : `INSERT INTO signature_event
           (signature_invitation_id, contract_id, actor_user_id, event_type,
            signature_method, decline_reason, is_active)
         VALUES ($1, $2, $3, $4, $5, $6, TRUE)
         RETURNING id`;
    const params = input.createdAtOverride
      ? [
          input.signatureInvitationId,
          contractId,
          input.actorUserId,
          evtType,
          sigMethod,
          declineReason,
          input.createdAtOverride,
        ]
      : [
          input.signatureInvitationId,
          contractId,
          input.actorUserId,
          evtType,
          sigMethod,
          declineReason,
        ];
    const r = await client.query<{ id: number | string }>(sql, params);
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
// ai_insight seed for fn_dashboard_executive_anomalies_history
// ---------------------------------------------------------------------------
export interface SeedAiInsightInput {
  entityType?: string;
  insightType?: string;
  language?: string;
  payload?: Record<string, unknown> | null;
  actorUserId: number;
  /** 'low' | 'medium' | 'high' | 'critical' embedded in payload (no severity column on ai_insight). */
  severity?: string;
  /** TTL in seconds; defaults to +1 hour so the row is NOT expired. */
  ttlSeconds?: number;
  /** Discriminator for UNIQUE INDEX collisions across helper calls. */
  payloadHashSalt?: string;
}

export const seedAiInsight = async (input: SeedAiInsightInput): Promise<number> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');

    // ai_insight required columns per migration 042: entity_type, insight_type,
    // language, payload_hash, prompt_id (FK to ai_prompt), provider, model_used,
    // payload, expires_at. Note: NO summary_en / summary_ar columns. The
    // executive-anomalies-history fn extracts elem->'summaryEn' from the
    // returned shape — meaning live anomalies just get null for those keys
    // unless callers pre-stage rows with payload that includes them.
    //
    // We need a real prompt_id (FK to ai_prompt); pick the first seeded one.
    const promptR = await client.query<{ prompt_id: string }>(
      `SELECT prompt_id FROM ai_prompt WHERE is_active = TRUE LIMIT 1`,
    );
    if (promptR.rows.length === 0) {
      throw new Error('seedAiInsight: no ai_prompt rows seeded — was migration 044 applied?');
    }
    const promptId = promptR.rows[0]!.prompt_id;
    const ttlSeconds = input.ttlSeconds ?? 3600;
    const salt =
      input.payloadHashSalt ??
      `${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
    const payloadHash = `m6test_${salt}`;

    const r = await client.query<{ id: number | string }>(
      `INSERT INTO ai_insight
         (entity_type, entity_id, insight_type, language, payload_hash,
          prompt_id, provider, model_used, payload,
          expires_at, is_active, created_by, updated_by)
       VALUES ($1, $2, $3, $4, $5,
               $6, 'openai', 'gpt-4o-mini', $7::jsonb,
               CURRENT_TIMESTAMP + ($8 || ' seconds')::INTERVAL, TRUE, $9, $9)
       RETURNING id`,
      [
        input.entityType ?? 'executive_anomalies',
        null,
        input.insightType ?? 'anomaly_detection',
        input.language ?? 'en',
        payloadHash,
        promptId,
        JSON.stringify({
          severity: input.severity ?? 'medium',
          summaryEn: 'Test anomaly summary',
          summaryAr: null,
          ...(input.payload ?? {}),
        }),
        ttlSeconds,
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
// Cleanup
// ---------------------------------------------------------------------------
export interface CleanupDashboardArtifactsInput {
  signatureInvitationIds?: number[];
  signaturePartyIds?: number[];
  signatureEventIds?: number[];
  aiInsightIds?: number[];
}

export const cleanupDashboardArtifacts = async (
  params: CleanupDashboardArtifactsInput,
): Promise<void> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');

    if (params.signatureEventIds && params.signatureEventIds.length > 0) {
      await client.query(
        `DELETE FROM signature_event WHERE id = ANY($1::BIGINT[])`,
        [params.signatureEventIds],
      );
    }
    if (params.signatureInvitationIds && params.signatureInvitationIds.length > 0) {
      // Children first — signature_event by invitation id.
      await client.query(
        `DELETE FROM signature_event WHERE signature_invitation_id = ANY($1::BIGINT[])`,
        [params.signatureInvitationIds],
      );
      await client.query(
        `DELETE FROM signature_invitation WHERE id = ANY($1::BIGINT[])`,
        [params.signatureInvitationIds],
      );
    }
    if (params.signaturePartyIds && params.signaturePartyIds.length > 0) {
      // Cascade — signature_invitation referencing the parties.
      await client.query(
        `DELETE FROM signature_invitation WHERE signature_party_id = ANY($1::BIGINT[])`,
        [params.signaturePartyIds],
      );
      await client.query(
        `DELETE FROM signature_party WHERE id = ANY($1::BIGINT[])`,
        [params.signaturePartyIds],
      );
    }
    if (params.aiInsightIds && params.aiInsightIds.length > 0) {
      await client.query(
        `DELETE FROM ai_insight WHERE id = ANY($1::BIGINT[])`,
        [params.aiInsightIds],
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

// ---------------------------------------------------------------------------
// Approval seed for fn_dashboard_approver pendingQueue5 (M6-DB-IMPL-DEFECT-1
// regression check — verifies migration 057 join chain works)
// ---------------------------------------------------------------------------
/**
 * Seed an approval_chain + a pending approval_step for a contract, with the
 * fixture user as the approver_user_id. Returns { chainId, stepId }.
 *
 * Used by S3 tests to:
 *   1. assert pendingMyApprovalCount > 0 for the fixture user
 *   2. assert pendingQueue5 has at least 1 row with proper contract context
 *      (proves the 057 join chain fix actually returns rows)
 */
export const seedPendingApprovalForUser = async (params: {
  contractId: number;
  approverUserId: number;
  approverRole: string;
  initiatedBy: number;
}): Promise<{ chainId: number; stepId: number }> => {
  const pool = adminPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL row_security = off');
    const chain = await client.query<{ id: number | string }>(
      `INSERT INTO approval_chain
         (contract_id, matrix_snapshot, status, current_step_order,
          initiated_by, initiated_at, created_by, updated_by, is_active)
       VALUES ($1, '[]'::jsonb, 'in_progress', 1, $2, CURRENT_TIMESTAMP, $2, $2, TRUE)
       RETURNING id`,
      [params.contractId, params.initiatedBy],
    );
    const chainId = Number(chain.rows[0]!.id);
    const step = await client.query<{ id: number | string }>(
      `INSERT INTO approval_step
         (approval_chain_id, step_order, parallel_group,
          approver_user_id, approver_role,
          is_required, status,
          created_by, updated_by, is_active)
       VALUES ($1, 1, NULL, $2, $3, TRUE, 'pending', $4, $4, TRUE)
       RETURNING id`,
      [chainId, params.approverUserId, params.approverRole, params.initiatedBy],
    );
    const stepId = Number(step.rows[0]!.id);
    await client.query('COMMIT');
    return { chainId, stepId };
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
// signature_invitation read for assertions
// ---------------------------------------------------------------------------
export const readSignatureInvitationById = async (
  id: number,
): Promise<Record<string, unknown> | null> => {
  const rows = await adminQuery<Record<string, unknown>>(
    `SELECT id, signature_party_id, contract_id, status,
            invitation_sent_at, invitation_expires_at,
            created_at, updated_at, is_active
       FROM signature_invitation WHERE id = $1`,
    [id],
  );
  return rows[0] ?? null;
};
