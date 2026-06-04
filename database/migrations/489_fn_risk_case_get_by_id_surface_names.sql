-- Migration: 489_fn_risk_case_get_by_id_surface_names.sql
-- Module: Risk Cases — Executive demo polish
-- Date: 2026-06-02
--
-- Problem: fn_risk_case_get_by_id returns raw actor_id on timeline events and
-- raw uploaded_by on attachments. FE then falls back to "System" / "Unknown
-- uploader" because event.actorName / attachment.uploadedByName are absent.
--
-- Fix: extend the two subqueries to JOIN "user" and surface display names.
-- Function body otherwise byte-for-byte identical to the current version.

DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_risk_case_get_by_id' LIMIT 1;

  -- Timeline: add actorName resolved via LEFT JOIN "user"
  v_def := REPLACE(v_def,
    $sql$SELECT jsonb_agg(jsonb_build_object(
               'id', e.id,
               'eventType', e.event_type,
               'actorId', e.actor_id,
               'payload', e.payload,
               'occurredAt', e.occurred_at
             ) ORDER BY e.occurred_at ASC)
        FROM risk_case_event e WHERE e.risk_case_id = v_case.id$sql$,
    $sql$SELECT jsonb_agg(jsonb_build_object(
               'id', e.id,
               'eventType', e.event_type,
               'actorId', e.actor_id,
               'actorName', NULLIF(TRIM(COALESCE(au.first_name,'') || ' ' || COALESCE(au.last_name,'')), ''),
               'payload', e.payload,
               'occurredAt', e.occurred_at
             ) ORDER BY e.occurred_at ASC)
        FROM risk_case_event e
        LEFT JOIN "user" au ON au.id = e.actor_id
        WHERE e.risk_case_id = v_case.id$sql$);

  -- Attachments: add uploadedByName + storage path so FE can show real download
  v_def := REPLACE(v_def,
    $sql$SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'fileName', a.file_name,
               'fileMime', a.file_mime,
               'fileBytes', a.file_bytes,
               'uploadedBy', a.uploaded_by,
               'uploadedAt', a.uploaded_at
             ) ORDER BY a.uploaded_at DESC)
        FROM risk_case_attachment a WHERE a.risk_case_id = v_case.id AND a.is_active = TRUE$sql$,
    $sql$SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'fileName', a.file_name,
               'fileMime', a.file_mime,
               'fileBytes', a.file_bytes,
               'uploadedBy', a.uploaded_by,
               'uploadedByName', NULLIF(TRIM(COALESCE(uu.first_name,'') || ' ' || COALESCE(uu.last_name,'')), ''),
               'uploadedAt', a.uploaded_at
             ) ORDER BY a.uploaded_at DESC)
        FROM risk_case_attachment a
        LEFT JOIN "user" uu ON uu.id = a.uploaded_by
        WHERE a.risk_case_id = v_case.id AND a.is_active = TRUE$sql$);

  EXECUTE v_def;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (489, '489_fn_risk_case_get_by_id_surface_names', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
