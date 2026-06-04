/**
 * One-shot data backfill — re-spread obligation due_date so the demo doesn't
 * look ridiculous (today there's stuff overdue by 122 days, plus open
 * obligations stretching out to 2030).
 *
 * Rules:
 *   - status='overdue'     → 1-30 days overdue (CURRENT_DATE - 1..30)
 *   - status='in_progress' → 1-14 days from today
 *   - status='open'        → 7-186 days from today (spread by id)
 *   - status='completed'   → untouched (history)
 *   - status='waived'      → untouched
 *
 * Deterministic: keyed off id so re-runs produce the same dates relative to
 * CURRENT_DATE.
 *
 * Run: node database/scripts/backfill-obligation-dates.js
 */
require('dotenv').config({ path: '.env.local' });
const { Pool } = require('pg');

const sql = `
UPDATE contract_obligation SET
  due_date = CASE status
    WHEN 'overdue'     THEN CURRENT_DATE - (((id * 7) % 30) + 1)::int
    WHEN 'in_progress' THEN CURRENT_DATE + (((id * 5) % 14) + 1)::int
    WHEN 'open'        THEN CURRENT_DATE + (((id * 13) % 180) + 7)::int
    ELSE due_date
  END,
  updated_at = NOW()
WHERE is_active = TRUE
  AND status IN ('overdue', 'in_progress', 'open')
RETURNING id, status, due_date, (due_date - CURRENT_DATE) AS days_from_today;
`;

(async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  try {
    const r = await pool.query(sql);
    console.log(JSON.stringify({ rowsUpdated: r.rowCount }, null, 2));

    const dist = await pool.query(`
      SELECT status,
             MIN(due_date - CURRENT_DATE)::int AS min_days,
             MAX(due_date - CURRENT_DATE)::int AS max_days,
             COUNT(*) AS cnt
      FROM contract_obligation
      WHERE is_active = TRUE
      GROUP BY status
      ORDER BY status
    `);
    console.log('NEW DISTRIBUTION:');
    console.log(JSON.stringify(dist.rows, null, 2));
  } finally {
    await pool.end();
  }
})().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
