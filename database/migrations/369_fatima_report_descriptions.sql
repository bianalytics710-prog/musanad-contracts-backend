-- Migration: 369_fatima_report_descriptions.sql
-- Unit: Fatima Finance QA Phase 3.5 (F1-F80 audit pass)
-- Targets:
--   F67  FX Exposure Report description: "MAR x FX exposure..." → "MaR × FX exposure..."
--   F68  Price Review Queue description leaks snake_case "price_review" → "price-review"

UPDATE report_template
   SET description = 'MaR × FX exposure aggregated by contract currency with USD equivalent total.',
       updated_at = NOW()
 WHERE template_id = 'finance_fx_exposure'
   AND description LIKE '%MAR x%';

UPDATE report_template
   SET description = 'Contracts flagged by price-review correlations with upcoming review due-dates.',
       updated_at = NOW()
 WHERE template_id = 'finance_price_review_queue'
   AND description LIKE '%price_review%';
