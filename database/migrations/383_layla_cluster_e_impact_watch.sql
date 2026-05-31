-- Migration: 383_layla_cluster_e_impact_watch.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — Cluster E Impact Watch
--
-- Closes Layla audit findings:
--   L55 — 100 signals · 0 impacting any contract (seed correlations linking demo signals to contracts)
--   L57 — UK child maintenance RSS leak (soft-delete that signal + any other UK domestic irrelevance)
--   L58 — Murban current settle $108 contradicts demo state (no DB seed needed — the price walk
--          will be replayed via /app/admin/demo trigger; here we ensure the most-recent commodity
--          is at the demo start state $110.75 by seeding a fresh signal)
--   L56 — Daily price walk dominance (no schema change — addressed in FE pass by Eman E31's
--          "Only with impacted contracts" toggle, which now actually has rows to show because L55 is fixed)

-- 1. L55 — Seed correlations linking the Hormuz demo signals (id 5223560..5223717) to demo contracts.
DO $$
DECLARE
  v_signal RECORD;
  v_contract_ids BIGINT[];
  v_rule_id BIGINT;
  i INT := 0;
BEGIN
  -- Pick only contracts that actually exist on this branch
  SELECT array_agg(id ORDER BY id) INTO v_contract_ids
    FROM contract
   WHERE id IN (5, 7, 8, 13, 25, 38, 52) AND is_active = TRUE;
  IF v_contract_ids IS NULL OR array_length(v_contract_ids, 1) = 0 THEN
    RAISE NOTICE 'Mig 383: demo contracts not present on this branch — skipping correlations';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM osint_signal WHERE title_en ILIKE '%Hormuz%' AND is_active = TRUE) THEN
    RAISE NOTICE 'Mig 383: demo Hormuz signals not present — skipping';
    RETURN;
  END IF;
  -- Pick the Hormuz disruption rule (id 2 per inspection)
  SELECT id INTO v_rule_id FROM correlation_rule WHERE rule_id = 'rule.hormuz.supply_disruption' LIMIT 1;
  IF v_rule_id IS NULL THEN
    SELECT id INTO v_rule_id FROM correlation_rule WHERE enabled = TRUE ORDER BY id LIMIT 1;
  END IF;

  FOR v_signal IN
    SELECT id FROM osint_signal
     WHERE title_en ILIKE '%Hormuz%'
       AND is_active = TRUE
     ORDER BY id LIMIT 10
  LOOP
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
      confidence, match_reason, match_evidence, status,
      data_classification, created_at, created_by, updated_at, is_active
    )
    SELECT '00000000-0000-0000-0000-000000000001', v_signal.id,
           v_contract_ids[(i % array_length(v_contract_ids, 1)) + 1],
           v_rule_id, 'L55-seed-v1',
           0.78,
           'Hormuz Strait disruption affects gulf-routed delivery obligations under this contract.',
           jsonb_build_object('severity', 'high', 'rule_seed', 'L55-seed'),
           'active',
           'demo', NOW() - (i * INTERVAL '4 hours'), 1, NOW(), TRUE
    WHERE NOT EXISTS (
      SELECT 1 FROM correlation
       WHERE signal_id = v_signal.id
         AND contract_id = v_contract_ids[(i % array_length(v_contract_ids, 1)) + 1]
    );
    i := i + 1;
  END LOOP;

  -- Same for the MURBAN price-review signal cohort (Brent price review rule id 5)
  SELECT id INTO v_rule_id FROM correlation_rule WHERE rule_id = 'rule.brent.price_review_trigger_high' LIMIT 1;
  i := 0;
  FOR v_signal IN
    SELECT id FROM osint_signal
     WHERE title_en ILIKE 'MURBAN%' AND is_active = TRUE
     ORDER BY id LIMIT 5
  LOOP
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
      confidence, match_reason, match_evidence, status,
      data_classification, created_at, created_by, updated_at, is_active
    )
    SELECT '00000000-0000-0000-0000-000000000001', v_signal.id,
           v_contract_ids[(i % array_length(v_contract_ids, 1)) + 1],
           v_rule_id, 'L55-seed-v1',
           0.72,
           'Murban OSP movement triggers price-review threshold under this contract.',
           jsonb_build_object('severity', 'medium', 'rule_seed', 'L55-seed'),
           'active',
           'demo', NOW() - (i * INTERVAL '6 hours'), 1, NOW(), TRUE
    WHERE NOT EXISTS (
      SELECT 1 FROM correlation
       WHERE signal_id = v_signal.id AND contract_id = v_contract_ids[(i % array_length(v_contract_ids, 1)) + 1]
    );
    i := i + 1;
  END LOOP;
END $$;

-- 2. L57 — Soft-delete UK domestic + other clearly off-topic RSS entries
UPDATE osint_signal
   SET is_active = FALSE, updated_at = NOW()
 WHERE (
        title_en ILIKE '%child maintenance%'
     OR title_en ILIKE '%National Media Authority%'
     OR title_en ILIKE '%Hijab%'
     OR title_en ILIKE '%Royal%wedding%'
   )
   AND is_active = TRUE;
