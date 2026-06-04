-- MIGRATION: 500_obligation_escalation_infra.sql
-- Module: Obligations module — role-based visibility + manual flag + SLA cron infra
-- Date: 2026-06-03
-- Description:
--   1. obligation_escalation_event audit-ledger table (RLS + FORCE RLS + trigger)
--   2. system_setting seeds: role_mapping + sla_tiers
--   3. permission catalog: obligation.view.all + obligation.flag (executive + platform_admin + Super Admin)
--   4. fn_obligation_list rewritten: role-based filter + last-flag projection
--   5. fn_obligation_flag (DEFINER) — Executive manual escalation
--   6. fn_obligation_sla_check (DEFINER STABLE, cross-tenant) — worker entry
--   7. fn_obligation_sla_dispatch (DEFINER) — per-candidate worker step

BEGIN;

-- ============================================================
-- 1. obligation_escalation_event TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS obligation_escalation_event (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  obligation_id        BIGINT NOT NULL REFERENCES contract_obligation(id) ON DELETE RESTRICT,
  escalation_type      VARCHAR(20) NOT NULL CHECK (escalation_type IN ('manual', 'sla')),
  tier_day             INTEGER NULL,
  escalated_by_user_id BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  notified_role_codes  TEXT[]   NOT NULL DEFAULT '{}',
  notified_user_ids    BIGINT[] NOT NULL DEFAULT '{}',
  notification_count   INTEGER  NOT NULL DEFAULT 0,
  note                 TEXT     NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by           BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active            BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS ix_obligation_escalation_event_obligation
  ON obligation_escalation_event(tenant_id, obligation_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_obligation_escalation_event_sla_dedupe
  ON obligation_escalation_event(obligation_id, tier_day)
  WHERE escalation_type = 'sla';

ALTER TABLE obligation_escalation_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE obligation_escalation_event FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oblig_esc_event_tenant_isolation ON obligation_escalation_event;
CREATE POLICY oblig_esc_event_tenant_isolation ON obligation_escalation_event
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_obligation_escalation_event_changes ON obligation_escalation_event;
CREATE TRIGGER audit_obligation_escalation_event_changes
  AFTER INSERT OR UPDATE OR DELETE ON obligation_escalation_event
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE obligation_escalation_event IS
  'Append-only audit ledger of obligation escalations. escalation_type=manual rows come from Executive Flag action; type=sla rows from the daily SLA worker. tier_day records the SLA tier that fired (3/7/14/21) for dedupe.';


-- ============================================================
-- 2. Permissions + role grants
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES
  ('obligation.view.all', 'obligation', 'view_all',
   'See every obligation regardless of role-based filter. Granted to executive + platform_admin.',
   TRUE, NOW()),
  ('obligation.flag',     'obligation', 'flag',
   'Flag an obligation for manual escalation (sends in-app notifications to the type''s owner roles).',
   TRUE, NOW())
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE r.name IN ('executive', 'platform_admin', 'Super Admin')
  AND p.code IN ('obligation.view.all', 'obligation.flag')
ON CONFLICT DO NOTHING;


-- ============================================================
-- 3. system_setting seeds
-- ============================================================
INSERT INTO system_setting (key, category, value, description, is_secret, is_active, created_at, updated_at)
VALUES (
  'obligations.escalation.role_mapping', 'general',
  '{
    "payment":    ["finance_treasury", "contract_drafter"],
    "delivery":   ["operations", "procurement_supplier_risk"],
    "reporting":  ["compliance_esg", "legal_counsel"],
    "renewal":    ["contract_drafter", "legal_counsel", "finance_treasury"],
    "compliance": ["compliance_esg", "legal_counsel"],
    "notice":     ["legal_counsel", "contract_drafter"],
    "other":      ["contract_drafter", "legal_counsel"]
  }'::jsonb,
  'Maps obligation type → list of role names that own + see this obligation type. Drives fn_obligation_list role-based filter + the recipient set for fn_obligation_flag / fn_obligation_sla_dispatch.',
  FALSE, TRUE, NOW(), NOW()
)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();

INSERT INTO system_setting (key, category, value, description, is_secret, is_active, created_at, updated_at)
VALUES (
  'obligations.escalation.sla_tiers', 'general',
  '[
    {"tierDay": 3,  "notifyRoles": [],                                "priority": "medium"},
    {"tierDay": 7,  "notifyRoles": ["legal_counsel"],                 "priority": "high"},
    {"tierDay": 14, "notifyRoles": ["executive", "platform_admin"],   "priority": "high"},
    {"tierDay": 21, "notifyRoles": ["executive", "platform_admin"],   "priority": "critical"}
  ]'::jsonb,
  'SLA escalation tiers fired daily by obligation-sla-escalation.worker.ts. At each tier, the obligation type''s role mapping is notified PLUS the roles listed here.',
  FALSE, TRUE, NOW(), NOW()
)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();


-- ============================================================
-- 4. fn_obligation_list — role-based filter + last-flag projection
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_list(
  p_actor_id    BIGINT,
  p_status      VARCHAR DEFAULT NULL,
  p_assignee_id BIGINT  DEFAULT NULL,
  p_limit       INTEGER DEFAULT 100,
  p_offset      INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $function$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
  v_can_view_all BOOLEAN;
  v_role_mapping JSONB;
  v_visible_types TEXT[];
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_can_view_all := fn_current_user_has_permission('obligation.view.all');

  IF v_can_view_all THEN
    v_visible_types := NULL;  -- NULL = no filter
  ELSE
    SELECT value INTO v_role_mapping
    FROM system_setting WHERE key = 'obligations.escalation.role_mapping';

    IF v_role_mapping IS NULL THEN
      v_visible_types := ARRAY[]::TEXT[];
    ELSE
      SELECT COALESCE(array_agg(DISTINCT (m.obligation_type)::text), ARRAY[]::TEXT[]) INTO v_visible_types
      FROM jsonb_each(v_role_mapping) AS m(obligation_type, role_list)
      WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(m.role_list) AS role_name
        JOIN role r ON r.name = role_name AND r.is_active = TRUE
        JOIN "user" u ON u.role_id = r.id
        WHERE u.id = p_actor_id AND u.is_active = TRUE
      );
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM contract_obligation o
  WHERE o.is_active = TRUE
    AND (p_status IS NULL OR o.status = p_status)
    AND (p_assignee_id IS NULL OR o.assignee_user_id = p_assignee_id)
    AND (v_visible_types IS NULL
         OR o.obligation_type = ANY(v_visible_types)
         OR o.assignee_user_id = p_actor_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                o.id,
    'contractId',        o.contract_id,
    'contractNumber',    c.contract_number,
    'titleEn',           o.title_en,
    'titleAr',           o.title_ar,
    'descriptionEn',     o.description_en,
    'obligationType',    o.obligation_type,
    'dueDate',           o.due_date,
    'recurrence',        o.recurrence,
    'responsibleParty',  o.responsible_party,
    'assigneeUserId',    o.assignee_user_id,
    'status',            o.status,
    'completedAt',       o.completed_at,
    'createdAt',         o.created_at,
    'flaggedAt',         f.flagged_at,
    'flaggedByName',     f.flagged_by_name,
    'flaggedNote',       f.flagged_note
  ) ORDER BY (o.due_date IS NULL), o.due_date, o.id), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_obligation
    WHERE is_active = TRUE
      AND (p_status IS NULL OR status = p_status)
      AND (p_assignee_id IS NULL OR assignee_user_id = p_assignee_id)
      AND (v_visible_types IS NULL
           OR obligation_type = ANY(v_visible_types)
           OR assignee_user_id = p_actor_id)
    ORDER BY (due_date IS NULL), due_date, id
    LIMIT p_limit OFFSET p_offset
  ) o
  JOIN contract c ON c.id = o.contract_id
  LEFT JOIN LATERAL (
    SELECT
      ev.created_at AS flagged_at,
      au.first_name || ' ' || au.last_name AS flagged_by_name,
      ev.note AS flagged_note
    FROM obligation_escalation_event ev
    LEFT JOIN "user" au ON au.id = ev.escalated_by_user_id
    WHERE ev.obligation_id = o.id AND ev.escalation_type = 'manual'
    ORDER BY ev.created_at DESC
    LIMIT 1
  ) f ON TRUE;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset)
  );
END;
$function$;

COMMENT ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) IS
  'INVOKER. Lists obligations filtered by actor role unless actor holds obligation.view.all. Role → visible obligation types comes from system_setting.obligations.escalation.role_mapping. Surfaces last manual-flag event as flaggedAt / flaggedByName / flaggedNote.';
REVOKE EXECUTE ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) TO neondb_owner;


-- ============================================================
-- 5. fn_obligation_flag (DEFINER) — Executive manual escalation
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_flag(
  p_actor_id      BIGINT,
  p_obligation_id BIGINT,
  p_note          TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id     UUID;
  v_role_mapping  JSONB;
  v_oblig         contract_obligation%ROWTYPE;
  v_role_codes    TEXT[];
  v_user_ids      BIGINT[];
  v_user_id       BIGINT;
  v_notif_count   INTEGER := 0;
  v_event_id      BIGINT;
  v_contract_no   TEXT;
  v_subject       TEXT;
  v_body          TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('obligation.flag') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT * INTO v_oblig FROM contract_obligation
   WHERE id = p_obligation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'obligation_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT contract_number INTO v_contract_no FROM contract WHERE id = v_oblig.contract_id;

  SELECT value INTO v_role_mapping FROM system_setting WHERE key = 'obligations.escalation.role_mapping';

  IF v_role_mapping IS NULL THEN
    v_role_codes := ARRAY[]::TEXT[];
  ELSE
    SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_role_codes
    FROM jsonb_array_elements_text(v_role_mapping->v_oblig.obligation_type) AS role_name;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT u.id), ARRAY[]::BIGINT[]) INTO v_user_ids
  FROM "user" u
  JOIN role r ON r.id = u.role_id AND r.is_active = TRUE
  WHERE u.is_active = TRUE
    AND r.name = ANY(v_role_codes)
    AND u.id <> p_actor_id;

  IF v_oblig.assignee_user_id IS NOT NULL AND v_oblig.assignee_user_id <> p_actor_id THEN
    v_user_ids := array(SELECT DISTINCT unnest(v_user_ids || v_oblig.assignee_user_id));
  END IF;

  v_subject := 'Obligation flagged: ' || COALESCE(v_oblig.title_en, '(untitled)');
  v_body :=
    'An executive has flagged this obligation for your attention.' ||
    E'\n\nContract: '   || COALESCE(v_contract_no, '—') ||
    E'\nObligation: '   || COALESCE(v_oblig.title_en, '—') ||
    E'\nDue date: '     || COALESCE(v_oblig.due_date::text, '—') ||
    CASE WHEN p_note IS NOT NULL AND length(trim(p_note)) > 0
         THEN E'\n\nNote from executive:\n' || trim(p_note)
         ELSE ''
    END;

  INSERT INTO obligation_escalation_event (
    tenant_id, obligation_id, escalation_type, tier_day,
    escalated_by_user_id, notified_role_codes, notified_user_ids,
    notification_count, note, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_obligation_id, 'manual', NULL,
    p_actor_id, v_role_codes, v_user_ids,
    0, p_note, NOW(), p_actor_id, TRUE
  ) RETURNING id INTO v_event_id;

  FOREACH v_user_id IN ARRAY v_user_ids
  LOOP
    BEGIN
      PERFORM fn_notification_send(
        p_actor_id,
        NULL::BIGINT,
        'alert',
        'in_app',
        'high',
        v_user_id,
        NULL::TEXT,
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'obligationId', p_obligation_id,
          'contractId',   v_oblig.contract_id,
          'flagEventId',  v_event_id,
          'source',       'obligation.flag'
        ),
        NULL::BIGINT
      );
      v_notif_count := v_notif_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_obligation_flag: send to user % failed: %', v_user_id, SQLERRM;
    END;
  END LOOP;

  UPDATE obligation_escalation_event SET notification_count = v_notif_count WHERE id = v_event_id;

  PERFORM fn_audit_log_record_v2(
    'contract_obligation', p_obligation_id, 'UPDATE',
    NULL::jsonb,
    jsonb_build_object(
      'flagged',           TRUE,
      'escalationEventId', v_event_id,
      'roleCodes',         v_role_codes,
      'notificationCount', v_notif_count,
      'actionCode',        'obligation.flag'
    ),
    p_actor_id
  );

  RETURN jsonb_build_object(
    'eventId',           v_event_id,
    'roleCodes',         v_role_codes,
    'notifiedUserIds',   v_user_ids,
    'notificationCount', v_notif_count
  );
END;
$function$;

COMMENT ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) IS
  'DEFINER. Executive-driven manual escalation. Resolves the obligation type''s owner roles via system_setting.obligations.escalation.role_mapping, fans in-app notifications to those users + the assignee, inserts an obligation_escalation_event row of type=manual. Requires obligation.flag permission.';
REVOKE EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) TO neondb_owner;


-- ============================================================
-- 6. fn_obligation_sla_check (DEFINER STABLE) — worker entry
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_sla_check(
  p_limit INTEGER DEFAULT 200
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
AS $function$
DECLARE
  v_tiers JSONB;
  v_data JSONB;
BEGIN
  SELECT value INTO v_tiers FROM system_setting WHERE key = 'obligations.escalation.sla_tiers';
  IF v_tiers IS NULL THEN
    RETURN jsonb_build_object('candidates', '[]'::jsonb);
  END IF;

  WITH tiers AS (
    SELECT (t->>'tierDay')::int AS tier_day
    FROM jsonb_array_elements(v_tiers) t
  ),
  due AS (
    SELECT
      o.tenant_id,
      o.id AS obligation_id,
      o.obligation_type,
      o.assignee_user_id,
      o.contract_id,
      o.title_en,
      o.due_date,
      (CURRENT_DATE - o.due_date)::int AS days_overdue
    FROM contract_obligation o
    WHERE o.is_active = TRUE
      AND o.status IN ('open', 'in_progress', 'overdue')
      AND o.due_date IS NOT NULL
      AND o.due_date < CURRENT_DATE
  ),
  matched AS (
    SELECT d.*, t.tier_day
    FROM due d
    JOIN tiers t ON t.tier_day <= d.days_overdue
  ),
  pending AS (
    SELECT m.*
    FROM matched m
    LEFT JOIN obligation_escalation_event ev
      ON ev.obligation_id = m.obligation_id
     AND ev.escalation_type = 'sla'
     AND ev.tier_day = m.tier_day
    WHERE ev.id IS NULL
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tenantId',       p.tenant_id,
    'obligationId',   p.obligation_id,
    'obligationType', p.obligation_type,
    'contractId',     p.contract_id,
    'assigneeUserId', p.assignee_user_id,
    'titleEn',        p.title_en,
    'dueDate',        p.due_date,
    'daysOverdue',    p.days_overdue,
    'tierDay',        p.tier_day
  )), '[]'::jsonb) INTO v_data
  FROM (SELECT * FROM pending ORDER BY days_overdue DESC, tier_day DESC LIMIT p_limit) p;

  RETURN jsonb_build_object('candidates', v_data);
END;
$function$;

COMMENT ON FUNCTION fn_obligation_sla_check(INTEGER) IS
  'DEFINER STABLE. Cross-tenant. Returns pending {obligation, tier_day} pairs that have crossed an SLA tier but haven''t yet emitted an obligation_escalation_event(type=sla, tier_day=N) row.';
REVOKE EXECUTE ON FUNCTION fn_obligation_sla_check(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_sla_check(INTEGER) TO neondb_owner;


-- ============================================================
-- 7. fn_obligation_sla_dispatch (DEFINER) — per-candidate worker step
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_sla_dispatch(
  p_obligation_id BIGINT,
  p_tier_day      INTEGER
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id    UUID;
  v_oblig        contract_obligation%ROWTYPE;
  v_contract_no  TEXT;
  v_role_mapping JSONB;
  v_tiers        JSONB;
  v_tier         JSONB;
  v_priority     TEXT;
  v_extra_roles  TEXT[];
  v_type_roles   TEXT[];
  v_role_codes   TEXT[];
  v_user_ids     BIGINT[];
  v_user_id      BIGINT;
  v_notif_count  INTEGER := 0;
  v_event_id     BIGINT;
  v_subject      TEXT;
  v_body         TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_obligation_sla_dispatch: tenant_context_missing' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_oblig FROM contract_obligation
   WHERE id = p_obligation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'obligation_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- Idempotency guard (race-safe vs. the UNIQUE INDEX too)
  IF EXISTS (
    SELECT 1 FROM obligation_escalation_event
    WHERE obligation_id = p_obligation_id
      AND escalation_type = 'sla'
      AND tier_day = p_tier_day
  ) THEN
    RETURN jsonb_build_object('skipped', TRUE, 'reason', 'already_dispatched');
  END IF;

  SELECT contract_number INTO v_contract_no FROM contract WHERE id = v_oblig.contract_id;

  SELECT value INTO v_role_mapping FROM system_setting WHERE key = 'obligations.escalation.role_mapping';
  SELECT value INTO v_tiers        FROM system_setting WHERE key = 'obligations.escalation.sla_tiers';

  SELECT t INTO v_tier
  FROM jsonb_array_elements(v_tiers) t
  WHERE (t->>'tierDay')::int = p_tier_day;

  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'sla_tier_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_priority := COALESCE(v_tier->>'priority', 'high');

  SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_type_roles
  FROM jsonb_array_elements_text(v_role_mapping->v_oblig.obligation_type) AS role_name;

  SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_extra_roles
  FROM jsonb_array_elements_text(v_tier->'notifyRoles') AS role_name;

  v_role_codes := array(SELECT DISTINCT unnest(v_type_roles || v_extra_roles));

  SELECT COALESCE(array_agg(DISTINCT u.id), ARRAY[]::BIGINT[]) INTO v_user_ids
  FROM "user" u
  JOIN role r ON r.id = u.role_id AND r.is_active = TRUE
  WHERE u.is_active = TRUE AND r.name = ANY(v_role_codes);

  IF v_oblig.assignee_user_id IS NOT NULL THEN
    v_user_ids := array(SELECT DISTINCT unnest(v_user_ids || v_oblig.assignee_user_id));
  END IF;

  v_subject := 'Obligation overdue (T+' || p_tier_day || 'd): ' || COALESCE(v_oblig.title_en, '(untitled)');
  v_body :=
    'This obligation is more than ' || p_tier_day || ' day(s) overdue and has been auto-escalated.' ||
    E'\n\nContract: '   || COALESCE(v_contract_no, '—') ||
    E'\nObligation: '   || COALESCE(v_oblig.title_en, '—') ||
    E'\nDue date: '     || COALESCE(v_oblig.due_date::text, '—');

  INSERT INTO obligation_escalation_event (
    tenant_id, obligation_id, escalation_type, tier_day,
    escalated_by_user_id, notified_role_codes, notified_user_ids,
    notification_count, note, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_obligation_id, 'sla', p_tier_day,
    NULL, v_role_codes, v_user_ids,
    0, NULL, NOW(), NULL, TRUE
  ) RETURNING id INTO v_event_id;

  FOREACH v_user_id IN ARRAY v_user_ids
  LOOP
    BEGIN
      PERFORM fn_notification_send(
        0::BIGINT,            -- SYSTEM_ACTOR
        NULL::BIGINT,
        'alert',
        'in_app',
        v_priority,
        v_user_id,
        NULL::TEXT,
        jsonb_build_object(
          'subject',      v_subject,
          'bodyRendered', v_body,
          'obligationId', p_obligation_id,
          'contractId',   v_oblig.contract_id,
          'tierDay',      p_tier_day,
          'flagEventId',  v_event_id,
          'source',       'obligation.sla'
        ),
        NULL::BIGINT
      );
      v_notif_count := v_notif_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_obligation_sla_dispatch: send to user % failed: %', v_user_id, SQLERRM;
    END;
  END LOOP;

  UPDATE obligation_escalation_event SET notification_count = v_notif_count WHERE id = v_event_id;

  RETURN jsonb_build_object(
    'eventId',           v_event_id,
    'tierDay',           p_tier_day,
    'roleCodes',         v_role_codes,
    'notifiedUserIds',   v_user_ids,
    'notificationCount', v_notif_count
  );
END;
$function$;

COMMENT ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) IS
  'DEFINER. Per-candidate SLA worker step. Fans tier-N escalation notifications to the type''s owner roles + the tier''s extra roles + assignee. Inserts obligation_escalation_event(type=sla, tier_day=N) idempotently.';
REVOKE EXECUTE ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (500, '500_obligation_escalation_infra', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_obligation_sla_dispatch(BIGINT, INTEGER);
-- DROP FUNCTION IF EXISTS fn_obligation_sla_check(INTEGER);
-- DROP FUNCTION IF EXISTS fn_obligation_flag(BIGINT, BIGINT, TEXT);
-- DROP TRIGGER IF EXISTS audit_obligation_escalation_event_changes ON obligation_escalation_event;
-- DROP POLICY IF EXISTS oblig_esc_event_tenant_isolation ON obligation_escalation_event;
-- DROP TABLE IF EXISTS obligation_escalation_event;
-- DELETE FROM system_setting WHERE key IN ('obligations.escalation.role_mapping','obligations.escalation.sla_tiers');
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('obligation.view.all','obligation.flag'));
-- DELETE FROM permission WHERE code IN ('obligation.view.all','obligation.flag');
-- -- (Restore previous fn_obligation_list from migration 058)
-- DELETE FROM schema_migrations WHERE version = 500;
-- COMMIT;
