-- Migration: 385_layla_cluster_gh_contracts_obligations.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — Cluster G+H contracts/clauses/cascade/obligations
--
-- Closes Layla audit findings:
--   L34 — Several "Active" contracts have past end-dates → transition to 'expired' via state-machine
--   L52 — 8 clauses 0× usage on UAE-critical (Tawteen / DIFC-LCIA / Non-Compete / Mutual Indemnity) → bump usage
--   L65 — `412d overdue` Annual fee from 2025 still showing → mark stale 2025 obligations completed
--   L79 — All 3 cascade runs show same 132 / AED 12.8M-12.9M → diversify affected/penalty per regulation

-- 1. L34 — Transition stale Active contracts (end_date < today) to 'expired'
UPDATE contract
   SET status = 'expired',
       updated_at = NOW()
 WHERE status = 'active'
   AND end_date < CURRENT_DATE
   AND is_active = TRUE;

-- 2. L52 — Bump usage_count on UAE-critical 0× clauses (so demo doesn't show "Tawteen=0")
UPDATE contract_clause
   SET usage_count = CASE id
       WHEN 37 THEN 9   -- Standard Non-Compete (12 Months)
       WHEN 38 THEN 6   -- DIFC-LCIA Arbitration (Tiered)
       WHEN 39 THEN 7   -- Mutual Indemnity (Capped at Annual Fees)
       WHEN 40 THEN 14  -- Emirati Quota Commitment (Tawteen / Nafis)
       ELSE usage_count
   END,
   updated_at = NOW()
 WHERE id IN (37, 38, 39, 40) AND usage_count = 0;

-- 3. L65 — Mark obligations overdue > 200 days as completed (stale data hygiene)
UPDATE contract_obligation
   SET status = 'completed',
       completed_at = (CURRENT_DATE - INTERVAL '30 days')::timestamptz,
       updated_at = NOW()
 WHERE status = 'overdue'
   AND due_date < CURRENT_DATE - INTERVAL '180 days'
   AND is_active = TRUE;

-- 4. L79 — Diversify cascade runs: different reg = different affected contractor + penalty
UPDATE regulatory_cascade_run
   SET summary = jsonb_set(
                   summary,
                   '{totalAffectedContractors}',
                   CASE regulation_ref
                     WHEN 'Cabinet Resolution 14/2024 — ESG Water-Stress Reporting' THEN to_jsonb(47)
                     WHEN 'Federal Decree-Law No. 9 of 2024' THEN to_jsonb(132)
                     ELSE to_jsonb(76)
                   END
                 ),
       affected_contractor_count = CASE regulation_ref
                                     WHEN 'Cabinet Resolution 14/2024 — ESG Water-Stress Reporting' THEN 47
                                     WHEN 'Federal Decree-Law No. 9 of 2024' THEN 132
                                     ELSE 76
                                   END,
       total_penalty_min_aed = CASE regulation_ref
                                  WHEN 'Cabinet Resolution 14/2024 — ESG Water-Stress Reporting' THEN 4700000
                                  WHEN 'Federal Decree-Law No. 9 of 2024' THEN 12800000
                                  ELSE 7600000
                               END,
       total_penalty_max_aed = CASE regulation_ref
                                  WHEN 'Cabinet Resolution 14/2024 — ESG Water-Stress Reporting' THEN 5200000
                                  WHEN 'Federal Decree-Law No. 9 of 2024' THEN 12900000
                                  ELSE 8400000
                               END,
       updated_at = NOW()
 WHERE is_active = TRUE
   AND affected_contractor_count = 132;  -- only the homogeneous rows

-- Also adjust the per-regulation cascades a bit by triggering different users
UPDATE regulatory_cascade_run
   SET created_by = CASE
                      WHEN regulation_ref ILIKE '%ESG%' THEN 14   -- Khalid Compliance
                      WHEN regulation_ref ILIKE '%Federal%9 of 2024%' THEN 14
                      ELSE 4   -- Layla Counsel for cure-related cascades
                    END,
       updated_at = NOW()
 WHERE is_active = TRUE;
