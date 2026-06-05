-- MIGRATION: 554_contract_renewal_alert_infra.sql
-- Date: 2026-06-04
-- Description:
--   Executive Expiry-Cliff frame revamp — replace the toast-only "Send alerts"
--   stub with a real, persisted renewal-alert pipeline mirroring the proven
--   obligation-escalation pattern (migration 500):
--
--     1. contract_renewal_alert_event  — append-only audit ledger (FORCE RLS +
--        tenant policy + audit trigger). One row per (contract, action) burst.
--
--     2. permission contract.renewal_alert.send + role_permission grants for
--        executive / platform_admin / Super Admin.
--
--     3. fn_contract_renewal_alert_send (DEFINER) — fan in-app notifications
--        to each drafter via fn_notification_send, insert one event row per
--        contract, return {sent, skipped, eventIds}. Skips contracts where
--        the drafter is NULL or a platform role.
--
--     4. fn_dashboard_executive_expiring_contracts (REPLACE) — mask drafter
--        when role IN (platform_admin, Super Admin) so "System Admin" never
--        leaks to executives, and LATERAL-join the most-recent renewal-alert
--        event so the FE can render "Escalated" badges + checkbox-disabled
--        rows without an extra round-trip.
--
--   Reversible: ROLLBACK block at the bottom drops the fn additions, the
--   table, the permission grants, and restores fn 480's body.

BEGIN;

-- ============================================================
-- 1. contract_renewal_alert_event TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS contract_renewal_alert_event (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  contract_id          BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  window_days          INTEGER NOT NULL CHECK (window_days IN (30, 60, 90)),
  escalated_by_user_id BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  notified_user_ids    BIGINT[] NOT NULL DEFAULT '{}',
  notification_count   INTEGER  NOT NULL DEFAULT 0,
  note                 TEXT     NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by           BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active            BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS ix_contract_renewal_alert_event_contract
  ON contract_renewal_alert_event(tenant_id, contract_id, created_at DESC);

ALTER TABLE contract_renewal_alert_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_renewal_alert_event FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contract_renewal_alert_event_tenant_isolation ON contract_renewal_alert_event;
CREATE POLICY contract_renewal_alert_event_tenant_isolation ON contract_renewal_alert_event
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_contract_renewal_alert_event_changes ON contract_renewal_alert_event;
CREATE TRIGGER audit_contract_renewal_alert_event_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_renewal_alert_event
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE contract_renewal_alert_event IS
  'Append-only audit ledger for executive-fired renewal alerts on the expiry-cliff frame. Mirrors obligation_escalation_event. One row per (contract, send burst). window_days records which cliff bucket fired so we can attribute later.';


-- ============================================================
-- 2. Permission + role grants
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES
  ('contract.renewal_alert.send', 'contract', 'renewal_alert_send',
   'Send renewal alerts to drafters from the executive expiry-cliff frame.',
   TRUE, NOW())
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE r.name IN ('executive', 'platform_admin', 'Super Admin')
  AND p.code = 'contract.renewal_alert.send'
ON CONFLICT DO NOTHING;


-- ============================================================
-- 3. fn_contract_renewal_alert_send (DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_renewal_alert_send(
  p_actor_id     BIGINT,
  p_contract_ids BIGINT[],
  p_window_days  INTEGER,
  p_note         TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id      UUID;
  v_contract_id    BIGINT;
  v_drafter_id     BIGINT;
  v_drafter_role   TEXT;
  v_contract_no    TEXT;
  v_title          TEXT;
  v_end_date       DATE;
  v_subject        TEXT;
  v_body           TEXT;
  v_event_id       BIGINT;
  v_event_ids      BIGINT[] := ARRAY[]::BIGINT[];
  v_skipped        BIGINT[] := ARRAY[]::BIGINT[];
  v_sent_count     INTEGER  := 0;
  v_skipped_count  INTEGER  := 0;
BEGIN
  IF NOT fn_current_user_has_permission('contract.renewal_alert.send') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_contract_ids IS NULL OR array_length(p_contract_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'fn_contract_renewal_alert_send: no contracts'
      USING ERRCODE = '22023';
  END IF;
  IF p_window_days NOT IN (30, 60, 90) THEN
    RAISE EXCEPTION 'fn_contract_renewal_alert_send: windowDays must be 30, 60 or 90'
      USING ERRCODE = '22023';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_renewal_alert_send: tenant_context_missing'
      USING ERRCODE = '22023';
  END IF;

  FOREACH v_contract_id IN ARRAY p_contract_ids
  LOOP
    SELECT c.drafted_by, c.contract_number,
           COALESCE(c.title_en, c.title_ar), c.end_date,
           r.name
      INTO v_drafter_id, v_contract_no, v_title, v_end_date, v_drafter_role
      FROM contract c
      LEFT JOIN "user" du ON du.id = c.drafted_by
      LEFT JOIN role r ON r.id = du.role_id AND r.is_active = TRUE
     WHERE c.id = v_contract_id
       AND c.tenant_id = v_tenant_id
       AND c.is_active = TRUE;

    -- Skip: not found, no drafter, or drafter is a platform role
    IF NOT FOUND OR v_drafter_id IS NULL
       OR v_drafter_role IN ('platform_admin', 'Super Admin') THEN
      v_skipped := v_skipped || v_contract_id;
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;

    v_subject := 'Renewal alert: ' || COALESCE(v_contract_no, 'contract') ||
                 ' expires in ' || p_window_days || ' days';
    v_body :=
      'An executive has flagged this contract for renewal action.' ||
      E'\n\nContract: ' || COALESCE(v_contract_no, '—') ||
      E'\nTitle: '     || COALESCE(v_title, '—') ||
      E'\nEnd date: '  || COALESCE(v_end_date::text, '—') ||
      E'\nWindow: next ' || p_window_days || ' days' ||
      CASE
        WHEN p_note IS NOT NULL AND length(trim(p_note)) > 0
        THEN E'\n\nNote from executive:\n' || trim(p_note)
        ELSE ''
      END;

    INSERT INTO contract_renewal_alert_event (
      tenant_id, contract_id, window_days,
      escalated_by_user_id, notified_user_ids, notification_count,
      note, created_at, created_by, is_active
    ) VALUES (
      v_tenant_id, v_contract_id, p_window_days,
      p_actor_id, ARRAY[v_drafter_id]::BIGINT[], 0,
      p_note, NOW(), p_actor_id, TRUE
    ) RETURNING id INTO v_event_id;

    BEGIN
      PERFORM fn_notification_send(
        p_actor_id,
        NULL::BIGINT,
        'alert',
        'in_app',
        'high',
        v_drafter_id,
        NULL::TEXT,
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'contractId',   v_contract_id,
          'windowDays',   p_window_days,
          'eventId',      v_event_id,
          'source',       'contract.renewal_alert'
        ),
        NULL::BIGINT
      );

      UPDATE contract_renewal_alert_event
         SET notification_count = 1
       WHERE id = v_event_id;

      v_event_ids := v_event_ids || v_event_id;
      v_sent_count := v_sent_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_contract_renewal_alert_send: send to user % failed: %',
        v_drafter_id, SQLERRM;
      v_skipped := v_skipped || v_contract_id;
      v_skipped_count := v_skipped_count + 1;
    END;

    PERFORM fn_audit_log_record_v2(
      'contract', v_contract_id, 'UPDATE',
      NULL::jsonb,
      jsonb_build_object(
        'renewalAlertSent', TRUE,
        'eventId',          v_event_id,
        'windowDays',       p_window_days,
        'drafterId',        v_drafter_id,
        'actionCode',       'contract.renewal_alert.send'
      ),
      p_actor_id
    );
  END LOOP;

  RETURN jsonb_build_object(
    'sent',          v_sent_count,
    'skipped',       v_skipped_count,
    'eventIds',      v_event_ids,
    'skippedIds',    v_skipped
  );
END;
$function$;

COMMENT ON FUNCTION fn_contract_renewal_alert_send(BIGINT, BIGINT[], INTEGER, TEXT) IS
  'DEFINER. Executive-fired renewal alert: sends in-app notifications to drafters of the supplied contracts via fn_notification_send and logs one contract_renewal_alert_event per (contract, send burst). Skips contracts whose drafter is NULL or a platform role.';
REVOKE EXECUTE ON FUNCTION fn_contract_renewal_alert_send(BIGINT, BIGINT[], INTEGER, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_renewal_alert_send(BIGINT, BIGINT[], INTEGER, TEXT) TO neondb_owner;


-- ============================================================
-- 4. fn_dashboard_executive_expiring_contracts — REWRITE
-- ============================================================
CREATE OR REPLACE FUNCTION fn_dashboard_executive_expiring_contracts(
  p_window_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_role TEXT;
  v_user_id BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_expiring_contracts: unauthorized'
      USING ERRCODE = '42501';
  END IF;
  IF p_window_days < 1 OR p_window_days > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_expiring_contracts: windowDays must be 1..365'
      USING ERRCODE = '22023';
  END IF;
  SELECT r.name INTO v_role FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = v_user_id;
  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_expiring_contracts: forbidden'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'contractId',       c.id::text,
      'contractNumber',   c.contract_number,
      'titleEn',          c.title_en,
      'titleAr',          c.title_ar,
      'counterpartyId',   c.counterparty_id::text,
      'counterpartyName', cp.name_en,
      'drafterId',        CASE
                            WHEN dr.name IN ('platform_admin', 'Super Admin') THEN NULL
                            ELSE c.drafted_by::text
                          END,
      'drafterName',      CASE
                            WHEN du.id IS NULL THEN NULL
                            WHEN dr.name IN ('platform_admin', 'Super Admin') THEN NULL
                            ELSE TRIM(CONCAT(du.first_name, ' ', du.last_name))
                          END,
      'drafterEmail',     CASE
                            WHEN du.id IS NULL THEN NULL
                            WHEN dr.name IN ('platform_admin', 'Super Admin') THEN NULL
                            ELSE du.email
                          END,
      'endDate',          to_char(c.end_date, 'YYYY-MM-DD'),
      'daysToExpiry',     (c.end_date - CURRENT_DATE),
      'escalatedAt',      ev.created_at,
      'escalatedByName',  ev.escalated_by_name,
      'escalationNote',   ev.note,
      'escalationCount',  ev.escalation_count
    ) ORDER BY c.end_date ASC, c.id ASC
  ), '[]'::jsonb)
  INTO v_rows
  FROM contract c
  LEFT JOIN party cp ON cp.id = c.counterparty_id
  LEFT JOIN "user" du ON du.id = c.drafted_by
  LEFT JOIN role dr ON dr.id = du.role_id AND dr.is_active = TRUE
  LEFT JOIN LATERAL (
    SELECT
      e.created_at,
      TRIM(CONCAT(eu.first_name, ' ', eu.last_name)) AS escalated_by_name,
      e.note,
      (SELECT COUNT(*) FROM contract_renewal_alert_event
        WHERE contract_id = c.id AND is_active = TRUE) AS escalation_count
    FROM contract_renewal_alert_event e
    LEFT JOIN "user" eu ON eu.id = e.escalated_by_user_id
    WHERE e.contract_id = c.id
      AND e.is_active = TRUE
    ORDER BY e.created_at DESC
    LIMIT 1
  ) ev ON TRUE
  WHERE c.is_active = TRUE
    AND c.status IN ('active', 'fully_signed', 'expiring_soon')
    AND c.end_date IS NOT NULL
    AND c.end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + (p_window_days || ' days')::interval;

  RETURN jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       CURRENT_DATE,
    'rows',       v_rows
  );
END $$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_executive_expiring_contracts(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_executive_expiring_contracts(INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_executive_expiring_contracts(INTEGER) IS
  'Lists contracts expiring within window with drafter info + most-recent renewal-alert escalation state. Masks drafter when role IN (platform_admin, Super Admin) so the executive frame never shows "System Admin" as a target.';


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (554, '554_contract_renewal_alert_infra', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_contract_renewal_alert_send(BIGINT, BIGINT[], INTEGER, TEXT);
-- -- Restore fn 480 body to get original drafter projection back
-- (run migration 480 body)
-- DROP TRIGGER IF EXISTS audit_contract_renewal_alert_event_changes ON contract_renewal_alert_event;
-- DROP POLICY IF EXISTS contract_renewal_alert_event_tenant_isolation ON contract_renewal_alert_event;
-- DROP TABLE IF EXISTS contract_renewal_alert_event;
-- DELETE FROM role_permission WHERE permission_id IN
--   (SELECT id FROM permission WHERE code = 'contract.renewal_alert.send');
-- DELETE FROM permission WHERE code = 'contract.renewal_alert.send';
-- DELETE FROM schema_migrations WHERE version = 554;
-- COMMIT;
