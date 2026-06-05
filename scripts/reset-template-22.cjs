const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });

(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  // Soft-delete template 22 (leftover from previous demo run of Mercury NDA).
  // Match queries already filter is_active = TRUE, so this removes it from
  // similarity. The Mercury demo can re-create it cleanly.
  const r = await c.query(
    `UPDATE contract_template
        SET is_active = FALSE, updated_at = NOW()
      WHERE id = 22
      RETURNING id, name_en, is_active`,
  );
  console.log('Deactivated:', r.rows);
  await c.end();
})();
