/**
 * Reverse-engineer: for each Mercury NDA clause we extracted in the demo,
 * what was its best similarity to the existing library? Helps decide if the
 * 0.85 clause-match threshold is too strict.
 *
 * We re-embed the 11 Mercury clauses (titles only — fast) and run them through
 * the same library match.
 */
const { Client } = require('pg');
const OpenAI = require('openai');
require('dotenv').config({ path: '.env.local' });

// Titles from the demo extraction.
const MERCURY_CLAUSE_TITLES = [
  ['Confidential Information', 'confidentiality'],
  ['Obligations of the Recipient', 'confidentiality'],
  ['Permitted Disclosures', 'confidentiality'],
  ['Term', 'term'],
  ['Return or Destruction', 'confidentiality'],
  ['No Licence, No Representations', 'intellectual_property'],
  ['No Obligation to Proceed', 'other'],
  ['Injunctive Relief', 'dispute_resolution'],
  ['Compliance', 'other'],
  ['Governing Law and Dispute Resolution', 'governing_law'],
  ['Entire Agreement, Assignment and Counterparts', 'other'],
];

function toPgVector(arr) {
  return '[' + arr.map((x) => x.toFixed(8)).join(',') + ']';
}

(async () => {
  const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();

  console.log('idx | mercury title                                  | best library match                          | sim');
  console.log('----|-----------------------------------------------|---------------------------------------------|------');

  for (let i = 0; i < MERCURY_CLAUSE_TITLES.length; i++) {
    const [title, cat] = MERCURY_CLAUSE_TITLES[i];
    const r = await openai.embeddings.create({
      model: 'text-embedding-3-small',
      input: `${title}\n\n[${cat}]`,
    });
    const emb = r.data[0].embedding;

    const lib = await c.query(
      `SELECT id, title_en, category,
              ROUND((1 - (body_embedding <=> $1::vector))::numeric, 4) AS sim
         FROM contract_clause
        WHERE is_active = TRUE AND body_embedding IS NOT NULL
        ORDER BY body_embedding <=> $1::vector
        LIMIT 1`,
      [toPgVector(emb)],
    );
    const m = lib.rows[0];
    console.log(
      `${String(i + 1).padStart(2)}  | ${title.padEnd(46)} | ${(m.title_en || '—').padEnd(43)} | ${m.sim}`,
    );
  }

  await c.end();
})();
