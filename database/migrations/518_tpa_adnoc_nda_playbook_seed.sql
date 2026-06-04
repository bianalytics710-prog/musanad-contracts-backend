-- MIGRATION: 518_tpa_adnoc_nda_playbook_seed.sql
-- Feature: TPA — ADNOC NDA playbook seed
-- Date: 2026-06-03
-- Description:
--   Seeds the ADNOC standard NDA playbook with 12 clauses that legal counsel
--   uses when reviewing counterparty paper. standard_position is what we
--   want; fallback_position is our maximum concession; non_negotiables are
--   deal-breakers that automatically produce a 'reject' verdict; red_flags
--   are common counterparty pushes worth amending.
--
--   This is realistic ADNOC posture for service / supply / consulting
--   relationships, drafted to surface meaningful conflicts when matched
--   against typical foreign-supplier paper.

BEGIN;

-- Insert the playbook header
INSERT INTO tpa_playbook (
  tenant_id, playbook_key, agreement_type, name_en, name_ar,
  description_en, version, status, created_by, updated_by
) VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid,
  'adnoc_nda_v1', 'nda',
  'ADNOC Standard NDA Playbook',
  'كتيب اتفاقية عدم الإفصاح القياسي لأدنوك',
  'Standard ADNOC posture for counterparty-paper NDA review. Covers definition of confidential information, term, permitted use, disclosure carve-outs, return of information, governing law (UAE — ADGM Courts), and dispute resolution. Used for supplier / contractor / JV / advisory NDAs.',
  1, 'active', 1, 1
)
ON CONFLICT (tenant_id, playbook_key) DO UPDATE SET
  name_en = EXCLUDED.name_en, name_ar = EXCLUDED.name_ar,
  description_en = EXCLUDED.description_en, version = EXCLUDED.version,
  status = EXCLUDED.status, updated_at = NOW();

-- Clause seeds (12 entries)
INSERT INTO tpa_playbook_clause (
  tenant_id, playbook_id, clause_key, clause_title_en, clause_title_ar,
  criticality, display_order, standard_position, fallback_position,
  non_negotiables, red_flags, guidance_notes, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  pb.id, c.clause_key, c.clause_title_en, c.clause_title_ar,
  c.criticality, c.display_order, c.standard_position, c.fallback_position,
  c.non_negotiables, c.red_flags, c.guidance_notes, 1, 1
FROM tpa_playbook pb
CROSS JOIN (VALUES
  -- 1. Definition of Confidential Information
  ('definition_confidential_info', 'Definition of Confidential Information',
   'تعريف المعلومات السرية', 'high', 10,
   'Confidential Information means all non-public information disclosed by either Party that is marked confidential, or that a reasonable person would understand to be confidential given the nature of the information and the circumstances of disclosure. Includes technical data, commercial terms, reservoir data, HSE records, and personnel data.',
   'May accept "any information disclosed by Disclosing Party" if scope is clearly time-bound and balanced (mutual).',
   ARRAY['unilateral definition favoring only counterparty', 'unlimited inclusion of unmarked oral disclosures', 'includes information already in public domain without carve-out'],
   ARRAY['broad catch-all without exclusions', 'absence of "marked confidential" requirement', 'no carve-out for independently developed information'],
   'ADNOC must always be on equal footing as both Discloser and Recipient. Always insist on the standard four exclusions (public domain, independently developed, lawfully received from third party, required by law).',
   1, 1),

  -- 2. Term / Duration
  ('term_duration', 'Term and Survival of Obligations',
   'مدة الاتفاقية واستمرار الالتزامات', 'non_negotiable', 20,
   'NDA term shall not exceed three (3) years from the Effective Date. Confidentiality obligations survive for a further two (2) years post-termination, except for trade secrets which survive for so long as they qualify as trade secrets under UAE law.',
   'May extend post-termination survival to maximum five (5) years for industrial process information.',
   ARRAY['indefinite or perpetual confidentiality obligations', 'survival period exceeding 7 years for non-trade-secret information', 'no termination right for either party'],
   ARRAY['"perpetual" or "in perpetuity" wording', 'survival "for so long as the information remains confidential"', 'no defined end date'],
   'Indefinite obligations are the single most common counterparty overreach. ALWAYS reject and offer the 3+2 ADNOC standard.',
   1, 1),

  -- 3. Permitted Use
  ('permitted_use', 'Permitted Use of Confidential Information',
   'الاستخدام المسموح به للمعلومات السرية', 'high', 30,
   'Confidential Information may be used solely for the Purpose (as defined). Use for any other purpose (including commercial exploitation, reverse engineering, or AI/ML training) requires prior written consent.',
   'May accept broad use within the same project scope if Purpose definition is sufficiently narrow.',
   ARRAY['unrestricted commercial use', 'silent on AI/ML training rights', 'allows use after termination'],
   ARRAY['absence of explicit "Purpose" definition', 'no prohibition on reverse engineering', 'no AI/ML training carve-out'],
   'AI/ML training prohibition added per Group Legal Policy 2026-Q1 (data sovereignty concern). Must be explicit.',
   1, 1),

  -- 4. Disclosure to Representatives
  ('representative_disclosure', 'Disclosure to Representatives',
   'الإفصاح للممثلين', 'high', 40,
   'Recipient may share Confidential Information only with directors, employees, professional advisors, and affiliates on a strict need-to-know basis, provided they are bound by confidentiality obligations no less stringent than this NDA. Recipient remains liable for breaches by its Representatives.',
   'May accept disclosure to specified subcontractors if listed in an Annex and individually bound.',
   ARRAY['disclosure to unnamed subcontractors without binding obligations', 'no flow-down of confidentiality duties', 'Recipient not liable for Representative breaches'],
   ARRAY['"need-to-know" not defined', 'no requirement that Representatives sign NDA', 'broad "agents" or "consultants" wording without controls'],
   'The "Recipient remains liable" clause is critical — without it, Recipient can dodge breach liability via its agents.',
   1, 1),

  -- 5. Return or Destruction
  ('return_destruction', 'Return or Destruction of Confidential Information',
   'إعادة أو إتلاف المعلومات السرية', 'medium', 50,
   'Upon written request or termination, Recipient shall within thirty (30) days return or, at Discloser''s option, destroy all Confidential Information including all copies and derived materials, and certify such return/destruction in writing.',
   'May accept retention of one (1) archival copy in secure legal hold for regulatory compliance and dispute defense, subject to continued confidentiality obligations.',
   ARRAY['indefinite retention rights without justification', 'no written certification requirement', 'no obligation to delete from electronic systems and backups'],
   ARRAY['silence on backup / archived copies', 'no certification of destruction', 'no defined deadline'],
   'Always insist on written certification — verbal confirmation has no audit trail.',
   1, 1),

  -- 6. Governing Law
  ('governing_law', 'Governing Law',
   'القانون الحاكم', 'non_negotiable', 60,
   'This Agreement shall be governed by and construed in accordance with the laws of the United Arab Emirates as applied in the Emirate of Abu Dhabi.',
   'For international counterparties with strong objections: may accept ADGM (Abu Dhabi Global Market) law (common-law system, English-language judgments) as a neutral alternative.',
   ARRAY['governing law of any sanctioned jurisdiction', 'governing law of jurisdictions hostile to UAE interests', 'silence / no governing law clause'],
   ARRAY['English law', 'New York law', 'Singapore law', 'counterparty-home-country law without ADGM offer'],
   'UAE / Abu Dhabi law is mandatory for ADNOC paper. ADGM is the only acceptable carve-out for international counterparties.',
   1, 1),

  -- 7. Jurisdiction / Dispute Resolution
  ('dispute_resolution', 'Dispute Resolution and Jurisdiction',
   'تسوية المنازعات والاختصاص القضائي', 'non_negotiable', 70,
   'Disputes shall be referred to the exclusive jurisdiction of the Abu Dhabi Courts. For international counterparties, disputes may be referred to arbitration under the ADGM Arbitration Centre Rules, seated in Abu Dhabi, in the English language, before a sole arbitrator (or three arbitrators for claims above USD 5 million).',
   'May accept DIFC Courts or DIAC arbitration if counterparty refuses ADGM and ADNOC counsel concurs.',
   ARRAY['exclusive jurisdiction in counterparty-home-country courts', 'arbitration seated outside UAE', 'litigation in jurisdictions with weak enforcement of UAE judgments'],
   ARRAY['foreign-seat arbitration (London / Singapore / Paris / Geneva)', 'silence on seat / venue / governing rules', 'ad-hoc arbitration without institutional rules'],
   'Seat of arbitration is more important than governing law for enforcement. Abu Dhabi-seated arbitration is mandatory.',
   1, 1),

  -- 8. Data Protection / UAE PDPL
  ('data_protection', 'Data Protection and UAE PDPL Compliance',
   'حماية البيانات والامتثال للقانون الإماراتي', 'high', 80,
   'Where Confidential Information includes Personal Data (as defined under UAE Federal Decree-Law No. 45 of 2021 — PDPL), the Parties shall process such data in accordance with PDPL. Cross-border transfer outside the UAE requires prior written consent and adequacy safeguards.',
   'May accept GDPR-style data processing addendum if counterparty offers, provided PDPL-equivalent protections are demonstrated.',
   ARRAY['silence on PDPL where Personal Data is involved', 'cross-border transfer without safeguards', 'sub-processing without ADNOC consent'],
   ARRAY['only references GDPR/CCPA without PDPL', 'unrestricted data transfer to "Affiliates worldwide"', 'no defined breach notification window'],
   'PDPL compliance is mandatory under UAE law. Reference Federal Decree-Law No. 45 of 2021 explicitly.',
   1, 1),

  -- 9. No License
  ('no_license_no_warranty', 'No License Granted and No Warranty',
   'لا منح للترخيص ولا ضمان', 'medium', 90,
   'Nothing in this Agreement transfers any IP rights, license, or ownership to Recipient. All Confidential Information is provided "AS IS" without any warranty of accuracy, completeness, or fitness for purpose.',
   'Recipient acknowledges no obligation on Discloser to update or correct information disclosed.',
   ARRAY['implied license to use beyond Purpose', 'implied warranties of accuracy / fitness for purpose'],
   ARRAY['ambiguous IP retention language', 'broad "best efforts" warranties on Discloser'],
   'The "AS IS" language protects ADNOC from liability for reliance damages.',
   1, 1),

  -- 10. Injunctive Relief
  ('injunctive_relief', 'Equitable / Injunctive Relief',
   'الإغاثة العادلة / الزجرية', 'medium', 100,
   'Parties acknowledge that breach of this Agreement may cause irreparable harm for which monetary damages are inadequate, and either Party is entitled to seek injunctive or other equitable relief from a court of competent jurisdiction without proof of damages or posting of bond.',
   'May limit to specific instances of trade-secret misappropriation if counterparty objects to broad equitable relief.',
   ARRAY['waiver of injunctive relief', 'exclusive remedy limited to damages'],
   ARRAY['requirement of bond / security as condition of injunction', '"sole and exclusive remedy" damages caps'],
   'Without injunctive relief, ADNOC may be unable to stop ongoing leakage even with a strong case.',
   1, 1),

  -- 11. Anti-Bribery / Sanctions
  ('compliance_sanctions', 'Anti-Bribery, Anti-Corruption, and Sanctions Compliance',
   'مكافحة الرشوة والفساد والامتثال للعقوبات', 'high', 110,
   'Each Party warrants compliance with applicable anti-bribery laws (UAE Federal Law No. 31 of 2021, US FCPA, UK Bribery Act 2010) and applicable sanctions regimes (UN, OFAC, EU, UK, UAE). Either Party may terminate immediately upon written notice if the other becomes subject to sanctions.',
   'May accept narrower warranty scope if counterparty is government-owned and provides letter of comfort.',
   ARRAY['no anti-bribery warranty', 'no termination right on sanctions designation', 'silence on US FCPA / UK Bribery Act'],
   ARRAY['warranty of "knowledge" or "to best of awareness" only', 'no obligation to notify if subject to investigation', 'no audit / step-in rights'],
   'Sanctions termination clause is increasingly important post-2024 secondary-sanctions enforcement.',
   1, 1),

  -- 12. Assignment
  ('assignment', 'Assignment',
   'التنازل', 'medium', 120,
   'Neither Party may assign this Agreement without the prior written consent of the other, except that ADNOC may assign to any of its Affiliates or to a successor in interest in connection with a corporate reorganisation, without consent.',
   'May accept reciprocal carve-out for counterparty corporate reorganisations within their group.',
   ARRAY['unilateral assignment rights for counterparty only', 'free assignment without notice'],
   ARRAY['broad "permitted assignees" without definition', 'no carve-out for ADNOC affiliate assignment'],
   'The ADNOC affiliate carve-out is important — corporate group structure means routine reassignment.',
   1, 1)
) AS c(
  clause_key, clause_title_en, clause_title_ar,
  criticality, display_order, standard_position, fallback_position,
  non_negotiables, red_flags, guidance_notes
)
WHERE pb.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND pb.playbook_key = 'adnoc_nda_v1'
ON CONFLICT (playbook_id, clause_key) DO UPDATE SET
  clause_title_en   = EXCLUDED.clause_title_en,
  clause_title_ar   = EXCLUDED.clause_title_ar,
  criticality       = EXCLUDED.criticality,
  display_order     = EXCLUDED.display_order,
  standard_position = EXCLUDED.standard_position,
  fallback_position = EXCLUDED.fallback_position,
  non_negotiables   = EXCLUDED.non_negotiables,
  red_flags         = EXCLUDED.red_flags,
  guidance_notes    = EXCLUDED.guidance_notes,
  updated_at        = NOW();

-- Bookkeeping
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (518, 'tpa_adnoc_nda_playbook_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
