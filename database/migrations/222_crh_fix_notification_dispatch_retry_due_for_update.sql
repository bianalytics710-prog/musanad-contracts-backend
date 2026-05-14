-- MIGRATION: 222_crh_fix_notification_dispatch_retry_due_for_update.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: Fix DEFECT-CRH-DB-04 — fn_notification_dispatch_retry_due used
--              FOR UPDATE SKIP LOCKED inside a SELECT with jsonb_agg() aggregate.
--              PostgreSQL prohibits FOR UPDATE with aggregate functions.
--              Fix: split into CTE that claims rows with FOR UPDATE SKIP LOCKED,
--              then wrap in outer jsonb_agg SELECT. Follows S2-24 split-aggregate pattern.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_notification_dispatch_retry_due(
  p_batch_size INTEGER DEFAULT 25
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
AS $$
DECLARE
  v_data JSONB;
BEGIN
  -- S2-24: split FOR UPDATE SKIP LOCKED claim from jsonb_agg aggregate
  -- CTE claims rows with row-level locking; outer SELECT aggregates without lock
  WITH claimed AS (
    SELECT id, channel, recipient_address, subject, body_rendered,
           retry_count, delivery_attempted_at, tenant_id
    FROM notification_dispatch_log
    WHERE status = 'pending_retry' AND next_retry_at <= NOW()
    ORDER BY next_retry_at ASC
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                   c.id,
    'channel',              c.channel,
    'recipientAddress',     c.recipient_address,
    'subject',              c.subject,
    'bodyRendered',         c.body_rendered,
    'retryCount',           c.retry_count,
    'deliveryAttemptedAt',  c.delivery_attempted_at,
    'tenantId',             c.tenant_id
  )), '[]'::jsonb) INTO v_data
  FROM claimed c;

  RETURN jsonb_build_object('data', v_data);
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_notification_dispatch_retry_due: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_dispatch_retry_due(INTEGER)
  IS 'CR-H: Claims a batch of notification_dispatch_log rows due for retry. Fix 222: CTE splits FOR UPDATE SKIP LOCKED from jsonb_agg to comply with Postgres aggregate+locking restriction (S2-24).';

REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (222, '222_crh_fix_notification_dispatch_retry_due_for_update', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Revert to the original (broken) body by re-applying migration 218 fn_notification_dispatch_retry_due.
-- DELETE FROM schema_migrations WHERE version = 222;
-- ============================================================
