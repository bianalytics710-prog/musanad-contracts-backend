/**
 * Cleanup: undo the rows I created while testing the analyze-upload flow.
 *   - Template #23 ("Confidentiality Agreement Template" — saved during pass 1).
 *   - Clauses #52..#62 (11 NDA clauses added during pass 1's "Add to library").
 *
 * Soft-delete (is_active = FALSE) — matches the rest of the project. Match
 * queries already filter is_active so these rows drop out of similarity.
 * Template #22 remains deactivated (it was a leftover from a previous demo).
 */
const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  const t = await c.query(
    `UPDATE contract_template
        SET is_active = FALSE, updated_at = NOW()
      WHERE id = 23 AND is_active = TRUE
      RETURNING id, name_en`,
  );
  console.log(`Templates deactivated: ${t.rows.length}`, t.rows);

  const cl = await c.query(
    `UPDATE contract_clause
        SET is_active = FALSE, updated_at = NOW()
      WHERE id BETWEEN 52 AND 62 AND is_active = TRUE
      RETURNING id, title_en`,
  );
  console.log(`Clauses deactivated: ${cl.rows.length}`);
  cl.rows.forEach((r) => console.log(`  #${r.id} ${r.title_en}`));

  // Sanity: confirm match queries will find the pre-test set only.
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
