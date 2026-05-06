-- Migration 075: R-LC5 — module catalogue gaps for legal counsel parity.
--   1. party.is_verified — flag drives the LC-L5 Verified indicator on
--      parties list/cards (Lovable parity column).
--   2. Seed 4 net-new clauses across the 4 missing categories (LC-H2):
--      non_compete / dispute_resolution / indemnity / emiratisation.
--      Categories already exist in the contract_clause CHECK constraint;
--      seed only.
--   3. Seed 6 net-new obligations across 3 obligation types that had
--      zero seed rows (delivery / compliance / notice) — covers the
--      Lovable categories that were missing locally (Deliverable /
--      Compliance / Notification). Finance / HR are not in the CHECK
--      enum and don't map cleanly — they are intentionally skipped per
--      LC scope.

-- 1. party.is_verified column ----------------------------------------------

ALTER TABLE party
  ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE;

-- Auto-flag parties with both a trade-licence number AND issuer as
-- verified (rough heuristic for seed data).
UPDATE party
SET is_verified = TRUE
WHERE trade_license_number IS NOT NULL
  AND trade_license_issuer IS NOT NULL
  AND is_verified = FALSE;

-- Extend the list/get fn projections to expose isVerified ------------------

CREATE OR REPLACE FUNCTION fn_party_list(
  p_actor_id   BIGINT,
  p_party_type VARCHAR DEFAULT NULL,
  p_search     VARCHAR DEFAULT NULL,
  p_limit      INTEGER DEFAULT 100,
  p_offset     INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM party p
  WHERE p.is_active = TRUE
    AND (p_party_type IS NULL OR p.party_type = p_party_type)
    AND (p_search IS NULL OR p.name_en ILIKE '%' || p_search || '%' OR COALESCE(p.name_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                 p.id,
    'partyType',          p.party_type,
    'nameEn',             p.name_en,
    'nameAr',             p.name_ar,
    'tradeLicenseNumber', p.trade_license_number,
    'tradeLicenseIssuer', p.trade_license_issuer,
    'emirate',            p.emirate,
    'freeZone',           p.free_zone,
    'country',            p.country,
    'contactEmail',       p.contact_email,
    'contactPhone',       p.contact_phone,
    'isVerified',         p.is_verified,
    'createdAt',          p.created_at
  ) ORDER BY p.name_en), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM party
    WHERE is_active = TRUE
      AND (p_party_type IS NULL OR party_type = p_party_type)
      AND (p_search IS NULL OR name_en ILIKE '%' || p_search || '%' OR COALESCE(name_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY name_en
    LIMIT p_limit OFFSET p_offset
  ) p;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset)
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_party_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_party_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

CREATE OR REPLACE FUNCTION fn_party_get_by_id(
  p_actor_id BIGINT,
  p_party_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
  v_contracts JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                 p.id,
    'partyType',          p.party_type,
    'nameEn',             p.name_en,
    'nameAr',             p.name_ar,
    'tradeLicenseNumber', p.trade_license_number,
    'tradeLicenseIssuer', p.trade_license_issuer,
    'emirate',            p.emirate,
    'freeZone',           p.free_zone,
    'country',            p.country,
    'contactEmail',       p.contact_email,
    'contactPhone',       p.contact_phone,
    'registeredAddress',  p.registered_address,
    'notes',              p.notes,
    'isVerified',         p.is_verified,
    'createdAt',          p.created_at,
    'updatedAt',          p.updated_at
  ) INTO v_row
  FROM party p
  WHERE p.id = p_party_id AND p.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
    'status',         c.status,
    'valueAed',       c.value_aed,
    'updatedAt',      c.updated_at
  ) ORDER BY c.updated_at DESC), '[]'::jsonb) INTO v_contracts
  FROM (
    SELECT id, contract_number, title_en, status, value_aed, updated_at
    FROM contract
    WHERE counterparty_id = p_party_id AND is_active = TRUE
    ORDER BY updated_at DESC
    LIMIT 5
  ) c;

  RETURN v_row || jsonb_build_object('recentContracts5', v_contracts);
END;
$$;

REVOKE ALL ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- 2. Seed 4 net-new clauses (one per missing category) ---------------------

DO $$
DECLARE
  v_admin_id BIGINT;
BEGIN
  SELECT id INTO v_admin_id FROM "user" WHERE email = 'admin@musanad.local' LIMIT 1;
  IF v_admin_id IS NULL THEN
    SELECT MIN(id) INTO v_admin_id FROM "user" WHERE is_active = TRUE;
  END IF;

  -- non_compete
  IF NOT EXISTS (SELECT 1 FROM contract_clause WHERE category = 'non_compete' AND is_active = TRUE) THEN
    INSERT INTO contract_clause (
      category, title_en, title_ar, variant, body_en, body_ar,
      legal_commentary_en, regulatory_refs, usage_count, is_seed,
      created_by, updated_by
    ) VALUES (
      'non_compete',
      'Standard Non-Compete (12 Months)',
      'عدم منافسة قياسي (12 شهرًا)',
      'standard',
      'For a period of twelve (12) months following termination of this Agreement, the Counterparty shall not, directly or indirectly, engage in any business that competes with the Company within the United Arab Emirates.',
      'لمدة اثني عشر (12) شهرًا بعد إنهاء هذه الاتفاقية، لا يجوز للطرف المقابل، بصورة مباشرة أو غير مباشرة، الانخراط في أي نشاط تجاري ينافس الشركة داخل دولة الإمارات العربية المتحدة.',
      'Enforceability subject to UAE Federal Decree-Law 33/2021 Art. 10 — non-competes must be limited in time, geography, and scope to the extent necessary to protect the employer''s legitimate interests.',
      ARRAY['Federal Decree-Law 33/2021']::TEXT[],
      0, TRUE, v_admin_id, v_admin_id
    );
  END IF;

  -- dispute_resolution
  IF NOT EXISTS (SELECT 1 FROM contract_clause WHERE category = 'dispute_resolution' AND is_active = TRUE) THEN
    INSERT INTO contract_clause (
      category, title_en, title_ar, variant, body_en, body_ar,
      legal_commentary_en, regulatory_refs, usage_count, is_seed,
      created_by, updated_by
    ) VALUES (
      'dispute_resolution',
      'DIFC-LCIA Arbitration (Tiered)',
      'تحكيم DIFC-LCIA (متدرج)',
      'standard',
      'Any dispute arising out of or in connection with this Agreement shall be referred first to senior-management negotiation; failing resolution within 30 days, to mediation administered by the DIFC-LCIA Arbitration Centre under its Mediation Rules; failing resolution within 60 days, to final arbitration administered by the DIFC-LCIA Arbitration Centre under its Arbitration Rules. The seat shall be the DIFC; the language English; one arbitrator.',
      'تُحال أي نزاعات أولاً إلى التفاوض على مستوى الإدارة العليا؛ فإن لم تُحل خلال 30 يومًا، إلى الوساطة التي يديرها مركز DIFC-LCIA للتحكيم؛ فإن لم تُحل خلال 60 يومًا، إلى التحكيم النهائي الذي يديره مركز DIFC-LCIA. مقر التحكيم مركز دبي المالي العالمي، اللغة الإنجليزية، محكّم واحد.',
      'DIFC-LCIA is the most common UAE-based arbitration centre for cross-border commercial disputes. Tiered escalation reduces cost and preserves business relationships.',
      ARRAY['DIFC-LCIA Rules 2021']::TEXT[],
      0, TRUE, v_admin_id, v_admin_id
    );
  END IF;

  -- indemnity
  IF NOT EXISTS (SELECT 1 FROM contract_clause WHERE category = 'indemnity' AND is_active = TRUE) THEN
    INSERT INTO contract_clause (
      category, title_en, title_ar, variant, body_en, body_ar,
      legal_commentary_en, regulatory_refs, usage_count, is_seed,
      created_by, updated_by
    ) VALUES (
      'indemnity',
      'Mutual Indemnity (Capped at Annual Fees)',
      'تعويض متبادل (حدّه الأقصى الأتعاب السنوية)',
      'standard',
      'Each Party shall indemnify and hold the other harmless against direct losses arising from (a) breach of warranty, (b) infringement of third-party intellectual property, or (c) breach of confidentiality. The indemnifying Party''s aggregate liability under this clause shall not exceed the total amount paid or payable in the twelve (12) months preceding the claim.',
      'يلتزم كل طرف بتعويض الطرف الآخر وحمايته من الخسائر المباشرة الناشئة عن (أ) الإخلال بالضمانات، (ب) انتهاك حقوق الملكية الفكرية للغير، (ج) الإخلال بالسرية. لا تتجاوز المسؤولية الإجمالية للطرف المعوّض إجمالي المبالغ المدفوعة أو المستحقة خلال الأشهر الاثني عشر السابقة للمطالبة.',
      'Mutual indemnity with annual-fees cap is the most common middle-ground in UAE commercial contracts. Excludes consequential losses.',
      ARRAY['UAE Civil Transactions Law Art. 282']::TEXT[],
      0, TRUE, v_admin_id, v_admin_id
    );
  END IF;

  -- emiratisation
  IF NOT EXISTS (SELECT 1 FROM contract_clause WHERE category = 'emiratisation' AND is_active = TRUE) THEN
    INSERT INTO contract_clause (
      category, title_en, title_ar, variant, body_en, body_ar,
      legal_commentary_en, regulatory_refs, usage_count, is_seed,
      created_by, updated_by
    ) VALUES (
      'emiratisation',
      'Emirati Quota Commitment (Tawteen / Nafis)',
      'التزام نسبة التوطين (توطين / نافس)',
      'standard',
      'Where the Company employs fifty (50) or more skilled workers, the Counterparty acknowledges the Company''s obligation under MoHRE Tawteen rules to maintain Emirati employment at no less than the prevailing annual percentage. The Counterparty shall cooperate with reasonable requests for hiring data and Nafis programme reporting.',
      'حيث يوظف صاحب العمل خمسين (50) عاملًا ماهرًا أو أكثر، يقر الطرف المقابل بالتزام الشركة بنظام التوطين (Tawteen) لدى وزارة الموارد البشرية بنسبة التوطين السنوية السائدة. يتعاون الطرف المقابل مع الطلبات المعقولة لبيانات التوظيف وتقارير برنامج نافس.',
      'Required for private-sector employers with 50+ skilled workers. Penalties for non-compliance escalate annually under MoHRE Decision No. 663/2022.',
      ARRAY['MoHRE Tawteen', 'Nafis Programme']::TEXT[],
      0, TRUE, v_admin_id, v_admin_id
    );
  END IF;

  -- 3. Seed 6 net-new obligations across 3 obligation types -------------------

  PERFORM 1 FROM contract_obligation WHERE obligation_type = 'delivery' LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO contract_obligation (
      contract_id, title_en, obligation_type, due_date, recurrence,
      responsible_party, status, is_seed, created_by, updated_by
    ) SELECT
      c.id,
      'Quarterly project deliverables',
      'delivery',
      CURRENT_DATE + INTERVAL '14 days',
      'quarterly',
      'counterparty',
      'open',
      TRUE,
      v_admin_id,
      v_admin_id
    FROM contract c WHERE c.is_active = TRUE LIMIT 2;
  END IF;

  PERFORM 1 FROM contract_obligation WHERE obligation_type = 'compliance' LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO contract_obligation (
      contract_id, title_en, obligation_type, due_date, recurrence,
      responsible_party, status, is_seed, created_by, updated_by
    ) SELECT
      c.id,
      'Annual PDPL compliance audit',
      'compliance',
      CURRENT_DATE + INTERVAL '90 days',
      'annually',
      'our_party',
      'open',
      TRUE,
      v_admin_id,
      v_admin_id
    FROM contract c WHERE c.is_active = TRUE LIMIT 2;
  END IF;

  PERFORM 1 FROM contract_obligation WHERE obligation_type = 'notice' LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO contract_obligation (
      contract_id, title_en, obligation_type, due_date, recurrence,
      responsible_party, status, is_seed, created_by, updated_by
    ) SELECT
      c.id,
      'Send month-end notification',
      'notice',
      CURRENT_DATE + INTERVAL '7 days',
      'monthly',
      'our_party',
      'open',
      TRUE,
      v_admin_id,
      v_admin_id
    FROM contract c WHERE c.is_active = TRUE LIMIT 2;
  END IF;
END$$;

-- ROLLBACK BEGIN
-- ALTER TABLE party DROP COLUMN IF EXISTS is_verified;
-- DELETE FROM contract_clause WHERE category IN ('non_compete','dispute_resolution','indemnity','emiratisation') AND is_seed = TRUE;
-- DELETE FROM contract_obligation WHERE obligation_type IN ('delivery','compliance','notice') AND is_seed = TRUE;
-- ROLLBACK END
