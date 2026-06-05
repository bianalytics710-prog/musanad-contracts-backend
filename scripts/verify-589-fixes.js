/* eslint-disable no-console */
/**
 * Verify the two fixes in migration 589:
 *
 *   FIX 1 — Rule 30 in_app channel now points at the in_app template, and
 *           the new template exists.
 *   FIX 2 — fn_obligation_flag dispatches ONCE per event with notifyUserIds
 *           array; adding a non-caller recipient no longer multiplies.
 */
'use strict';
require('dotenv').config({ path: '.env.local' });
const { Pool } = require('pg');

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const MARKER = 'audit-589-verify';

(async () => {
  const c = await pool.connect();
  try {
    // ── FIX 1 ─────────────────────────────────────────────────────────
    console.log('\n── FIX 1: contract.expiry_30day.in_app template + rule 30 channel ──');
    const tpl = await c.query(`
      SELECT id, template_id, channel, is_active
      FROM notification_template
      WHERE template_id LIKE 'contract.expiry_30day%'
      ORDER BY template_id
    `);
    console.table(tpl.rows);

    const r30 = await c.query(`
      SELECT
        nr.id, nr.event_type, nr.template_id AS legacy_mirror_slug,
        rc.channel, rc.template_slug,
        EXISTS (SELECT 1 FROM notification_template t
                 WHERE t.template_id = rc.template_slug AND t.channel = rc.channel
                   AND t.is_active = TRUE) AS slug_aligned_with_channel
      FROM notification_rule nr
      JOIN notification_rule_channel rc ON rc.rule_id = nr.id AND rc.is_active = TRUE
      WHERE nr.id = 30
    `);
    console.table(r30.rows);

    // ── Recipient seed updates ───────────────────────────────────────
    console.log('\n── Recipient seed: obligation.flag + obligation.sla_breach default rules ──');
    const recips = await c.query(`
      SELECT
        nr.event_type, nr.id AS rule_id,
        nr.tenant_id IS NULL AS is_system_default,
        rr.recipient_type, rr.recipient_value
      FROM notification_rule nr
      JOIN notification_rule_recipient rr ON rr.rule_id = nr.id AND rr.is_active = TRUE
      WHERE nr.event_type IN ('obligation.flag','obligation.sla_breach')
        AND nr.is_active = TRUE
      ORDER BY nr.event_type, nr.id
    `);
    console.table(recips.rows);

    // ── Resolver catalogue exposes notifyUserIds ─────────────────────
    console.log('\n── Resolver catalogue includes notifyUserIds ──');
    const cat = await c.query(`SELECT fn_notification_context_resolver_list() AS list`);
    const codes = cat.rows[0].list.data.map((x) => x.code);
    console.log(codes.join(' | '));
    console.log('Has notifyUserIds:', codes.includes('notifyUserIds'));

    // ── FIX 2: smoke fn_notification_dispatch end-to-end ─────────────
    console.log('\n── FIX 2 — smoke: dispatch obligation.flag with notifyUserIds [1,2,3] ──');
    const tenant = (await c.query("SELECT id FROM tenant WHERE is_active = TRUE ORDER BY created_at LIMIT 1")).rows[0].id;
    await c.query(`SELECT set_config('app.current_tenant_id', $1, false)`, [tenant]);
    await c.query(`SELECT set_config('app.current_user_id',   '1', false)`);

    // Baseline (no extra recipient): expect 3 dispatches (1 per user in array)
    const payload1 = {
      subject:       '[verify-589] obligation flag',
      bodyRendered:  '[verify-589] body',
      obligationId:  999999,
      contractId:    999999,
      notifyUserIds: [1, 2, 3],
      auditMarker:   MARKER,
    };
    const r1 = await c.query(
      `SELECT fn_notification_dispatch(1::bigint, 'obligation.flag', $1::jsonb, 'alert', 'high', NULL::bigint, NULL::text) AS res`,
      [JSON.stringify(payload1)]
    );
    console.log('Baseline (caller-supplied 3 users):', JSON.stringify(r1.rows[0].res, null, 2));

    // Add a role:executive recipient temporarily to the obligation.flag rule
    // (we'll roll it back at the end). Check whether the multiplication is gone.
    const ruleId = recips.rows.find((r) => r.event_type === 'obligation.flag').rule_id;
    console.log(`\n  Adding role:executive recipient to rule ${ruleId}…`);
    await c.query(`
      INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, created_by, updated_by)
      VALUES ($1::bigint, 'role', 'executive', 1, 1)
    `, [ruleId]);

    const execCount = await c.query(`
      SELECT COUNT(*)::int AS n FROM "user" u
      JOIN role r ON r.id = u.role_id
      WHERE r.name = 'executive' AND u.is_active = TRUE
    `);
    console.log(`  Executive role currently resolves to ${execCount.rows[0].n} user(s).`);

    const r2 = await c.query(
      `SELECT fn_notification_dispatch(1::bigint, 'obligation.flag', $1::jsonb, 'alert', 'high', NULL::bigint, NULL::text) AS res`,
      [JSON.stringify(payload1)]
    );
    console.log('\nWith executive role added:', JSON.stringify(r2.rows[0].res, null, 2));
    console.log(`Expected = 3 (notifyUserIds) + ${execCount.rows[0].n} (executive role) = ${3 + execCount.rows[0].n}`);
    console.log(`Got      = ${r2.rows[0].res.dispatchesCreated}`);

    // ── Cleanup ──────────────────────────────────────────────────────
    console.log('\n── Cleanup: remove the test recipient + soft-deactivate audit marker rows ──');
    const undo = await c.query(`
      DELETE FROM notification_rule_recipient
       WHERE rule_id = $1 AND recipient_type = 'role' AND recipient_value = 'executive'
       RETURNING id
    `, [ruleId]);
    console.log(`Removed ${undo.rowCount} test recipient row(s).`);

    const del = await c.query(`
      UPDATE notification_dispatch_log
         SET is_active = FALSE
       WHERE context_payload->>'auditMarker' = $1
       RETURNING id
    `, [MARKER]);
    console.log(`Soft-deactivated ${del.rowCount} dispatch_log marker row(s).`);

    console.log('\nDone.');
  } finally {
    c.release();
    await pool.end();
  }
})().catch((e) => { console.error('VERIFY FAILED', e); process.exitCode = 1; });
