-- Migration: 200_unit3_compliance_attachment_upload_permission.sql
-- Unit: Unit-3 (R-OPS + R-FT + R-CES)
-- Description: New permission `contract.attachment.upload` so the compliance_esg role
--              can upload ICV certificates via POST /api/v1/compliance/contracts/:id/icv-certificate
--              without holding the full contract.edit grant. Also grants to the
--              standard contract-editor roles so existing attachment upload UIs stay
--              functional after we tighten the gate from contract.edit to this new
--              perm in BE code.
-- Reference: GAP-REPORT-COMPLIANCE-ESG.md H3 (ICV manual upload path), decisions AD-7.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO permission (code, module, action, description, created_at, is_active)
VALUES ('contract.attachment.upload', 'contract', 'attachment.upload', 'Upload contract attachments (general + kind-tagged: icv_certificate, signature, annex, exhibit, other).', NOW(), TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, created_at, created_by, is_active)
SELECT r.id, p.id, NOW(), 1, TRUE
FROM role r CROSS JOIN permission p
WHERE p.code = 'contract.attachment.upload'
  AND r.name IN ('compliance_esg', 'contract_drafter', 'contract_approver', 'legal_counsel', 'platform_admin', 'Super Admin')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (200, 'Unit-3 R-CES5: new permission contract.attachment.upload granted to 6 roles for ICV upload path', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission WHERE permission_id = (SELECT id FROM permission WHERE code='contract.attachment.upload');
-- DELETE FROM permission WHERE code='contract.attachment.upload';
-- DELETE FROM schema_migrations WHERE version = 200;
