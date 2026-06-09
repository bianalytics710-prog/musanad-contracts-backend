const { Client } = require('pg');
require('dotenv').config({ path: '.env.local' });
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  // Find clauses linked to a "Mercury" template, or with Mercury in the title/source.
  const probe = await c.query(`
    SELECT id, title_en, category, source, source_template_id, source_contract_id,
           created_at, is_active
      FROM clause
     WHERE (lower(title_en) LIKE '%mercury%'
        OR lower(coalesce(body_en, '')) LIKE '%mercury%'
        OR lower(coalesce(source, '')) LIKE '%mercury%'
        OR lower(coalesce(source, '')) LIKE '%11-nda-mercury%')
       AND is_active = TRUE
     ORDER BY created_at DESC
  `);
  console.log("Mercury-tagged clauses (active):", probe.rows.length);
  for (const r of probe.rows) console.log(`  id=${r.id}  cat=${r.category}  title="${r.title_en}"  source="${r.source}"  template=${r.source_template_id}`);

  // Also check templates with Mercury name
  const tpl = await c.query(`
    SELECT id, name_en, contract_type, is_active, created_at
      FROM contract_template
     WHERE lower(name_en) LIKE '%mercury%' AND is_active = TRUE
  `);
  console.log("\nMercury templates (active):", tpl.rows.length);
  for (const r of tpl.rows) console.log(`  id=${r.id}  name="${r.name_en}"  type=${r.contract_type}`);

  // Check clauses with no source — maybe seeded ones
  const unsourced = await c.query(`
    SELECT id, title_en, category, source_template_id
      FROM clause
     WHERE source_template_id IN (SELECT id FROM contract_template WHERE lower(name_en) LIKE '%mercury%')
       AND is_active = TRUE
  `);
  console.log("\nClauses by source_template_id linkage to Mercury template:", unsourced.rows.length);
  for (const r of unsourced.rows) console.log(`  id=${r.id}  cat=${r.category}  title="${r.title_en}"`);

  await c.end();
})();
