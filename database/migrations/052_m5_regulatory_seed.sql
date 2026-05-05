-- ============================================================================
-- 052_m5_regulatory_seed.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   049 (impact_category table).
-- ----------------------------------------------------------------------------
-- 8 default impact_category rows (per Lovable extraction). Idempotent —
-- ON CONFLICT (key) DO NOTHING.
-- regulator seed lives in 048; permission/role_permission seed in 046.
-- regulation, regulatory_update, regulatory_impact: NO seed data (admin-authored).
-- ----------------------------------------------------------------------------

BEGIN;

INSERT INTO impact_category (
  key, name_en, name_ar, description_en, description_ar,
  icon, colour, active, display_order,
  sources, severity_scale, ai_prompt_context, default_clause_categories, is_seed
) VALUES
  ('labour', 'Labour & Employment', 'العمل والتوظيف',
   'Working hours, leave, termination, end-of-service gratuity, Emiratisation quotas.',
   'ساعات العمل، الإجازات، الإنهاء، مكافأة نهاية الخدمة، حصص التوطين.',
   'users', 'amber', TRUE, 10,
   '["MoHRE"]'::jsonb, '["low","medium","high","critical"]'::jsonb,
   'Focus on employee rights, working hours, leave entitlements, end-of-service obligations, and Emiratisation requirements per UAE Federal Labour Law.',
   ARRAY['working_hours','leave','termination','end_of_service','emiratisation'],
   TRUE),

  ('tax', 'Taxation', 'الضرائب',
   'VAT, corporate tax, excise tax compliance and reporting.',
   'ضريبة القيمة المضافة، ضريبة الشركات، الضريبة الانتقائية والامتثال والإبلاغ.',
   'percent', 'rose', TRUE, 20,
   '["FTA"]'::jsonb, '["low","medium","high","critical"]'::jsonb,
   'Focus on VAT registration thresholds, corporate tax rates and exemptions, transfer pricing, and reporting deadlines per FTA regulations.',
   ARRAY['payment_terms','invoicing','tax_clauses'],
   TRUE),

  ('financial', 'Financial Services', 'الخدمات المالية',
   'Banking, capital adequacy, AML/CFT, payments regulation.',
   'الخدمات المصرفية، كفاية رأس المال، مكافحة غسل الأموال وتمويل الإرهاب، تنظيم المدفوعات.',
   'landmark', 'sky', TRUE, 30,
   '["Central Bank","DIFC","ADGM"]'::jsonb,
   '["low","medium","high","critical"]'::jsonb,
   'Focus on financial institution licensing, capital adequacy, AML/CFT compliance, payment system regulations.',
   ARRAY['payment_terms','financial_covenants','reporting'],
   TRUE),

  ('data_privacy', 'Data Privacy & Protection', 'خصوصية البيانات وحمايتها',
   'PDPL, cross-border data transfer, consent, data subject rights.',
   'قانون حماية البيانات الشخصية، نقل البيانات عبر الحدود، الموافقة، حقوق أصحاب البيانات.',
   'shield-check', 'indigo', TRUE, 40,
   '["TDRA","DIFC","ADGM"]'::jsonb,
   '["low","medium","high","critical"]'::jsonb,
   'Focus on personal data processing lawful bases, cross-border transfer mechanisms, data subject access rights per UAE PDPL.',
   ARRAY['data_protection','confidentiality','sub_processing'],
   TRUE),

  ('commercial', 'Commercial Practices', 'الممارسات التجارية',
   'Competition law, consumer protection, e-commerce.',
   'قانون المنافسة، حماية المستهلك، التجارة الإلكترونية.',
   'shopping-cart', 'emerald', TRUE, 50,
   '["MoE","TDRA"]'::jsonb,
   '["low","medium","high","critical"]'::jsonb,
   'Focus on anti-competitive agreements, consumer rights, e-commerce disclosure obligations per UAE Federal Commercial Law.',
   ARRAY['warranties','consumer_rights','marketing'],
   TRUE),

  ('dispute_resolution', 'Dispute Resolution', 'حل النزاعات',
   'Arbitration rules, court jurisdiction, ADR mechanisms.',
   'قواعد التحكيم، اختصاص المحاكم، آليات حل النزاعات البديلة.',
   'gavel', 'slate', TRUE, 60,
   '["MoJ","DIFC","ADGM"]'::jsonb,
   '["low","medium","high","critical"]'::jsonb,
   'Focus on arbitration seat, governing law, court jurisdiction, recognition of foreign judgments.',
   ARRAY['governing_law','dispute_resolution','arbitration'],
   TRUE),

  ('intellectual_property', 'Intellectual Property', 'الملكية الفكرية',
   'Trademark, copyright, patent, trade secrets.',
   'العلامة التجارية، حقوق النشر، براءة الاختراع، الأسرار التجارية.',
   'lightbulb', 'violet', TRUE, 70,
   '["MoE"]'::jsonb,
   '["low","medium","high","critical"]'::jsonb,
   'Focus on IP ownership, licensing, infringement remedies per UAE IP regulations.',
   ARRAY['ip_ownership','licensing','confidentiality'],
   TRUE),

  ('other', 'Other', 'أخرى',
   'Cross-cutting or uncategorised regulatory impact.',
   'تأثير تنظيمي شامل أو غير مصنف.',
   'shield', 'slate', TRUE, 99,
   '[]'::jsonb,
   '["low","medium","high","critical"]'::jsonb,
   'General regulatory guidance — apply legal judgment.',
   ARRAY[]::TEXT[],
   TRUE)
ON CONFLICT (key) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (52, 'm5_regulatory_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DELETE FROM impact_category WHERE key IN (
  'labour','tax','financial','data_privacy','commercial',
  'dispute_resolution','intellectual_property','other'
);
DELETE FROM schema_migrations WHERE version = 52;
COMMIT;
-- ROLLBACK END
