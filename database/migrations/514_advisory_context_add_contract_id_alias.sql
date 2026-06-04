-- 514_advisory_context_add_contract_id_alias.sql
-- ============================================================================
-- The 3 templates from mig 211 (Hormuz FM, Sanctions Hold, Cure Notice) use
-- {{contract_id}} in their bodies. Mig 512/513 removed that key in favour of
-- {{contract_number}}, causing unresolved placeholders to leak through.
-- This patch adds contract_id (mapped to contract_number) back to the context,
-- updates the synthesizer + the regenerate path, and re-renders unapproved
-- drafts.
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION fn_demo_synthesize_advisories_for_correlations(
  p_signal_id   BIGINT,
  p_scenario_id TEXT,
  p_actor_id    BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_inserted_count INTEGER := 0;
  v_template_id    BIGINT;
  v_template_ver   INTEGER;
  v_draft_type     TEXT;
  v_body_en_tpl    TEXT;
  v_body_ar_tpl    TEXT;
  v_template_key   TEXT;
  v_correlation    RECORD;
  v_signal         RECORD;
  v_ctx            JSONB;
  v_body_en        TEXT;
  v_body_ar        TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  v_template_key := CASE p_scenario_id
    WHEN 'brent_review'      THEN 'budget_cure_notice_v1'
    WHEN 'cyclone'           THEN 'weather_fm_notice_v1'
    WHEN 'hormuz'            THEN 'hormuz_fm_invocation_v1'
    WHEN 'ofac_sanctions'    THEN 'sanctions_hold_v1'
    WHEN 'epc_sla'           THEN 'cure_notice_v1'
    WHEN 'icv_shortfall'     THEN 'icv_rectification_notice_v1'
    WHEN 'esg_subcontractor' THEN 'esg_concern_memo_v1'
    WHEN 'renewal'           THEN 'insurance_renewal_reminder_v1'
    ELSE NULL
  END;

  IF v_template_key IS NULL THEN RETURN 0; END IF;

  SELECT id, version, body_template_en, body_template_ar, draft_type
  INTO v_template_id, v_template_ver, v_body_en_tpl, v_body_ar_tpl, v_draft_type
  FROM advisory_template
  WHERE tenant_id = v_tenant_id AND template_id = v_template_key AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT
    COALESCE(title_en, title) AS title,
    COALESCE(summary, description_en, '') AS summary,
    to_char(COALESCE(event_date_v2, published_date, NOW()), 'DD Mon YYYY') AS sig_date
  INTO v_signal
  FROM osint_signal
  WHERE id = p_signal_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    v_signal := ROW('', '', '')::RECORD;
  END IF;

  FOR v_correlation IN
    SELECT
      co.id AS correlation_id, co.contract_id, co.matched_clause_id, co.rule_id, co.match_reason,
      c.contract_number, c.title_en AS contract_title_en, c.title_ar AS contract_title_ar,
      COALESCE(p.name_en, p.name_ar, 'Counterparty') AS counterparty_name,
      CASE WHEN cce.clause_type_v2 IS NULL THEN 'applicable'
           ELSE initcap(replace(cce.clause_type_v2, '_', ' ')) END AS clause_title,
      LEFT(COALESCE(cce.summary_en, ''), 600) AS clause_excerpt
    FROM correlation co
    LEFT JOIN contract c ON c.id = co.contract_id
    LEFT JOIN party p ON p.id = c.counterparty_id
    LEFT JOIN contract_clause_extracted cce ON cce.id = co.matched_clause_id
      AND cce.tenant_id = v_tenant_id AND cce.is_active = TRUE
    WHERE co.tenant_id = v_tenant_id AND co.signal_id = p_signal_id
      AND co.status = 'active' AND co.is_active = TRUE
    ORDER BY co.id DESC
  LOOP
    v_ctx := jsonb_build_object(
      'notice_date',          to_char(CURRENT_DATE, 'DD Mon YYYY'),
      -- contract_id alias = contract_number, so legacy templates resolve cleanly.
      'contract_id',          COALESCE(v_correlation.contract_number, '—'),
      'contract_number',      COALESCE(v_correlation.contract_number, '—'),
      'contract_title',       COALESCE(v_correlation.contract_title_en, ''),
      'counterparty_name',    v_correlation.counterparty_name,
      'addressee',            v_correlation.counterparty_name,
      'signal_title',         COALESCE(v_signal.title, ''),
      'signal_summary',       COALESCE(v_signal.summary, ''),
      'signal_date',          COALESCE(v_signal.sig_date, to_char(CURRENT_DATE, 'DD Mon YYYY')),
      'clause_title',         v_correlation.clause_title,
      'clause_excerpt',       v_correlation.clause_excerpt,
      'fm_clause_text',       v_correlation.clause_title,
      'notice_period_days',   14,
      'sanctioning_authority','OFAC/EU/UN',
      'designation_date',     to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'hold_basis',           COALESCE(v_signal.summary, v_correlation.match_reason, ''),
      'breach_description',   COALESCE(v_correlation.match_reason, v_signal.summary, ''),
      'cure_period_days',     14,
      'cure_period_end_date', to_char(CURRENT_DATE + 14, 'DD Mon YYYY'),
      'cure_address',         'ADNOC Group — Legal Affairs Division'
    );

    v_body_en := fn_mustache_render(v_body_en_tpl, v_ctx);
    v_body_ar := fn_mustache_render(v_body_ar_tpl, v_ctx);

    INSERT INTO advisory_draft (
      tenant_id, correlation_id, contract_id,
      template_id, template_version, draft_type,
      generated_text_en, generated_text_ar,
      template_context, model_version, prompt_hash,
      approval_status, dispatch_recipients,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_correlation.correlation_id, v_correlation.contract_id,
      v_template_id, v_template_ver, v_draft_type,
      v_body_en, v_body_ar,
      v_ctx || jsonb_build_object(
        'scenarioId', p_scenario_id,
        'correlationId', v_correlation.correlation_id,
        'ruleId', v_correlation.rule_id,
        'demoSynthesized', TRUE
      ),
      'template-mustache-' || v_template_key,
      encode(digest(p_scenario_id || ':' || v_correlation.correlation_id::text, 'sha256'), 'hex'),
      'unapproved', '[]'::jsonb, 'demo', p_actor_id, p_actor_id
    )
    ON CONFLICT DO NOTHING;
    IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
  END LOOP;

  RETURN v_inserted_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT) TO neondb_owner;

-- Re-render all unapproved drafts so the {{contract_id}} placeholder resolves.

DO $regen$
DECLARE
  v_tenant_id UUID := '00000000-0000-0000-0000-000000000001';
  v_d         RECORD;
  v_ctx       JSONB;
  v_count     INTEGER := 0;
BEGIN
  FOR v_d IN
    SELECT
      ad.id AS draft_id, ad.template_id,
      at.body_template_en AS body_en_tpl,
      at.body_template_ar AS body_ar_tpl,
      c.contract_number,
      c.title_en AS contract_title_en,
      COALESCE(p.name_en, p.name_ar, 'Counterparty') AS counterparty_name,
      co.matched_clause_id, co.match_reason,
      cce.clause_type_v2, cce.summary_en AS clause_summary,
      os.title_en AS sig_title_en, os.title AS sig_title,
      os.summary AS sig_summary, os.description_en AS sig_description_en,
      COALESCE(os.event_date_v2, os.published_date) AS sig_date_iso
    FROM advisory_draft ad
    JOIN advisory_template at ON at.id = ad.template_id
    LEFT JOIN contract c ON c.id = ad.contract_id
    LEFT JOIN party p ON p.id = c.counterparty_id
    LEFT JOIN correlation co ON co.id = ad.correlation_id
    LEFT JOIN contract_clause_extracted cce ON cce.id = co.matched_clause_id
      AND cce.tenant_id = v_tenant_id AND cce.is_active = TRUE
    LEFT JOIN osint_signal os ON os.id = co.signal_id AND os.tenant_id = v_tenant_id
    WHERE ad.tenant_id = v_tenant_id AND ad.is_active = TRUE
      AND ad.approval_status = 'unapproved'
  LOOP
    v_ctx := jsonb_build_object(
      'notice_date',          to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'contract_id',          COALESCE(v_d.contract_number, '—'),
      'contract_number',      COALESCE(v_d.contract_number, '—'),
      'contract_title',       COALESCE(v_d.contract_title_en, ''),
      'counterparty_name',    v_d.counterparty_name,
      'addressee',            v_d.counterparty_name,
      'signal_title',         COALESCE(v_d.sig_title_en, v_d.sig_title, ''),
      'signal_summary',       COALESCE(v_d.sig_summary, v_d.sig_description_en, ''),
      'signal_date',          to_char(COALESCE(v_d.sig_date_iso, CURRENT_DATE), 'DD Mon YYYY'),
      'clause_title',         CASE WHEN v_d.clause_type_v2 IS NULL THEN 'applicable'
                                   ELSE initcap(replace(v_d.clause_type_v2, '_', ' ')) END,
      'clause_excerpt',       LEFT(COALESCE(v_d.clause_summary, ''), 600),
      'fm_clause_text',       CASE WHEN v_d.clause_type_v2 IS NULL THEN 'applicable'
                                   ELSE initcap(replace(v_d.clause_type_v2, '_', ' ')) END,
      'notice_period_days',   14,
      'sanctioning_authority','OFAC/EU/UN',
      'designation_date',     to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'hold_basis',           COALESCE(v_d.sig_summary, v_d.match_reason, ''),
      'breach_description',   COALESCE(v_d.match_reason, v_d.sig_summary, ''),
      'cure_period_days',     14,
      'cure_period_end_date', to_char(CURRENT_DATE + 14, 'DD Mon YYYY'),
      'cure_address',         'ADNOC Group — Legal Affairs Division'
    );
    UPDATE advisory_draft SET
      generated_text_en = fn_mustache_render(COALESCE(v_d.body_en_tpl, ''), v_ctx),
      generated_text_ar = fn_mustache_render(COALESCE(v_d.body_ar_tpl, ''), v_ctx),
      template_context  = COALESCE(template_context, '{}'::jsonb) || v_ctx,
      updated_at        = NOW()
    WHERE id = v_d.draft_id;
    v_count := v_count + 1;
  END LOOP;
  RAISE NOTICE 'mig 514 re-rendered % unapproved drafts', v_count;
END
$regen$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (514, 'advisory_context_add_contract_id_alias', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
