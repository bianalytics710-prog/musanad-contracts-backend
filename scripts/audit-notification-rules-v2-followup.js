/* eslint-disable no-console */
/**
 * Follow-up probes to the v2 audit. Focuses on:
 *   1. Does a `contract.expiry_30day.in_app` template exist? If yes, rule 30
 *      should point at it, not the .email slug.
 *   2. Per-event channel/template alignment — any rule whose channel doesn't
 *      match its template_slug suffix.
 *   3. Sample suppressed_by_preference rows to confirm email suppression is
 *      working as expected.
 *   4. Coverage of all event_types that have BE/DB call-site evidence.
 *   5. The unrefactored `fn_advisory_dispatch` path: how many rule rows for
 *      `advisory.dispatched`? Are they enabled? Is the v1 short-circuit
 *      catching them?
 *   6. Approval / signature / contract.assigned events — do they have any
 *      DB or BE callers wiring them through fn_notification_dispatch?
 */
'use strict';
require('dotenv').config({ path: '.env.local' });
const { Pool } = require('pg');

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

(async () => {
  const c = await pool.connect();
  try {
    console.log('\n── 1. Templates for contract.expiry_30day ───────────────────────');
    let r = await c.query(`
      SELECT id, tenant_id, template_id, channel, is_active
      FROM notification_template
      WHERE template_id LIKE 'contract.expiry_30day%'
      ORDER BY template_id
    `);
    console.table(r.rows);

    console.log('\n── 2. Channel/template mismatch (channel ≠ slug suffix) ──────────');
    r = await c.query(`
      SELECT
        rc.rule_id,
        nr.event_type,
        rc.channel,
        rc.template_slug,
        CASE
          WHEN rc.template_slug LIKE '%.' || rc.channel THEN 'aligned'
          ELSE 'mismatch'
        END AS alignment
      FROM notification_rule_channel rc
      JOIN notification_rule nr ON nr.id = rc.rule_id
      WHERE rc.is_active = TRUE AND nr.is_active = TRUE
      ORDER BY alignment DESC, nr.event_type, rc.channel
    `);
    console.table(r.rows);

    console.log('\n── 3. Sample suppressed_by_preference rows ───────────────────────');
    r = await c.query(`
      SELECT id, recipient_user_id, channel, priority,
             context_payload->>'eventType' AS event_type,
             delivery_attempted_at
      FROM notification_dispatch_log
      WHERE status = 'suppressed_by_preference'
      ORDER BY delivery_attempted_at DESC
      LIMIT 5
    `);
    console.table(r.rows);

    console.log('\n── 4. Per-event total dispatches in last 30 days ─────────────────');
    r = await c.query(`
      SELECT
        context_payload->>'eventType' AS event_type,
        status,
        COUNT(*) AS n
      FROM notification_dispatch_log
      WHERE delivery_attempted_at > NOW() - INTERVAL '30 days'
        AND context_payload ? 'eventType'
      GROUP BY 1, 2
      ORDER BY 1, 2
    `);
    console.table(r.rows);

    console.log('\n── 5. Advisory dispatched: any rows since the refactor? ───────────');
    r = await c.query(`
      SELECT
        nr.id, nr.event_type, nr.is_enabled,
        rc.channel, rc.template_slug
      FROM notification_rule nr
      LEFT JOIN notification_rule_channel rc ON rc.rule_id = nr.id AND rc.is_active = TRUE
      WHERE nr.event_type = 'advisory.dispatched' AND nr.is_active = TRUE
      ORDER BY nr.id, rc.channel
    `);
    console.table(r.rows);

    console.log('\n── 6. fn_advisory_dispatch is in DB? (intentionally unrefactored) ─');
    r = await c.query(`
      SELECT proname, pronargs, prorettype::regtype
      FROM pg_proc
      WHERE proname = 'fn_advisory_dispatch'
    `);
    console.table(r.rows);

    console.log('\n── 7. Events covered by enabled rules vs caller code references ──');
    r = await c.query(`
      SELECT
        et.code,
        et.category,
        (SELECT COUNT(*) FROM notification_rule r
          WHERE r.event_type = et.code AND r.is_active AND r.is_enabled) AS enabled_rules
      FROM notification_event_type et
      WHERE et.is_active = TRUE
      ORDER BY enabled_rules ASC, et.code
    `);
    console.table(r.rows);
  } finally {
    c.release();
    await pool.end();
  }
})().catch((e) => { console.error(e); process.exitCode = 1; });
