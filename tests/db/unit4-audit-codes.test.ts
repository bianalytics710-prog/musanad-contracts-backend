/**
 * Unit-4 / R-PROC — DB verification tests.
 *
 * Coverage:
 *   S1  Migration version check — schema_migrations has versions 201 + 202.
 *   S2  audit_log_action_code catalog — 4 new procurement codes present.
 *   S3  role_permission grants — risk.acknowledge granted to the correct roles.
 *   S4  S2-21 streak check — no PUBLIC EXECUTE on procurement action-related fn_s.
 *
 * Runs against TEST_DATABASE_URL (migrations applied through 202).
 * ADNOC tenant id = '00000000-0000-0000-0000-000000000001'.
 *
 * @module Unit-4 DB audit-codes verification tests
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { adminQuery, closeAdminPool, adminPool } from '../helpers/m1a-helpers';

// ─────────────────────────────────────────────────────────────────────────────
// S1 — Migration version check
// ─────────────────────────────────────────────────────────────────────────────

describe('schema_migrations — Unit-4 migrations 201 + 202 applied', () => {
  it('AC-DB-01: schema_migrations has version 201 (audit_log_action_codes_procurement)', async () => {
    const rows = await adminQuery<{ version: number; description: string }>(
      `SELECT version, description
         FROM schema_migrations
        WHERE version = 201`,
    );
    expect(rows.length).toBeGreaterThanOrEqual(1);
    expect(Number(rows[0]!.version)).toBe(201);
    expect(rows[0]!.description).toMatch(/procurement/i);
  }, 15_000);

  it('AC-DB-02: schema_migrations has version 202 (grant risk.acknowledge)', async () => {
    const rows = await adminQuery<{ version: number; description: string }>(
      `SELECT version, description
         FROM schema_migrations
        WHERE version = 202`,
    );
    expect(rows.length).toBeGreaterThanOrEqual(1);
    expect(Number(rows[0]!.version)).toBe(202);
    expect(rows[0]!.description).toMatch(/risk\.acknowledge|drafter|approver/i);
  }, 15_000);
});

// ─────────────────────────────────────────────────────────────────────────────
// S2 — audit_log_action_code catalog verification
// ─────────────────────────────────────────────────────────────────────────────

describe('audit_log_action_code — Unit-4 procurement codes present (migration 201)', () => {
  const EXPECTED_CODES = [
    'vendor_alternate_activated',
    'vendor_performance_escalated',
    'cure_notice_intent_recorded',
    'icv_remediation_initiated',
  ];

  for (const code of EXPECTED_CODES) {
    it(`AC-DB-03: code '${code}' exists in audit_log_action_code`, async () => {
      const rows = await adminQuery<{ code: string; persona: string; introduced_in_migration: number }>(
        `SELECT code, persona, introduced_in_migration
           FROM audit_log_action_code
          WHERE code = $1`,
        [code],
      );
      expect(rows.length).toBeGreaterThanOrEqual(1);
      expect(rows[0]!.code).toBe(code);
      expect(rows[0]!.persona).toBe('procurement');
      expect(Number(rows[0]!.introduced_in_migration)).toBe(201);
    }, 15_000);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// S3 — role_permission grants for risk.acknowledge (migration 202)
// ─────────────────────────────────────────────────────────────────────────────

describe('role_permission — risk.acknowledge granted to procurement roles (migration 202)', () => {
  const EXPECTED_ROLES = ['contract_drafter', 'contract_approver', 'platform_admin', 'Super Admin'];

  for (const roleName of EXPECTED_ROLES) {
    it(`AC-DB-07: role '${roleName}' has risk.acknowledge permission`, async () => {
      const rows = await adminQuery<{ cnt: string }>(
        `SELECT COUNT(*)::text AS cnt
           FROM role_permission rp
           JOIN role r ON r.id = rp.role_id
           JOIN permission p ON p.id = rp.permission_id
          WHERE r.name = $1
            AND p.code = 'risk.acknowledge'
            AND rp.is_active = TRUE`,
        [roleName],
      );
      const cnt = parseInt(rows[0]?.cnt ?? '0', 10);
      expect(cnt).toBeGreaterThanOrEqual(1);
    }, 15_000);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// S4 — S2-21 streak check: no PUBLIC EXECUTE on fn_audit_log_record_v2
// ─────────────────────────────────────────────────────────────────────────────

describe('S2-21 streak check — key fn_ used by Unit-4 routes has no PUBLIC EXECUTE', () => {
  // fn_audit_log_record_v2 is the only fn_ called by Unit-4 routes
  // (they do not add new fn_'s — they reuse the existing fn_ via the service)
  const CHECKED_FUNCTIONS = ['fn_audit_log_record_v2'];

  it('AC-DB-08: fn_audit_log_record_v2 has no PUBLIC EXECUTE entry in proacl', async () => {
    const rows = await adminQuery<{ proname: string; proacl: string | null }>(
      `SELECT p.proname, array_to_string(p.proacl, ',') AS proacl
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = ANY($1::text[])`,
      [CHECKED_FUNCTIONS],
    );

    const proaclMap = new Map<string, string | null>();
    for (const row of rows) {
      proaclMap.set(row.proname, row.proacl);
    }

    for (const fnName of CHECKED_FUNCTIONS) {
      const proacl = proaclMap.get(fnName);
      // fn should exist
      expect(proaclMap.has(fnName), `${fnName} not found in pg_proc — was it dropped?`).toBe(true);

      if (proacl === null || proacl === undefined) {
        // NULL proacl = hidden PUBLIC EXECUTE (S2-21 hidden leak pattern)
        expect(
          `${fnName} has NULL proacl (hidden PUBLIC EXECUTE leak)`,
        ).toBe(
          `${fnName} should have explicit REVOKE FROM PUBLIC + GRANT TO neondb_owner`,
        );
      } else {
        const entries = proacl
          .replace(/^\{/, '')
          .replace(/\}$/, '')
          .split(',')
          .map((e) => e.trim())
          .filter(Boolean);

        for (const entry of entries) {
          const grantee = entry.split('=')[0] ?? '';
          const hasExecute = entry.includes('X');
          if (grantee === '' && hasExecute) {
            expect(
              `${fnName} entry '${entry}' grants PUBLIC EXECUTE`,
            ).toBe(`${fnName} should have no PUBLIC EXECUTE entry`);
          }
        }
        expect(proacl).toMatch(/neondb_owner=X/);
      }
    }
  }, 30_000);
});

afterAll(async () => {
  await closeAdminPool();
});
