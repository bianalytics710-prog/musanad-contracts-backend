/**
 * One-shot backfill: compute body_embedding for every contract_template +
 * contract_clause row that doesn't have one yet.
 *
 * Skips already-embedded rows so this is idempotent. Re-run safely.
 *
 * Required env: DATABASE_URL, OPENAI_API_KEY (in .env.local).
 */
const { Client } = require('pg');
const OpenAI = require('openai');
require('dotenv').config({ path: '.env.local' });

const EMBED_MODEL = 'text-embedding-3-small';

async function embed(openai, text) {
  // text-embedding-3-small input cap is 8191 tokens; truncate hard to stay safe.
  const trimmed = String(text || '').slice(0, 24000);
  if (trimmed.trim().length === 0) return null;
  const r = await openai.embeddings.create({ model: EMBED_MODEL, input: trimmed });
  return r.data[0]?.embedding ?? null;
}

function toPgVector(arr) {
  return '[' + arr.map((x) => x.toFixed(8)).join(',') + ']';
}

(async () => {
  if (!process.env.OPENAI_API_KEY) {
    console.error('OPENAI_API_KEY missing in .env.local');
    process.exit(1);
  }
  const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  // --- Templates ---
  const tpls = await c.query(
    `SELECT id, name_en, body_en
       FROM contract_template
      WHERE is_active = TRUE AND body_embedding IS NULL`,
  );
  console.log(`Templates to embed: ${tpls.rows.length}`);
  for (const r of tpls.rows) {
    const src = (r.name_en + '\n\n' + (r.body_en || '')).slice(0, 24000);
    try {
      const emb = await embed(openai, src);
      if (!emb) { console.log(`  skip #${r.id} (empty body)`); continue; }
      await c.query('UPDATE contract_template SET body_embedding = $1::vector WHERE id = $2', [toPgVector(emb), r.id]);
      console.log(`  ok #${r.id}: ${r.name_en}`);
    } catch (e) {
      console.error(`  fail #${r.id}: ${e.message}`);
    }
  }

  // --- Clauses ---
  const cls = await c.query(
    `SELECT id, title_en, body_en
       FROM contract_clause
      WHERE is_active = TRUE AND body_embedding IS NULL`,
  );
  console.log(`Clauses to embed: ${cls.rows.length}`);
  for (const r of cls.rows) {
    const src = (r.title_en + '\n\n' + (r.body_en || '')).slice(0, 24000);
    try {
      const emb = await embed(openai, src);
      if (!emb) { console.log(`  skip #${r.id} (empty body)`); continue; }
      await c.query('UPDATE contract_clause SET body_embedding = $1::vector WHERE id = $2', [toPgVector(emb), r.id]);
      console.log(`  ok #${r.id}: ${r.title_en}`);
    } catch (e) {
      console.error(`  fail #${r.id}: ${e.message}`);
    }
  }

  await c.end();
  console.log('Done.');
})();
