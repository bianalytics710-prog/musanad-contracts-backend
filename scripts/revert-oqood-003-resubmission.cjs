// One-shot revert: undo Layla's "Request resubmission" on OQOOD-2026-003
// so the contract is back in her queue and I can walk the failure modes
// (no notification, comment missing from Comments tab, no drafter CTA).
//
// Reversal:
//   1. contract id 7 (OQOOD-2026-003): status draft → in_approval
//   2. approval_chain id 3: status='in_progress', completed_at=NULL
//   3. approval_step id 4 (Layla's step): status='pending', decided_at=NULL
//   4. approval_decision id 107 (the resubmission decision + note): is_active=FALSE
//   5. Soft-delete any contract_activity rows decided at that timestamp
//      so the activity feed reads cleanly.
//
// NOT a migration — this is targeted demo data cleanup, run-once.
const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  try {
    await c.query('BEGIN');
    await c.query("SELECT set_config('app.current_tenant_id','00000000-0000-0000-0000-000000000001', true)");
    await c.query("SELECT set_config('app.current_user_id','5', true)"); // Hala for audit fields

    const r1 = await c.query(
      "UPDATE contract SET status='in_approval', updated_at=NOW() WHERE id=7 AND contract_number='OQOOD-2026-003' RETURNING id, status",
    );
    console.log('contract:', r1.rows[0]);

    const r2 = await c.query(
      "UPDATE approval_chain SET status='in_progress', completed_at=NULL, updated_at=NOW() WHERE id=3 RETURNING id, status, completed_at",
    );
    console.log('approval_chain:', r2.rows[0]);

    const r3 = await c.query(
      "UPDATE approval_step SET status='pending', decided_at=NULL, updated_at=NOW() WHERE id=4 RETURNING id, status, decided_at",
    );
    console.log('approval_step:', r3.rows[0]);

    // approval_decision is append-only (denied by trigger) — hard DELETE
    // is the only way back. Demo data only, not a pattern for production.
    const r4 = await c.query(
      "DELETE FROM approval_decision WHERE id=107 RETURNING id, decision, decision_note",
    );
    console.log('approval_decision DELETED:', r4.rows[0]);

    // Soft-delete recent resubmission-related activity rows for tidy feed.
    const r5 = await c.query(
      "UPDATE contract_activity SET is_active=FALSE WHERE contract_id=7 AND created_at >= NOW() - INTERVAL '30 minutes' AND activity_type LIKE '%resubmission%' RETURNING id, activity_type, created_at",
    );
    console.log('contract_activity (soft-deleted):', r5.rows);

    await c.query('COMMIT');
    console.log('\nReverted.');
  } catch (e) {
    await c.query('ROLLBACK');
    console.error('FAIL:', e.message);
    process.exit(1);
  } finally {
    await c.end();
  }
})();
