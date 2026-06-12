-- Migration: 624_cleanup_v1_work_order_data.sql
-- Module: Work Order Queue (M21) — V1 demo data purge
-- Date: 2026-06-11
--
-- mig 620/621 auto-created contract 703 (CT-2026-000027) + work_order 1 at
-- request time. Architecture pivoted in mig 623 so the contract is no
-- longer created up-front. Purge the dupe.

BEGIN;

-- 1) work_order references contract 703 via target_contract_id FK, so the
--    work_order row must go first. RLS deny-DELETE is bypassed transiently.
ALTER TABLE public.work_order NO FORCE ROW LEVEL SECURITY;
DELETE FROM public.work_order WHERE id = 1 AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
ALTER TABLE public.work_order FORCE ROW LEVEL SECURITY;

-- 2) contract_clause_extracted FK → contract
DELETE FROM public.contract_clause_extracted WHERE contract_id = 703;
-- 3) contract_version FK → contract
DELETE FROM public.contract_version WHERE contract_id = 703;
-- 4) finally the contract row itself (audit_log rows kept as history)
DELETE FROM public.contract WHERE id = 703 AND contract_number = 'CT-2026-000027';

COMMIT;
