/**
 * One-shot data backfill — populate contact_email / contact_phone /
 * registered_address for every active party that has any of those NULL.
 *
 * Deterministic: uses party.id + name_en + country + emirate so re-runs are
 * idempotent (no-op on rows that already have all three fields).
 *
 * Run: node database/scripts/backfill-party-contacts.js
 */
require('dotenv').config({ path: '.env.local' });
const { Pool } = require('pg');

const sql = `
WITH country_map(country, dial, tld, capital) AS (
  VALUES
    ('United Arab Emirates', '+971', 'ae',     'Dubai'),
    ('United States',        '+1',   'com',    'New York'),
    ('United Kingdom',       '+44',  'co.uk',  'London'),
    ('Cyprus',               '+357', 'com.cy', 'Nicosia'),
    ('Netherlands',          '+31',  'nl',     'Amsterdam'),
    ('Cayman Islands',       '+1-345','com',   'George Town'),
    ('British Virgin Islands','+1-284','com',  'Road Town'),
    ('India',                '+91',  'in',     'Mumbai'),
    ('Singapore',            '+65',  'com.sg', 'Singapore'),
    ('Saudi Arabia',         '+966', 'sa',     'Riyadh'),
    ('Qatar',                '+974', 'qa',     'Doha'),
    ('Bahrain',              '+973', 'bh',     'Manama'),
    ('Kuwait',               '+965', 'kw',     'Kuwait City'),
    ('Oman',                 '+968', 'om',     'Muscat'),
    ('Egypt',                '+20',  'eg',     'Cairo'),
    ('Jordan',               '+962', 'jo',     'Amman'),
    ('Lebanon',              '+961', 'lb',     'Beirut'),
    ('Iraq',                 '+964', 'iq',     'Baghdad'),
    ('Iran',                 '+98',  'ir',     'Tehran'),
    ('Turkey',               '+90',  'tr',     'Istanbul'),
    ('Germany',              '+49',  'de',     'Berlin'),
    ('France',               '+33',  'fr',     'Paris'),
    ('Switzerland',          '+41',  'ch',     'Zurich'),
    ('Italy',                '+39',  'it',     'Milan'),
    ('Spain',                '+34',  'es',     'Madrid'),
    ('Russia',               '+7',   'ru',     'Moscow'),
    ('China',                '+86',  'cn',     'Shanghai'),
    ('Japan',                '+81',  'jp',     'Tokyo'),
    ('Hong Kong',            '+852', 'com.hk', 'Hong Kong'),
    ('Australia',            '+61',  'com.au', 'Sydney')
),
emirate_map(emirate, city) AS (
  VALUES
    ('abu_dhabi',     'Abu Dhabi'),
    ('dubai',         'Dubai'),
    ('sharjah',       'Sharjah'),
    ('ajman',         'Ajman'),
    ('fujairah',      'Fujairah'),
    ('ras_al_khaimah','Ras Al Khaimah'),
    ('umm_al_quwain', 'Umm Al Quwain')
),
party_enriched AS (
  SELECT
    p.id,
    p.party_type,
    p.name_en,
    p.country,
    p.emirate,
    p.free_zone,
    p.contact_email,
    p.contact_phone,
    p.registered_address,
    cm.dial,
    cm.tld,
    cm.capital,
    em.city
  FROM party p
  LEFT JOIN country_map cm ON cm.country = p.country
  LEFT JOIN emirate_map em ON em.emirate = p.emirate
  WHERE p.is_active = TRUE
    AND (p.contact_email IS NULL OR p.contact_phone IS NULL OR p.registered_address IS NULL)
)
UPDATE party p SET
  contact_email = COALESCE(p.contact_email,
    CASE
      WHEN pe.party_type = 'individual' THEN
        regexp_replace(lower(pe.name_en), '[^a-z0-9]+', '.', 'g')
        || '@email.' || COALESCE(pe.tld, 'com')
      ELSE
        'legal@'
        || trim(both '-' from regexp_replace(lower(pe.name_en), '[^a-z0-9]+', '-', 'g'))
        || '.' || COALESCE(pe.tld, 'com')
    END
  ),
  contact_phone = COALESCE(p.contact_phone,
    COALESCE(pe.dial, '+1-555') || '-' ||
    lpad(((pe.id * 137) % 900 + 100)::text, 3, '0') || '-' ||
    lpad(((pe.id * 911) % 9000 + 1000)::text, 4, '0')
  ),
  registered_address = COALESCE(p.registered_address,
    CASE
      WHEN pe.country = 'United Arab Emirates' THEN
        CASE
          WHEN pe.free_zone IS NOT NULL THEN
            pe.free_zone || ', ' || COALESCE(pe.city, 'Dubai') || ', United Arab Emirates'
          ELSE
            CASE (pe.id % 4)
              WHEN 0 THEN 'Office ' || (100 + (pe.id % 800))::text || ', ' || COALESCE(pe.city, 'Dubai') || ', United Arab Emirates'
              WHEN 1 THEN 'Sheikh Zayed Road, ' || COALESCE(pe.city, 'Dubai') || ', United Arab Emirates'
              WHEN 2 THEN 'Corniche Road, ' || COALESCE(pe.city, 'Abu Dhabi') || ', United Arab Emirates'
              ELSE 'Business Bay, ' || COALESCE(pe.city, 'Dubai') || ', United Arab Emirates'
            END
        END
      ELSE
        COALESCE(pe.capital, pe.country, 'Dubai') || ', ' || COALESCE(pe.country, 'United Arab Emirates')
    END
  ),
  updated_at = NOW()
FROM party_enriched pe
WHERE pe.id = p.id
RETURNING p.id;
`;

(async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  try {
    const r = await pool.query(sql);
    console.log(JSON.stringify({ rowsUpdated: r.rowCount }, null, 2));

    const sample = await pool.query(
      "SELECT id, name_en, contact_email, contact_phone, registered_address FROM party WHERE id IN (27, 29, 31, 35, 38, 39) ORDER BY id",
    );
    console.log('SAMPLE AFTER:');
    console.log(JSON.stringify(sample.rows, null, 2));

    const remaining = await pool.query(
      "SELECT COUNT(*) AS n FROM party WHERE is_active=TRUE AND (contact_email IS NULL OR contact_phone IS NULL OR registered_address IS NULL)",
    );
    console.log('REMAINING NULL:', remaining.rows[0].n);
  } finally {
    await pool.end();
  }
})().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
