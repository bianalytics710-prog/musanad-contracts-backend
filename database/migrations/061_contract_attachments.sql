-- Migration 061 — contract_attachment table + functions
--
-- Stores file metadata for files uploaded to a contract. The actual
-- bytes live in Supabase Storage (private bucket "contract-attachments")
-- — only the storage_path is held here, so we never persist file bytes
-- in Postgres.
--
-- Permissions:
--   contract.attachment.read   → drafter/approver/legal/recipient/executive/admin
--   contract.attachment.write  → drafter/admin (uploads are gated through BE
--                                that uses the Supabase service-role key)
--   contract.attachment.delete → drafter (their own contracts) + admin
--
-- Functions:
--   fn_contract_attachment_create     — inserts metadata after BE writes file to storage
--   fn_contract_attachment_list       — paginated list for a contract
--   fn_contract_attachment_get_by_id  — single row (used to resolve storage_path for signed URL)
--   fn_contract_attachment_soft_delete — sets is_active=false; BE then removes from storage

BEGIN;

CREATE TABLE contract_attachment (
  id                BIGSERIAL PRIMARY KEY,
  contract_id       BIGINT      NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  filename          VARCHAR(255) NOT NULL,
  mime_type         VARCHAR(120) NOT NULL,
  size_bytes        BIGINT       NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 50 * 1024 * 1024),
  storage_bucket    VARCHAR(120) NOT NULL DEFAULT 'contract-attachments',
  storage_path      VARCHAR(500) NOT NULL,
  uploaded_by       BIGINT       NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  description       VARCHAR(500),
  is_active         BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_by        BIGINT       NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  updated_by        BIGINT       NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  CONSTRAINT contract_attachment_storage_path_uq UNIQUE (storage_bucket, storage_path)
);

CREATE INDEX idx_contract_attachment_contract_id
  ON contract_attachment(contract_id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_attachment_uploaded_by
  ON contract_attachment(uploaded_by);
CREATE INDEX idx_contract_attachment_created_at
  ON contract_attachment(created_at DESC);

CREATE TRIGGER audit_contract_attachment_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_attachment
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

ALTER TABLE contract_attachment ENABLE ROW LEVEL SECURITY;

-- Read policy — same gate as contract read
CREATE POLICY contract_attachment_select ON contract_attachment FOR SELECT
  USING (
    is_active = TRUE
    AND EXISTS (
      SELECT 1 FROM contract c
      WHERE c.id = contract_attachment.contract_id
        AND c.is_active = TRUE
    )
  );

-- Write through fn_ only (BYPASSRLS BE service)
CREATE POLICY contract_attachment_insert ON contract_attachment FOR INSERT
  WITH CHECK (FALSE);
CREATE POLICY contract_attachment_update ON contract_attachment FOR UPDATE
  USING (FALSE) WITH CHECK (FALSE);
CREATE POLICY contract_attachment_delete ON contract_attachment FOR DELETE
  USING (FALSE);

-- Permissions
INSERT INTO permission (code, description, module, action) VALUES
  ('contract.attachment.read',   'Read contract attachments',   'contract', 'read'),
  ('contract.attachment.write',  'Upload contract attachments', 'contract', 'write'),
  ('contract.attachment.delete', 'Delete contract attachments', 'contract', 'delete')
ON CONFLICT (code) DO NOTHING;

-- Grant attachment.read to all roles that can read contracts
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, 1
FROM role r, permission p
WHERE p.code IN ('contract.attachment.read')
  AND r.name IN ('contract_drafter', 'contract_approver', 'legal_counsel',
                 'contract_recipient', 'executive', 'platform_admin', 'super_admin')
ON CONFLICT DO NOTHING;

-- Grant attachment.write to drafter + admin
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, 1
FROM role r, permission p
WHERE p.code IN ('contract.attachment.write')
  AND r.name IN ('contract_drafter', 'platform_admin', 'super_admin')
ON CONFLICT DO NOTHING;

-- Grant attachment.delete to drafter + admin
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, 1
FROM role r, permission p
WHERE p.code IN ('contract.attachment.delete')
  AND r.name IN ('contract_drafter', 'platform_admin', 'super_admin')
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────
-- fn_contract_attachment_create
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_contract_attachment_create(
  p_contract_id   BIGINT,
  p_filename      TEXT,
  p_mime_type     TEXT,
  p_size_bytes    BIGINT,
  p_storage_path  TEXT,
  p_description   TEXT,
  p_actor_user_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id     BIGINT;
  v_exists BOOLEAN;
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_attachment_create: actor required'
      USING ERRCODE = '23503';
  END IF;
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_attachment_create: %', 'contractId:Contract id required'
      USING ERRCODE = '23503';
  END IF;
  SELECT TRUE INTO v_exists FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_attachment_create: %', 'contractId:Contract not found'
      USING ERRCODE = '23503';
  END IF;
  IF p_filename IS NULL OR LENGTH(TRIM(p_filename)) = 0 THEN
    RAISE EXCEPTION 'fn_contract_attachment_create: %', 'filename:Filename required'
      USING ERRCODE = '23502';
  END IF;
  IF p_size_bytes IS NULL OR p_size_bytes <= 0 OR p_size_bytes > 50 * 1024 * 1024 THEN
    RAISE EXCEPTION 'fn_contract_attachment_create: %', 'sizeBytes:Size must be 1B - 50MB'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO contract_attachment (
    contract_id, filename, mime_type, size_bytes, storage_path,
    description, uploaded_by, created_by, updated_by
  ) VALUES (
    p_contract_id, p_filename, p_mime_type, p_size_bytes, p_storage_path,
    p_description, p_actor_user_id, p_actor_user_id, p_actor_user_id
  )
  RETURNING id INTO v_id;

  -- attachmentCount on contract is computed dynamically inside
  -- fn_contract_get_by_id (M1a) — no denormalised counter to bump.

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id',        v_id,
      'contractId', p_contract_id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_attachment_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_attachment_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────────────────
-- fn_contract_attachment_list
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_contract_attachment_list(
  p_contract_id   BIGINT,
  p_actor_user_id BIGINT,
  p_actor_role    TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows   JSONB;
  v_can    BOOLEAN;
BEGIN
  -- Permission gate: contract.attachment.read OR contract.read.all
  SELECT TRUE INTO v_can
  FROM role r
  JOIN role_permission rp ON rp.role_id = r.id
  JOIN permission p ON p.id = rp.permission_id
  WHERE r.code = p_actor_role
    AND p.code IN ('contract.attachment.read', 'contract.read.all');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_attachment_list: %', 'forbidden:Permission denied'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',           a.id,
    'contractId',   a.contract_id,
    'filename',     a.filename,
    'mimeType',     a.mime_type,
    'sizeBytes',    a.size_bytes,
    'description',  a.description,
    'storageBucket', a.storage_bucket,
    'storagePath',  a.storage_path,
    'uploadedBy',   jsonb_build_object(
                      'id',        u.id,
                      'firstName', u.first_name,
                      'lastName',  u.last_name
                    ),
    'createdAt',    a.created_at
  ) ORDER BY a.created_at DESC), '[]'::jsonb)
    INTO v_rows
    FROM contract_attachment a
    JOIN "user" u ON u.id = a.uploaded_by
   WHERE a.contract_id = p_contract_id
     AND a.is_active = TRUE;

  RETURN jsonb_build_object('data', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_attachment_list(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_attachment_list(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────────────────
-- fn_contract_attachment_get_by_id (used to resolve storage_path for signed URL)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_contract_attachment_get_by_id(
  p_attachment_id BIGINT,
  p_actor_user_id BIGINT,
  p_actor_role    TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row JSONB;
  v_can BOOLEAN;
BEGIN
  SELECT TRUE INTO v_can
  FROM role r
  JOIN role_permission rp ON rp.role_id = r.id
  JOIN permission p ON p.id = rp.permission_id
  WHERE r.code = p_actor_role
    AND p.code IN ('contract.attachment.read', 'contract.read.all');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_attachment_get_by_id: %', 'forbidden:Permission denied'
      USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',            a.id,
    'contractId',    a.contract_id,
    'filename',      a.filename,
    'mimeType',      a.mime_type,
    'sizeBytes',     a.size_bytes,
    'storageBucket', a.storage_bucket,
    'storagePath',   a.storage_path,
    'description',   a.description,
    'uploadedBy',    a.uploaded_by,
    'createdAt',     a.created_at
  )
    INTO v_row
    FROM contract_attachment a
   WHERE a.id = p_attachment_id
     AND a.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'fn_contract_attachment_get_by_id: %', 'attachmentId:Not found'
      USING ERRCODE = '02000';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_attachment_get_by_id(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_attachment_get_by_id(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────────────────
-- fn_contract_attachment_soft_delete
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_contract_attachment_soft_delete(
  p_attachment_id BIGINT,
  p_actor_user_id BIGINT,
  p_actor_role    TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract_id BIGINT;
  v_can         BOOLEAN;
BEGIN
  SELECT TRUE INTO v_can
  FROM role r
  JOIN role_permission rp ON rp.role_id = r.id
  JOIN permission p ON p.id = rp.permission_id
  WHERE r.code = p_actor_role
    AND p.code = 'contract.attachment.delete';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_attachment_soft_delete: %', 'forbidden:Permission denied'
      USING ERRCODE = '42501';
  END IF;

  UPDATE contract_attachment
     SET is_active   = FALSE,
         updated_at  = NOW(),
         updated_by  = p_actor_user_id
   WHERE id = p_attachment_id
     AND is_active = TRUE
   RETURNING contract_id INTO v_contract_id;
  IF v_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_attachment_soft_delete: %', 'attachmentId:Not found or already deleted'
      USING ERRCODE = '02000';
  END IF;

  -- attachmentCount on contract is computed dynamically — no decrement needed.

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id',         p_attachment_id,
      'contractId', v_contract_id,
      'deleted',    TRUE
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_attachment_soft_delete(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_attachment_soft_delete(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- Record migration
INSERT INTO schema_migrations (version, applied_at, description)
VALUES (61, NOW(), 'contract_attachment table + create/list/get/soft_delete functions')
ON CONFLICT (version) DO NOTHING;

COMMIT;
