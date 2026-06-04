-- Migration: 462_replace_placeholder_summaries.sql
-- Module: ADNOC demo — Act 5 external signing page hygiene
-- Date: 2026-06-02
--
-- Problem: contract.ai_summary_en (and _ar) on at least 2 contracts contain
-- literal AI-generation placeholders like "[Our Party]", "[Counterparty]",
-- "[value]", "[services/products]". These render on the public /sign/{token}
-- page (SigningCeremony summaryDisplay) — counterparties see bracketed
-- placeholder text and lose trust before they sign.
--
-- Fix: regenerate summaries by substituting actual party names, contract
-- value, and dates pulled from the row itself. Idempotent; only touches
-- summaries that still contain unresolved placeholders.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

UPDATE contract c
SET
  ai_summary_en = TRIM(
    CONCAT(
      'This contract — ', COALESCE(c.title_en, c.contract_number),
      ' — is between ', COALESCE(op.name_en, 'our organisation'),
      ' and ', COALESCE(cp.name_en, 'the counterparty'), '. ',
      CASE WHEN c.value_aed IS NOT NULL AND c.value_aed > 0
        THEN 'Total contract value is ' ||
             COALESCE(c.currency, 'AED') || ' ' ||
             TRIM(TO_CHAR(c.value_aed, 'FM999,999,999,999.00')) || '. '
        ELSE ''
      END,
      CASE WHEN c.start_date IS NOT NULL AND c.end_date IS NOT NULL
        THEN 'Term runs from ' || TO_CHAR(c.start_date, 'DD Mon YYYY') ||
             ' to ' || TO_CHAR(c.end_date, 'DD Mon YYYY') || '. '
        ELSE ''
      END,
      'Both parties commit to the performance, payment and termination ',
      'terms set out in the body of the agreement. Material breach or ',
      'failure to meet milestones may trigger cure or termination ',
      'provisions. By executing this instrument the parties accept the ',
      'governing law and dispute-resolution venue stated above.'
    )
  ),
  ai_summary_ar = TRIM(
    CONCAT(
      'هذا العقد — ', COALESCE(c.title_ar, c.title_en, c.contract_number),
      ' — مُبرم بين ', COALESCE(op.name_ar, op.name_en, 'مؤسستنا'),
      ' و', COALESCE(cp.name_ar, cp.name_en, 'الطرف المقابل'), '. ',
      CASE WHEN c.value_aed IS NOT NULL AND c.value_aed > 0
        THEN 'القيمة الإجمالية للعقد ' ||
             COALESCE(c.currency, 'AED') || ' ' ||
             TRIM(TO_CHAR(c.value_aed, 'FM999,999,999,999.00')) || '. '
        ELSE ''
      END,
      CASE WHEN c.start_date IS NOT NULL AND c.end_date IS NOT NULL
        THEN 'تسري المدة من ' || TO_CHAR(c.start_date, 'DD Mon YYYY') ||
             ' إلى ' || TO_CHAR(c.end_date, 'DD Mon YYYY') || '. '
        ELSE ''
      END,
      'يلتزم الطرفان بشروط الأداء والدفع والإنهاء المنصوص عليها في متن ',
      'الاتفاقية. وقد يؤدي الإخلال الجوهري أو الفشل في تحقيق المراحل ',
      'الرئيسية إلى تفعيل أحكام الإصلاح أو الإنهاء. وبتنفيذ هذه الوثيقة ',
      'يقبل الطرفان القانون الحاكم وجهة تسوية المنازعات المحددة أعلاه.'
    )
  ),
  updated_at = now()
FROM party op, party cp
WHERE c.our_party_id    = op.id
  AND c.counterparty_id = cp.id
  AND (
       c.ai_summary_en LIKE '%[Our Party]%'
    OR c.ai_summary_en LIKE '%[Counterparty]%'
    OR c.ai_summary_en LIKE '%[value]%'
    OR c.ai_summary_en LIKE '%[services/products]%'
    OR c.ai_summary_en LIKE '%[frequency]%'
    OR c.ai_summary_en LIKE '%[specific dates%'
    OR c.ai_summary_ar LIKE '%[Our Party]%'
    OR c.ai_summary_ar LIKE '%[Counterparty]%'
  );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (462, '462_replace_placeholder_summaries', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 462;
-- ============================================================
