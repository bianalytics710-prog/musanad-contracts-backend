/**
 * Soft-delete what the user added during their manual demo test:
 *   - Template #24 ("Confidentiality Agreement Template", created 15:39 UTC).
 *   - Clauses #63..#73 (the 11 NDA clauses added via cross-check).
 * Match queries filter is_active so these will not surface in similarity.
 */
const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  const t = await c.query(
    `UPDATE contract_template
        SET is_active = FALSE, updated_at = NOW()
      WHERE id = 24 AND is_active = TRUE
      RETURNING id, name_en`,
  );
  console.log(`Templates deactivated: ${t.rows.length}`, t.rows);

  const cl = await c.query(
    `UPDATE contract_clause
        SET is_active = FALSE, updated_at = NOW()
      WHERE id BETWEEN 63 AND 73 AND is_active = TRUE
      RETURNING id, title_en`,
  );
  console.log(`Clauses deactivated: ${cl.rows.length}`);
  cl.rows.forEach((r) => console.log(`  #${r.id} ${r.title_en}`));

  const tc = await c.query(
    `SELECT COUNT(*)::int AS active_templates
       FROM contract_template WHERE is_active = TRUE AND body_embedding IS NOT NULL`,
  );
  const cc = await c.query(
    `SELECT COUNT(*)::int AS active_clauses
       FROM contract_clause WHERE is_active = TRUE AND body_embedding IS NOT NULL`,
  );
  console.log(`\nRemaining active+embedded — templates: ${tc.rows[0].active_templates}, clauses: ${cc.rows[0].active_clauses}`);

  await c.end();
})();
