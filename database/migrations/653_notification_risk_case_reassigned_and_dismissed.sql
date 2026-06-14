-- ============================================================================
-- Migration 653 — Phase E.6: notification plumbing for the 2 new event types
-- ============================================================================
-- WHY: mig 651 (reassign) + mig 652 (dismiss-as-noise) call
-- fn_notification_dispatch with two brand-new event_type codes:
--   - risk_case.reassigned         (medium priority, in-app to both owners)
--   - risk_case.dismissed_as_noise (low priority, in-app to old owner)
-- For the dispatcher to fire anything we need:
--   1. A notification_event_type row per code (catalogue).
--   2. A notification_template row per (template_slug, channel) the rule
--      targets (in_app only per locked decision E-Q6).
--   3. A notification_rule with a notification_rule_channel + a
--      notification_rule_recipient of type='context' reading notifyUserIds
--      from the payload (matches the mig 651/652 payload contract).
-- All gated by tenant_id IS NULL so they apply to every tenant by default.
-- Idempotent — ON CONFLICT DO NOTHING / DO UPDATE on every INSERT.
-- ============================================================================

BEGIN;

-- ─── 1. event_type catalogue rows ──────────────────────────────────────────
-- NOTE: notification_event_type.category is gated by a CHECK constraint that
-- pre-dates risk_case as a domain. The check whitelist (mig 579 era) does not
-- include 'risk_case'; the next best bucket is 'system' (catch-all). Both new
-- codes use category='system' here. If the whitelist is widened later, a
-- follow-up migration can flip these to 'risk_case' without churning rules.
INSERT INTO notification_event_type (code, display_name, description, category, sort_order, is_active)
VALUES
  ('risk_case.reassigned',
   'Risk case reassigned',
   'Executive moved a Tier-1 risk case from one owner to another while it was still open.',
   'system', 510, TRUE),
  ('risk_case.dismissed_as_noise',
   'Risk case dismissed as noise',
   'Executive closed a risk case (Tier-1 or Tier-2) as no_action because the underlying signal turned out to be noise.',
   'system', 511, TRUE)
ON CONFLICT (code) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      description  = EXCLUDED.description,
      category     = EXCLUDED.category,
      sort_order   = EXCLUDED.sort_order,
      is_active    = EXCLUDED.is_active,
      updated_at   = now();

-- ─── 2. templates (in_app per locked decision E-Q6) ────────────────────────
-- Templates are tenant-scoped (tenant_id NOT NULL) per the existing schema.
-- We fan out one row per tenant. The unique constraint (tenant_id,
-- template_id) lets us use ON CONFLICT for idempotency. data_classification
-- must be one of demo/pilot/production per the table CHECK; using
-- 'production' (these templates ship with the framework, no demo-only PII).
-- The fn_notification_dispatch lookup uses template_id alone (no tenant
-- filter), so any tenant's row matches at dispatch time.

INSERT INTO notification_template (
  tenant_id, template_id, channel,
  subject_en, subject_ar,
  body_en,    body_ar,
  parameter_schema, data_classification, is_active
)
SELECT t.id,
       'risk_case.reassigned.in_app',
       'in_app',
       'Risk case reassigned: {{title}}',
       'تم إعادة تعيين حالة المخاطر: {{title}}',
       '{{fromUserName}} → {{toUserName}}: you''re now the owner of "{{title}}". Open the case from My Work to review.',
       'تم نقل المخاطر "{{title}}" من {{fromUserName}} إليك ({{toUserName}}). افتح المهمة من قائمة عملي للمراجعة.',
       '{"properties": {"title": {"type": "string"}, "fromUserName": {"type": "string"}, "toUserName": {"type": "string"}}}'::jsonb,
       'production',
       TRUE
  FROM tenant t
ON CONFLICT (tenant_id, template_id) DO UPDATE
  SET subject_en          = EXCLUDED.subject_en,
      subject_ar          = EXCLUDED.subject_ar,
      body_en             = EXCLUDED.body_en,
      body_ar             = EXCLUDED.body_ar,
      parameter_schema    = EXCLUDED.parameter_schema,
      data_classification = EXCLUDED.data_classification,
      channel             = EXCLUDED.channel,
      is_active           = EXCLUDED.is_active,
      updated_at          = now();

INSERT INTO notification_template (
  tenant_id, template_id, channel,
  subject_en, subject_ar,
  body_en,    body_ar,
  parameter_schema, data_classification, is_active
)
SELECT t.id,
       'risk_case.dismissed_as_noise.in_app',
       'in_app',
       'Risk case dismissed as noise: {{title}}',
       'تم استبعاد حالة المخاطر كضوضاء: {{title}}',
       'The case "{{title}}" was closed by the executive as noise. It will no longer appear in your My Work.',
       'تم إغلاق المخاطر "{{title}}" من قبل التنفيذ كضوضاء، ولن تظهر بعد الآن في قائمة عملي.',
       '{"properties": {"title": {"type": "string"}}}'::jsonb,
       'production',
       TRUE
  FROM tenant t
ON CONFLICT (tenant_id, template_id) DO UPDATE
  SET subject_en          = EXCLUDED.subject_en,
      subject_ar          = EXCLUDED.subject_ar,
      body_en             = EXCLUDED.body_en,
      body_ar             = EXCLUDED.body_ar,
      parameter_schema    = EXCLUDED.parameter_schema,
      data_classification = EXCLUDED.data_classification,
      channel             = EXCLUDED.channel,
      is_active           = EXCLUDED.is_active,
      updated_at          = now();

-- ─── 3. rules (system-wide: tenant_id IS NULL) ─────────────────────────────
-- We need stable rule names so the upsert below stays idempotent. The
-- channel + recipient rows hang off rule_id, so we capture the IDs in
-- the DO block below.
DO $do$
DECLARE
  v_rule_reassigned BIGINT;
  v_rule_dismissed  BIGINT;
BEGIN
  -- reassigned --------------------------------------------------------------
  SELECT id INTO v_rule_reassigned
    FROM notification_rule
   WHERE tenant_id IS NULL
     AND event_type = 'risk_case.reassigned'
     AND name = 'risk_case.reassigned.system_default'
   LIMIT 1;

  IF v_rule_reassigned IS NULL THEN
    INSERT INTO notification_rule (
      tenant_id, event_type, template_id, channel, is_enabled,
      audience, condition, priority, cooldown_minutes, description,
      module, name, ordering, is_active
    ) VALUES (
      NULL, 'risk_case.reassigned', 'risk_case.reassigned.in_app', 'in_app', TRUE,
      '[]'::jsonb, '{}'::jsonb, 'medium', 0,
      'In-app notify both old + new owner on Tier-1 reassign.',
      'risk_case', 'risk_case.reassigned.system_default', 100, TRUE
    ) RETURNING id INTO v_rule_reassigned;
  END IF;

  -- Ensure channel row exists.
  INSERT INTO notification_rule_channel (rule_id, channel, template_slug, is_active)
  SELECT v_rule_reassigned, 'in_app', 'risk_case.reassigned.in_app', TRUE
   WHERE NOT EXISTS (
     SELECT 1 FROM notification_rule_channel
      WHERE rule_id = v_rule_reassigned AND channel = 'in_app'
   );

  -- Ensure recipient row exists (context resolver reads notifyUserIds from payload).
  INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active)
  SELECT v_rule_reassigned, 'context', 'notifyUserIds', TRUE
   WHERE NOT EXISTS (
     SELECT 1 FROM notification_rule_recipient
      WHERE rule_id = v_rule_reassigned
        AND recipient_type = 'context'
        AND recipient_value = 'notifyUserIds'
   );

  -- dismissed_as_noise ------------------------------------------------------
  SELECT id INTO v_rule_dismissed
    FROM notification_rule
   WHERE tenant_id IS NULL
     AND event_type = 'risk_case.dismissed_as_noise'
     AND name = 'risk_case.dismissed_as_noise.system_default'
   LIMIT 1;

  IF v_rule_dismissed IS NULL THEN
    INSERT INTO notification_rule (
      tenant_id, event_type, template_id, channel, is_enabled,
      audience, condition, priority, cooldown_minutes, description,
      module, name, ordering, is_active
    ) VALUES (
      NULL, 'risk_case.dismissed_as_noise', 'risk_case.dismissed_as_noise.in_app', 'in_app', TRUE,
      '[]'::jsonb, '{}'::jsonb, 'low', 0,
      'In-app notify previously-assigned owner when the executive dismisses a Tier-1 case as noise.',
      'risk_case', 'risk_case.dismissed_as_noise.system_default', 100, TRUE
    ) RETURNING id INTO v_rule_dismissed;
  END IF;

  INSERT INTO notification_rule_channel (rule_id, channel, template_slug, is_active)
  SELECT v_rule_dismissed, 'in_app', 'risk_case.dismissed_as_noise.in_app', TRUE
   WHERE NOT EXISTS (
     SELECT 1 FROM notification_rule_channel
      WHERE rule_id = v_rule_dismissed AND channel = 'in_app'
   );

  INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active)
  SELECT v_rule_dismissed, 'context', 'notifyUserIds', TRUE
   WHERE NOT EXISTS (
     SELECT 1 FROM notification_rule_recipient
      WHERE rule_id = v_rule_dismissed
        AND recipient_type = 'context'
        AND recipient_value = 'notifyUserIds'
   );
END
$do$;

-- Sanity assertion ───────────────────────────────────────────────────────────
DO $$
DECLARE
  v_evt INTEGER;
  v_tpl INTEGER;
  v_rul INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_evt FROM notification_event_type
   WHERE code IN ('risk_case.reassigned','risk_case.dismissed_as_noise');
  IF v_evt < 2 THEN
    RAISE EXCEPTION 'mig 653: expected 2 event_type rows (got %)', v_evt;
  END IF;

  SELECT COUNT(*) INTO v_tpl FROM notification_template
   WHERE template_id IN ('risk_case.reassigned.in_app','risk_case.dismissed_as_noise.in_app');
  IF v_tpl < 2 THEN
    RAISE EXCEPTION 'mig 653: expected 2 templates (got %)', v_tpl;
  END IF;

  SELECT COUNT(*) INTO v_rul FROM notification_rule
   WHERE event_type IN ('risk_case.reassigned','risk_case.dismissed_as_noise')
     AND name LIKE '%.system_default';
  IF v_rul < 2 THEN
    RAISE EXCEPTION 'mig 653: expected 2 rules (got %)', v_rul;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (653, 'notification_risk_case_reassigned_and_dismissed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
