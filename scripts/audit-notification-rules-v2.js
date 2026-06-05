/* eslint-disable no-console */
/**
 * audit-notification-rules-v2.js
 *
 * Fresh-eye audit of the v2 notification dispatcher. Inventories:
 *   A. Migrations applied.
 *   B. All event_types + per-event rule/channel/recipient counts + template
 *      slug existence + tenant scope (system default vs per-tenant).
 *   C. Cross-check: every event_type referenced in DB call sites
 *      (mig 584/586) and BE worker (report-run) has at least one enabled
 *      rule with a valid template.
 *   D. Verifies v1 short-circuit table mirror still aligns with v2 first
 *      channel/template.
 *   E. Smoke-tests fn_notification_dispatch for a few representative events,
 *      reading dispatchesCreated and the corresponding dispatch_log row.
 *   F. Tests the condition predicate evaluator covers the documented
 *      operators.
 *
 * Read-only by default. Smoke tests INSERT into notification_dispatch_log
 * but those inserts are auto-cleaned with a marker payload field
 * 'auditMarker' = 'audit-2026-06-05' so they can be deleted afterwards.
 *
 * Usage: node scripts/audit-notification-rules-v2.js
 */
'use strict';

require('dotenv').config({ path: '.env.local' });
const { Pool } = require('pg');

const MARKER = 'audit-2026-06-05';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

function section(title) {
  console.log('\n' + '═'.repeat(72));
  console.log('  ' + title);
  console.log('═'.repeat(72));
}

async function pickTenant(client) {
  const { rows } = await client.query(
    "SELECT id, name FROM tenant WHERE is_active = TRUE ORDER BY created_at LIMIT 1"
  );
  if (rows.length === 0) throw new Error('No active tenant');
  return rows[0];
}

async function pickActor(client) {
  const { rows } = await client.query(
    `SELECT u.id, u.email, r.name AS role
       FROM "user" u JOIN role r ON r.id = u.role_id
      WHERE r.name IN ('platform_admin','Super Admin') AND u.is_active = TRUE
      ORDER BY u.id LIMIT 1`
  );
  if (rows.length === 0) throw new Error('No platform admin actor');
  return rows[0];
}

(async () => {
  const client = await pool.connect();
  try {
    section('A. Schema migrations 579..588 applied?');
    const migs = await client.query(
      "SELECT version, description FROM schema_migrations WHERE version BETWEEN 579 AND 588 ORDER BY version"
    );
    console.table(migs.rows);

    section('B. Event types registered (notification_event_type)');
    const events = await client.query(
      `SELECT code, category, display_name
         FROM notification_event_type
        WHERE is_active = TRUE
        ORDER BY category, code`
    );
    console.table(events.rows);

    section('C. Rule × channel × recipient inventory per event');
    const inv = await client.query(`
      SELECT
        r.event_type,
        r.id        AS rule_id,
        r.module,
        r.name,
        r.is_enabled,
        r.tenant_id IS NULL                                                   AS is_system_default,
        r.priority,
        r.condition,
        r.cooldown_minutes,
        r.dedupe_key,
        (SELECT COUNT(*) FROM notification_rule_channel    c WHERE c.rule_id = r.id AND c.is_active) AS channels,
        (SELECT COUNT(*) FROM notification_rule_recipient  p WHERE p.rule_id = r.id AND p.is_active) AS recipients
      FROM notification_rule r
      WHERE r.is_active = TRUE
      ORDER BY r.event_type, r.id
    `);
    console.table(inv.rows);

    section('D. Channels per rule — template_slug exists in notification_template?');
    const chans = await client.query(`
      SELECT
        rc.rule_id,
        r.event_type,
        rc.channel,
        rc.template_slug,
        EXISTS (
          SELECT 1 FROM notification_template t
          WHERE t.template_id = rc.template_slug AND t.is_active = TRUE
        ) AS template_exists
      FROM notification_rule_channel rc
      JOIN notification_rule r ON r.id = rc.rule_id
      WHERE rc.is_active = TRUE AND r.is_active = TRUE
      ORDER BY r.event_type, rc.channel
    `);
    console.table(chans.rows);

    const missingTpl = chans.rows.filter((r) => !r.template_exists);
    if (missingTpl.length) {
      console.log(`!! ${missingTpl.length} channel rows reference a missing template slug.`);
    } else {
      console.log('All channel→template slugs resolve.');
    }

    section('E. Recipients per rule');
    const recips = await client.query(`
      SELECT
        rr.rule_id,
        r.event_type,
        rr.recipient_type,
        rr.recipient_value
      FROM notification_rule_recipient rr
      JOIN notification_rule r ON r.id = rr.rule_id
      WHERE rr.is_active = TRUE AND r.is_active = TRUE
      ORDER BY r.event_type, rr.recipient_type, rr.recipient_value
    `);
    console.table(recips.rows);

    section('F. v1 mirror columns (notification_rule.template_id / channel) match v2 first channel?');
    const mirror = await client.query(`
      WITH first_chan AS (
        SELECT DISTINCT ON (rule_id) rule_id, channel, template_slug
        FROM notification_rule_channel
        WHERE is_active = TRUE
        ORDER BY rule_id, id
      )
      SELECT
        r.id, r.event_type,
        r.template_id  AS legacy_template_id,
        r.channel      AS legacy_channel,
        fc.template_slug AS v2_first_template_slug,
        fc.channel       AS v2_first_channel,
        (r.template_id IS NOT DISTINCT FROM fc.template_slug AND r.channel IS NOT DISTINCT FROM fc.channel) AS mirror_ok
      FROM notification_rule r
      LEFT JOIN first_chan fc ON fc.rule_id = r.id
      WHERE r.is_active = TRUE
      ORDER BY r.event_type, r.id
    `);
    const mismatch = mirror.rows.filter((r) => !r.mirror_ok);
    if (mismatch.length) {
      console.log('!! Mirror MISMATCH on these rules (v1 short-circuit may behave inconsistently):');
      console.table(mismatch);
    } else {
      console.log('All rules: v1 mirror matches v2 first-channel.');
    }

    section('G. BE/DB event_type call sites — coverage check');
    const expectedEvents = [
      'contract.expiry_30day',
      'contract.expiry_7day',
      'obligation.flag',
      'obligation.sla_breach',
      'advisory.rejected',
      'advisory.dispatched',
      'report.delivered',
    ];
    const cov = await client.query(
      `SELECT
         e AS event_type,
         (SELECT COUNT(*) FROM notification_rule r
            WHERE r.event_type = e AND r.is_active AND r.is_enabled) AS enabled_rules
       FROM unnest($1::text[]) e`,
      [expectedEvents]
    );
    console.table(cov.rows);
    const orphans = cov.rows.filter((r) => Number(r.enabled_rules) === 0);
    if (orphans.length) {
      console.log('!! Events with NO enabled rule (silent dispatcher):');
      console.table(orphans);
    } else {
      console.log('Every expected event has at least one enabled rule.');
    }

    section('H. Recent dispatch_log rows from v2 dispatcher (eventType stamped)');
    const recent = await client.query(`
      SELECT
        id,
        notification_template_id,
        channel,
        status,
        context_payload->>'eventType' AS event_type,
        context_payload->>'ruleId'    AS rule_id,
        delivery_attempted_at
      FROM notification_dispatch_log
      WHERE context_payload ? 'eventType'
      ORDER BY delivery_attempted_at DESC
      LIMIT 10
    `);
    console.table(recent.rows);

    section('I. Live smoke — fn_notification_dispatch for contract.expiry_30day');
    const tenant = await pickTenant(client);
    const actor  = await pickActor(client);
    console.log(`Using tenant=${tenant.id} (${tenant.name}); actor=${actor.id} (${actor.email})`);

    await client.query(`SELECT set_config('app.current_tenant_id', $1, false)`, [tenant.id]);
    await client.query(`SELECT set_config('app.current_user_id',   $1, false)`, [String(actor.id)]);

    const probePayload = {
      subject:       '[audit] expiry probe',
      bodyRendered:  '[audit] body',
      contractId:    999999,
      windowDays:    30,
      auditMarker:   MARKER,
    };
    const dispatch1 = await client.query(
      `SELECT fn_notification_dispatch($1::bigint, 'contract.expiry_30day', $2::jsonb, 'alert', 'high', $1::bigint, NULL::text) AS result`,
      [actor.id, JSON.stringify(probePayload)]
    );
    console.log(JSON.stringify(dispatch1.rows[0].result, null, 2));

    section('J. Live smoke — fn_notification_dispatch for obligation.flag (no role on payload)');
    const dispatch2 = await client.query(
      `SELECT fn_notification_dispatch($1::bigint, 'obligation.flag', $2::jsonb, 'alert', 'high', $1::bigint, NULL::text) AS result`,
      [actor.id, JSON.stringify({ subject: '[audit]', bodyRendered: '[audit]', auditMarker: MARKER })]
    );
    console.log(JSON.stringify(dispatch2.rows[0].result, null, 2));

    section('K. Condition evaluator — 9 micro-tests');
    const cases = [
      ['NULL condition',          null,                                       { x: 1 },        true],
      ['Literal eq, match',       { foo: 'bar' },                             { foo: 'bar' },  true],
      ['Literal eq, miss',        { foo: 'bar' },                             { foo: 'baz' },  false],
      ['gte, pass',               { val: { gte: 100 } },                      { val: 200 },    true],
      ['gte, fail',               { val: { gte: 100 } },                      { val: 50 },     false],
      ['in, pass',                { tier: { in: ['A','B'] } },                { tier: 'B' },   true],
      ['notIn, pass',             { tier: { notIn: ['A'] } },                 { tier: 'B' },   true],
      ['contains, pass',          { note: { contains: 'urgent' } },           { note: 'urgent thing' }, true],
      ['Dotted path, pass',       { 'contract.valueAed': { gte: 1000000 } },  { contract: { valueAed: 5000000 } }, true],
      ['Dotted path, fail',       { 'contract.valueAed': { gte: 1000000 } },  { contract: { valueAed: 500 } }, false],
    ];
    const out = [];
    for (const [label, cond, payload, expected] of cases) {
      const { rows } = await client.query(
        `SELECT fn_internal_condition_matches($1::jsonb, $2::jsonb) AS r`,
        [cond === null ? null : JSON.stringify(cond), JSON.stringify(payload)]
      );
      const got = rows[0].r;
      out.push({ label, expected, got, ok: got === expected });
    }
    console.table(out);
    const condFails = out.filter((c) => !c.ok);
    if (condFails.length) console.log(`!! ${condFails.length} condition cases failed.`);
    else console.log('All condition cases pass.');

    section('L. Cleanup — soft-delete audit-marker dispatch_log rows');
    const del = await client.query(
      `UPDATE notification_dispatch_log
         SET is_active = FALSE
       WHERE context_payload->>'auditMarker' = $1
       RETURNING id`,
      [MARKER]
    );
    console.log(`Soft-deactivated ${del.rowCount} audit rows.`);

    console.log('\nAudit complete.');
  } finally {
    client.release();
    await pool.end();
  }
})().catch((e) => {
  console.error('AUDIT FAILED', e);
  process.exitCode = 1;
});
