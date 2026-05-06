-- Migration 079: R-LC7 — Impact Watch feature module.
--
-- Replaces the FE "Coming soon" placeholder with a full multi-source
-- intelligence surface mirroring Lovable's /regulations page.
--
-- Single unified table impact_signal with a `category` enum that covers
-- the 5 Lovable categories (regulatory + commodity_prices + supply_chain
-- + geopolitical + market_financial). One signal can be linked to N
-- contracts via the existing regulatory_impact table when category =
-- 'regulatory' (preserving M5 backwards-compat) — non-regulatory signals
-- get a parallel impact_signal_contract junction so the same
-- "impacted contracts" list pattern works for ALL categories.
--
-- Tables:
--   impact_signal              — the news / event / regulation
--   impact_signal_contract     — per-contract attachment (impact + status)
--
-- Functions:
--   fn_impact_signal_list      — paginated, filterable
--   fn_impact_signal_get       — single signal + impacted contracts
--   fn_impact_signal_mark_reviewed — flip a signal_contract row to reviewed
--   fn_impact_signal_notify_drafters — emit contract_activity event for
--                                      each impacted contract drafter
--   fn_impact_signal_bulk_amend — emit contract_activity 'amendment_initiated'
--                                  for each impacted contract
--
-- Seed: 18 sample signals across all 5 categories so the FE has rich data.

-- 1. Tables -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS impact_signal (
  id                  BIGSERIAL PRIMARY KEY,
  ext_id              VARCHAR(60)  UNIQUE NOT NULL,
  category            VARCHAR(40)  NOT NULL CHECK (
    category IN ('regulatory','commodity_prices','supply_chain','geopolitical','market_financial')
  ),
  source              VARCHAR(120) NOT NULL,
  severity            VARCHAR(40)  NOT NULL,
  title_en            VARCHAR(260) NOT NULL,
  title_ar            VARCHAR(260),
  description_en      TEXT,
  description_ar      TEXT,
  affected_clause_categories  TEXT[]   NOT NULL DEFAULT '{}',
  published_date      DATE         NOT NULL DEFAULT CURRENT_DATE,
  effective_date      DATE,
  compliance_deadline DATE,
  is_seed             BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_impact_signal_category    ON impact_signal(category) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_impact_signal_published   ON impact_signal(published_date DESC) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_impact_signal_severity    ON impact_signal(severity) WHERE is_active = TRUE;

CREATE TABLE IF NOT EXISTS impact_signal_contract (
  id                  BIGSERIAL PRIMARY KEY,
  signal_id           BIGINT       NOT NULL REFERENCES impact_signal(id) ON DELETE CASCADE,
  contract_id         BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  impact_score        INTEGER      NOT NULL DEFAULT 50 CHECK (impact_score BETWEEN 0 AND 100),
  status              VARCHAR(20)  NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','reviewed','amended','dismissed')),
  reviewed_at         TIMESTAMPTZ,
  reviewed_by         BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_seed             BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,

  UNIQUE (signal_id, contract_id)
);

CREATE INDEX IF NOT EXISTS idx_impact_signal_contract_signal  ON impact_signal_contract(signal_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_impact_signal_contract_contract ON impact_signal_contract(contract_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_impact_signal_contract_status   ON impact_signal_contract(status) WHERE is_active = TRUE;

-- 2. Activity-type whitelist additions --------------------------------------

ALTER TABLE contract_activity DROP CONSTRAINT contract_activity_activity_type_check;
ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check CHECK (
    activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
      'payment_schedule_replaced','exported',
      'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
      'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
      'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated',
      'regulatory_impact_detected','regulatory_impact_resolved',
      'review_request_info',
      'impact_signal_notify','amendment_initiated'
    )
  );

CREATE OR REPLACE FUNCTION fn_contract_activity_create(
  p_contract_id    BIGINT,
  p_activity_type  TEXT,
  p_actor_id       BIGINT       DEFAULT NULL,
  p_description_en TEXT         DEFAULT NULL,
  p_description_ar TEXT         DEFAULT NULL,
  p_metadata       JSONB        DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id    BIGINT;
  v_actor BIGINT;
BEGIN
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
    'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
    'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated',
    'regulatory_impact_detected','regulatory_impact_resolved',
    'review_request_info',
    'impact_signal_notify','amendment_initiated'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: activityType:invalid type %', p_activity_type USING ERRCODE = '22023';
  END IF;

  v_actor := COALESCE(
    p_actor_id,
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'activityType', p_activity_type, 'contractId', p_contract_id);
END;
$$;

-- 3. fn_impact_signal_list --------------------------------------------------

CREATE OR REPLACE FUNCTION fn_impact_signal_list(
  p_actor_id BIGINT,
  p_category VARCHAR DEFAULT NULL,
  p_severity VARCHAR DEFAULT NULL,
  p_search   VARCHAR DEFAULT NULL,
  p_limit    INTEGER DEFAULT 100,
  p_offset   INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total FROM impact_signal s
    WHERE s.is_active = TRUE
      AND (p_category IS NULL OR s.category = p_category)
      AND (p_severity IS NULL OR s.severity = p_severity)
      AND (p_search IS NULL OR s.title_en ILIKE '%' || p_search || '%' OR COALESCE(s.title_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                s.id,
    'extId',             s.ext_id,
    'category',          s.category,
    'source',            s.source,
    'severity',          s.severity,
    'titleEn',           s.title_en,
    'titleAr',           s.title_ar,
    'descriptionEn',     s.description_en,
    'descriptionAr',     s.description_ar,
    'affectedClauseCategories', s.affected_clause_categories,
    'publishedDate',     s.published_date,
    'effectiveDate',     s.effective_date,
    'complianceDeadline', s.compliance_deadline,
    'impactedContractCount', (SELECT COUNT(*) FROM impact_signal_contract isc WHERE isc.signal_id = s.id AND isc.is_active = TRUE),
    'createdAt',         s.created_at
  ) ORDER BY s.published_date DESC, s.id DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM impact_signal
    WHERE is_active = TRUE
      AND (p_category IS NULL OR category = p_category)
      AND (p_severity IS NULL OR severity = p_severity)
      AND (p_search IS NULL OR title_en ILIKE '%' || p_search || '%' OR COALESCE(title_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY published_date DESC, id DESC
    LIMIT p_limit OFFSET p_offset
  ) s;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

-- 4. fn_impact_signal_get ---------------------------------------------------

CREATE OR REPLACE FUNCTION fn_impact_signal_get(
  p_actor_id BIGINT,
  p_signal_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
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
    'id',                s.id,
    'extId',             s.ext_id,
    'category',          s.category,
    'source',            s.source,
    'severity',          s.severity,
    'titleEn',           s.title_en,
    'titleAr',           s.title_ar,
    'descriptionEn',     s.description_en,
    'descriptionAr',     s.description_ar,
    'affectedClauseCategories', s.affected_clause_categories,
    'publishedDate',     s.published_date,
    'effectiveDate',     s.effective_date,
    'complianceDeadline', s.compliance_deadline,
    'createdAt',         s.created_at,
    'updatedAt',         s.updated_at
  ) INTO v_row
  FROM impact_signal s WHERE s.id = p_signal_id AND s.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'impact_signal_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             isc.id,
    'contractId',     c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
    'impactScore',    isc.impact_score,
    'status',         isc.status,
    'reviewedAt',     isc.reviewed_at
  ) ORDER BY isc.impact_score DESC, c.contract_number), '[]'::jsonb) INTO v_contracts
  FROM impact_signal_contract isc
  JOIN contract c ON c.id = isc.contract_id
  WHERE isc.signal_id = p_signal_id AND isc.is_active = TRUE AND c.is_active = TRUE;

  RETURN v_row || jsonb_build_object('impactedContracts', v_contracts);
END;
$$;

-- 5. fn_impact_signal_mark_reviewed -----------------------------------------

CREATE OR REPLACE FUNCTION fn_impact_signal_mark_reviewed(
  p_actor_id BIGINT,
  p_link_id  BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_signal_id BIGINT;
  v_contract_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE impact_signal_contract
    SET status = 'reviewed',
        reviewed_at = CURRENT_TIMESTAMP,
        reviewed_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_link_id AND is_active = TRUE
    RETURNING signal_id, contract_id INTO v_signal_id, v_contract_id;

  IF v_signal_id IS NULL THEN
    RAISE EXCEPTION 'impact_link_not_found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', p_link_id, 'signalId', v_signal_id, 'contractId', v_contract_id, 'status', 'reviewed');
END;
$$;

-- 6. fn_impact_signal_notify_drafters --------------------------------------

CREATE OR REPLACE FUNCTION fn_impact_signal_notify_drafters(
  p_actor_id  BIGINT,
  p_signal_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  rec RECORD;
  v_count INTEGER := 0;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  FOR rec IN
    SELECT isc.contract_id, c.contract_number
    FROM impact_signal_contract isc
    JOIN contract c ON c.id = isc.contract_id
    WHERE isc.signal_id = p_signal_id
      AND isc.is_active = TRUE
      AND isc.status IN ('pending','reviewed')
      AND c.is_active = TRUE
  LOOP
    PERFORM fn_contract_activity_create(
      rec.contract_id,
      'impact_signal_notify',
      p_actor_id,
      'Drafter notified of regulatory / market signal',
      NULL,
      jsonb_build_object('signalId', p_signal_id)
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('signalId', p_signal_id, 'notified', v_count);
END;
$$;

-- 7. fn_impact_signal_bulk_amend ------------------------------------------

CREATE OR REPLACE FUNCTION fn_impact_signal_bulk_amend(
  p_actor_id  BIGINT,
  p_signal_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  rec RECORD;
  v_count INTEGER := 0;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  FOR rec IN
    SELECT isc.id AS link_id, isc.contract_id
    FROM impact_signal_contract isc
    JOIN contract c ON c.id = isc.contract_id
    WHERE isc.signal_id = p_signal_id
      AND isc.is_active = TRUE
      AND isc.status IN ('pending','reviewed')
      AND c.is_active = TRUE
  LOOP
    PERFORM fn_contract_activity_create(
      rec.contract_id,
      'amendment_initiated',
      p_actor_id,
      'Bulk amendment initiated from impact signal',
      NULL,
      jsonb_build_object('signalId', p_signal_id)
    );
    UPDATE impact_signal_contract
      SET status = 'amended',
          updated_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id
      WHERE id = rec.link_id;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('signalId', p_signal_id, 'amended', v_count);
END;
$$;

-- 8. Permissions / grants ---------------------------------------------------

REVOKE ALL ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_impact_signal_get(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_impact_signal_mark_reviewed(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_impact_signal_notify_drafters(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_impact_signal_bulk_amend(BIGINT, BIGINT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_impact_signal_get(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_impact_signal_mark_reviewed(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_impact_signal_notify_drafters(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_impact_signal_bulk_amend(BIGINT, BIGINT) TO neondb_owner;

-- 9. Seed -------------------------------------------------------------------

DO $$
DECLARE
  v_admin_id BIGINT;
  v_signal RECORD;
  v_contract_ids BIGINT[];
BEGIN
  SELECT MIN(id) INTO v_admin_id FROM "user" WHERE is_active = TRUE;
  SELECT array_agg(id) INTO v_contract_ids FROM (SELECT id FROM contract WHERE is_active = TRUE LIMIT 5) x;

  -- Seed signals across all 5 categories.
  INSERT INTO impact_signal (ext_id, category, source, severity, title_en, title_ar, description_en, affected_clause_categories, published_date, effective_date, is_seed, created_by, updated_by) VALUES
    ('CBUAE-AML-08-2025',  'regulatory',       'Central Bank',          'critical',  'AML/CFT Enhanced Due Diligence',                  'متطلبات العناية الواجبة المعزّزة لمكافحة غسل الأموال', 'New CBUAE rule mandating enhanced KYC for high-risk counterparties; affects all regulated financial-services contracts.', ARRAY['data_protection','indemnity']::TEXT[], CURRENT_DATE - 7,  CURRENT_DATE + 60,  TRUE, v_admin_id, v_admin_id),
    ('FTA-VAT-ART53-2026', 'regulatory',       'Federal Tax Authority', 'high',      'FTA VAT Article 53 — Input Tax Apportionment',    'تعديل المادة 53 — توزيع ضريبة المدخلات',                'Reduces input-tax recovery for partly-exempt suppliers; may require contract value adjustments.', ARRAY['payment','indemnity']::TEXT[], CURRENT_DATE - 14, CURRENT_DATE + 90,  TRUE, v_admin_id, v_admin_id),
    ('MOHRE-DOMESTIC-V3',  'regulatory',       'MoHRE',                 'medium',    'Domestic Workers Standard Contract v3',           'عقد عمال المنازل القياسي - الإصدار 3',                  'Updated MoHRE template covering working hours, rest periods, end-of-service.', ARRAY['employment','termination']::TEXT[], CURRENT_DATE - 21, CURRENT_DATE + 30,  TRUE, v_admin_id, v_admin_id),
    ('TDRA-CYBER-2026',    'regulatory',       'TDRA',                  'high',      'Cybersecurity Reporting Obligations',             'التزامات الإبلاغ عن الأمن السيبراني',                  'TDRA mandates 72-hour breach notification for critical-sector contractors.', ARRAY['data_protection']::TEXT[], CURRENT_DATE - 30, CURRENT_DATE + 45,  TRUE, v_admin_id, v_admin_id),
    ('DIFC-DPR-2025',      'regulatory',       'DIFC',                  'high',      'DIFC Data Protection Regulation Amendment',       'تعديل لائحة حماية البيانات في DIFC',                    'Strengthens cross-border transfer requirements + introduces PIA obligations.', ARRAY['data_protection']::TEXT[], CURRENT_DATE - 45, CURRENT_DATE + 60,  TRUE, v_admin_id, v_admin_id),

    ('BRENT-OIL-95-2026',  'commodity_prices', 'Brent Crude',           'sharp_move','Brent crude breached $95/bbl — 18% above 90d MA', NULL, 'Sustained price action above $95/bbl materially affects fuel-indexed clauses in logistics, freight, and certain construction contracts.', ARRAY['payment','force_majeure']::TEXT[], CURRENT_DATE - 4,  CURRENT_DATE,       TRUE, v_admin_id, v_admin_id),
    ('LME-STEEL-2026',     'commodity_prices', 'LME Steel',             'volatile',  'Steel rebar prices up 14% YTD',                   NULL, 'Construction-sector materials cost escalation; review fixed-price contracts for index-tied adjustment clauses.', ARRAY['payment']::TEXT[], CURRENT_DATE - 8,  CURRENT_DATE,       TRUE, v_admin_id, v_admin_id),
    ('GOLD-LBMA-2026',     'commodity_prices', 'LBMA Gold Price',       'moderate',  'Gold up 7% MoM on geopolitical tensions',         NULL, 'Affects precious-metals trading contracts and gold-collateral facilities.', ARRAY['payment']::TEXT[], CURRENT_DATE - 12, CURRENT_DATE,       TRUE, v_admin_id, v_admin_id),

    ('JEBEL-ALI-Q2-2026',  'supply_chain',     'Jebel Ali Port',        'moderate',  'Jebel Ali Port — extended customs clearance',     NULL, 'Q2 2026 customs processing delays; SLA-bound supply contracts may need extension.', ARRAY['notice','force_majeure']::TEXT[], CURRENT_DATE - 16, NULL, TRUE, v_admin_id, v_admin_id),
    ('SUEZ-RED-SEA-2026',  'supply_chain',     'Suez Canal Authority',  'major',     'Red Sea routing — alt-route adds 14 days transit', NULL, 'Vessels rerouting around the Cape add ~14 days; trigger force majeure carve-outs.', ARRAY['force_majeure','notice']::TEXT[], CURRENT_DATE - 28, NULL, TRUE, v_admin_id, v_admin_id),
    ('UAE-AIRSPACE-2026',  'supply_chain',     'GCAA',                  'minor',     'UAE airspace congestion advisory',                NULL, 'Minor delays affecting air-cargo SLAs.', ARRAY['notice']::TEXT[], CURRENT_DATE - 35, NULL, TRUE, v_admin_id, v_admin_id),

    ('OFAC-SDN-2026',      'geopolitical',     'OFAC Updates',          'elevated',  'OFAC adds 12 entities to SDN list',               NULL, 'Sanctions screening required for affected counterparties; pause payments pending counsel review.', ARRAY['data_protection','indemnity']::TEXT[], CURRENT_DATE - 19, CURRENT_DATE,       TRUE, v_admin_id, v_admin_id),
    ('GCC-EMBARGO-2026',   'geopolitical',     'GCC Council',           'major',     'New GCC embargo on dual-use goods',                NULL, 'Restricts export of certain technologies to non-GCC jurisdictions.', ARRAY['governing_law']::TEXT[], CURRENT_DATE - 25, CURRENT_DATE,       TRUE, v_admin_id, v_admin_id),

    ('CBUAE-RATE-HOLD',    'market_financial', 'CBUAE Rate',            'shifting',  'CBUAE base rate held at 4.40%',                   NULL, 'Divergence from US Fed widening; review interest-tied loan and lease contracts.', ARRAY['payment']::TEXT[], CURRENT_DATE - 22, NULL, TRUE, v_admin_id, v_admin_id),
    ('USD-AED-PEG-2026',   'market_financial', 'AED-USD Peg',           'stable',    'AED-USD peg holds at 3.6725',                     NULL, 'No FX variance — contracts denominated in USD remain stable for AED-pegged operations.', ARRAY[]::TEXT[], CURRENT_DATE - 40, NULL, TRUE, v_admin_id, v_admin_id),
    ('DUBAI-FIRE-RE-2026', 'market_financial', 'Dubai RE Index',        'shifting',  'Dubai residential real-estate index +9% YoY',      NULL, 'Affects long-term lease pricing; review rent escalation clauses.', ARRAY['payment','termination']::TEXT[], CURRENT_DATE - 11, NULL, TRUE, v_admin_id, v_admin_id),
    ('ADGM-BANK-LIQ-2026', 'market_financial', 'ADGM Banking',          'moderate',  'ADGM bank liquidity coverage ratio adjustment',    NULL, 'Affects credit facility pricing and covenant tests.', ARRAY['payment','indemnity']::TEXT[], CURRENT_DATE - 6,  CURRENT_DATE + 30,  TRUE, v_admin_id, v_admin_id);

  -- Attach each signal to a few contracts (round-robin) when contracts exist.
  IF v_contract_ids IS NOT NULL AND array_length(v_contract_ids, 1) > 0 THEN
    FOR v_signal IN SELECT id FROM impact_signal WHERE is_seed = TRUE LOOP
      INSERT INTO impact_signal_contract (signal_id, contract_id, impact_score, status, is_seed, created_by, updated_by)
      SELECT v_signal.id, cid, 30 + (random() * 60)::INT, 'pending', TRUE, v_admin_id, v_admin_id
      FROM unnest(v_contract_ids[1:LEAST(3, array_length(v_contract_ids,1))]) AS cid
      ON CONFLICT (signal_id, contract_id) DO NOTHING;
    END LOOP;
  END IF;
END$$;

-- ROLLBACK BEGIN
-- DROP FUNCTION IF EXISTS fn_impact_signal_bulk_amend(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_impact_signal_notify_drafters(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_impact_signal_mark_reviewed(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_impact_signal_get(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER);
-- DROP TABLE IF EXISTS impact_signal_contract;
-- DROP TABLE IF EXISTS impact_signal;
-- ROLLBACK END
